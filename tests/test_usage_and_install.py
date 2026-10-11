import email.message
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError

from click.testing import CliRunner

from claude_monitor import main as cli_main
from claude_monitor import usage


def http_error(code, retry_after=None):
    headers = email.message.Message()
    if retry_after is not None:
        headers["Retry-After"] = retry_after
    return HTTPError(usage.API_URL, code, "err", headers, None)


class UsageTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"CLAUDE_MONITOR_DIR": self._tmp.name})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.calls = 0

    def fetch_ok(self, token):
        self.calls += 1
        return b'{"five_hour": {"utilization": 10}}'

    def test_success_then_throttled(self):
        token = lambda now: "tok"
        self.assertEqual(usage.fetch_and_write_usage(1000.0, self.fetch_ok, token), "ok")
        self.assertEqual(json.loads(usage.usage_file().read_text())["five_hour"]["utilization"], 10)
        self.assertEqual(usage.fetch_and_write_usage(1010.0, self.fetch_ok, token), "throttled")
        self.assertEqual(usage.fetch_and_write_usage(1000.0 + usage.MIN_INTERVAL, self.fetch_ok, token), "ok")
        self.assertEqual(self.calls, 2)

    def test_rate_limit_backs_off_and_keeps_old_data(self):
        token = lambda now: "tok"
        usage.fetch_and_write_usage(1000.0, self.fetch_ok, token)

        def limited(t):
            raise http_error(429, "600")

        self.assertEqual(usage.fetch_and_write_usage(2000.0, limited, token), "http-429")
        self.assertEqual(usage.fetch_and_write_usage(2500.0, self.fetch_ok, token), "throttled")
        self.assertEqual(usage.fetch_and_write_usage(2601.0, self.fetch_ok, token), "ok")
        self.assertIn("five_hour", json.loads(usage.usage_file().read_text()))

    def test_auth_error_and_garbage(self):
        token = lambda now: "tok"

        def unauthorized(t):
            raise http_error(401)

        self.assertEqual(usage.fetch_and_write_usage(1000.0, unauthorized, token), "http-401")
        self.assertEqual(usage.fetch_and_write_usage(1000.0 + usage.MIN_INTERVAL + 1, self.fetch_ok, token), "throttled")
        self.assertEqual(usage.fetch_and_write_usage(5000.0, lambda t: b"<html>", token), "error")
        self.assertFalse(usage.usage_file().exists())

    def test_no_token(self):
        self.assertEqual(usage.fetch_and_write_usage(1000.0, self.fetch_ok, lambda now: None), "no-token")
        self.assertEqual(self.calls, 0)

    def test_expired_token_is_skipped(self):
        creds = {"claudeAiOauth": {"accessToken": "t", "expiresAt": 1_000_000}}
        self.assertIsNone(usage._token_from_creds(creds, now=2_000.0))
        self.assertEqual(usage._token_from_creds(creds, now=100.0), "t")

    def test_retry_after_formats(self):
        self.assertEqual(usage._retry_after("120", 0.0), 120.0)
        self.assertIsNone(usage._retry_after("soon", 0.0))
        self.assertGreater(usage._retry_after("Wed, 21 Oct 2099 07:28:00 GMT", 0.0), 0)


class InstallTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.settings = Path(self._tmp.name) / "settings.json"
        for target, value in (
            ("SETTINGS_PATH", self.settings),
            ("_claude_version", lambda: (2, 1, 296)),
            ("_command", lambda sub: f"/opt/bin/claude-monitor {sub}"),
        ):
            patcher = mock.patch.object(cli_main, target, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_cli(self, *args):
        result = CliRunner().invoke(cli_main.cli, list(args))
        return result

    def test_install_preserves_other_settings_and_is_idempotent(self):
        self.settings.write_text(json.dumps({
            "model": "opus",
            "hooks": {
                "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "other-tool"}]},
                         {"matcher": ".*", "hooks": [{"type": "command", "command": "/old/claude-monitor hook"}]}],
                "TeammateIdle": [{"matcher": ".*", "hooks": [{"type": "command", "command": "/old/claude-monitor hook"}]}],
            },
        }))
        self.assertEqual(self.run_cli("install").exit_code, 0)
        self.assertEqual(self.run_cli("install").exit_code, 0)
        data = json.loads(self.settings.read_text())
        self.assertEqual(data["model"], "opus")
        self.assertEqual(sorted(data["hooks"]), sorted(cli_main.HOOK_EVENTS))  # stale TeammateIdle entry removed
        stop = data["hooks"]["Stop"]
        self.assertEqual(stop[0]["hooks"][0]["command"], "other-tool")
        ours = [h for entry in stop[1:] for h in entry["hooks"]]
        self.assertEqual([h["command"] for h in ours], ["/opt/bin/claude-monitor hook", "/opt/bin/claude-monitor usage-hook"])
        self.assertTrue(all(h.get("async") for h in ours))
        session_end = data["hooks"]["SessionEnd"][0]["hooks"][0]
        self.assertNotIn("async", session_end)  # synchronous on purpose

    def test_uninstall_removes_only_ours(self):
        self.settings.write_text(json.dumps({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other-tool"}]}]}}))
        self.run_cli("install")
        self.assertEqual(self.run_cli("uninstall").exit_code, 0)
        data = json.loads(self.settings.read_text())
        self.assertEqual(data, {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other-tool"}]}]}})

    def test_unreadable_settings_are_left_alone(self):
        self.settings.write_text("{ not json")
        result = self.run_cli("install")
        self.assertNotEqual(result.exit_code, 0)
        self.assertEqual(self.settings.read_text(), "{ not json")

    def test_old_claude_version_warns(self):
        with mock.patch.object(cli_main, "_claude_version", lambda: (2, 1, 200)):
            result = self.run_cli("install")
        self.assertIn("older than 2.1.251", result.output)


if __name__ == "__main__":
    unittest.main()
