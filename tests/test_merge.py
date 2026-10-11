import json
import unittest
from pathlib import Path

from claude_monitor import live
from claude_monitor.live import LiveEntry, effective, parse_agents_json
from claude_monitor.state import SessionState

FIXTURES = Path(__file__).parent / "fixtures"


class MergeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads((FIXTURES / "merge_cases.json").read_text())

    def test_constants_match_fixture(self):
        for name, value in self.data["constants"].items():
            with self.subTest(name=name):
                self.assertEqual(getattr(live, name), value)

    def test_cases(self):
        for case in self.data["cases"]:
            with self.subTest(case["name"]):
                hook = SessionState.from_dict({**case["hook"], "session_id": "s"}) if case["hook"] else None
                entry = LiveEntry.from_agents_json(case["live"]) if case["live"] else None
                eff = effective(hook, entry, case["observed_at"], case["now"])
                got = {
                    "status": eff.status,
                    "detail": eff.detail,
                    "hidden": eff.hidden,
                    "legacy": eff.legacy,
                    "untracked": eff.untracked,
                    "stale_idle": eff.stale_idle,
                }
                self.assertEqual(got, case["expect"])


class AgentsJsonTest(unittest.TestCase):
    def test_parses_documented_shape_and_dedupes(self):
        text = json.dumps([
            {"cwd": "/p", "kind": "background", "id": "7c5dcf5d", "state": "blocked", "pid": 4242,
             "status": "waiting", "waitingFor": "permission prompt", "startedAt": 1767225600000,
             "sessionId": "s1", "name": "flaky-test-fix"},
            {"cwd": "/p", "kind": "interactive", "startedAt": 1767225600000, "sessionId": "s2"},
            {"cwd": "/p", "kind": "interactive", "pid": 7, "status": "idle", "startedAt": 1767225600000, "sessionId": "s2"},
            {"cwd": "/p", "kind": "background", "id": "nosession", "state": "working"},
        ])
        snap = parse_agents_json(text, 123.0)
        self.assertEqual(snap.observed_at, 123.0)
        self.assertEqual(set(snap.entries), {"s1", "s2"})
        s1 = snap.entries["s1"]
        self.assertEqual((s1.kind, s1.job_id, s1.pid, s1.status, s1.waiting_for), ("background", "7c5dcf5d", 4242, "waiting", "permission prompt"))
        self.assertEqual(s1.started_at, 1767225600.0)
        self.assertEqual(snap.entries["s2"].pid, 7)  # the row with a live process wins

    def test_rejects_non_json(self):
        self.assertIsNone(parse_agents_json("not json", 1.0))
        self.assertIsNone(parse_agents_json('{"a": 1}', 1.0))


if __name__ == "__main__":
    unittest.main()
