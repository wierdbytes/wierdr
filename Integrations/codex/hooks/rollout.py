"""
What the thread's rollout (`transcript_path`, Codex's JSONL of the thread)
says about the session. No hook carries the effort, the context window or
the rate limits; the rollout has them:

- the first line, `session_meta`: who runs it (`source`: cli, vscode for the
  app-server, exec, a sub-agent), the model provider, the account;
- per turn, `turn_context` {model, effort}; a `/model` between turns as
  `event_msg` `thread_settings_applied` {thread_settings{model, reasoning_effort}};
- `event_msg` `task_started` {model_context_window} at each turn's start;
- after each response `event_msg` `token_count` {info{last_token_usage,
  model_context_window}, rate_limits{limit_id, primary, secondary, plan_type}}.

Rollouts grow long, so the tail is read backwards in chunks until the
latest of each is found (or a byte budget is spent). Pure apart from file
reads.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any, Dict, Iterator, Optional, Set

HEAD_MAX = 1 << 20  # session_meta carries the base instructions: ~20 KB
TAIL_CHUNK = 64 << 10
TAIL_MAX = 8 << 20


def iso_to_unix(value: Any) -> Optional[float]:
    """An RFC 3339 time (`2026-11-18T19:07:45.503Z`) as unix seconds."""
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    # Python < 3.11 takes at most six fraction digits.
    if "." in text:
        head, _, rest = text.partition(".")
        digits = ""
        i = 0
        while i < len(rest) and rest[i].isdigit():
            digits += rest[i]
            i += 1
        text = head + "." + (digits[:6] or "0") + rest[i:]
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.timestamp()


def read_head(path: Optional[str]) -> Optional[Dict[str, Any]]:
    """The `session_meta` payload on the rollout's first line."""
    if not path:
        return None
    try:
        with open(path, "rb") as f:
            line = f.readline(HEAD_MAX)
    except OSError:
        return None
    try:
        item = json.loads(line.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(item, dict) or item.get("type") != "session_meta":
        return None
    payload = item.get("payload")
    return payload if isinstance(payload, dict) else None


def tail_lines(path: str, chunk: int = TAIL_CHUNK, budget: int = TAIL_MAX) -> Iterator[bytes]:
    """The file's complete lines, last first, reading at most `budget` bytes."""
    try:
        f = open(path, "rb")
    except OSError:
        return
    with f:
        try:
            f.seek(0, os.SEEK_END)
            end = f.tell()
        except OSError:
            return
        pos = end
        rest = b""
        spent = 0
        while pos > 0 and spent < budget:
            size = min(chunk, pos)
            pos -= size
            spent += size
            f.seek(pos)
            data = f.read(size) + rest
            lines = data.split(b"\n")
            # The first piece may be the end of a line that starts earlier.
            rest = lines[0]
            for line in reversed(lines[1:]):
                if line.strip():
                    yield line
        if pos == 0 and rest.strip():
            yield rest


class Tail:
    """The latest of everything the labels and the limits need."""

    def __init__(self) -> None:
        self.model: Optional[str] = None
        self.effort: Optional[str] = None
        self.effort_known = False  # the latest turn_context / thread_settings_applied was seen
        self.ctx: Optional[int] = None
        self.ctx_at: Optional[float] = None
        self.ctx_max: Optional[int] = None
        # limit_id -> (rate_limits payload, unix seconds of the line)
        self.rate_limits: Dict[str, Any] = {}
        # Turns seen from the end back to the latest `task_started`: turn id -> when it
        # started (unix seconds) and which ended (`task_complete`, `turn_aborted`).
        self.turn_started: Dict[str, Optional[float]] = {}
        self.turns_ended: Set[str] = set()
        self.latest_turn: Optional[str] = None
        self.lines = 0

    def as_dict(self) -> Dict[str, Any]:
        return {
            "model": self.model,
            "effort": self.effort,
            "ctx": self.ctx,
            "ctx_max": self.ctx_max,
            "rate_limits": sorted(self.rate_limits),
        }


def _int(value: Any) -> Optional[int]:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value == value:
        return int(value)
    return None


def scan_lines(lines: Iterator[bytes], want_limits: bool = True, max_lines: int = 20000, want_turn: bool = False) -> Tail:
    """
    Reads lines last first until the latest settings, usage and window are
    known (`want_turn`: and the latest turn's start).
    """
    tail = Tail()
    have_usage = False
    for raw in lines:
        tail.lines += 1
        if tail.lines > max_lines:
            break
        # Cheap filter before parsing: most lines are messages and tool output.
        if b'"turn_context"' not in raw and b'"event_msg"' not in raw:
            continue
        try:
            item = json.loads(raw.decode("utf-8"))
        except Exception:
            continue
        if not isinstance(item, dict):
            continue
        kind = item.get("type")
        payload = item.get("payload")
        if not isinstance(payload, dict):
            continue
        if kind == "turn_context":
            if not tail.effort_known:
                tail.effort_known = True
                tail.model = payload.get("model") if isinstance(payload.get("model"), str) else None
                tail.effort = payload.get("effort") if isinstance(payload.get("effort"), str) else None
        elif kind == "event_msg":
            event = payload.get("type")
            if event == "thread_settings_applied":
                settings = payload.get("thread_settings")
                if not tail.effort_known and isinstance(settings, dict):
                    tail.effort_known = True
                    model = settings.get("model")
                    effort = settings.get("reasoning_effort")
                    tail.model = model if isinstance(model, str) else None
                    tail.effort = effort if isinstance(effort, str) else None
            elif event == "token_count":
                info = payload.get("info")
                if not have_usage and isinstance(info, dict):
                    last = info.get("last_token_usage")
                    total = _int(last.get("total_tokens")) if isinstance(last, dict) else None
                    if total is not None:
                        have_usage = True
                        tail.ctx = total
                        tail.ctx_at = iso_to_unix(item.get("timestamp"))
                    if tail.ctx_max is None:
                        tail.ctx_max = _int(info.get("model_context_window"))
                limits = payload.get("rate_limits")
                if want_limits and isinstance(limits, dict):
                    limit_id = limits.get("limit_id") if isinstance(limits.get("limit_id"), str) else "codex"
                    if limit_id not in tail.rate_limits:
                        tail.rate_limits[limit_id] = (limits, iso_to_unix(item.get("timestamp")))
            elif event in ("task_complete", "turn_aborted"):
                if isinstance(payload.get("turn_id"), str):
                    tail.turns_ended.add(payload["turn_id"])
            elif event == "task_started":
                if tail.ctx_max is None:
                    tail.ctx_max = _int(payload.get("model_context_window"))
                turn = payload.get("turn_id")
                if isinstance(turn, str) and turn not in tail.turn_started:
                    tail.turn_started[turn] = iso_to_unix(item.get("timestamp"))
                    if tail.latest_turn is None:
                        tail.latest_turn = turn
                # Other limit families come in token_count events of their own: the
                # windows of the turn the usage came from are all read by its start.
                if want_limits and have_usage and tail.effort_known and tail.ctx_max is not None:
                    break
        if not want_limits and tail.effort_known and have_usage and tail.ctx_max is not None and (not want_turn or tail.turn_started):
            break
    return tail


def scan(path: Optional[str], want_limits: bool = True, want_turn: bool = False) -> Tail:
    if not path:
        return Tail()
    return scan_lines(tail_lines(path), want_limits, want_turn=want_turn)
