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
counts. The database is read-only here.
"""

from __future__ import annotations

import glob
import os
import sqlite3
from typing import Any, Dict, Optional, Set
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


def mark(agents: Dict[str, Any], agent_id: str, what: str, turn_id: Optional[str]) -> Dict[str, Any]:
    """`agents` with turn `turn_id` of `agent_id` marked `active` or `done`."""
    out = {k: {kk: list(vv) for kk, vv in v.items() if isinstance(vv, list)} for k, v in agents.items() if isinstance(v, dict)}
    entry = out.setdefault(agent_id, {})
    turns = [t for t in entry.get(what, []) if t != (turn_id or "?")]
    entry[what] = (turns + [turn_id or "?"])[-KEEP_TURNS:]
    return out


def working(agents: Dict[str, Any], closed: Optional[Set[str]] = None) -> int:
    """Agents with an active turn that isn't done, and that Codex hasn't closed."""
    count = 0
    for agent_id, entry in agents.items():
        if not isinstance(entry, dict):
            continue
        if closed and agent_id in closed:
            continue
        active = entry.get("active") if isinstance(entry.get("active"), list) else []
        done = entry.get("done") if isinstance(entry.get("done"), list) else []
        if set(active) - set(done):
            count += 1
    return count
