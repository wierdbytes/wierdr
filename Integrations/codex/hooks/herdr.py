#!/usr/bin/env python3
"""
Codex hooks for herdr and Wierdr: `herdr.py <event>` with the hook's JSON
on stdin. Writes the `agent.*` labels on the herdr-core terminal Codex runs
in and folds the ChatGPT subscription limits into herdr-core's `limits`
document, as @wierdbytes/pi-wierdr does for pi.

Prints nothing (a SessionStart or UserPromptSubmit hook's stdout becomes
model context) and always exits 0: a broken hook must never disturb Codex.

Events (hooks/hooks.json):
  session-start       SessionStart: every label (fires at the first prompt)
  prompt              UserPromptSubmit: model, effort, window
  pre-model-request   PreModelRequest (async): a sub-agent at work (the main
                      agent's exit at once)
  post-model-request  PostModelRequest (async): the context, or a sub-agent
                      at work; the limits at most every 30 s
  post-compact        PostCompact: the context after compaction
  subagent-start      SubagentStart: a sub-agent at work
  subagent-stop       SubagentStop: a sub-agent's turn ended
  agent-tool          PostToolUse of close_agent / resume_agent: the sub-agents
  stop                Stop: every label again, and the limits
  session-end         SessionEnd: remove every label
"""

from __future__ import annotations

import contextlib
import json
import os
import signal
import socket
import sys
import time
from typing import Any, Callable, Dict, Iterator, Optional, Set

# The plugin root is Codex's copy of the plugin: leave no bytecode in it.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import guard  # noqa: E402
import hc  # noqa: E402
import limits  # noqa: E402
import meta  # noqa: E402
import rollout  # noqa: E402
import subagents  # noqa: E402

try:
    import fcntl
except ImportError:  # not on Windows, where Codex would run another command anyway
    fcntl = None  # type: ignore

INTERACTIVE_SOURCES = ("cli", "vscode")
LIMITS_EVERY_S = 30
STDIN_MAX = 4 << 20

# Which labels each event changes once the terminal carries this Codex's labels.
EVENT_KEYS = {
    "session-start": meta.LABEL_KEYS,
    "stop": meta.LABEL_KEYS,
    "prompt": ("agent.model", "agent.model_id", "agent.provider", "agent.effort", "agent.ctx_max", "agent.session",
               "agent.subagents", "agent.subagents_meta"),
    "post-model-request": ("agent.ctx",),
    "post-compact": ("agent.ctx", "agent.ctx_max"),
}
# The session's own events: they may write every label when the terminal doesn't carry them yet.
SESSION_EVENTS = tuple(EVENT_KEYS)
# Events about sub-agents: they only change `agent.subagents` and `agent.subagents_meta`, and
# only once the session published. A model request is one when it carries `agent_id`.
AGENT_EVENTS = ("subagent-start", "subagent-stop", "agent-tool")
MODEL_REQUESTS = ("pre-model-request", "post-model-request")
AGENT_KEYS = ("agent.subagents", "agent.subagents_meta")
# Events that read the rollout for the labels.
SCANS = ("session-start", "prompt", "post-compact", "stop")


def _int_label(value: Any) -> Optional[int]:
    return int(value) if isinstance(value, str) and value.isdigit() else None


class Hook:
    def __init__(self, event: str, payload: Dict[str, Any], env: Dict[str, str], *, parent: Optional[int] = None,
                 lookup: Optional[Callable[[int], Any]] = None, now: Optional[Callable[[], float]] = None):
        self.event = event
        self.payload = payload
        self.env = env
        self.parent = parent if parent is not None else os.getppid()
        self._lookup = lookup
        self.now = now or time.time
        self.started_at = self.now()
        self.started = time.monotonic()
        self.terminal_id = env.get("HC_TERMINAL_ID") or ""
        self.socket = env.get("HC_TERMINAL_SOCKET") or ""
        home = env.get("HOME") or os.path.expanduser("~")
        self.codex_home = env.get("CODEX_HOME") or os.path.join(home, ".codex")
        self.data = env.get("PLUGIN_DATA") or os.path.join(self.codex_home, "plugins", "data", "codex-wierdr")
        self.doc_name = env.get("WIERDR_CODEX_LIMITS_DOC") or limits.LIMITS_DOC
        self.debug = bool(env.get("WIERDR_CODEX_DEBUG"))
        self.transcript = payload.get("transcript_path") if isinstance(payload.get("transcript_path"), str) else None
        self.session = payload.get("session_id") if isinstance(payload.get("session_id"), str) else None
        agent = payload.get("agent_id")
        self.agent_id = agent if isinstance(agent, str) and agent else None
        self.core = hc.Core(self.socket)
        self.trace: Dict[str, Any] = {"event": event}
        self._head: Any = False
        self._tail: Optional[rollout.Tail] = None
        self._tail_limits = False
        self._models: Any = False
        self._agents: Optional[Any] = None

    # ---- small readers ----

    def head(self) -> Optional[Dict[str, Any]]:
        if self._head is False:
            self._head = rollout.read_head(self.transcript)
        return self._head

    def tail(self, want_limits: bool) -> rollout.Tail:
        if self._tail is None or (want_limits and not self._tail_limits):
            self._tail = rollout.scan(self.transcript, want_limits)
            self._tail_limits = want_limits
        return self._tail

    def models(self) -> Dict[str, Any]:
        if self._models is False:
            self._models = {}
            try:
                with open(os.path.join(self.codex_home, "models_cache.json"), "rb") as f:
                    cache = json.loads(f.read().decode("utf-8"))
                for m in cache.get("models") or []:
                    if isinstance(m, dict) and isinstance(m.get("slug"), str):
                        self._models[m["slug"]] = m
            except Exception:
                pass
        return self._models

    def lookup(self):
        if self._lookup is None:
            self._lookup = guard.default_lookup()
        return self._lookup

    # ---- state under PLUGIN_DATA ----

    def state_path(self, name: str) -> str:
        return os.path.join(self.data, name)

    def read_state(self, name: str) -> Dict[str, Any]:
        try:
            with open(self.state_path(name), "rb") as f:
                value = json.loads(f.read().decode("utf-8"))
            return value if isinstance(value, dict) else {}
        except Exception:
            return {}

    def write_state(self, name: str, value: Dict[str, Any]) -> None:
        try:
            os.makedirs(self.data, exist_ok=True)
            path = self.state_path(name)
            tmp = "%s.%d.tmp" % (path, os.getpid())
            with open(tmp, "wb") as f:
                f.write(json.dumps(value).encode("utf-8"))
            os.replace(tmp, path)
        except Exception:
            pass

    def remove_state(self, name: str) -> None:
        for path in (self.state_path(name), self.state_path(name) + ".lock"):
            try:
                os.remove(path)
            except OSError:
                pass

    @contextlib.contextmanager
    def locked(self, name: str, wait_s: float = 2.0) -> Iterator[None]:
        """Hooks run concurrently: one read-modify-write of a state file at a time (best effort)."""
        fd = None
        try:
            os.makedirs(self.data, exist_ok=True)
            fd = os.open(self.state_path(name) + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
            deadline = time.monotonic() + wait_s
            while fcntl is not None:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        break
                    time.sleep(0.02)
        except Exception:
            pass
        try:
            yield
        finally:
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass

    @staticmethod
    def _safe(text: Optional[str]) -> str:
        return "".join(c if c.isalnum() or c in "-_" else "_" for c in (text or ""))[:80]

    def ctx_state(self) -> str:
        return "ctx-%s.json" % self._safe(self.terminal_id)

    def agents_state(self) -> str:
        return "agents-%s.json" % self._safe(self.session)

    # ---- the run ----

    def run(self) -> None:
        if not self.socket:
            return
        if self.event == "pre-model-request" and not self.agent_id:
            return  # the main agent's request: nothing to tell yet
        try:
            self.track_agents()
            if self.terminal_id:
                if self.event == "session-end":
                    self.clear_labels()
                else:
                    self.publish_labels()
            if self.event in ("post-model-request", "stop"):
                self.publish_limits()
        finally:
            self.core.close()
            self.log()

    def track_agents(self) -> None:
        """Marks a sub-agent at work or done, with what the hook tells of it (see subagents.py)."""
        what = None
        if self.event == "subagent-start" or (self.event in MODEL_REQUESTS and self.agent_id):
            what = "active"
        elif self.event == "subagent-stop":
            what = "done"
        if not what or not self.agent_id or not self.session:
            return
        p = self.payload
        # Its own rollout: SubagentStart's and its model requests' transcript, SubagentStop's
        # agent_transcript_path (its transcript_path is the parent's). Kept only when it is the agent's.
        path = p.get("agent_transcript_path") if self.event == "subagent-stop" else self.transcript
        if isinstance(path, str) and path:
            head = rollout.read_head(path)
            if not isinstance(head, dict) or head.get("id") != self.agent_id:
                path = None
        else:
            path = None
        ctx = None
        if self.event == "post-model-request":
            usage = p.get("token_usage")
            total = usage.get("total_tokens") if isinstance(usage, dict) else None
            ctx = total if isinstance(total, int) and not isinstance(total, bool) and total > 0 else None
        model = p.get("model") if self.event != "subagent-stop" else None
        name = self.agents_state()
        turn = p.get("turn_id")
        with self.locked(name):
            agents = self.read_state(name)
            self.write_state(name, subagents.note(
                agents, self.agent_id, what, turn if isinstance(turn, str) else None, int(self.started_at * 1000),
                start=self.event == "subagent-start", path=path,
                agent_type=p.get("agent_type") if isinstance(p.get("agent_type"), str) else None,
                model=model if isinstance(model, str) else None, ctx=ctx))

    def agent_labels(self) -> Dict[str, str]:
        """`agent.subagents` and `agent.subagents_meta` from the session's sub-agents (see subagents.py)."""
        if self._agents is not None:
            return self._agents
        self._agents = {"agent.subagents": "", "agent.subagents_meta": ""}
        agents = self.read_state(self.agents_state()) if self.session else {}
        if not subagents.working_ids(agents):
            return self._agents
        db = subagents.state_db(self.codex_home, self.env.get("CODEX_SQLITE_HOME"))
        closed = subagents.closed_agents(db, self.session)
        tails: Dict[str, rollout.Tail] = {}

        def tail_of(agent_id: str, entry: Dict[str, Any]) -> rollout.Tail:
            if agent_id not in tails:
                path = entry.get("path") if isinstance(entry.get("path"), str) else None
                tails[agent_id] = rollout.scan(path, want_limits=False, want_turn=True)
            return tails[agent_id]

        def ended(agent_id: str, entry: Dict[str, Any]) -> Set[str]:
            tail = tail_of(agent_id, entry)
            latest = tail.latest_turn
            return subagents.ended_turns(entry, tail.turns_ended, latest, tail.turn_started.get(latest) if latest else None)

        ids = subagents.working_ids(agents, closed, ended)
        entries = {}
        for agent_id in ids:
            try:
                entries[agent_id] = self.agent_entry(agents[agent_id], tail_of(agent_id, agents[agent_id]))
            except Exception:
                entries[agent_id] = subagents.meta_entry()
        self._agents = {
            "agent.subagents": str(len(ids)) if ids else "",
            "agent.subagents_meta": subagents.meta_label(entries),
        }
        return self._agents

    def agent_entry(self, entry: Dict[str, Any], tail: rollout.Tail) -> Dict[str, Any]:
        """One running sub-agent's row: what its rollout says, else what its hooks told."""
        path = entry.get("path") if isinstance(entry.get("path"), str) else None
        head = rollout.read_head(path) if path else None
        title, name = subagents.describe(head, entry.get("type") if isinstance(entry.get("type"), str) else None)
        seen = entry.get("seen") if isinstance(entry.get("seen"), dict) else {}
        latest = tail.latest_turn
        turns = subagents.running_turns(entry, subagents.ended_turns(entry, tail.turns_ended, latest, tail.turn_started.get(latest) if latest else None))
        since = None
        if turns:
            began = tail.turn_started.get(turns[0])
            since = began * 1000 if isinstance(began, (int, float)) else seen.get(turns[0])
        hooked = entry.get("model") if isinstance(entry.get("model"), str) else None
        model_id = tail.model if tail.effort_known and tail.model else hooked
        info = self.models().get(model_id) if model_id else None
        info = info if isinstance(info, dict) else {}
        if tail.effort_known:
            effort = tail.effort
        else:
            level = info.get("default_reasoning_level")
            effort = level if isinstance(level, str) else None
        ctx = tail.ctx
        hook_ctx, hook_at = entry.get("ctx"), entry.get("ctx_at")
        if isinstance(hook_ctx, int) and isinstance(hook_at, (int, float)):
            if ctx is None or (tail.ctx_at or 0) * 1000 < hook_at:
                ctx = hook_ctx
        ctx_max = tail.ctx_max if tail.ctx_max is not None else self.window(info)
        # Its spawn: when its thread was made (the rollout's first line), else when its
        # SubagentStart hook ran (a second or so later), else its first hook.
        at = rollout.iso_to_unix((head or {}).get("timestamp"))
        times = [t for t in (entry.get("started"), at * 1000 if at is not None else None) if isinstance(t, (int, float))]
        times = times or [v for v in seen.values() if isinstance(v, (int, float))]
        started = min(times) if times else None
        display = info.get("display_name") if isinstance(info.get("display_name"), str) else None
        return subagents.meta_entry(
            title=title, name=name, since=since,
            model=meta.model_name(model_id, display) if model_id else None, model_id=model_id,
            effort=meta.effort_label(effort), ctx=ctx, ctx_max=ctx_max, started=started)

    @staticmethod
    def window(info: Dict[str, Any]) -> Optional[int]:
        """The model's context window as Codex works with it: its window times its effective share."""
        if not isinstance(info.get("context_window"), int):
            return None
        pct = info.get("effective_context_window_percent")
        pct = pct if isinstance(pct, (int, float)) and 0 < pct <= 100 else 100
        return int(info["context_window"] * pct / 100)

    def own_terminal(self, check_source: bool = True):
        """(terminal, codex pid) when this hook belongs to the interactive Codex in the terminal."""
        terminal = self.core.terminal(self.terminal_id)
        if terminal is None:
            self.trace["skip"] = "no terminal"
            return None
        fg = terminal.get("foreground") if isinstance(terminal.get("foreground"), dict) else {}
        pid = guard.codex_pid(fg.get("pid"), self.parent, self.lookup())
        if pid is None:
            self.trace["skip"] = "not the foreground's hook (fg %s)" % fg.get("pid")
            return None
        if check_source:
            head = self.head()
            if head is not None:
                source = head.get("source")
                if not (isinstance(source, str) and source in INTERACTIVE_SOURCES):
                    self.trace["skip"] = "source %s" % json.dumps(source)[:60]
                    return None
            elif guard.foreground_runs_exec(fg.get("argv")):
                self.trace["skip"] = "exec"
                return None
        return terminal, pid

    def publish_labels(self) -> None:
        agent_event = self.event in AGENT_EVENTS or (self.event in MODEL_REQUESTS and self.agent_id)
        if not agent_event and (self.event not in SESSION_EVENTS or self.agent_id):
            return  # a sub-agent's prompt or compaction: not the session's model or context
        # A sub-agent's hook carries the sub-agent's transcript: the session owns the labels already.
        own = self.own_terminal(check_source=not agent_event)
        if own is None:
            return
        terminal, pid = own
        current = terminal.get("labels") if isinstance(terminal.get("labels"), dict) else {}
        owned = meta.owns(current, pid, self.session)
        if agent_event:
            if not owned:
                self.trace["skip"] = "not published yet"
                return
            change = meta.diff(current, self.agent_labels(), AGENT_KEYS)
        else:
            full = self.event == "session-start" or not owned
            self.trace["full"] = full
            keys = meta.LABEL_KEYS if full else EVENT_KEYS[self.event]
            change = meta.diff(current, self.wanted(pid, full, current), keys)
        self.trace["labels"] = change
        if change:
            self.trace["sent"] = self.core.label(self.terminal_id, change)

    def wanted(self, pid: int, full: bool, current: Dict[str, Any]) -> Dict[str, str]:
        """Every label as this event sees it; what the event doesn't read keeps the terminal's value."""
        p = self.payload
        kept = {k: current.get(k) if isinstance(current.get(k), str) else "" for k in meta.LABEL_KEYS}
        scan = full or self.event in SCANS
        tail = self.tail(want_limits=self.event == "stop") if scan else None
        model_id = p.get("model") if isinstance(p.get("model"), str) and p.get("model") else None
        if tail is not None and not model_id:
            model_id = tail.model
        if not model_id:
            model_id = kept["agent.model_id"] or None
        info = self.models().get(model_id) if model_id else None
        info = info if isinstance(info, dict) else {}
        head = self.head() or {}

        if tail is not None and tail.effort_known:
            effort = tail.effort
        elif tail is not None:
            level = info.get("default_reasoning_level")
            effort = level if isinstance(level, str) else None
        else:
            effort = kept["agent.effort"] or None

        ctx: Optional[int] = None
        if self.event == "post-model-request":
            usage = p.get("token_usage")
            total = usage.get("total_tokens") if isinstance(usage, dict) else None
            if isinstance(total, int) and not isinstance(total, bool) and total > 0:
                ctx = total
                self.write_state(self.ctx_state(), {"session": self.session, "ctx": total, "at": self.started_at})
            else:
                ctx = _int_label(kept["agent.ctx"])
        elif tail is not None:
            ctx = tail.ctx
            # A response's token_count reaches the rollout only after its tools ran: a newer
            # PostModelRequest value wins until then.
            last = self.read_state(self.ctx_state())
            if last.get("session") == self.session and isinstance(last.get("ctx"), int):
                if tail.ctx is None or (tail.ctx_at or 0) < float(last.get("at") or 0):
                    ctx = last["ctx"]
        else:
            ctx = _int_label(kept["agent.ctx"])

        ctx_max = tail.ctx_max if tail is not None else None
        if ctx_max is None:
            ctx_max = self.window(info)
        if ctx_max is None:
            ctx_max = _int_label(kept["agent.ctx_max"])

        if full or self.event in ("stop", "prompt"):
            agents = self.agent_labels()
        else:
            agents = {k: kept[k] for k in AGENT_KEYS}

        provider = head.get("model_provider")
        return meta.build_labels(
            pid=pid,
            session=self.session or kept["agent.session"] or None,
            model_id=model_id,
            model_display=info.get("display_name") if isinstance(info.get("display_name"), str) else None,
            provider=provider if isinstance(provider, str) and provider else None,
            effort=effort,
            ctx=ctx,
            ctx_max=ctx_max,
            subagents=_int_label(agents["agent.subagents"]),
            subagents_meta=agents["agent.subagents_meta"] or None,
        )

    def clear_labels(self) -> None:
        own = self.own_terminal()
        if own is None:
            return
        terminal, pid = own
        current = terminal.get("labels") if isinstance(terminal.get("labels"), dict) else {}
        if current.get("agent.app") != meta.APP or current.get("agent.pid") != str(pid):
            self.trace["skip"] = "labels not ours"
            return
        change = meta.removal(current)
        self.trace["labels"] = change
        if change:
            self.trace["sent"] = self.core.label(self.terminal_id, change)
        self.remove_state(self.ctx_state())
        if self.session:
            self.remove_state(self.agents_state())

    # ---- limits ----

    def account(self) -> Dict[str, str]:
        try:
            with open(os.path.join(self.codex_home, "auth.json"), "rb") as f:
                found = limits.account_from_auth(f.read().decode("utf-8"))
        except Exception:
            found = {}
        if "id" not in found:
            creator = (self.head() or {}).get("creator_account_id")
            if isinstance(creator, str) and creator:
                found["id"] = creator
        return found

    def publish_limits(self) -> None:
        name = "limits.json"
        if self.event == "post-model-request" and self.now() - float(self.read_state(name).get("last") or 0) < LIMITS_EVERY_S:
            return
        with self.locked(name):
            state = self.read_state(name)
            now = self.now()
            if self.event == "post-model-request" and now - float(state.get("last") or 0) < LIMITS_EVERY_S:
                return
            tail = self.tail(want_limits=True)
            written = state.get("written") if isinstance(state.get("written"), dict) else {}
            batch = []
            account = None
            for limit_id, (raw, at) in sorted(tail.rate_limits.items()):
                at = at if isinstance(at, (int, float)) else now
                if float(written.get(limit_id) or 0) >= at:
                    continue  # this report is in the document already
                reading = limits.reading_from_rate_limits(raw)
                if reading is None:
                    continue
                if account is None:
                    found = self.account()
                    account = {"slug": limits.account_slug(found.get("id"))}
                    if found.get("label"):
                        account["label"] = found["label"]
                batch.append((reading, account, at, limit_id))
            self.trace["limits"] = [b[3] for b in batch]
            if not batch:
                return
            ok = limits.write_readings(self.core, self.doc_name, [(r, a, int(t)) for r, a, t, _ in batch], socket.gethostname() or None)
            self.trace["limits_ok"] = ok
            if ok:
                for _, _, at, limit_id in batch:
                    written[limit_id] = max(float(written.get(limit_id) or 0), at)
                self.write_state(name, {"last": now, "written": written})

    def log(self) -> None:
        if not self.debug:
            return
        self.trace.update(
            ms=int((time.monotonic() - self.started) * 1000),
            at=round(self.started_at, 3),
            pid=os.getpid(),
            ppid=self.parent,
            session=self.session,
            agent_id=self.agent_id,
            turn_id=self.payload.get("turn_id"),
        )
        try:
            os.makedirs(self.data, exist_ok=True)
            with open(self.state_path("debug.log"), "a") as f:
                f.write(json.dumps(self.trace) + "\n")
        except Exception:
            pass


def _bail(*_args) -> None:
    os._exit(0)


def main(argv) -> int:
    event = argv[1] if len(argv) > 1 else ""
    try:
        # Stay inside the hook's timeout: SessionEnd gets 3 s, the others 10.
        signal.signal(signal.SIGALRM, _bail)
        signal.alarm(2 if event == "session-end" else 8)
    except Exception:
        pass
    try:
        sys.stdout = open(os.devnull, "w")
        raw = sys.stdin.buffer.read(STDIN_MAX)
        payload = json.loads(raw.decode("utf-8")) if raw.strip() else {}
        if not isinstance(payload, dict):
            payload = {}
        Hook(event, payload, dict(os.environ)).run()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
