"""
Is this hook Codex's own, the Codex that runs in the terminal?

Plain `codex` (0.167+) hands the model loop, the tools and the hooks to a
shared `codex app-server` daemon, one per CODEX_HOME, which keeps the
environment of the terminal that started it: every terminal's hooks then
carry that first terminal's HC_TERMINAL_ID. Only an embedded Codex
(`--no-daemon`) runs its hooks as its own children, with its own terminal
in the environment. So labels are written only when the terminal's
foreground program (the Codex TUI, or the wrapper that started it) is one of
the hook's nearest ancestors, and no app-server sits in between.
"""

from __future__ import annotations

import os
import subprocess
from typing import Callable, Dict, List, Optional, Tuple

Proc = Tuple[int, str]  # (ppid, command line)
Table = Callable[[int], Optional[Proc]]

MAX_DEPTH = 4


def ps_table() -> Dict[int, Proc]:
    """Every process's parent and command line, from one `ps` run."""
    try:
        out = subprocess.run(
            ["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "command="],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=4,
            check=False,
        ).stdout.decode("utf-8", "replace")
    except Exception:
        return {}
    table: Dict[int, Proc] = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        table[pid] = (ppid, parts[2] if len(parts) > 2 else "")
    return table


def chain(start: int, lookup: Table, depth: int = MAX_DEPTH) -> List[Tuple[int, str]]:
    """`start` and its ancestors, nearest first, at most `depth` of them."""
    out: List[Tuple[int, str]] = []
    pid = start
    seen = set()
    while pid > 1 and len(out) < depth and pid not in seen:
        seen.add(pid)
        proc = lookup(pid)
        if proc is None:
            break
        out.append((pid, proc[1]))
        pid = proc[0]
    return out


def is_app_server(command: str) -> bool:
    words = command.split()
    return "app-server" in words


def codex_pid(foreground_pid: Optional[int], parent: int, lookup: Table, depth: int = MAX_DEPTH) -> Optional[int]:
    """
    The foreground pid when it is the hook's parent or one of its nearest
    ancestors (a shell between them, an npm wrapper above the native binary)
    and no `codex app-server` stands in between; None otherwise.
    """
    if not isinstance(foreground_pid, int) or foreground_pid <= 1:
        return None
    for pid, command in chain(parent, lookup, depth):
        if pid == foreground_pid:
            return pid
        if is_app_server(command):
            return None
    return None


def foreground_runs_exec(argv) -> bool:
    """`codex exec ...` in the foreground: a one-shot run, not the interactive Codex."""
    if not isinstance(argv, list):
        return False
    return any(isinstance(a, str) and a in ("exec", "e", "review") for a in argv[1:2]) or "exec" in argv[1:]


def lookup_from(table: Dict[int, Proc]) -> Table:
    return table.get


def proc_lookup(pid: int) -> Optional[Proc]:
    """Linux: a process's parent and command line from /proc, without running anything."""
    try:
        with open("/proc/%d/stat" % pid, "rb") as f:
            stat = f.read().decode("utf-8", "replace")
        ppid = int(stat[stat.rindex(")") + 2 :].split()[1])
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            command = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        return ppid, command
    except Exception:
        return None


def default_lookup() -> Table:
    if os.path.isdir("/proc/self") and os.path.exists("/proc/self/stat"):
        return proc_lookup
    return lookup_from(ps_table())


def own_parent() -> int:
    return os.getppid()
