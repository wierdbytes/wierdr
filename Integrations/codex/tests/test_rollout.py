import os
import tempfile
import unittest

import helpers as h
import rollout


def write(lines):
    fd, path = tempfile.mkstemp(suffix=".jsonl")
    with os.fdopen(fd, "w") as f:
        f.write("".join(lines))
    return path


class Tail(unittest.TestCase):
    def setUp(self):
        self.paths = []

    def tearDown(self):
        for p in self.paths:
            os.remove(p)

    def file(self, lines):
        p = write(lines)
        self.paths.append(p)
        return p

    def test_tail_lines_across_chunks(self):
        lines = ["%d %s\n" % (i, "x" * (i * 7 % 50)) for i in range(300)]
        path = self.file(lines)
        got = [l.decode() + "\n" for l in rollout.tail_lines(path, chunk=37)]
        self.assertEqual(got, list(reversed(lines)))

    def test_head_is_the_session_meta(self):
        path = self.file([h.session_meta(source="exec"), h.task_started("2026-11-18T19:07:42.262Z")])
        head = rollout.read_head(path)
        self.assertEqual(head["source"], "exec")
        self.assertEqual(head["model_provider"], "openai")
        self.assertIsNone(rollout.read_head(None))
        self.assertIsNone(rollout.read_head("/nonexistent/x.jsonl"))

    def test_latest_turn_wins(self):
        path = self.file([
            h.session_meta(),
            h.task_started("2026-11-18T19:07:42.262Z", window=258400),
            h.turn_context("2026-11-18T19:07:42.633Z", model="gpt-6-luna", effort="low"),
            h.token_count("2026-11-18T19:07:45.503Z", 16356, primary=(3.0, 300, 1795030046)),
            h.task_started("2026-11-18T19:09:22.505Z", window=258400),
            h.turn_context("2026-11-18T19:09:22.515Z", model="gpt-6-luna", effort="high"),
            h.message("2026-11-18T19:09:23.000Z"),
            h.token_count("2026-11-18T19:09:24.731Z", 16489, primary=(4.0, 300, 1795030046)),
        ] + [h.message("2026-11-18T19:09:25.000Z", "y" * 1000) for _ in range(50)])
        tail = rollout.scan(path)
        self.assertEqual((tail.model, tail.effort, tail.ctx, tail.ctx_max), ("gpt-6-luna", "high", 16489, 258400))
        self.assertAlmostEqual(tail.ctx_at, rollout.iso_to_unix("2026-11-18T19:09:24.731Z"))
        limits, at = tail.rate_limits["codex"]
        self.assertEqual(limits["primary"]["used_percent"], 4.0)
        self.assertEqual(int(at), 1795028964)

    def test_model_change_between_turns(self):
        path = self.file([
            h.session_meta(),
            h.task_started("2026-11-18T19:07:42.262Z"),
            h.turn_context("2026-11-18T19:07:42.633Z", model="gpt-6-luna", effort="low"),
            h.token_count("2026-11-18T19:07:45.503Z", 16356),
            h.settings_applied("2026-11-18T19:08:00.000Z", model="gpt-6.1-sol", effort="xhigh"),
        ])
        tail = rollout.scan(path)
        self.assertEqual((tail.model, tail.effort), ("gpt-6.1-sol", "xhigh"))

    def test_other_limit_families_of_the_turn(self):
        path = self.file([
            h.session_meta(),
            h.task_started("2026-11-18T19:07:40.000Z"),
            h.turn_context("2026-11-18T19:07:40.100Z"),
            h.token_count("2026-11-18T19:07:41.000Z", 100, primary=(1.0, 300, 1795030046)),
            h.task_started("2026-11-18T19:07:42.262Z"),
            h.turn_context("2026-11-18T19:07:42.633Z"),
            h.token_count("2026-11-18T19:07:44.000Z", 200, limit_id="codex_bengalfox", limit_name="GPT-5.3-Codex-Spark", primary=(20.0, 300, 1795030000), secondary=None),
            h.token_count("2026-11-18T19:07:45.503Z", 300, primary=(3.0, 300, 1795030046)),
        ])
        tail = rollout.scan(path)
        self.assertEqual(sorted(tail.rate_limits), ["codex", "codex_bengalfox"])
        self.assertEqual(tail.rate_limits["codex"][0]["primary"]["used_percent"], 3.0)
        self.assertEqual(tail.ctx, 300)

    def test_a_fresh_session_has_no_usage(self):
        path = self.file([h.session_meta(), h.task_started("2026-11-18T19:07:42.262Z", window=258400), h.turn_context("2026-11-18T19:07:42.633Z")])
        tail = rollout.scan(path)
        self.assertEqual((tail.ctx, tail.ctx_max, tail.effort), (None, 258400, "low"))
        self.assertEqual(tail.rate_limits, {})

    def test_broken_lines_are_skipped(self):
        path = self.file([h.session_meta(), h.turn_context("2026-11-18T19:07:42.633Z"), '{"type":"event_msg", broken\n', h.token_count("2026-11-18T19:07:45.503Z", 5)])
        self.assertEqual(rollout.scan(path).ctx, 5)

    def test_iso(self):
        self.assertEqual(rollout.iso_to_unix("1970-01-01T00:00:01.500Z"), 1.5)
        self.assertEqual(rollout.iso_to_unix("1970-01-01T00:00:01.123456789Z"), 1.123456)
        self.assertIsNone(rollout.iso_to_unix("nope"))


if __name__ == "__main__":
    unittest.main()
