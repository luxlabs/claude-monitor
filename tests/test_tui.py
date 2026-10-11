import os
import tempfile
import time
import unittest
from unittest import mock

from claude_monitor import live, state, tui
from claude_monitor.live import LiveEntry, Snapshot
from claude_monitor.state import SessionState, SubagentState


class TuiTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        env = mock.patch.dict(os.environ, {"CLAUDE_MONITOR_DIR": self._tmp.name})
        env.start()
        self.addCleanup(env.stop)
        now = time.time()
        state.write_session(SessionState(
            session_id="tracked", project="proj", base_status="BACKGROUND", status_ts=now - 5,
            activity_ts=now - 5, model="claude-opus-5-5", effort="max", context_tokens=412345,
            permission_mode="default", last_error="rate_limit", bg_active=1,
            subagents=[SubagentState(agent_id="a1", agent_type="Explore", description="Scan [repo]", tool_name="Read", ts=now - 5)],
            subagents_overflow=2, topic="fix [the] bug",
        ))
        state.write_session(SessionState(session_id="probe", project="ClaudeProbe", base_status="THINKING",
                                         status_ts=now, activity_ts=now))
        self.snapshot = Snapshot(observed_at=now, entries={
            "tracked": LiveEntry(session_id="tracked", pid=111, status="idle", name="proj-1a"),
            "busy-untracked": LiveEntry(session_id="busy-untracked", pid=222, status="busy", cwd="/x/other", name="other-2b"),
            "idle-untracked": LiveEntry(session_id="idle-untracked", pid=333, status="idle", cwd="/x/old", name="old-3c"),
        })
        poll = mock.patch.object(live, "poll", return_value=self.snapshot)
        poll.start()
        self.addCleanup(poll.stop)

    async def settle(self, app, pilot):
        await app.workers.wait_for_complete()
        await pilot.pause()

    async def test_rows_toggle_and_confirm(self):
        app = tui.ClaudeMonitorApp()
        async with app.run_test(size=(160, 30)) as pilot:
            await self.settle(app, pilot)
            self.assertEqual(app._keys, ["busy-untracked", "tracked", "tracked/a1", "tracked/+more"])
            cells = app._cells["tracked"]
            self.assertIn("BACKGROUND", cells[1])
            self.assertIn("rate_limit", cells[1])
            self.assertEqual(cells[3], "opus 5.5 · max")
            self.assertEqual((cells[4], cells[5]), ("manual", "412k"))

            await pilot.press("i")
            await pilot.pause()
            self.assertIn("idle-untracked", app._keys)

            await pilot.press("k")  # cursor is on the first row: busy-untracked
            await pilot.pause()
            self.assertIsInstance(app.screen, tui.ConfirmScreen)
            await pilot.press("n")
            await pilot.pause()
            self.assertNotIsInstance(app.screen, tui.ConfirmScreen)

    async def test_hooks_only_mode_without_live_data(self):
        with mock.patch.object(live, "poll", return_value=None):
            app = tui.ClaudeMonitorApp()
            async with app.run_test(size=(160, 30)) as pilot:
                await self.settle(app, pilot)
                self.assertEqual(app._keys, ["tracked", "tracked/a1", "tracked/+more"])


if __name__ == "__main__":
    unittest.main()
