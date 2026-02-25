"""Hook handler for Claude Code events.

Reads JSON from stdin and writes session state files.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from claude_monitor.state import SessionState, SubagentState, remove_session, write_session

# Tools that wait for user input (not tool permissions)
_USER_INPUT_TOOLS = {"ExitPlanMode", "AskUserQuestion"}

# Map hook events to session states
EVENT_STATE_MAP = {
    "SessionStart": "STARTING",
    "UserPromptSubmit": "THINKING",
    "PreToolUse": "EXECUTING",
    "PermissionRequest": "PERMISSION",
    "PostToolUse": "THINKING",
    "Stop": "WAITING",
    "Notification": None,  # handled separately
    "SessionEnd": "ENDED",
}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _project_name(cwd: str) -> str:
    """Extract project name from git root, falling back to cwd basename."""
    if not cwd:
        return ""
    p = Path(cwd)
    # Walk up to find git root
    for d in [p, *p.parents]:
        if (d / ".git").exists():
            return d.name
        if d == d.parent:
            break
    return p.name


_IDE_TAG_RE = re.compile(r"<ide_\w+>.*?</ide_\w+>", re.DOTALL)
_SYSTEM_TAG_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL)


def _clean_prompt(text: str) -> str:
    """Strip IDE context tags and system reminders from a prompt."""
    text = _IDE_TAG_RE.sub("", text)
    text = _SYSTEM_TAG_RE.sub("", text)
    return text.strip()


def _read_topic_from_transcript(transcript_path: str) -> str:
    """Read the first user message from a transcript JSONL file."""
    if not transcript_path:
        return ""
    try:
        p = Path(transcript_path)
        if not p.exists():
            return ""
        with open(p) as f:
            for line in f:
                try:
                    obj = json.loads(line)
                    if obj.get("type") == "user":
                        content = obj.get("message", {}).get("content", "")
                        if isinstance(content, str):
                            cleaned = _clean_prompt(content)
                            if cleaned:
                                return cleaned
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return ""


def _handle_subagent(session_id: str, event: str, data: dict) -> None:
    """Handle SubagentStart/SubagentStop by updating the session's subagent list."""
    from claude_monitor.state import _session_path

    agent_id = data.get("agent_id", "")
    agent_type = data.get("agent_type", "")
    now = _now_iso()

    path = _session_path(session_id)
    if not path.exists():
        return

    try:
        existing = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return

    subagents: list[dict] = existing.get("subagents", [])

    if event == "SubagentStart":
        # Add new subagent (avoid duplicates)
        if not any(sa.get("agent_id") == agent_id for sa in subagents):
            subagents.append({
                "agent_id": agent_id,
                "agent_type": agent_type,
                "status": "running",
                "last_updated": now,
            })
    elif event == "SubagentStop":
        # Remove completed subagent
        subagents = [sa for sa in subagents if sa.get("agent_id") != agent_id]

    existing["subagents"] = subagents
    existing["last_updated"] = now

    status = existing.get("status", "STARTING")
    # If launching a subagent, Claude is actively working — PERMISSION is stale
    # (race: SubagentStart read the file before PostToolUse wrote THINKING)
    if event == "SubagentStart" and status == "PERMISSION":
        status = "THINKING"

    state = SessionState(
        session_id=existing.get("session_id", session_id),
        cwd=existing.get("cwd", ""),
        project=existing.get("project", ""),
        status=status,
        tool_name=existing.get("tool_name"),
        permission_mode=existing.get("permission_mode", ""),
        model=existing.get("model", ""),
        topic=existing.get("topic", ""),
        last_prompt=existing.get("last_prompt", ""),
        tool_count=existing.get("tool_count", 0),
        started_at=existing.get("started_at", now),
        last_updated=now,
        subagents=[
            SubagentState(
                agent_id=sa.get("agent_id", ""),
                agent_type=sa.get("agent_type", ""),
                status=sa.get("status", "running"),
                last_updated=sa.get("last_updated", ""),
            )
            for sa in subagents
        ],
    )
    write_session(state)


def handle_hook(data: dict) -> None:
    """Process a single hook event."""
    session_id = data.get("session_id", "")
    if not session_id:
        return

    event = data.get("hook_event_name", "")
    new_status = EVENT_STATE_MAP.get(event)

    # PreToolUse for user-input tools → PERMISSION
    if event == "PreToolUse" and data.get("tool_name") in _USER_INPUT_TOOLS:
        new_status = "PERMISSION"

    if event == "SessionEnd":
        remove_session(session_id)
        return

    if event in ("SubagentStart", "SubagentStop"):
        _handle_subagent(session_id, event, data)
        return

    # Notification with permission_prompt → PERMISSION state
    if event == "Notification":
        if data.get("notification_type") == "permission_prompt":
            new_status = "PERMISSION"
        else:
            # Other notifications: keep current state, just update timestamp
            new_status = None

    if new_status is None and event not in ("Notification",):
        return

    cwd = data.get("cwd", "")
    tool_name = data.get("tool_name") if event in ("PreToolUse", "PermissionRequest") else None
    permission_mode = data.get("permission_mode", "")
    now = _now_iso()

    # Try to read existing state to preserve fields
    from claude_monitor.state import _session_path

    existing_status = "STARTING"
    existing_started = now
    existing_tool = None
    existing_model = ""
    existing_topic = ""
    existing_prompt = ""
    existing_tool_count = 0
    existing_subagents: list[SubagentState] = []
    path = _session_path(session_id)
    if path.exists():
        try:
            existing = json.loads(path.read_text())
            existing_status = existing.get("status", "STARTING")
            existing_started = existing.get("started_at", now)
            existing_tool = existing.get("tool_name")
            existing_model = existing.get("model", "")
            existing_topic = existing.get("topic", "")
            existing_prompt = existing.get("last_prompt", "")
            existing_tool_count = existing.get("tool_count", 0)
            existing_subagents = [
                SubagentState(
                    agent_id=sa.get("agent_id", ""),
                    agent_type=sa.get("agent_type", ""),
                    status=sa.get("status", "running"),
                    last_updated=sa.get("last_updated", ""),
                )
                for sa in existing.get("subagents", [])
                if isinstance(sa, dict)
            ]
        except (json.JSONDecodeError, OSError):
            pass

    # Prevent PERMISSION-setting events from regressing state (async race).
    # Since hooks run with "async": True, a delayed PermissionRequest can
    # arrive after Stop has already moved the state to WAITING (e.g. user
    # pressed Escape or chose "Other" during a permission prompt).
    # NOTE: we must NOT block THINKING here because PermissionRequest often
    # arrives before PreToolUse due to async scheduling — blocking THINKING
    # would prevent PERMISSION from ever being displayed.
    if new_status == "PERMISSION":
        if existing_status == "WAITING":
            return
        # Notification is always a secondary signal — block more aggressively
        if event == "Notification" and existing_status in ("THINKING", "EXECUTING", "WAITING"):
            return

    status = new_status if new_status else existing_status
    if event not in ("PreToolUse", "PermissionRequest"):
        tool_name = None

    # Extract model from SessionStart
    model = data.get("model", "") if event == "SessionStart" else existing_model

    # Extract last prompt from UserPromptSubmit
    last_prompt = data.get("prompt", "") if event == "UserPromptSubmit" else existing_prompt

    # Extract topic: always update to latest user prompt, clean IDE tags
    topic = existing_topic
    if event == "UserPromptSubmit" and data.get("prompt"):
        cleaned = _clean_prompt(data["prompt"])
        if cleaned:
            topic = cleaned
    elif not topic:
        topic = _read_topic_from_transcript(data.get("transcript_path", ""))

    # Increment tool count on PostToolUse
    tool_count = existing_tool_count
    if event == "PostToolUse":
        tool_count += 1

    # Clear subagents on Stop — all subagents have already finished
    subagents = existing_subagents if event != "Stop" else []

    state = SessionState(
        session_id=session_id,
        cwd=cwd or "",
        project=_project_name(cwd),
        status=status,
        tool_name=tool_name,
        permission_mode=permission_mode,
        model=model,
        topic=topic,
        last_prompt=last_prompt,
        tool_count=tool_count,
        started_at=existing_started,
        last_updated=now,
        subagents=subagents,
    )

    write_session(state)


def main() -> None:
    """Entry point: read JSON from stdin and process."""
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return
        data = json.loads(raw)
        handle_hook(data)
    except Exception:
        pass


if __name__ == "__main__":
    main()
