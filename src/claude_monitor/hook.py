"""Hook handler for Claude Code events.

Reads JSON from stdin and writes session state files.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from claude_monitor.state import (
    SessionState,
    SubagentState,
    remove_session,
    write_lock,
    write_session,
)

# Tools that wait for user input (not tool permissions)
_USER_INPUT_TOOLS = {"ExitPlanMode", "AskUserQuestion"}

# Map hook events to session states.
#
# Recent Claude Code versions split the old single post-tool / stop events
# into success/failure pairs, so we must handle both halves:
#   * PostToolUse fires only on success now; PostToolUseFailure on failure.
#   * Stop fires on a normal turn end; StopFailure on an API error.
# Without the *Failure events a session gets stuck showing EXECUTING/THINKING
# after a failed tool call or an API error until the zombie reaper removes it.
EVENT_STATE_MAP = {
    "SessionStart": "STARTING",
    "UserPromptSubmit": "THINKING",
    "PreToolUse": "EXECUTING",
    "PermissionRequest": "PERMISSION",
    "PostToolUse": "THINKING",
    "PostToolUseFailure": "THINKING",  # tool failed; Claude keeps working
    "Stop": "WAITING",
    "StopFailure": "WAITING",  # turn ended on an API error; session now idle
    "Elicitation": "PERMISSION",  # MCP server is waiting on the user
    "ElicitationResult": "THINKING",  # user answered the MCP prompt
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


def _content_to_text(content) -> str:
    """Flatten a message ``content`` to plain text.

    Handles both the plain-string form and the Anthropic content-block list
    form (``[{"type": "text", "text": ...}, ...]``), so the topic still resolves
    if Claude Code stores user content as blocks instead of a bare string.
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
        return " ".join(p for p in parts if p)
    return ""


def _read_topic_from_transcript(transcript_path: str) -> str:
    """Read the first real user prompt from a transcript JSONL file.

    Skips meta entries and subagent sidechain turns — both now appear in the
    transcript — so the topic reflects the user's actual first message rather
    than an injected reminder or a subagent's internal prompt.
    """
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
                except json.JSONDecodeError:
                    continue
                if obj.get("type") != "user":
                    continue
                # Skip system/meta injections and subagent sidechain turns.
                if obj.get("isMeta") or obj.get("isSidechain"):
                    continue
                content = obj.get("message", {}).get("content", "")
                cleaned = _clean_prompt(_content_to_text(content))
                if cleaned:
                    return cleaned
    except OSError:
        pass
    return ""


def _read_ai_title_from_transcript(transcript_path: str, tail_bytes: int = 131072) -> str:
    """Return the most recent AI-generated session title from the transcript.

    Claude Code writes ``{"type": "ai-title", "aiTitle": ...}`` entries and
    regenerates the title as the session evolves, so the latest is near the end.
    We read only the tail of the file to stay cheap on long transcripts.
    """
    if not transcript_path:
        return ""
    try:
        p = Path(transcript_path)
        if not p.exists():
            return ""
        size = p.stat().st_size
        with open(p, "rb") as f:
            if size > tail_bytes:
                f.seek(size - tail_bytes)
                f.readline()  # discard the partial first line
            chunk = f.read()
    except OSError:
        return ""

    title = ""
    for raw in chunk.splitlines():
        try:
            obj = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(obj, dict) and obj.get("type") == "ai-title":
            candidate = obj.get("aiTitle", "")
            if isinstance(candidate, str) and candidate.strip():
                title = candidate.strip()
    return title


def _handle_subagent(session_id: str, event: str, data: dict) -> None:
    """Handle SubagentStart/SubagentStop by updating the session's subagent list."""
    from claude_monitor.state import _session_path

    agent_id = data.get("agent_id", "")
    agent_type = data.get("agent_type", "")
    now = _now_iso()

    path = _session_path(session_id)

    # Hold the lock across the read AND the write. Workflows spawn up to 16
    # subagents at once and hooks run async (parallel processes), so an unlocked
    # read-modify-write here silently drops subagents from the list.
    with write_lock():
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
        # If launching a subagent, Claude is actively working — PERMISSION is
        # stale (race: SubagentStart read the file before PostToolUse wrote
        # THINKING)
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
            title=existing.get("title", ""),
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
        # We already read the freshest state under the lock, so this idempotent
        # add/remove must always win — bypass the timestamp anti-regression.
        write_session(state, check_regression=False)


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
        with write_lock():
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

    # Refresh the AI-generated title at turn boundaries. Do the transcript read
    # BEFORE taking the lock — it touches the transcript, not the session file,
    # so holding the global lock during it would needlessly block other sessions'
    # hooks (e.g. this session's PreToolUse waiting on another session's Stop).
    fresh_title = ""
    if event in ("SessionStart", "UserPromptSubmit", "Stop", "StopFailure"):
        fresh_title = _read_ai_title_from_transcript(data.get("transcript_path", ""))

    # Read existing state, apply this event, and write — all under one lock so a
    # concurrent subagent event (workflows spawn up to 16 at once) can't slip in
    # between our read and write and get dropped when we rewrite the file.
    from claude_monitor.state import _session_path

    with write_lock():
        existing_status = "STARTING"
        existing_started = now
        existing_tool = None
        existing_model = ""
        existing_topic = ""
        existing_title = ""
        existing_updated = ""
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
                existing_title = existing.get("title", "")
                existing_updated = existing.get("last_updated", "")
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

        # A PreToolUse that lands right after a permission prompt was raised is
        # the async-reordered event for the SAME tool call (hooks run async, so
        # PreToolUse and PermissionRequest can be processed out of order) — it
        # must not flip the active prompt back to EXECUTING. A genuine next
        # PreToolUse (e.g. after the user denies) arrives seconds later and is
        # allowed through to clear PERMISSION.
        if (event == "PreToolUse" and new_status == "EXECUTING"
                and existing_status == "PERMISSION"):
            try:
                prev = datetime.fromisoformat(existing_updated)
                if (datetime.now(timezone.utc) - prev).total_seconds() < 3.0:
                    return
            except (ValueError, TypeError):
                pass

        status = new_status if new_status else existing_status

        # Compaction fires SessionStart(source="compact") mid-session. Don't
        # regress a session that is actively working back to STARTING.
        if event == "SessionStart" and data.get("source") == "compact":
            status = existing_status

        # ElicitationResult only clears the PERMISSION set by Elicitation; keep
        # the real state otherwise so a late event can't revive a moved-on one.
        if event == "ElicitationResult":
            status = "THINKING" if existing_status == "PERMISSION" else existing_status

        if event not in ("PreToolUse", "PermissionRequest"):
            tool_name = None

        # Extract model from SessionStart. It may be omitted (e.g. on a "compact"
        # or "resume" start), so only overwrite when a value is present —
        # otherwise keep the model we already recorded.
        model = existing_model
        if event == "SessionStart" and data.get("model"):
            model = data["model"]

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

        # Apply the title read before the lock (fresh_title is "" when this
        # isn't a turn-boundary event or no ai-title exists yet).
        title = fresh_title or existing_title

        # Increment tool count when a tool finishes — success (PostToolUse) or
        # failure (PostToolUseFailure) both mean one more tool call completed.
        tool_count = existing_tool_count
        if event in ("PostToolUse", "PostToolUseFailure"):
            tool_count += 1

        # Clear subagents when the turn ends — on a normal Stop or an API-error
        # StopFailure, any subagents have finished or been aborted with the turn.
        subagents = [] if event in ("Stop", "StopFailure") else existing_subagents

        state = SessionState(
            session_id=session_id,
            cwd=cwd or "",
            project=_project_name(cwd),
            status=status,
            tool_name=tool_name,
            permission_mode=permission_mode,
            model=model,
            topic=topic,
            title=title,
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
