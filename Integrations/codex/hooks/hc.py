"""
The smallest herdr-core client the hooks need: JSON-RPC lines over the
socket herdr-core hands every terminal (`HC_TERMINAL_SOCKET`), as
@wierdbytes/pi-wierdr talks to it. One connection per hook run, one line per
request, one line per answer: `terminal.get` (the foreground pid and the
labels), `terminal.label` (empty value removes), `doc.get` / `doc.set`.

Never raises: a missing core, a broken answer or a timeout come back as an
error kind (`unreachable`, `bad_reply`, `timeout`), like herdr-core's own
error kinds (`conflict`, `not_found`...).
"""

from __future__ import annotations

import json
import socket
import time
from typing import Any, Dict, Optional, Tuple

Reply = Tuple[bool, Any]  # (True, result) or (False, error kind)


def parse_reply(line: bytes, request_id: int) -> Reply:
    """herdr-core's answer line to request `request_id`."""
    try:
        reply = json.loads(line.decode("utf-8"))
    except Exception:
        return False, "bad_reply"
    if not isinstance(reply, dict) or reply.get("id") != request_id:
        return False, "bad_reply"
    error = reply.get("error")
    if error is not None:
        kind = None
        if isinstance(error, dict):
            data = error.get("data")
            kind = data.get("kind") if isinstance(data, dict) else None
            kind = kind or error.get("message")
        return False, str(kind or "error")
    if "result" in reply:
        return True, reply["result"]
    return False, "bad_reply"


class Core:
    """A connection to herdr-core, opened on the first call."""

    def __init__(self, path: str, timeout: float = 1.5):
        self.path = path
        self.timeout = timeout
        self._sock: Optional[socket.socket] = None
        self._buf = b""
        self._next = 1

    def _connect(self) -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.path)
        self._sock = s

    def call(self, method: str, params: Dict[str, Any]) -> Reply:
        request_id = self._next
        self._next += 1
        line = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n"
        try:
            if self._sock is None:
                self._connect()
            assert self._sock is not None
            self._sock.sendall(line.encode("utf-8"))
            deadline = time.monotonic() + self.timeout
            while True:
                newline = self._buf.find(b"\n")
                if newline >= 0:
                    answer, self._buf = self._buf[:newline], self._buf[newline + 1 :]
                    if not answer.strip():
                        continue
                    ok, result = parse_reply(answer, request_id)
                    if not ok and result == "bad_reply" and _is_other_id(answer, request_id):
                        continue  # a notification or a stale answer
                    return ok, result
                left = deadline - time.monotonic()
                if left <= 0:
                    self.close()
                    return False, "timeout"
                self._sock.settimeout(left)
                chunk = self._sock.recv(65536)
                if not chunk:
                    self.close()
                    return False, "unreachable"
                self._buf += chunk
        except socket.timeout:
            self.close()
            return False, "timeout"
        except Exception:
            self.close()
            return False, "unreachable"

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except Exception:
                pass
        self._sock = None
        self._buf = b""

    # The methods the hooks use.

    def terminal(self, terminal: str) -> Optional[Dict[str, Any]]:
        ok, result = self.call("terminal.get", {"terminal": terminal})
        if not ok or not isinstance(result, dict):
            return None
        # Older cores wrap it; the current one answers with the terminal itself.
        inner = result.get("terminal")
        return inner if isinstance(inner, dict) else result

    def label(self, terminal: str, labels: Dict[str, str]) -> bool:
        if not labels:
            return True
        ok, _ = self.call("terminal.label", {"terminal": terminal, "labels": labels})
        return ok

    def doc_get(self, name: str) -> Optional[Tuple[Any, int]]:
        ok, result = self.call("doc.get", {"name": name})
        if not ok or not isinstance(result, dict) or not isinstance(result.get("version"), int):
            return None
        return result.get("value"), result["version"]

    def doc_set(self, name: str, value: Any, version: int):
        """The new version, "conflict" when someone wrote in between, None on any other failure."""
        ok, result = self.call("doc.set", {"name": name, "value": value, "version": version})
        if not ok:
            return "conflict" if result == "conflict" else None
        version = result.get("version") if isinstance(result, dict) else None
        return version if isinstance(version, int) else None


def _is_other_id(line: bytes, request_id: int) -> bool:
    try:
        reply = json.loads(line.decode("utf-8"))
    except Exception:
        return False
    return isinstance(reply, dict) and reply.get("id") != request_id
