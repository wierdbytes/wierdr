"""herdr.py end to end: run as Codex runs it, against a fake herdr-core socket."""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

import helpers as h

HERDR = os.path.join(h.HOOKS, "herdr.py")


class Hook(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="wcx", dir="/tmp")
        self.home = os.path.join(self.root, "codex-home")
        self.data = os.path.join(self.root, "data")
        os.makedirs(self.home)
        with open(os.path.join(self.home, "auth.json"), "w") as f:
            f.write(h.auth_json("acct-1", "me@example.com"))
        with open(os.path.join(self.home, "models_cache.json"), "w") as f:
            json.dump({"models": [{"slug": "gpt-6-luna", "display_name": "GPT-6-Luna", "context_window": 272000,
                                   "effective_context_window_percent": 95, "default_reasoning_level": "medium"}]}, f)
        db = sqlite3.connect(os.path.join(self.home, "state_5.sqlite"))
        db.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL)")
        db.commit()
        db.close()
        self.rollout = os.path.join(self.root, "rollout.jsonl")
        self.write_rollout([h.session_meta(), h.task_started("2026-11-18T19:07:42.262Z"), h.turn_context("2026-11-18T19:07:42.633Z", effort="low")])
        self.core = h.FakeCore(terminal="t1", foreground_pid=os.getpid())

    def tearDown(self):
        self.core.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def sub_rollout(self, agent_id="child", lines=(), append=False, **meta):
        """A sub-agent's rollout: its real-shaped session_meta, then `lines`."""
        path = os.path.join(self.root, "sub-%s.jsonl" % agent_id)
        with open(path, "a" if append else "w") as f:
            if not append:
                f.write(h.subagent_meta(agent_id, **meta))
            f.write("".join(lines))
        return path

    def rows(self):
        raw = self.core.labels.get("agent.subagents_meta")
        return json.loads(raw) if raw else None

    def write_rollout(self, lines, append=False):
        with open(self.rollout, "a" if append else "w") as f:
            f.write("".join(lines))

    def env(self, **extra):
        env = {"PATH": os.environ.get("PATH", ""), "HOME": self.root, "HC_TERMINAL_ID": "t1", "HC_TERMINAL_SOCKET": self.core.path,
               "CODEX_HOME": self.home, "PLUGIN_DATA": self.data, "PLUGIN_ROOT": os.path.dirname(h.HOOKS),
               "WIERDR_CODEX_LIMITS_DOC": "test-limits"}
        env.update(extra)
        return env

    def hook(self, event, payload=None, env=None, via_shell=False):
        body = {"session_id": h.SESSION, "transcript_path": self.rollout, "cwd": "/tmp", "model": "gpt-6-luna"}
        body.update(payload or {})
        if via_shell:
            with open(os.path.join(h.HOOKS, "hooks.json")) as f:
                commands = json.load(f)["hooks"]
            name = {"session-start": "SessionStart", "stop": "Stop", "session-end": "SessionEnd", "subagent-start": "SubagentStart"}[event]
            argv = ["/bin/sh", "-c", commands[name][0]["hooks"][0]["command"]]
        else:
            argv = [sys.executable, HERDR, event]
        out = subprocess.run(argv, input=json.dumps(body).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env or self.env(), timeout=20)
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, b"", "a hook must print nothing")
        return out

    def test_a_session_end_to_end(self):
        self.core.labels = {"agent.app": "pi", "agent.cache_ttl": "300000", "where": "x"}
        self.hook("session-start", {"source": "startup"}, via_shell=True)
        self.assertEqual(self.core.labels, {
            "agent.app": "codex", "agent.pid": str(os.getpid()), "agent.model": "GPT-6 Luna", "agent.model_id": "gpt-6-luna",
            "agent.provider": "openai", "agent.effort": "low", "agent.ctx_max": "258400", "agent.session": h.SESSION, "where": "x",
        })
        # The first write sent every key: the cache labels an earlier agent left are gone.
        self.assertEqual(self.core.label_requests()[0]["agent.cache_ttl"], "")

        # A response came: its usage is the context, before the rollout has it.
        self.hook("post-model-request", {"hook_event_name": "PostModelRequest", "status": "completed", "turn_id": "t",
                                         "token_usage": {"input_tokens": 16000, "cached_input_tokens": 0, "output_tokens": 356, "reasoning_output_tokens": 0, "total_tokens": 16356}})
        self.assertEqual(self.core.labels["agent.ctx"], "16356")
        self.assertEqual(self.core.label_requests()[-1], {"agent.ctx": "16356"})
        # No token_count in the rollout yet: nothing for the limits.
        self.assertNotIn("test-limits", self.core.docs)

        # The turn ended: the rollout has the usage and the windows.
        self.write_rollout([h.token_count("2026-11-18T19:07:45.503Z", 16356)], append=True)
        before = len(self.core.label_requests())
        self.hook("stop", {"hook_event_name": "Stop", "turn_id": "t"}, via_shell=True)
        self.assertEqual(len(self.core.label_requests()), before, "nothing changed, nothing sent")
        doc, version = self.core.docs["test-limits"]
        self.assertEqual(version, 1)
        acct = doc["accounts"][__import__("limits").account_key("codex", __import__("limits").account_slug("acct-1"))]
        self.assertEqual(acct["label"], "me@example.com")
        self.assertEqual(acct["plan"], "plus")
        self.assertEqual(acct["source"], "codex")
        self.assertEqual(acct["windows"]["5h"], {"id": "5h", "label": "5 hours", "used": 3, "at": 1795028865, "window_s": 18000, "resets_at": 1795030046})
        self.assertEqual(acct["windows"]["7d"]["used"], 6)
        # The same reading isn't written twice.
        self.hook("stop", {"hook_event_name": "Stop", "turn_id": "t"})
        self.assertEqual(self.core.docs["test-limits"][1], 1)

        # A sub-agent at work, then done.
        self.hook("subagent-start", {"hook_event_name": "SubagentStart", "agent_id": "child", "turn_id": "c1", "agent_type": "default", "transcript_path": self.sub_rollout()})
        self.assertEqual(self.core.labels["agent.subagents"], "1")
        self.assertEqual(set(self.core.label_requests()[-1]), {"agent.subagents", "agent.subagents_meta"})
        self.assertEqual(self.rows()["child"]["title"], "probe")
        # Its own model requests don't touch the session's context, only its row's.
        before = len(self.core.label_requests())
        self.hook("post-model-request", {"agent_id": "child", "turn_id": "c1", "status": "completed", "token_usage": {"total_tokens": 5}, "transcript_path": self.sub_rollout(lines=[], append=True)})
        self.assertEqual(len(self.core.label_requests()), before + 1)
        self.assertEqual(set(self.core.label_requests()[-1]), {"agent.subagents_meta"})
        self.assertEqual(self.rows()["child"]["ctx"], 5)
        self.assertEqual(self.core.labels["agent.ctx"], "16356")
        self.hook("subagent-stop", {"hook_event_name": "SubagentStop", "agent_id": "child", "agent_type": "default", "turn_id": "c1",
                                    "agent_transcript_path": self.sub_rollout(lines=[], append=True)})
        self.assertNotIn("agent.subagents", self.core.labels)
        self.assertNotIn("agent.subagents_meta", self.core.labels)
        # The turn's last model request, late: still done.
        self.hook("post-model-request", {"agent_id": "child", "turn_id": "c1", "status": "completed", "token_usage": {"total_tokens": 5}, "transcript_path": self.sub_rollout()})
        self.assertNotIn("agent.subagents", self.core.labels)
        # A follow-up turn, then Codex closes it mid-turn.
        self.hook("post-model-request", {"agent_id": "child", "turn_id": "c2", "status": "completed", "token_usage": {"total_tokens": 5}, "transcript_path": self.sub_rollout()})
        self.assertEqual(self.core.labels["agent.subagents"], "1")
        db = sqlite3.connect(os.path.join(self.home, "state_5.sqlite"))
        db.execute("INSERT INTO thread_spawn_edges VALUES (?, 'child', 'closed')", (h.SESSION,))
        db.commit()
        db.close()
        self.hook("agent-tool", {"hook_event_name": "PostToolUse", "tool_name": "close_agent"})
        self.assertNotIn("agent.subagents", self.core.labels)
        self.assertNotIn("agent.subagents_meta", self.core.labels)

        # /model between turns: the next prompt shows it.
        self.write_rollout([h.settings_applied("2026-11-18T19:08:00.000Z", effort="high")], append=True)
        self.hook("prompt", {"hook_event_name": "UserPromptSubmit", "prompt": "hi"})
        self.assertEqual(self.core.labels["agent.effort"], "high")

        # Quitting removes every label it set, and only those.
        self.hook("session-end", {"hook_event_name": "SessionEnd", "reason": "other"}, via_shell=True)
        self.assertEqual(self.core.labels, {"where": "x"})

    # ---- agent.subagents_meta ----

    def start_session(self):
        self.hook("session-start", {"source": "startup"})
        self.assertNotIn("agent.subagents_meta", self.core.labels)

    def sub(self, event, agent_id, turn, **payload):
        body = {"agent_id": agent_id, "turn_id": turn, "agent_type": "default", "model": "gpt-6-luna"}
        if event == "subagent-stop":
            body["agent_transcript_path"] = os.path.join(self.root, "sub-%s.jsonl" % agent_id)  # transcript_path: the parent's
        else:
            body["transcript_path"] = os.path.join(self.root, "sub-%s.jsonl" % agent_id)
        body.update(payload)
        self.hook(event, body)

    def test_a_sub_agent_row_from_start_to_stop(self):
        self.start_session()
        self.sub_rollout("a1", [h.task_started("2026-11-18T19:11:53.400Z", turn="c1"), h.turn_context("2026-11-18T19:11:53.500Z", effort="low", turn="c1")])
        self.sub("subagent-start", "a1", "c1")
        row = self.rows()["a1"]
        since = int(__import__("rollout").iso_to_unix("2026-11-18T19:11:53.400Z") * 1000)
        self.assertEqual(row, {"title": "probe", "name": "Euler", "status": "running", "since": since, "model": "GPT-6 Luna",
                               "model_id": "gpt-6-luna", "effort": "low", "ctx_max": 258400, "started": row["started"]})
        spawned = int(__import__("rollout").iso_to_unix("2026-11-18T19:11:53.376Z") * 1000)
        self.assertEqual(row["started"], spawned, "started: when its thread was made (its rollout's first line)")
        self.assertEqual(self.core.labels["agent.subagents"], "1")
        # Its request starts and answers: the context.
        self.sub("pre-model-request", "a1", "c1", hook_event_name="PreModelRequest")
        self.sub("post-model-request", "a1", "c1", status="completed", token_usage={"total_tokens": 16268})
        self.assertEqual(self.rows()["a1"]["ctx"], 16268)
        self.assertEqual(self.rows()["a1"]["since"], since)
        # Its turn ends: no row, no label.
        self.sub_rollout("a1", [h.token_count("2026-11-18T19:11:55.000Z", 16268), h.task_complete("2026-11-18T19:11:55.100Z", turn="c1")], append=True)
        self.sub("subagent-stop", "a1", "c1", last_assistant_message="sub-ok")
        self.assertIsNone(self.rows())
        self.assertNotIn("agent.subagents", self.core.labels)
        # The late last model-request hook doesn't bring it back.
        self.sub("post-model-request", "a1", "c1", status="completed", token_usage={"total_tokens": 16268})
        self.assertIsNone(self.rows())

    def test_two_sub_agents(self):
        self.start_session()
        self.sub_rollout("a1", [h.task_started("2026-11-18T19:11:53.400Z", turn="c1")])
        self.sub_rollout("a2", [h.task_started("2026-11-18T19:11:54.000Z", turn="d1"), h.turn_context("2026-11-18T19:11:54.100Z", model="gpt-6.1-sol", effort="high", turn="d1")],
                         agent_path="/root/review", nickname="Noether", role="explorer")
        self.sub("subagent-start", "a1", "c1")
        self.sub("subagent-start", "a2", "d1", agent_type="explorer", model="gpt-6.1-sol")
        rows = self.rows()
        self.assertEqual(sorted(rows), ["a1", "a2"])
        self.assertEqual(self.core.labels["agent.subagents"], "2")
        self.assertEqual((rows["a2"]["title"], rows["a2"]["name"], rows["a2"]["model"], rows["a2"]["effort"]), ("review", "Noether", "GPT-6.1 Sol", "high"))
        # Without a turn_context yet: the hook's model, the model's default effort.
        self.assertEqual((rows["a1"]["model"], rows["a1"]["effort"]), ("GPT-6 Luna", "medium"))
        self.assertTrue(self.core.labels["agent.subagents_meta"].startswith('{"a1":'), "compact, ids sorted")
        self.assertNotIn(" ", self.core.labels["agent.subagents_meta"].replace("GPT-6 Luna", "").replace("GPT-6.1 Sol", ""))
        self.sub("subagent-stop", "a1", "c1")
        self.assertEqual(sorted(self.rows()), ["a2"])
        self.assertEqual(self.core.labels["agent.subagents"], "1")
        # Quitting clears it with the others.
        self.hook("session-end", {"reason": "other"})
        self.assertNotIn("agent.subagents_meta", self.core.labels)
        self.assertNotIn("agent.app", self.core.labels)

    def test_a_resumed_sub_agent_shows_again_from_its_new_turn(self):
        self.start_session()
        self.sub_rollout("a1", [h.task_started("2026-11-18T19:11:53.400Z", turn="c1"), h.task_complete("2026-11-18T19:11:55.100Z", turn="c1")])
        self.sub("subagent-start", "a1", "c1")
        self.sub("subagent-stop", "a1", "c1")
        self.assertIsNone(self.rows())
        started = int(__import__("rollout").iso_to_unix("2026-11-18T19:11:53.376Z") * 1000)
        # send_message / followup_task wakes it: its next request is the news (no SubagentStart).
        self.sub("pre-model-request", "a1", "c2")
        row = self.rows()["a1"]
        self.assertEqual(row["started"], started, "started stays the spawn's")
        self.assertGreater(row["since"], started, "since: when the new turn was first seen")
        self.sub_rollout("a1", [h.task_started("2026-11-18T19:20:00.000Z", turn="c2")], append=True)
        self.sub("post-model-request", "a1", "c2", status="completed", token_usage={"total_tokens": 17000})
        row = self.rows()["a1"]
        self.assertEqual(row["since"], int(__import__("rollout").iso_to_unix("2026-11-18T19:20:00.000Z") * 1000), "the rollout's turn start")
        self.assertEqual(row["ctx"], 17000)
        self.sub("subagent-stop", "a1", "c2")
        self.assertIsNone(self.rows())

    def test_an_interrupted_turn_goes_at_the_next_hook(self):
        # An interrupt fires no SubagentStop; the sub-agent's rollout says the turn is over.
        self.start_session()
        self.sub_rollout("a1", [h.task_started("2026-11-18T19:11:53.400Z", turn="c1")])
        self.sub("subagent-start", "a1", "c1")
        self.assertIn("a1", self.rows())
        self.sub_rollout("a1", [h.turn_aborted("2026-11-18T19:11:58.000Z", turn="c1")], append=True)
        self.hook("prompt", {"prompt": "next"})
        self.assertIsNone(self.rows())
        self.assertNotIn("agent.subagents", self.core.labels)

    def test_someone_elses_rollout_isnt_its_own(self):
        # A transcript that isn't the agent's (the parent's): no title from it, the row still there.
        self.start_session()
        t0 = time.time() * 1000
        self.sub("subagent-start", "a9", "c1", transcript_path=self.rollout)
        row = self.rows()["a9"]
        self.assertEqual(row["status"], "running")
        self.assertNotIn("title", row)
        # No rollout of its own: started and since are when its SubagentStart ran.
        self.assertTrue(t0 - 1 <= row["started"] <= time.time() * 1000 + 1)
        self.assertEqual(row["since"], row["started"])

    def test_the_main_agents_pre_model_request_does_nothing(self):
        before = len(self.core.requests)
        self.hook("pre-model-request", {"turn_id": "t"})
        self.assertEqual(len(self.core.requests), before)

    def test_not_the_foreground_writes_no_labels_but_limits(self):
        # The daemon case: the terminal's foreground isn't this hook's ancestor.
        self.core.foreground_pid = 999999
        self.write_rollout([h.token_count("2026-11-18T19:07:45.503Z", 100)], append=True)
        self.hook("session-start", {"source": "startup"})
        self.hook("stop", {})
        self.assertEqual(self.core.label_requests(), [])
        self.assertIn("test-limits", self.core.docs)

    def test_exec_writes_no_labels_but_limits(self):
        self.write_rollout([h.session_meta(source="exec"), h.turn_context("2026-11-18T19:07:42.633Z"), h.token_count("2026-11-18T19:07:45.503Z", 100)])
        self.hook("session-start", {"source": "startup"})
        self.hook("stop", {})
        self.hook("session-end", {})
        self.assertEqual(self.core.label_requests(), [])
        self.assertIn("test-limits", self.core.docs)

    def test_session_end_leaves_someone_elses_labels(self):
        self.core.labels = {"agent.app": "pi", "agent.pid": "1234"}
        self.hook("session-end", {})
        self.assertEqual(self.core.labels, {"agent.app": "pi", "agent.pid": "1234"})

    def test_new_session_after_clear_republishes(self):
        self.hook("session-start", {"source": "startup"})
        self.hook("session-start", {"source": "clear", "session_id": "new-session"})
        self.assertEqual(self.core.labels["agent.session"], "new-session")

    def test_outside_herdr_does_nothing(self):
        env = self.env()
        del env["HC_TERMINAL_SOCKET"]
        out = self.hook("session-start", {}, env=env, via_shell=True)
        self.assertEqual(out.stderr, b"")
        self.assertEqual(self.core.requests, [])

    def test_no_core_doesnt_fail(self):
        env = self.env(HC_TERMINAL_SOCKET=os.path.join(self.root, "nothing.sock"))
        start = time.monotonic()
        self.hook("stop", {}, env=env)
        self.assertLess(time.monotonic() - start, 5)

    def test_bad_input_doesnt_fail(self):
        out = subprocess.run([sys.executable, HERDR, "stop"], input=b"not json", stdout=subprocess.PIPE, env=self.env(), timeout=10)
        self.assertEqual((out.returncode, out.stdout), (0, b""))

    def test_limits_wait_30s_between_model_requests(self):
        self.write_rollout([h.token_count("2026-11-18T19:07:45.503Z", 100)], append=True)
        self.hook("post-model-request", {"status": "completed", "token_usage": {"total_tokens": 100}})
        self.assertEqual(self.core.docs["test-limits"][1], 1)
        self.write_rollout([h.token_count("2026-11-18T19:07:55.503Z", 200, primary=(4.0, 300, 1795030046))], append=True)
        self.hook("post-model-request", {"status": "completed", "token_usage": {"total_tokens": 200}})
        self.assertEqual(self.core.docs["test-limits"][1], 1, "throttled")
        self.hook("stop", {})
        self.assertEqual(self.core.docs["test-limits"][1], 2, "Stop always writes a new reading")


if __name__ == "__main__":
    unittest.main()
