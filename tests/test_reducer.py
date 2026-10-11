import itertools
import unittest

from claude_monitor.hook import Facts, clean_prompt, fingerprint, is_injected, reduce
from claude_monitor.state import (
    BACKGROUND,
    COMPACTING,
    EXECUTING,
    PERMISSION,
    STARTING,
    SUBAGENT_LIMIT,
    THINKING,
    WAITING,
)

NO_FACTS = Facts()


def ev(event, sid="s1", **kw):
    data = {"session_id": sid, "hook_event_name": event, "cwd": "/tmp/proj", "permission_mode": "auto"}
    data.update(kw)
    return data


def bash(cmd):
    return {"tool_name": "Bash", "tool_input": {"command": cmd}}


def play(steps, state=None):
    """Apply (data, now[, facts]) steps in the given (processing) order."""
    for step in steps:
        data, now = step[0], step[1]
        facts = step[2] if len(step) > 2 else NO_FACTS
        new = reduce(state, data, facts, now)
        if new is not None:
            state = new
    return state


def started(now=1.0, prompt_at=2.0):
    return play([
        (ev("SessionStart", source="startup", model="claude-opus-5-5"), now),
        (ev("UserPromptSubmit", prompt="fix the bug"), prompt_at),
    ])


class BasicTurnTest(unittest.TestCase):
    def test_full_turn(self):
        s = play([(ev("SessionStart", source="startup", model="claude-opus-5-5"), 1.0)])
        self.assertEqual(s.status, STARTING)
        self.assertEqual(s.model, "claude-opus-5-5")
        s = play([(ev("UserPromptSubmit", prompt="fix the bug"), 2.0)], s)
        self.assertEqual((s.status, s.topic), (THINKING, "fix the bug"))
        s = play([(ev("PreToolUse", **bash("ls")), 3.0)], s)
        self.assertEqual((s.status, s.tool_name), (EXECUTING, "Bash"))
        s = play([(ev("PostToolUse", **bash("ls")), 4.0)], s)
        self.assertEqual((s.status, s.tool_name, s.tool_count), (THINKING, None, 1))
        s = play([(ev("Stop", background_tasks=[], session_crons=[]), 5.0)], s)
        self.assertEqual(s.status, WAITING)
        self.assertEqual(s.activity_ts, 5.0)

    def test_only_session_start_and_prompt_create_a_file(self):
        self.assertIsNone(reduce(None, ev("PreToolUse", **bash("ls")), NO_FACTS, 1.0))
        self.assertIsNone(reduce(None, ev("Stop"), NO_FACTS, 1.0))
        self.assertIsNotNone(reduce(None, ev("UserPromptSubmit", prompt="hi"), NO_FACTS, 1.0))

    def test_late_pre_tool_after_stop_is_ignored(self):
        s = play([(ev("Stop", background_tasks=[]), 5.0), (ev("PreToolUse", **bash("ls")), 3.0)], started())
        self.assertEqual(s.status, WAITING)

    def test_metadata_events_keep_status(self):
        s = play([
            (ev("PreToolUse", **bash("ls")), 3.0),
            (ev("PostModelSwitch", from_model="claude-opus-5-5", to_model="claude-sonnet-5-5", context_tokens=1234), 3.5),
        ], started())
        self.assertEqual((s.status, s.model, s.context_tokens), (EXECUTING, "claude-sonnet-5-5", 1234))

    def test_effort_and_mode_and_cwd(self):
        s = play([(ev("PreToolUse", cwd="/tmp/other", permission_mode="plan", effort={"level": "max"}, **bash("ls")), 3.0,
                   Facts(project="other"))], started())
        self.assertEqual((s.effort, s.permission_mode, s.cwd, s.project), ("max", "plan", "/tmp/other", "other"))

    def test_permission_denied_returns_to_thinking_without_counting(self):
        s = play([
            (ev("PreToolUse", **bash("rm -rf x")), 3.0),
            (ev("PermissionDenied", reason="[Data Exfiltration]", **bash("rm -rf x")), 3.5),
        ], started())
        self.assertEqual((s.status, s.tool_count), (THINKING, 0))


class PromptTest(unittest.TestCase):
    def test_injected_prompts_keep_topic(self):
        s = play([(ev("UserPromptSubmit", prompt="<task-notification>\n<task-id>a1</task-id>…"), 5.0)], started())
        self.assertEqual((s.status, s.topic), (THINKING, "fix the bug"))
        for tag in ("teammate-message", "cross-session-message"):
            self.assertTrue(is_injected(f"<{tag} from='x'>hi</{tag}>"))

    def test_clean_prompt(self):
        self.assertEqual(clean_prompt("<ide_selection>x</ide_selection> hello"), "hello")
        self.assertEqual(clean_prompt("<system-reminder>r</system-reminder>"), "")
        self.assertEqual(
            clean_prompt("<command-message>effort</command-message> <command-name>/effort</command-name> <command-args>max</command-args>"),
            "/effort max",
        )

    def test_long_prompt_is_capped_on_disk(self):
        s = play([(ev("UserPromptSubmit", prompt="x" * 60000), 3.0)], started())
        self.assertLessEqual(len(s.to_dict()["topic"]), 500)

    def test_title_prefers_custom_over_ai(self):
        s = play([(ev("Stop", background_tasks=[]), 5.0, Facts(ai_title="AI title"))], started())
        self.assertEqual(s.title, "AI title")
        s = play([(ev("UserPromptSubmit", prompt="more", session_title="my-name"), 6.0)], s)
        self.assertEqual(s.title, "my-name")

    def test_model_fallback_only_when_missing(self):
        s = play([
            (ev("SessionStart", source="startup"), 1.0),
            (ev("Stop", background_tasks=[]), 5.0, Facts(model="claude-opus-5-5", context_tokens=4242, last_prompt="hi")),
        ], play([(ev("UserPromptSubmit", prompt="hi"), 0.5)]))
        self.assertEqual((s.model, s.context_tokens), ("claude-opus-5-5", 4242))
        s = play([(ev("Stop", background_tasks=[]), 6.0, Facts(model="claude-haiku-5-5"))], s)
        self.assertEqual(s.model, "claude-opus-5-5")

    def test_stop_failure_sets_and_prompt_clears_error(self):
        s = play([(ev("StopFailure", error="rate_limit"), 5.0)], started())
        self.assertEqual((s.status, s.last_error), (WAITING, "rate_limit"))
        s = play([(ev("UserPromptSubmit", prompt="again"), 6.0)], s)
        self.assertEqual(s.last_error, "")


class PermissionTest(unittest.TestCase):
    def test_approved_call(self):
        s = play([
            (ev("PreToolUse", **bash("make")), 3.0),
            (ev("PermissionRequest", **bash("make")), 3.1),
        ], started())
        self.assertEqual(s.status, PERMISSION)
        s = play([(ev("PostToolUse", **bash("make")), 10.0)], s)
        self.assertEqual((s.status, s.pending), (THINKING, {}))

    def test_same_call_any_processing_order_shows_permission(self):
        for order in itertools.permutations([
            (ev("PreToolUse", **bash("make")), 3.0),
            (ev("PermissionRequest", **bash("make")), 3.1),
        ]):
            with self.subTest(order=[o[0]["hook_event_name"] for o in order]):
                self.assertEqual(play(list(order), started()).status, PERMISSION)

    def test_permission_request_with_earlier_clock_than_its_pre_tool(self):
        s = play([
            (ev("PreToolUse", **bash("make")), 3.2),
            (ev("PermissionRequest", **bash("make")), 3.1),
        ], started())
        self.assertEqual(s.status, PERMISSION)

    def test_any_order_of_pre_permission_post_ends_resolved(self):
        steps = [
            (ev("PreToolUse", **bash("make")), 3.0),
            (ev("PermissionRequest", **bash("make")), 3.1),
            (ev("PostToolUse", **bash("make")), 10.0),
        ]
        for order in itertools.permutations(steps):
            with self.subTest(order=[o[0]["hook_event_name"] for o in order]):
                s = play(list(order), started())
                self.assertEqual((s.status, s.pending), (THINKING, {}))

    def test_any_order_of_pre_permission_stop_ends_waiting(self):
        steps = [
            (ev("PreToolUse", **bash("make")), 3.0),
            (ev("PermissionRequest", **bash("make")), 3.1),
            (ev("Stop", background_tasks=[]), 5.0),
        ]
        for order in itertools.permutations(steps):
            with self.subTest(order=[o[0]["hook_event_name"] for o in order]):
                s = play(list(order), started())
                self.assertEqual((s.status, s.pending), (WAITING, {}))

    def test_manual_deny_cleared_by_next_call(self):
        s = play([
            (ev("PreToolUse", **bash("rm x")), 3.0),
            (ev("PermissionRequest", **bash("rm x")), 3.1),
            (ev("PreToolUse", **bash("ls")), 10.0),
        ], started())
        self.assertEqual((s.status, s.tool_name), (EXECUTING, "Bash"))
        self.assertEqual(s.pending, {})

    def test_parallel_call_finishing_does_not_clear_prompt(self):
        s = play([
            (ev("PreToolUse", **bash("rm x")), 3.0),
            (ev("PermissionRequest", **bash("rm x")), 3.1),
            (ev("PostToolUse", tool_name="Read", tool_input={"file_path": "/a"}), 3.5),
        ], started())
        self.assertEqual(s.status, PERMISSION)

    def test_user_input_tool(self):
        s = play([(ev("PreToolUse", tool_name="ExitPlanMode", tool_input={"plan": "p"}), 3.0)], started())
        self.assertEqual(s.status, PERMISSION)
        s = play([(ev("PostToolUse", tool_name="ExitPlanMode", tool_input={"plan": "p"}), 20.0)], s)
        self.assertEqual(s.status, THINKING)

    def test_sandbox_notification_only_while_executing(self):
        s = play([
            (ev("PreToolUse", **bash("curl x")), 3.0),
            (ev("Notification", notification_type="permission_prompt", message="Network request"), 4.0),
        ], started())
        self.assertEqual(s.status, PERMISSION)
        s = play([(ev("PostToolUse", **bash("curl x")), 9.0)], s)
        self.assertEqual(s.status, THINKING)
        s = play([(ev("Notification", notification_type="permission_prompt"), 9.5)], s)
        self.assertEqual(s.status, THINKING)

    def test_elicitation(self):
        s = play([(ev("Elicitation", mcp_server_name="srv"), 3.0)], started())
        self.assertEqual(s.status, PERMISSION)
        s = play([(ev("ElicitationResult", mcp_server_name="srv"), 4.0)], s)
        self.assertEqual(s.status, THINKING)

    def test_idle_prompt_clears_everything(self):
        s = play([
            (ev("SubagentStart", agent_id="a1", agent_type="Explore"), 3.0),
            (ev("PermissionRequest", agent_id="a1", **bash("x")), 4.0),
            (ev("Notification", notification_type="idle_prompt"), 70.0),
        ], started())
        self.assertEqual((s.status, s.pending, s.subagents), (WAITING, {}, []))

    def test_late_idle_prompt_ignored(self):
        s = play([
            (ev("UserPromptSubmit", prompt="next"), 80.0),
            (ev("Notification", notification_type="idle_prompt"), 70.0),
        ], started())
        self.assertEqual(s.status, THINKING)


class SubagentTest(unittest.TestCase):
    def test_subagent_tools_do_not_touch_main(self):
        s = play([
            (ev("SubagentStart", agent_id="a1", agent_type="Explore"), 3.0, Facts(agent_description="Scan repo")),
            (ev("PreToolUse", agent_id="a1", agent_type="Explore", cwd="/tmp/wt", permission_mode="plan",
                tool_name="Read", tool_input={"file_path": "/a"}), 4.0),
        ], started())
        self.assertEqual((s.status, s.tool_name, s.tool_count, s.cwd, s.permission_mode), (THINKING, None, 0, "/tmp/proj", "auto"))
        sa = s.find_subagent("a1")
        self.assertEqual((sa.tool_name, sa.description), ("Read", "Scan repo"))
        s = play([(ev("PostToolUse", agent_id="a1", tool_name="Read", tool_input={"file_path": "/a"}), 5.0)], s)
        sa = s.find_subagent("a1")
        self.assertEqual((sa.tool_name, sa.tool_count, s.tool_count), (None, 1, 0))

    def test_subagent_permission(self):
        s = play([
            (ev("SubagentStart", agent_id="a1"), 3.0),
            (ev("PermissionRequest", agent_id="a1", **bash("make")), 4.0),
        ], started())
        self.assertEqual(s.status, PERMISSION)
        self.assertEqual(s.to_dict()["subagents"][0]["status"], "permission")
        s = play([(ev("PostToolUse", agent_id="a1", **bash("make")), 9.0)], s)
        self.assertEqual(s.status, THINKING)

    def test_subagent_stop_clears_its_prompt(self):
        s = play([
            (ev("SubagentStart", agent_id="a1"), 3.0),
            (ev("PermissionRequest", agent_id="a1", **bash("make")), 4.0),
            (ev("SubagentStop", agent_id="a1"), 5.0),
        ], started())
        self.assertEqual((s.status, s.subagents), (THINKING, []))

    def test_background_agents_survive_stop(self):
        s = play([
            (ev("SubagentStart", agent_id="a1", agent_type="Explore"), 3.0),
            (ev("Stop", background_tasks=[
                {"id": "a1", "type": "subagent", "status": "running", "description": "Scan", "agent_type": "Explore"},
                {"id": "a2", "type": "subagent", "status": "running", "description": "Missed", "agent_type": "Plan"},
                {"id": "t9", "type": "shell", "status": "running", "description": "dev server", "command": "npm run dev"},
            ]), 5.0),
        ], started())
        self.assertEqual(s.status, BACKGROUND)
        self.assertEqual({sa.agent_id for sa in s.subagents}, {"a1", "a2"})
        self.assertEqual((s.bg_active, s.bg_types), (2, {"subagent": 2, "shell": 1}))
        s = play([(ev("SubagentStop", agent_id="a1", background_tasks=[
            {"id": "a2", "type": "subagent", "status": "running"}]), 6.0)], s)
        self.assertEqual((s.status, s.bg_active), (BACKGROUND, 1))
        s = play([
            (ev("UserPromptSubmit", prompt="<task-notification><task-id>a1</task-id></task-notification>"), 7.0),
            (ev("Stop", background_tasks=[{"id": "a2", "type": "subagent", "status": "completed"}]), 8.0),
        ], s)
        self.assertEqual((s.status, s.subagents, s.topic), (WAITING, [], "fix the bug"))

    def test_only_passive_tasks_mean_waiting(self):
        s = play([(ev("Stop", background_tasks=[{"id": "t1", "type": "shell", "status": "running"}]), 5.0)], started())
        self.assertEqual((s.status, s.bg_active, s.bg_types), (WAITING, 0, {"shell": 1}))

    def test_workflow_keeps_tracked_agents(self):
        s = play([
            (ev("SubagentStart", agent_id="w1", agent_type="general-purpose"), 3.0),
            (ev("Stop", background_tasks=[{"id": "wf", "type": "workflow", "status": "running", "name": "review"}]), 5.0),
        ], started())
        self.assertEqual(s.status, BACKGROUND)
        self.assertEqual([sa.agent_id for sa in s.subagents], ["w1"])

    def test_stop_without_task_info_is_legacy(self):
        s = play([(ev("SubagentStart", agent_id="a1"), 3.0), (ev("Stop"), 5.0)], started())
        self.assertEqual((s.status, s.subagents), (WAITING, []))

    def test_late_events_do_not_resurrect_ended_agents(self):
        s = play([
            (ev("SubagentStart", agent_id="a1"), 3.0),
            (ev("SubagentStop", agent_id="a1"), 6.0),
            (ev("PostToolUse", agent_id="a1", **bash("x")), 5.0),
            (ev("SubagentStart", agent_id="a1"), 3.0),
        ], started())
        self.assertEqual(s.subagents, [])
        s = play([(ev("SubagentStart", agent_id="a1"), 9.0)], s)  # resumed later
        self.assertEqual([sa.agent_id for sa in s.subagents], ["a1"])

    def test_subagent_cap(self):
        steps = [(ev("SubagentStart", agent_id=f"a{i}"), 3.0 + i / 1000) for i in range(SUBAGENT_LIMIT + 5)]
        s = play(steps, started())
        self.assertEqual((len(s.subagents), s.subagents_overflow), (SUBAGENT_LIMIT, 5))


class LifecycleTest(unittest.TestCase):
    def test_compaction(self):
        s = play([(ev("PreCompact", trigger="auto"), 3.0)], started())
        self.assertEqual(s.status, COMPACTING)
        self.assertEqual(play([(ev("PostCompact", trigger="auto"), 4.0)], s).status, THINKING)
        s = play([(ev("PostCompact", trigger="manual"), 4.0), (ev("SessionStart", source="compact"), 4.1)], s)
        self.assertEqual(s.status, WAITING)

    def test_session_start_compact_after_pre_compact(self):
        s = play([(ev("PreCompact", trigger="auto"), 3.0), (ev("SessionStart", source="compact"), 4.0)], started())
        self.assertEqual(s.status, THINKING)

    def test_resume_resets_transient_state(self):
        s = play([
            (ev("SubagentStart", agent_id="a1"), 3.0),
            (ev("PermissionRequest", **bash("x")), 3.5),
            (ev("Stop", background_tasks=[{"id": "a1", "type": "subagent", "status": "running"}]), 5.0),
            (ev("SessionStart", source="resume"), 500.0),
        ], started())
        self.assertEqual((s.status, s.subagents, s.pending, s.topic), (STARTING, [], {}, "fix the bug"))

    def test_resume_racing_first_prompt(self):
        s = play([
            (ev("UserPromptSubmit", prompt="continue"), 10.0),
            (ev("SessionStart", source="resume"), 11.0),
        ])
        self.assertEqual(s.status, THINKING)

    def test_fingerprint_is_stable_and_input_sensitive(self):
        self.assertEqual(fingerprint(bash("a")), fingerprint(bash("a")))
        self.assertNotEqual(fingerprint(bash("a")), fingerprint(bash("b")))
        self.assertEqual(fingerprint({"tool_name": "X"}), "")


if __name__ == "__main__":
    unittest.main()
