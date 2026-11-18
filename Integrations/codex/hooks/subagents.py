"""
How many sub-agents of a Codex session are working. Sub-agents run inside
the Codex process (no terminal, no OSC 7501 records of their own), so the
hooks keep the count themselves, per session, in a small state file:

- SubagentStart (a spawn) and a sub-agent's model request (`agent_id` set,
  also in a follow-up turn of an idle agent) mark that turn of the agent
  active;
- SubagentStop (the end of each sub-agent turn) marks that turn done;
- an agent counts while one of its active turns isn't done.

Hook processes run concurrently and land out of order (a turn's last
model-request hook can start after its SubagentStop hook), so the marks are
sets of turn ids, not times. Codex's state database adds what the hooks
can't see: an agent closed (`thread_spawn_edges.status` = `closed`) never
counts. The database is read-only here. So does the sub-agent's rollout:
a turn it records as ended (`task_complete`, `turn_aborted`: an interrupt
fires no SubagentStop) doesn't count either.

The same entries make `agent.subagents_meta`, one row per sub-agent at
work (`describe`, `meta_label`): its task path and nickname from its
rollout's `session_meta`, `running` since its turn started, its model,
effort and context. A sub-agent between turns isn't listed: Codex keeps it
resumable until `close_agent`, which models rarely call, so nothing tells
an agent that will be asked again from one that never will.
"""

from __future__ import annotations

import glob
import json
import os
import sqlite3
from typing import Any, Callable, Dict, List, Optional, Set, Tuple
from urllib.parse import quote

CLOSED_QUERY = """
WITH RECURSIVE tree(id, status, depth) AS (
  SELECT child_thread_id, status, 1 FROM thread_spawn_edges WHERE parent_thread_id = ?
  UNION
  SELECT e.child_thread_id, e.status, t.depth + 1 FROM thread_spawn_edges e JOIN tree t ON e.parent_thread_id = t.id
  WHERE t.depth < 16
)
SELECT DISTINCT id FROM tree WHERE status = 'closed'
"""


def state_db(codex_home: str, sqlite_home: Optional[str] = None) -> Optional[str]:
    """`state_5.sqlite` (or the newest `state_<n>.sqlite`) under CODEX_SQLITE_HOME or CODEX_HOME."""
    root = sqlite_home or codex_home
    path = os.path.join(root, "state_5.sqlite")
    if os.path.isfile(path):
        return path
    found = []
    for p in glob.glob(os.path.join(root, "state_*.sqlite")):
        try:
            found.append((int(os.path.basename(p)[6:-7]), p))
        except ValueError:
            continue
    return max(found)[1] if found else None


def closed_agents(db: Optional[str], session_id: Optional[str]) -> Set[str]:
    """The sub-agents under `session_id` Codex has closed; empty when the database can't tell."""
    if not db or not session_id:
        return set()
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % quote(db), uri=True, timeout=0.5)
    except Exception:
        return set()
    try:
        return {row[0] for row in conn.execute(CLOSED_QUERY, (session_id,)).fetchall()}
    except Exception:
        return set()
    finally:
        conn.close()


KEEP_TURNS = 32


KEEP_AGENTS = 64


def _copy(agents: Dict[str, Any]) -> Dict[str, Any]:
    return {k: json.loads(json.dumps(v)) for k, v in agents.items() if isinstance(v, dict)}


def _list(entry: Dict[str, Any], key: str) -> List[str]:
    value = entry.get(key)
    return [t for t in value if isinstance(t, str)] if isinstance(value, list) else []


def _num(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        return None
    return float(value)


def mark(agents: Dict[str, Any], agent_id: str, what: str, turn_id: Optional[str]) -> Dict[str, Any]:
    """`agents` with turn `turn_id` of `agent_id` marked `active` or `done`."""
    out = _copy(agents)
    entry = out.setdefault(agent_id, {})
    turns = [t for t in _list(entry, what) if t != (turn_id or "?")]
    entry[what] = (turns + [turn_id or "?"])[-KEEP_TURNS:]
    return out


def note(
    agents: Dict[str, Any],
    agent_id: str,
    what: str,
    turn_id: Optional[str],
    at_ms: int,
    *,
    start: bool = False,
    path: Optional[str] = None,
    agent_type: Optional[str] = None,
    model: Optional[str] = None,
    ctx: Optional[int] = None,
) -> Dict[str, Any]:
    """
    `mark`, and what the hook tells of the agent: when each turn was first
    seen (`seen`, turn id -> epoch ms; hooks land out of order, so the
    earliest), when it was spawned (`started`: its SubagentStart), its
    rollout, role, model and the context its latest response reported
    (`ctx`, `ctx_at` epoch ms).
    """
    out = mark(agents, agent_id, what, turn_id)
    entry = out[agent_id]
    turn = turn_id or "?"
    seen = entry.get("seen") if isinstance(entry.get("seen"), dict) else {}
    first = _num(seen.get(turn))
    seen[turn] = int(min(first, at_ms)) if first is not None else int(at_ms)
    keep = set(_list(entry, "active")) | set(_list(entry, "done"))
    entry["seen"] = {k: v for k, v in seen.items() if k in keep}
    if start:
        before = _num(entry.get("started"))
        entry["started"] = int(min(before, at_ms)) if before is not None else int(at_ms)
    if isinstance(path, str) and path:
        entry["path"] = path
    if isinstance(agent_type, str) and agent_type:
        entry["type"] = agent_type
    if isinstance(model, str) and model:
        entry["model"] = model
    if isinstance(ctx, int) and not isinstance(ctx, bool) and ctx > 0 and at_ms >= (_num(entry.get("ctx_at")) or 0):
        entry["ctx"] = ctx
        entry["ctx_at"] = int(at_ms)
    if len(out) > KEEP_AGENTS:
        def last_seen(item):
            s = item[1].get("seen") if isinstance(item[1].get("seen"), dict) else {}
            return max([_num(v) or 0 for v in s.values()] or [0])
        out = dict(sorted(out.items(), key=last_seen)[-KEEP_AGENTS:])
    return out


def running_turns(entry: Dict[str, Any], ended: Optional[Set[str]] = None) -> List[str]:
    """The agent's turns marked active, not done and not ended in its rollout, the latest first."""
    done = set(_list(entry, "done")) | (ended or set())
    seen = entry.get("seen") if isinstance(entry.get("seen"), dict) else {}
    turns = [t for t in _list(entry, "active") if t not in done]
    return sorted(turns, key=lambda t: _num(seen.get(t)) or 0, reverse=True)


def ended_turns(entry: Dict[str, Any], ended: Set[str], latest: Optional[str], latest_at: Optional[float]) -> Set[str]:
    """
    The agent's turns over as its rollout tells (read from the end back to its
    latest `task_started`): the ones it records as ended, and, since a thread
    runs one turn at a time, any other first seen before the latest turn
    started (`latest_at`, unix seconds). A turn its hooks saw that the rollout
    doesn't have yet (just started) isn't over.
    """
    out = set(ended)
    if latest is None or latest_at is None:
        return out
    seen = entry.get("seen") if isinstance(entry.get("seen"), dict) else {}
    for turn in _list(entry, "active"):
        at = _num(seen.get(turn))
        if turn != latest and at is not None and at < latest_at * 1000:
            out.add(turn)
    return out


def working_ids(agents: Dict[str, Any], closed: Optional[Set[str]] = None,
                ended: Optional[Callable[[str, Dict[str, Any]], Set[str]]] = None) -> List[str]:
    """
    The agents at work, sorted: an active turn that isn't done, Codex hasn't
    closed them, and (`ended(agent_id, entry)`: the turns their rollout
    records as ended) their rollout doesn't say the turn is over.
    """
    out = []
    for agent_id, entry in agents.items():
        if not isinstance(entry, dict) or (closed and agent_id in closed):
            continue
        if not running_turns(entry):
            continue
        if ended is not None and not running_turns(entry, ended(agent_id, entry)):
            continue
        out.append(agent_id)
    return sorted(out)


def working(agents: Dict[str, Any], closed: Optional[Set[str]] = None) -> int:
    """Agents with an active turn that isn't done, and that Codex hasn't closed."""
    return len(working_ids(agents, closed))


# ---- agent.subagents_meta ----


def describe(head: Optional[Dict[str, Any]], agent_type: Optional[str] = None) -> Tuple[Optional[str], Optional[str]]:
    """
    (title, name) of a sub-agent from its rollout's `session_meta`, as Codex
    names it. Codex's TUI tells a sub-agent by its task path ("Started
    `/root/probe`", the footer, what `send_message` targets): the title is
    that path under the root agent (`probe`, `probe/check` one level down).
    The name is its nickname (`Euler`, the agent picker's). Without a path
    (the older multi-agent tools), the title is what the picker shows:
    `Euler [explorer]`.
    """
    head = head if isinstance(head, dict) else {}
    source = head.get("source")
    spawn = {}
    if isinstance(source, dict) and isinstance(source.get("subagent"), dict):
        found = source["subagent"].get("thread_spawn")
        spawn = found if isinstance(found, dict) else {}

    def text(*values: Any) -> Optional[str]:
        for v in values:
            if isinstance(v, str) and v.strip():
                return v.strip()
        return None

    path = text(spawn.get("agent_path"), head.get("agent_path"))
    nickname = text(spawn.get("agent_nickname"), head.get("agent_nickname"))
    role = text(spawn.get("agent_role"), head.get("agent_role"), None if agent_type == "default" else agent_type)
    title = None
    if path:
        rest = path[len("/root/"):] if path.startswith("/root/") else path.lstrip("/")
        title = rest or path
    elif nickname:
        title = "%s [%s]" % (nickname, role) if role else nickname
    elif role:
        title = "[%s]" % role
    return title, nickname


def meta_entry(
    *,
    title: Optional[str] = None,
    name: Optional[str] = None,
    since: Optional[float] = None,
    model: Optional[str] = None,
    model_id: Optional[str] = None,
    effort: Optional[str] = None,
    ctx: Optional[int] = None,
    ctx_max: Optional[int] = None,
    started: Optional[float] = None,
) -> Dict[str, Any]:
    """One running sub-agent's value in `agent.subagents_meta`; fields not known left out."""
    entry: Dict[str, Any] = {}
    if title:
        entry["title"] = title
    if name:
        entry["name"] = name
    entry["status"] = "running"
    if since is not None and since > 0:
        entry["since"] = int(since)
    if model:
        entry["model"] = model
    if model_id:
        entry["model_id"] = model_id
    if effort:
        entry["effort"] = effort
    if isinstance(ctx, int) and ctx > 0:
        entry["ctx"] = ctx
    if isinstance(ctx_max, int) and ctx_max > 0:
        entry["ctx_max"] = ctx_max
    if started is not None and started > 0:
        entry["started"] = int(started)
    return entry


def meta_label(entries: Dict[str, Dict[str, Any]]) -> str:
    """`agent.subagents_meta`: compact JSON by agent id, ids sorted; `""` (remove) when none."""
    if not entries:
        return ""
    return json.dumps({k: entries[k] for k in sorted(entries)}, separators=(",", ":"), ensure_ascii=False)
