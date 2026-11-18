"""subagents.py: the bookkeeping and agent.subagents_meta's pieces, pure."""

import json
import unittest

import helpers as h
import rollout
import subagents


def head(text):
    return json.loads(text)["payload"]


class Describe(unittest.TestCase):
    def test_task_path_and_nickname_of_a_real_shaped_spawn(self):
        # Codex shows it as "Started `/root/probe`"; its picker as "Euler".
        self.assertEqual(subagents.describe(head(h.subagent_meta("a1"))), ("probe", "Euler"))
        self.assertEqual(subagents.describe(head(h.subagent_meta("a1", agent_path="/root/sleep_waiter", nickname="Lorentz"))),
                         ("sleep_waiter", "Lorentz"))

    def test_nested_keeps_the_path_under_the_root(self):
        self.assertEqual(subagents.describe(head(h.subagent_meta("a2", agent_path="/root/probe/check", nickname="Noether", depth=2))),
                         ("probe/check", "Noether"))

    def test_without_a_path_the_pickers_name(self):
        meta = head(h.subagent_meta("a3", agent_path=None, nickname="Robie", role="explorer"))
        self.assertEqual(subagents.describe(meta), ("Robie [explorer]", "Robie"))
        meta = head(h.subagent_meta("a3", agent_path=None, nickname=None, role=None))
        self.assertEqual(subagents.describe(meta, "worker"), ("[worker]", None))
        self.assertEqual(subagents.describe(meta, "default"), (None, None))
        self.assertEqual(subagents.describe(None), (None, None))


class Bookkeeping(unittest.TestCase):
    def test_note_keeps_what_the_hooks_tell(self):
        agents = subagents.note({}, "a", "active", "t1", 2000, start=True, path="/r/a.jsonl", agent_type="default", model="gpt-6-luna")
        # A later hook of the same turn that started earlier (out of order): the earliest wins.
        agents = subagents.note(agents, "a", "active", "t1", 1500, ctx=100)
        agents = subagents.note(agents, "a", "active", "t1", 3000, ctx=90)
        self.assertEqual(agents["a"]["seen"], {"t1": 1500})
        self.assertEqual(agents["a"]["started"], 2000)
        self.assertEqual((agents["a"]["ctx"], agents["a"]["ctx_at"]), (90, 3000))
        self.assertEqual(agents["a"]["path"], "/r/a.jsonl")
        # An older response doesn't replace a newer context.
        agents = subagents.note(agents, "a", "active", "t1", 2500, ctx=50)
        self.assertEqual(agents["a"]["ctx"], 90)
        self.assertEqual(subagents.working_ids(agents), ["a"])
        agents = subagents.note(agents, "a", "done", "t1", 4000)
        self.assertEqual(subagents.working_ids(agents), [])
        # mark() keeps the other fields.
        self.assertEqual(subagents.mark(agents, "a", "active", "t2")["a"]["path"], "/r/a.jsonl")

    def test_a_turn_the_rollout_ended_doesnt_count(self):
        agents = subagents.note({}, "a", "active", "t1", 1000)
        agents = subagents.note(agents, "b", "active", "u1", 1000)
        ended = {"a": {"t1"}, "b": {"u0"}}
        self.assertEqual(subagents.working_ids(agents, ended=lambda i, e: ended[i]), ["b"])
        self.assertEqual(subagents.working_ids(agents, closed={"b"}, ended=lambda i, e: ended[i]), [])

    def test_a_later_turn_in_the_rollout_ends_the_earlier_ones(self):
        # Its SubagentStop was missed, and the rollout was read back only to a later turn's start.
        agents = subagents.note({}, "a", "active", "c1", 1_000_000)
        agents = subagents.note(agents, "a", "active", "c2", 2_000_500)
        self.assertEqual(subagents.ended_turns(agents["a"], set(), "c2", 2000.0), {"c1"})
        self.assertEqual(subagents.running_turns(agents["a"], subagents.ended_turns(agents["a"], set(), "c2", 2000.0)), ["c2"])
        # A turn its hooks saw after the rollout's latest start is newer: not over.
        agents = subagents.note(agents, "a", "active", "c3", 3_000_000)
        self.assertEqual(subagents.ended_turns(agents["a"], {"c2"}, "c2", 2000.0), {"c1", "c2"})
        self.assertEqual(subagents.ended_turns(agents["a"], {"x"}, None, None), {"x"})

    def test_running_turns_latest_first(self):
        agents = subagents.note({}, "a", "active", "t2", 5000)
        agents = subagents.note(agents, "a", "active", "t1", 1000)
        self.assertEqual(subagents.running_turns(agents["a"]), ["t2", "t1"])
        self.assertEqual(subagents.running_turns(agents["a"], {"t2"}), ["t1"])


class Label(unittest.TestCase):
    def test_compact_json_ids_sorted_unknowns_left_out(self):
        entries = {
            "b": subagents.meta_entry(title="probe", name="Euler", since=1795029113000, model="GPT-6 Luna", model_id="gpt-6-luna",
                                      effort="low", ctx=16268, ctx_max=258400, started=1795029113376),
            "a": subagents.meta_entry(),
        }
        text = subagents.meta_label(entries)
        self.assertEqual(text, '{"a":{"status":"running"},"b":{"title":"probe","name":"Euler","status":"running","since":1795029113000,'
                               '"model":"GPT-6 Luna","model_id":"gpt-6-luna","effort":"low","ctx":16268,"ctx_max":258400,"started":1795029113376}}')
        self.assertEqual(subagents.meta_label({}), "")


class RolloutTurns(unittest.TestCase):
    def test_turn_starts_and_ends(self):
        lines = [h.subagent_meta("a"), h.task_started("2026-11-18T19:11:53.400Z", turn="t1"), h.turn_context("2026-11-18T19:11:53.500Z", turn="t1"),
                 h.token_count("2026-11-18T19:11:55.000Z", 16268), h.task_complete("2026-11-18T19:11:55.100Z", turn="t1"),
                 h.task_started("2026-11-18T19:12:10.000Z", turn="t2"), h.turn_context("2026-11-18T19:12:10.100Z", effort="high", turn="t2")]
        tail = rollout.scan_lines(iter(l.encode().rstrip(b"\n") for l in reversed(lines)), want_limits=False, want_turn=True)
        self.assertEqual(tail.turns_ended, {"t1"})
        self.assertEqual(tail.latest_turn, "t2")
        self.assertEqual(tail.turn_started.get("t2"), rollout.iso_to_unix("2026-11-18T19:12:10.000Z"))
        self.assertEqual((tail.model, tail.effort, tail.ctx, tail.ctx_max), ("gpt-6-luna", "high", 16268, 258400))


if __name__ == "__main__":
    unittest.main()
