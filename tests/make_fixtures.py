"""Regenerate the session-file fixtures from the real writer.

    PYTHONPATH=src python3 tests/make_fixtures.py

session_v2.json is what state.to_dict() writes today; session_v1.json is the
schema the July 2026 version wrote. The Swift tests decode both.
"""

import json
from pathlib import Path

from claude_monitor.state import SessionState, SubagentState

FIXTURES = Path(__file__).parent / "fixtures"


def main() -> None:
    state = SessionState(
        session_id="11111111-2222-3333-4444-555555555555",
        cwd="/Users/me/project/src",
        project="project",
        base_status="EXECUTING",
        status_ts=1791702455.25,
        activity_ts=1791702460.5,
        tool_name="Bash",
        tool_fp="0a1b2c3d4e5f",
        permission_mode="auto",
        model="claude-opus-5-5",
        effort="max",
        context_tokens=412345,
        topic="Fix the flaky test",
        last_prompt="Fix the flaky test",
        custom_title="flaky-test",
        ai_title="Flaky test fix",
        tool_count=12,
        started_at="2026-10-11T07:07:34.767302+00:00",
        pending={"a72b09f1ce480cbcf": {"tool": "Bash", "fp": "ffeeddccbbaa", "since": 1791702459.0}},
        bg_active=2,
        bg_types={"subagent": 2, "shell": 1},
        crons=1,
        subagents=[
            SubagentState(
                agent_id="a72b09f1ce480cbcf", agent_type="Explore", description="Changelog analysis",
                tool_name="Read", tool_count=5, started_at="2026-10-11T07:10:49.529418+00:00", ts=1791702459.0,
            ),
            SubagentState(
                agent_id="ab0000000000000ff", agent_type="general-purpose",
                started_at="2026-10-11T07:11:00+00:00", ts=1791702460.5,
            ),
        ],
        subagents_overflow=3,
        ended_agents=[["a0000000000000001", 1791702400.0]],
        done_calls=["main:0a1b2c3d4e5f"],
    )
    (FIXTURES / "session_v2.json").write_text(json.dumps(state.to_dict(), indent=2, ensure_ascii=False) + "\n")

    legacy = {
        "session_id": "abc-123",
        "cwd": "/path/to/project",
        "project": "my-project",
        "status": "PERMISSION",
        "tool_name": "ExitPlanMode",
        "permission_mode": "default",
        "model": "claude-opus-4-8",
        "topic": "Implement feature X",
        "title": "Feature X implementation",
        "last_prompt": "Implement feature X",
        "tool_count": 12,
        "started_at": "2025-01-15T10:30:00+00:00",
        "last_updated": "2025-01-15T10:35:22+00:00",
        "subagents": [
            {"agent_id": "sub-456", "agent_type": "Explore", "status": "running",
             "last_updated": "2025-01-15T10:34:00+00:00"},
        ],
    }
    (FIXTURES / "session_v1.json").write_text(json.dumps(legacy, indent=2) + "\n")


if __name__ == "__main__":
    main()
