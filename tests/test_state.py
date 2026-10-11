import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from claude_monitor import hook, state
from claude_monitor.state import PERMISSION, SessionState, SubagentState

FIXTURES = Path(__file__).parent / "fixtures"


class TempDirs(unittest.TestCase):
    """Point the monitor dir and Claude's config dir at a fresh temp dir."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.monitor = self.root / "monitor"
        self.config = self.root / "config"
        (self.config / "sessions").mkdir(parents=True)
        patcher = mock.patch.dict(os.environ, {
            "CLAUDE_MONITOR_DIR": str(self.monitor),
            "CLAUDE_CONFIG_DIR": str(self.config),
        })
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self._tmp.cleanup)


class SchemaTest(unittest.TestCase):
    def test_round_trip(self):
        data = json.loads((FIXTURES / "session_v2.json").read_text())
        s = SessionState.from_dict(data)
        self.assertEqual(s.to_dict(), data)

    def test_legacy_permission_becomes_pending_main(self):
        data = json.loads((FIXTURES / "session_v1.json").read_text())
        s = SessionState.from_dict(data)
        self.assertEqual(s.status, PERMISSION)
        self.assertEqual(s.base_status, "EXECUTING")
        self.assertEqual(s.pending["main"]["tool"], "ExitPlanMode")
        self.assertEqual(s.ai_title, "Feature X implementation")
        self.assertEqual(s.subagents[0].agent_id, "sub-456")
        self.assertGreater(s.activity_ts, 0)

    def test_derived_legacy_fields(self):
        s = SessionState(session_id="x", base_status="WAITING", activity_ts=1_000_000.0,
                         pending={"a1": {"tool": "Bash", "fp": "f", "since": 1.0}},
                         subagents=[SubagentState(agent_id="a1"), SubagentState(agent_id="a2")])
        d = s.to_dict()
        self.assertEqual(d["status"], PERMISSION)
        self.assertEqual([sa["status"] for sa in d["subagents"]], ["permission", "running"])
        self.assertTrue(d["last_updated"].startswith("1970-01-12"))

    def test_garbage_is_tolerated(self):
        s = SessionState.from_dict({"session_id": 5, "pending": {"x": "bad"}, "subagents": ["bad", {}],
                                    "ended_agents": "nope", "tool_count": "3"}, fallback_id="fb")
        self.assertEqual((s.session_id, s.pending, s.subagents, s.tool_count), ("fb", {}, [], 0))


class StorageTest(TempDirs):
    def test_write_read_and_tmp_location(self):
        s = SessionState(session_id="abc", base_status="THINKING", activity_ts=time.time())
        state.write_session(s)
        self.assertEqual(state.read_session("abc").base_status, "THINKING")
        self.assertEqual([p.name for p in state.sessions_dir().iterdir()], ["abc.json"])

    def test_list_sessions_never_deletes(self):
        state.write_session(SessionState(session_id="old", activity_ts=1.0))
        self.assertEqual([s.session_id for s in state.list_sessions()], ["old"])
        self.assertTrue(state.session_path("old").exists())

    def test_gc_keeps_live_and_recent(self):
        now = time.time()
        for sid, ts in (("old-dead", now - 90000), ("old-live", now - 90000), ("recent", now - 60)):
            state.write_session(SessionState(session_id=sid, activity_ts=ts))
        stray = state.sessions_dir() / "tmpabc.tmp"
        stray.write_text("")
        os.utime(stray, (now - 7200, now - 7200))
        removed = state.gc({"old-live"}, now)
        self.assertEqual(removed, 1)
        self.assertEqual(sorted(s.session_id for s in state.list_sessions()), ["old-live", "recent"])
        self.assertFalse(stray.exists())

    def test_write_lock_times_out(self):
        with state.write_lock() as first:
            self.assertTrue(first)
            pid = os.fork()
            if pid == 0:  # child: the parent holds the lock
                with state.write_lock(timeout=0.05) as second:
                    os._exit(0 if second is False else 1)
            _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0)


class HandleHookTest(TempDirs):
    def hook(self, event, now, **kw):
        data = {"session_id": "s1", "hook_event_name": event, "cwd": str(self.root), "permission_mode": "auto"}
        data.update(kw)
        hook.handle_hook(data, now)

    def test_lifecycle(self):
        self.hook("PreToolUse", 1.0, tool_name="Bash", tool_input={"command": "ls"})
        self.assertFalse(state.session_path("s1").exists())  # only start/prompt create files
        self.hook("SessionStart", 2.0, source="startup", model="claude-opus-5-5")
        self.hook("UserPromptSubmit", 3.0, prompt="hello")
        self.assertEqual(state.read_session("s1").status, "THINKING")
        self.hook("SessionEnd", 4.0, reason="other")
        self.assertFalse(state.session_path("s1").exists())
        self.hook("Stop", 5.0, background_tasks=[])  # late event: no resurrection
        self.assertFalse(state.session_path("s1").exists())

    def test_session_start_runs_gc_with_registry_liveness(self):
        old = time.time() - 90000
        state.write_session(SessionState(session_id="dead", activity_ts=old))
        state.write_session(SessionState(session_id="alive", activity_ts=old))
        (self.config / "sessions" / f"{os.getpid()}.json").write_text(json.dumps(
            {"pid": os.getpid(), "sessionId": "alive", "startedAt": 1}))
        self.hook("SessionStart", time.time(), source="startup")
        self.assertEqual(sorted(s.session_id for s in state.list_sessions()), ["alive", "s1"])

    def test_main_never_raises(self):
        with mock.patch("sys.stdin") as stdin:
            stdin.read.return_value = "{not json"
            hook.main()
            stdin.read.return_value = "[]"
            hook.main()


class ProjectNameTest(TempDirs):
    def test_repo_worktree_and_plain_dir(self):
        repo = self.root / "myrepo"
        (repo / ".git" / "worktrees" / "feat").mkdir(parents=True)
        (repo / "src").mkdir()
        wt = repo / ".claude" / "worktrees" / "feat"
        (wt / "pkg").mkdir(parents=True)
        (wt / ".git").write_text(f"gitdir: {repo}/.git/worktrees/feat\n")
        sub = self.root / "outer" / "lib"
        sub.mkdir(parents=True)
        (sub / ".git").write_text("gitdir: ../.git/modules/lib\n")
        self.assertEqual(hook.project_name(str(repo / "src")), "myrepo")
        self.assertEqual(hook.project_name(str(wt / "pkg")), "myrepo/feat")
        self.assertEqual(hook.project_name(str(sub)), "lib")
        self.assertEqual(hook.project_name(str(self.root / "nogit")), "nogit")


class TranscriptTest(TempDirs):
    def write_transcript(self, entries, filler=0):
        path = self.root / "t.jsonl"
        lines = [json.dumps(e) for e in entries]
        if filler:
            lines = [json.dumps({"type": "attachment", "x": "y" * 1000})] * filler + lines
        path.write_text("\n".join(lines) + "\n")
        return str(path)

    def test_scan_extracts_latest_facts(self):
        path = self.write_transcript([
            {"type": "ai-title", "aiTitle": "Old title"},
            {"type": "user", "message": {"content": "first prompt"}},
            {"type": "assistant", "message": {"model": "claude-opus-5-5",
                                              "usage": {"input_tokens": 10, "cache_read_input_tokens": 1000,
                                                        "cache_creation_input_tokens": 90, "output_tokens": 50}}},
            {"type": "assistant", "isSidechain": True, "message": {"model": "claude-haiku-5-5"}},
            {"type": "assistant", "message": {"model": "<synthetic>"}},
            {"type": "user", "message": {"content": "<task-notification><task-id>a</task-id></task-notification>"}},
            {"type": "user", "isCompactSummary": True, "message": {"content": "This session is being continued"}},
            {"type": "ai-title", "aiTitle": "Line separated title"},
        ])
        f = hook.scan_transcript_tail(path)
        self.assertEqual((f.model, f.context_tokens, f.last_prompt), ("claude-opus-5-5", 1150, "first prompt"))
        self.assertEqual(f.ai_title, "Line separated title")

    def test_last_prompt_entry_wins_and_window_grows(self):
        path = self.write_transcript([
            {"type": "last-prompt", "lastPrompt": "the human prompt"},
            {"type": "assistant", "message": {"model": "claude-sonnet-5-5"}},
        ] + [{"type": "attachment", "x": "y" * 1000}] * 200)
        f = hook.scan_transcript_tail(path, start=4096)
        self.assertEqual((f.last_prompt, f.model), ("the human prompt", "claude-sonnet-5-5"))

    def test_missing_transcript(self):
        self.assertEqual(hook.scan_transcript_tail(str(self.root / "nope.jsonl")), hook.Facts())

    def test_agent_description(self):
        transcript = self.root / "sess.jsonl"
        meta = self.root / "sess" / "subagents" / "agent-a1.meta.json"
        meta.parent.mkdir(parents=True)
        meta.write_text(json.dumps({"agentType": "Explore", "description": "Scan the repo"}))
        self.assertEqual(hook.read_agent_description(str(transcript), "a1"), "Scan the repo")
        self.assertEqual(hook.read_agent_description(str(transcript), "a2"), "")


if __name__ == "__main__":
    unittest.main()
