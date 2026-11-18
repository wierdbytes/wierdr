import unittest

import helpers  # noqa: F401  (puts hooks/ on sys.path)
import meta


class ModelName(unittest.TestCase):
    def test_codex_display_names_in_pi_style(self):
        self.assertEqual(meta.model_name("gpt-6.1-sol", "GPT-6.1-Sol"), "GPT-6.1 Sol")
        self.assertEqual(meta.model_name("gpt-6-luna", "GPT-6-Luna"), "GPT-6 Luna")
        self.assertEqual(meta.model_name("gpt-5.6-sol", "GPT-5.6-Sol"), "GPT-5.6 Sol")
        self.assertEqual(meta.model_name("gpt-6.1-terra", "GPT-6.1 Terra"), "GPT-6.1 Terra")
        self.assertEqual(meta.model_name("gpt-5.1-codex-max", "GPT-5.1-Codex-Max"), "GPT-5.1 Codex Max")

    def test_from_the_slug_without_a_display_name(self):
        self.assertEqual(meta.model_name("gpt-6.1-sol"), "GPT-6.1 Sol")
        self.assertEqual(meta.model_name("gpt-5.3-codex"), "GPT-5.3 Codex")
        self.assertEqual(meta.model_name("gpt-5"), "GPT-5")
        self.assertEqual(meta.model_name("gpt-5.4-mini"), "GPT-5.4 Mini")

    def test_anything_else_is_its_display_name_or_slug(self):
        self.assertEqual(meta.model_name("codex-auto-review", "Codex Auto Review"), "Codex Auto Review")
        self.assertEqual(meta.model_name("gpt-reserve", "GPT-Reserve"), "GPT-Reserve")
        self.assertEqual(meta.model_name("o3"), "o3")
        self.assertIsNone(meta.model_name(None))


class Labels(unittest.TestCase):
    def test_every_key_with_empties_for_unknowns(self):
        labels = meta.build_labels(pid=42, session="s1", model_id="gpt-6-luna", effort="low", ctx=16356, ctx_max=258400)
        self.assertEqual(set(labels), set(meta.LABEL_KEYS))
        self.assertEqual(labels["agent.app"], "codex")
        self.assertEqual(labels["agent.pid"], "42")
        self.assertEqual(labels["agent.model"], "GPT-6 Luna")
        self.assertEqual(labels["agent.model_id"], "gpt-6-luna")
        self.assertEqual(labels["agent.provider"], "openai")
        self.assertEqual(labels["agent.effort"], "low")
        self.assertEqual(labels["agent.ctx"], "16356")
        self.assertEqual(labels["agent.ctx_max"], "258400")
        self.assertEqual(labels["agent.session"], "s1")
        self.assertEqual(labels["agent.subagents"], "")
        self.assertEqual(labels["agent.cache_until"], "")
        self.assertEqual(labels["agent.cache_ttl"], "")

    def test_no_effort_and_no_subagents(self):
        labels = meta.build_labels(pid=1, session=None, model_id="m", effort="none", subagents=0)
        self.assertEqual(labels["agent.effort"], "")
        self.assertEqual(labels["agent.subagents"], "")
        self.assertEqual(meta.build_labels(pid=1, session=None, model_id="m", subagents=2)["agent.subagents"], "2")
        self.assertEqual(meta.build_labels(pid=1, session=None, model_id="m", effort="xhigh")["agent.effort"], "xhigh")

    def test_diff_sends_changes_and_removes_only_what_is_there(self):
        current = {"agent.app": "codex", "agent.ctx": "100", "agent.cache_ttl": "300000", "where": "x"}
        wanted = {"agent.app": "codex", "agent.ctx": "200", "agent.cache_ttl": "", "agent.effort": ""}
        self.assertEqual(meta.diff(current, wanted), {"agent.ctx": "200", "agent.cache_ttl": ""})
        self.assertEqual(meta.diff(current, wanted, ["agent.ctx"]), {"agent.ctx": "200"})
        self.assertEqual(meta.diff(current, current), {})

    def test_removal_and_ownership(self):
        current = {"agent.app": "codex", "agent.pid": "7", "agent.session": "s", "agent.ctx": "", "pi-agents.pid": "1"}
        self.assertEqual(meta.removal(current), {"agent.app": "", "agent.pid": "", "agent.session": ""})
        self.assertTrue(meta.owns(current, 7, "s"))
        self.assertFalse(meta.owns(current, 8, "s"))
        self.assertFalse(meta.owns(current, 7, "other"))
        self.assertFalse(meta.owns({"agent.app": "pi", "agent.pid": "7"}, 7, None))


if __name__ == "__main__":
    unittest.main()
