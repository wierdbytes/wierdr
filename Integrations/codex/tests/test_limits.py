import json
import unittest

import helpers as h
import limits


def rate(**kw):
    return json.loads(h.token_count("2026-11-18T19:07:45.503Z", 100, **kw))["payload"]["rate_limits"]


class Reading(unittest.TestCase):
    def test_main_family(self):
        r = limits.reading_from_rate_limits(rate())
        self.assertEqual(r["provider"], "codex")
        self.assertEqual(r["source"], "codex")
        self.assertEqual(r["plan"], "plus")
        self.assertNotIn("status", r)
        self.assertEqual(r["windows"], [
            {"id": "5h", "label": "5 hours", "usedPercent": 3, "windowSeconds": 18000, "resetsAt": 1795030046},
            {"id": "7d", "label": "7 days", "usedPercent": 6, "windowSeconds": 604800, "resetsAt": 1795159821},
        ])

    def test_other_family_as_pi_herdr_names_it(self):
        r = limits.reading_from_rate_limits(rate(limit_id="codex_bengalfox", limit_name="GPT-5.3-Codex-Spark", primary=(12.345, 300, 1), secondary=None))
        self.assertEqual(r["windows"], [{"id": "codex_bengalfox.5h", "label": "GPT-5.3-Codex-Spark 5h", "usedPercent": 12.35, "windowSeconds": 18000, "resetsAt": 1}])
        r = limits.reading_from_rate_limits(rate(limit_id="odd id!", primary=(1, 90, None), secondary=None))
        self.assertEqual(r["windows"][0]["id"], "odd_id_.90m")
        self.assertEqual(r["windows"][0]["label"], "odd id! 90m")

    def test_exhausted(self):
        r = limits.reading_from_rate_limits(rate(primary=(100.0, 300, 5), reached="rate_limit_reached"))
        self.assertEqual(r["status"], "exhausted")
        self.assertEqual(r["windows"][0]["status"], "exhausted")
        self.assertNotIn("status", r["windows"][1])

    def test_no_windows(self):
        self.assertIsNone(limits.reading_from_rate_limits(rate(primary=None, secondary=None)))
        self.assertIsNone(limits.reading_from_rate_limits(None))

    def test_durations(self):
        self.assertEqual((limits.duration_id(86400), limits.duration_label(86400)), ("1d", "1 day"))
        self.assertEqual((limits.duration_id(3600), limits.duration_label(3600)), ("1h", "1 hour"))
        self.assertEqual((limits.duration_id(5400), limits.duration_label(5400)), ("90m", "90 minutes"))


class Account(unittest.TestCase):
    def test_slug_is_pi_herdrs(self):
        import hashlib
        self.assertEqual(limits.account_slug("acct-1"), hashlib.sha256(b"acct-1").hexdigest()[:8])
        self.assertEqual(limits.account_slug(None), "main")

    def test_from_auth_json(self):
        self.assertEqual(limits.account_from_auth(h.auth_json("acct-1", "me@example.com")), {"id": "acct-1", "label": "me@example.com"})
        # Without tokens.account_id: the id token's chatgpt_account_id.
        self.assertEqual(limits.account_from_auth(h.auth_json("acct-2", "x@y", put_account=False)), {"id": "acct-2", "label": "x@y"})
        self.assertEqual(limits.account_from_auth('{"OPENAI_API_KEY":"sk-x"}'), {})
        self.assertEqual(limits.account_from_auth("not json"), {})
        self.assertEqual(limits.account_from_auth(None), {})

    def test_no_secret_leaves(self):
        out = json.dumps(limits.account_from_auth(h.auth_json()))
        self.assertNotIn("secret", out)


def win(used, resets, at, wid="5h"):
    return {"id": wid, "label": "5 hours", "window_s": 18000, "used": used, "resets_at": resets, "at": at}


class Fold(unittest.TestCase):
    def test_same_window_only_grows(self):
        a = win(40, 1000, 10)
        self.assertEqual(limits.fold_window(a, win(30, 1050, 20)), {**win(40, 1050, 20)})
        self.assertEqual(limits.fold_window(a, win(50, 990, 5))["used"], 50)

    def test_later_window_replaces_earlier_is_dropped(self):
        a = win(90, 1000, 10)
        self.assertEqual(limits.fold_window(a, win(2, 1000 + 18000, 30)), win(2, 19000, 30))
        self.assertEqual(limits.fold_window(a, win(95, 1000 - 18000, 40)), a)

    def test_without_reset(self):
        a = win(90, 1000, 10)
        b = {"id": "5h", "label": "5 hours", "used": 1, "at": 500}
        self.assertEqual(limits.fold_window(a, b), a)
        b["at"] = 1200
        self.assertEqual(limits.fold_window(a, b), b)

    def test_fold_reading_into_doc(self):
        reading = limits.reading_from_rate_limits(rate())
        account = {"slug": "d4800446", "label": "me@example.com"}
        doc = limits.fold_reading(limits.as_limits_doc(None), reading, account, 1795028865, "mentoair")
        self.assertEqual(doc, {
            "schema": 1, "updated_at": 1795028865,
            "accounts": {"codex.d4800446": {
                "provider": "codex", "account": "d4800446", "at": 1795028865, "label": "me@example.com", "plan": "plus",
                "source": "codex", "host": "mentoair",
                "windows": {
                    "5h": {"id": "5h", "label": "5 hours", "used": 3, "at": 1795028865, "window_s": 18000, "resets_at": 1795030046},
                    "7d": {"id": "7d", "label": "7 days", "used": 6, "at": 1795028865, "window_s": 604800, "resets_at": 1795159821},
                },
            }},
        })
        # pi-herdr read more of the same window a bit later from another machine: it stays.
        doc["accounts"]["codex.d4800446"]["windows"]["5h"].update(used=9, at=1795028900)
        doc["accounts"]["codex.d4800446"].update(at=1795028900, host="other", source="stream")
        older = limits.fold_reading(doc, reading, account, 1795028870, "mentoair")
        acct = older["accounts"]["codex.d4800446"]
        self.assertEqual(acct["windows"]["5h"]["used"], 9)
        self.assertEqual((acct["host"], acct["source"], acct["at"]), ("other", "stream", 1795028900))
        # Other accounts are kept.
        doc["accounts"]["claude.849d2d8c"] = {"provider": "claude"}
        self.assertIn("claude.849d2d8c", limits.fold_reading(doc, reading, account, 1795029000)["accounts"])

    def test_foreign_doc_is_replaced(self):
        self.assertEqual(limits.as_limits_doc({"schema": 2}), limits.empty_doc())
        self.assertEqual(limits.as_limits_doc([]), limits.empty_doc())


class FakeStore:
    def __init__(self, conflicts=0):
        self.value, self.version, self.conflicts, self.sets = None, 3, conflicts, 0

    def doc_get(self, name):
        return self.value, self.version

    def doc_set(self, name, value, version):
        self.sets += 1
        if self.conflicts:
            self.conflicts -= 1
            self.version += 1
            return "conflict"
        self.value, self.version = value, version + 1
        return self.version


class Write(unittest.TestCase):
    def test_retries_on_conflict(self):
        store = FakeStore(conflicts=2)
        reading = limits.reading_from_rate_limits(rate())
        self.assertTrue(limits.write_readings(store, "limits", [(reading, {"slug": "a"}, 100)], "h"))
        self.assertEqual(store.sets, 3)
        self.assertIn("codex.a", store.value["accounts"])

    def test_gives_up(self):
        store = FakeStore(conflicts=10)
        self.assertFalse(limits.write_readings(store, "limits", [(limits.reading_from_rate_limits(rate()), {"slug": "a"}, 1)], None, attempts=3))
        self.assertEqual(store.sets, 3)


if __name__ == "__main__":
    unittest.main()
