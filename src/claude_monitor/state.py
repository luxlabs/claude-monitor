"""Reading and writing session state files."""

from __future__ import annotations

import json
import os
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

MONITOR_DIR = Path.home() / ".claude" / "monitor" / "sessions"
ZOMBIE_THRESHOLD_HOURS = 24


@dataclass
class SubagentState:
    agent_id: str
    agent_type: str = ""
    status: str = "running"
    last_updated: str = ""


@dataclass
class SessionState:
    session_id: str
    cwd: str = ""
    project: str = ""
    status: str = "STARTING"
    tool_name: str | None = None
    permission_mode: str = ""
    model: str = ""
    topic: str = ""
    last_prompt: str = ""
    tool_count: int = 0
    started_at: str = ""
    last_updated: str = ""
    subagents: list[SubagentState] = field(default_factory=list)

    @property
    def is_active(self) -> bool:
        return self.status not in ("ENDED",)

    @property
    def last_updated_dt(self) -> datetime:
        try:
            return datetime.fromisoformat(self.last_updated)
        except (ValueError, TypeError):
            return datetime.min.replace(tzinfo=timezone.utc)


def _ensure_dir() -> None:
    MONITOR_DIR.mkdir(parents=True, exist_ok=True)


def _session_path(session_id: str) -> Path:
    return MONITOR_DIR / f"{session_id}.json"


def write_session(state: SessionState) -> None:
    """Atomically write session state to disk.

    Includes anti-regression: if a later hook (with a newer last_updated)
    already wrote to the file, skip this write to avoid async race conditions
    (e.g. PreToolUse overwriting Stop).
    """
    _ensure_dir()
    path = _session_path(state.session_id)

    # Anti-regression: don't overwrite with a stale event
    if path.exists():
        try:
            existing = json.loads(path.read_text())
            existing_ts = existing.get("last_updated", "")
            if existing_ts > state.last_updated:
                return
        except (json.JSONDecodeError, OSError):
            pass

    data = {
        "session_id": state.session_id,
        "cwd": state.cwd,
        "project": state.project,
        "status": state.status,
        "tool_name": state.tool_name,
        "permission_mode": state.permission_mode,
        "model": state.model,
        "topic": state.topic,
        "last_prompt": state.last_prompt,
        "tool_count": state.tool_count,
        "started_at": state.started_at,
        "last_updated": state.last_updated,
        "subagents": [
            {
                "agent_id": sa.agent_id,
                "agent_type": sa.agent_type,
                "status": sa.status,
                "last_updated": sa.last_updated,
            }
            for sa in state.subagents
        ],
    }
    # Atomic write: temp file + rename
    fd, tmp_path = tempfile.mkstemp(dir=MONITOR_DIR, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def remove_session(session_id: str) -> None:
    """Remove session state file."""
    path = _session_path(session_id)
    try:
        path.unlink(missing_ok=True)
    except OSError:
        pass


def get_sessions() -> list[SessionState]:
    """Read all session state files, cleaning up zombies."""
    _ensure_dir()
    sessions: list[SessionState] = []
    now = datetime.now(timezone.utc)

    for path in MONITOR_DIR.glob("*.json"):
        try:
            data = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue

        subagents = [
            SubagentState(
                agent_id=sa.get("agent_id", ""),
                agent_type=sa.get("agent_type", ""),
                status=sa.get("status", "running"),
                last_updated=sa.get("last_updated", ""),
            )
            for sa in data.get("subagents", [])
            if isinstance(sa, dict)
        ]

        state = SessionState(
            session_id=data.get("session_id", path.stem),
            cwd=data.get("cwd", ""),
            project=data.get("project", ""),
            status=data.get("status", "STARTING"),
            tool_name=data.get("tool_name"),
            permission_mode=data.get("permission_mode", ""),
            model=data.get("model", ""),
            topic=data.get("topic", ""),
            last_prompt=data.get("last_prompt", ""),
            tool_count=data.get("tool_count", 0),
            started_at=data.get("started_at", ""),
            last_updated=data.get("last_updated", ""),
            subagents=subagents,
        )

        # Cleanup zombies
        age = (now - state.last_updated_dt).total_seconds() / 3600
        if age > ZOMBIE_THRESHOLD_HOURS:
            try:
                path.unlink()
            except OSError:
                pass
            continue

        sessions.append(state)

    # Active sessions first, then sorted by last_updated descending
    sessions.sort(key=lambda s: (not s.is_active, s.last_updated), reverse=False)
    sessions.sort(key=lambda s: (not s.is_active, -s.last_updated_dt.timestamp()))
    return sessions


def cleanup_old_sessions(max_age_hours: float = 1.0) -> int:
    """Remove sessions older than max_age_hours. Returns count removed."""
    _ensure_dir()
    now = datetime.now(timezone.utc)
    removed = 0

    for path in MONITOR_DIR.glob("*.json"):
        try:
            data = json.loads(path.read_text())
            last = datetime.fromisoformat(data.get("last_updated", ""))
            age = (now - last).total_seconds() / 3600
            if age > max_age_hours:
                path.unlink()
                removed += 1
        except (json.JSONDecodeError, OSError, ValueError):
            try:
                path.unlink()
                removed += 1
            except OSError:
                pass

    return removed
