"""Shared test helpers: the hooks' modules on sys.path, real-shaped rollout lines, a fake core."""

from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import sys
import tempfile
import threading

HOOKS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hooks")
if HOOKS not in sys.path:
    sys.path.insert(0, HOOKS)

SESSION = "01a1f00e-2d8b-7632-a9b7-b9081882b0a3"


def line(obj) -> str:
    return json.dumps(obj) + "\n"


def session_meta(source="cli", provider="openai", account="acct-1"):
    return line({
        "timestamp": "2026-11-18T19:07:03.100Z",
        "type": "session_meta",
        "payload": {
            "id": SESSION, "session_id": SESSION, "source": source, "thread_source": "user",
            "cli_version": "0.170.0", "originator": "codex-tui", "model_provider": provider,
            "creator_account_id": account, "base_instructions": {"text": "x" * 20000},
        },
    })


def task_started(ts, window=258400):
    return line({"timestamp": ts, "type": "event_msg", "payload": {"type": "task_started", "turn_id": "t", "model_context_window": window}})


def turn_context(ts, model="gpt-6-luna", effort="low"):
    return line({"timestamp": ts, "type": "turn_context", "payload": {"turn_id": "t", "model": model, "effort": effort, "cwd": "/tmp"}})


def settings_applied(ts, model="gpt-6-luna", effort="low"):
    return line({"timestamp": ts, "type": "event_msg", "payload": {"type": "thread_settings_applied", "thread_id": SESSION,
                 "thread_settings": {"model": model, "model_provider_id": "openai", "reasoning_effort": effort}}})


def message(ts, text="hello"):
    return line({"timestamp": ts, "type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}})


def token_count(ts, total, window=258400, limit_id="codex", limit_name=None, primary=(3.0, 300, 1795030046), secondary=(6.0, 10080, 1795159821), plan="plus", reached=None):
    usage = {"input_tokens": total - 5, "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": 5, "reasoning_output_tokens": 0, "total_tokens": total}
    limits = {"limit_id": limit_id, "limit_name": limit_name,
              "primary": {"used_percent": primary[0], "window_minutes": primary[1], "resets_at": primary[2]} if primary else None,
              "secondary": {"used_percent": secondary[0], "window_minutes": secondary[1], "resets_at": secondary[2]} if secondary else None,
              "credits": {"has_credits": False, "unlimited": False, "balance": "0"}, "plan_type": plan, "rate_limit_reached_type": reached}
    return line({"timestamp": ts, "type": "event_msg", "payload": {"type": "token_count",
                 "info": {"total_token_usage": usage, "last_token_usage": usage, "model_context_window": window}, "rate_limits": limits}})


def jwt(claims) -> str:
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")
    return "%s.%s.%s" % (enc({"alg": "none"}), enc(claims), "sig")


def auth_json(account_id="acct-1", email="me@example.com", put_account=True) -> str:
    claims = {"email": email, "https://api.openai.com/auth": {"chatgpt_account_id": account_id, "chatgpt_plan_type": "plus"}}
    tokens = {"id_token": jwt(claims), "access_token": "secret-access", "refresh_token": "secret-refresh"}
    if put_account:
        tokens["account_id"] = account_id
    return json.dumps({"auth_mode": "chatgpt", "OPENAI_API_KEY": None, "tokens": tokens, "last_refresh": "2026-11-18T00:00:00Z"})


class FakeCore:
    """A herdr-core socket: terminal.get / terminal.label / doc.get / doc.set, recording every request."""

    def __init__(self, terminal="t1", foreground_pid=None, labels=None, argv=None):
        self.dir = tempfile.mkdtemp(prefix="wct", dir="/tmp")
        self.path = os.path.join(self.dir, "core.sock")
        self.terminal = terminal
        self.foreground_pid = foreground_pid
        self.argv = argv or ["codex", "--no-daemon"]
        self.labels = dict(labels or {})
        self.docs = {}
        self.requests = []
        self.conflicts = 0
        self.lock = threading.Lock()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(8)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        f = conn.makefile("rwb")
        try:
            for raw in f:
                req = json.loads(raw.decode())
                with self.lock:
                    self.requests.append(req)
                    reply = self._answer(req)
                f.write((json.dumps(reply) + "\n").encode())
                f.flush()
        except Exception:
            pass
        finally:
            conn.close()

    def _answer(self, req):
        m, p, rid = req["method"], req["params"], req["id"]
        if m == "terminal.get":
            if p["terminal"] != self.terminal:
                return {"jsonrpc": "2.0", "id": rid, "error": {"code": 1, "message": "no terminal", "data": {"kind": "not_found"}}}
            fg = {"pid": self.foreground_pid, "argv": self.argv, "name": "codex"} if self.foreground_pid else None
            return {"jsonrpc": "2.0", "id": rid, "result": {"address": self.terminal, "foreground": fg, "labels": dict(self.labels)}}
        if m == "terminal.label":
            for k, v in p["labels"].items():
                if v == "":
                    self.labels.pop(k, None)
                else:
                    self.labels[k] = v
            return {"jsonrpc": "2.0", "id": rid, "result": {}}
        if m == "doc.get":
            value, version = self.docs.get(p["name"], (None, 0))
            return {"jsonrpc": "2.0", "id": rid, "result": {"value": value, "version": version}}
        if m == "doc.set":
            value, version = self.docs.get(p["name"], (None, 0))
            if self.conflicts > 0 or p["version"] != version:
                self.conflicts = max(0, self.conflicts - 1)
                self.docs[p["name"]] = (value, version + 1)  # someone else wrote
                return {"jsonrpc": "2.0", "id": rid, "error": {"code": 1, "message": "version", "data": {"kind": "conflict"}}}
            self.docs[p["name"]] = (p["value"], version + 1)
            return {"jsonrpc": "2.0", "id": rid, "result": {"version": version + 1}}
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "no method"}}

    def methods(self):
        with self.lock:
            return [r["method"] for r in self.requests]

    def label_requests(self):
        with self.lock:
            return [r["params"]["labels"] for r in self.requests if r["method"] == "terminal.label"]

    def close(self):
        try:
            self.server.close()
        except Exception:
            pass
        shutil.rmtree(self.dir, ignore_errors=True)
