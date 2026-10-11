"""Session state model and on-disk storage.

One JSON file per session lives in ``<monitor dir>/sessions/<session_id>.json``.
Hooks are the only writers; the TUI and the macOS app only read (and hide).

Schema 2 keeps every field a schema-1 reader used (``status``, ``title``,
``last_updated``, ``subagents[].status`` …) as *derived* values, so an older
build of either UI keeps working against files written by this version.
"""

from __future__ import annotations

import json
import os
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

try:
    import fcntl  # POSIX advisory file locking
except ImportError:  # pragma: no cover - non-Unix; hooks target macOS/Linux
    fcntl = None

SCHEMA_VERSION = 2

# Statuses. PERMISSION is never stored as ``base_status``: it is derived from
# a non-empty ``pending`` map, so a prompt raised by one agent can't hide (or
# be cleared by) what another agent is doing.
STARTING = "STARTING"
THINKING = "THINKING"
EXECUTING = "EXECUTING"
PERMISSION = "PERMISSION"
WAITING = "WAITING"
BACKGROUND = "BACKGROUND"  # turn ended, background agents/workflows still running
COMPACTING = "COMPACTING"
ENDED = "ENDED"  # legacy; SessionEnd removes the file instead

TEXT_LIMIT = 500  # topic / last_prompt cap: injected prompts can be 50+ KB
SUBAGENT_LIMIT = 64  # workflows fan out to 256 agents; keep the file small
ENDED_AGENTS_LIMIT = 32
DONE_CALLS_LIMIT = 16
GC_MAX_AGE_HOURS = 24


# ── Paths (resolved at call time so tests can point CLAUDE_MONITOR_DIR elsewhere)

def monitor_dir() -> Path:
    override = os.environ.get("CLAUDE_MONITOR_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".claude" / "monitor"


def sessions_dir() -> Path:
    return monitor_dir() / "sessions"


def _tmp_dir() -> Path:
    # Temp files live outside sessions/ so directory watchers only see the
    # final atomic rename, never the half-written temp file.
    return monitor_dir() / ".tmp"


def _lock_path() -> Path:
    return monitor_dir() / ".write.lock"


def session_path(session_id: str) -> Path:
    return sessions_dir() / f"{session_id}.json"


# ── Time helpers

def iso(ts: float) -> str:
    if not ts:
        return ""
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def parse_iso(value: object) -> float:
    if not isinstance(value, str) or not value:
        return 0.0
    try:
        return datetime.fromisoformat(value).timestamp()
    except ValueError:
        return 0.0


def cap(text: str, limit: int = TEXT_LIMIT) -> str:
    text = text or ""
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _num(value: object, default: float = 0.0) -> float:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else default


def _int(value: object, default: int = 0) -> int:
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else default


def _str(value: object, default: str = "") -> str:
    return value if isinstance(value, str) else default


# ── Model

@dataclass
class SubagentState:
    agent_id: str
    agent_type: str = ""
    description: str = ""
    tool_name: str | None = None
    tool_count: int = 0
    started_at: str = ""
    ts: float = 0.0  # this agent's own clock; never compared with the session's

    @classmethod
    def from_dict(cls, d: dict) -> SubagentState:
        ts = _num(d.get("ts")) or parse_iso(d.get("last_updated"))
        return cls(
            agent_id=_str(d.get("agent_id")),
            agent_type=_str(d.get("agent_type")),
            description=_str(d.get("description")),
            tool_name=d.get("tool_name") if isinstance(d.get("tool_name"), str) else None,
            tool_count=_int(d.get("tool_count")),
            started_at=_str(d.get("started_at")),
            ts=ts,
        )

    def to_dict(self, pending: dict) -> dict:
        return {
            "agent_id": self.agent_id,
            "agent_type": self.agent_type,
            "description": self.description,
            # Legacy field: schema-1 readers map "running" to an active row.
            "status": "permission" if self.agent_id in pending else "running",
            "tool_name": self.tool_name,
            "tool_count": self.tool_count,
            "started_at": self.started_at,
            "ts": self.ts,
            "last_updated": iso(self.ts),
        }


@dataclass
class SessionState:
    session_id: str
    cwd: str = ""
    project: str = ""
    base_status: str = STARTING
    status_ts: float = 0.0  # last main-status transition (event clock)
    activity_ts: float = 0.0  # last event of any kind, main or subagent
    tool_name: str | None = None
    tool_fp: str = ""  # fingerprint of the main agent's in-flight tool call
    permission_mode: str = ""
    model: str = ""
    effort: str = ""
    context_tokens: int = 0
    topic: str = ""
    last_prompt: str = ""
    custom_title: str = ""
    ai_title: str = ""
    tool_count: int = 0
    started_at: str = ""
    # agent key ("main" or an agent_id) -> {"tool", "fp", "since"}
    pending: dict[str, dict] = field(default_factory=dict)
    last_error: str = ""
    bg_active: int = 0
    bg_types: dict[str, int] = field(default_factory=dict)
    crons: int = 0
    subagents: list[SubagentState] = field(default_factory=list)
    subagents_overflow: int = 0
    ended_agents: list[list] = field(default_factory=list)  # [[agent_id, ended_ts], …]
    done_calls: list[str] = field(default_factory=list)  # "<agent key>:<fp>" of finished calls

    # Derived, legacy-compatible views
    @property
    def status(self) -> str:
        return PERMISSION if self.pending else self.base_status

    @property
    def title(self) -> str:
        return self.custom_title or self.ai_title

    @property
    def last_updated(self) -> str:
        return iso(self.activity_ts)

    def find_subagent(self, agent_id: str) -> SubagentState | None:
        for sa in self.subagents:
            if sa.agent_id == agent_id:
                return sa
        return None

    def ended_at(self, agent_id: str) -> float | None:
        for entry in self.ended_agents:
            if entry and entry[0] == agent_id:
                return _num(entry[1]) if len(entry) > 1 else 0.0
        return None

    @classmethod
    def from_dict(cls, d: dict, fallback_id: str = "") -> SessionState:
        legacy = "base_status" not in d
        last_ts = _num(d.get("activity_ts")) or parse_iso(d.get("last_updated"))
        pending = {
            k: {"tool": _str(v.get("tool")), "fp": _str(v.get("fp")), "since": _num(v.get("since"))}
            for k, v in (d.get("pending") or {}).items()
            if isinstance(k, str) and isinstance(v, dict)
        }
        base = _str(d.get("base_status")) or _str(d.get("status"), STARTING)
        if legacy and base == PERMISSION:
            # Schema-1 PERMISSION: keep it visible until the main agent moves on.
            base = EXECUTING if d.get("tool_name") else THINKING
            pending = {"main": {"tool": _str(d.get("tool_name")), "fp": "", "since": last_ts}}
        background = d.get("background") if isinstance(d.get("background"), dict) else {}
        return cls(
            session_id=_str(d.get("session_id")) or fallback_id,
            cwd=_str(d.get("cwd")),
            project=_str(d.get("project")),
            base_status=base,
            status_ts=_num(d.get("status_ts")) or last_ts,
            activity_ts=last_ts,
            tool_name=d.get("tool_name") if isinstance(d.get("tool_name"), str) else None,
            tool_fp=_str(d.get("tool_fp")),
            permission_mode=_str(d.get("permission_mode")),
            model=_str(d.get("model")),
            effort=_str(d.get("effort")),
            context_tokens=_int(d.get("context_tokens")),
            topic=_str(d.get("topic")),
            last_prompt=_str(d.get("last_prompt")),
            custom_title=_str(d.get("custom_title")),
            # Schema 1 stored the AI title in "title".
            ai_title=_str(d.get("ai_title")) or (_str(d.get("title")) if legacy else ""),
            tool_count=_int(d.get("tool_count")),
            started_at=_str(d.get("started_at")),
            pending=pending,
            last_error=_str(d.get("last_error")),
            bg_active=_int(background.get("active")),
            bg_types={k: _int(v) for k, v in (background.get("types") or {}).items() if isinstance(k, str)},
            crons=_int(d.get("crons")),
            subagents=[
                SubagentState.from_dict(sa)
                for sa in d.get("subagents") or []
                if isinstance(sa, dict) and sa.get("agent_id")
            ],
            subagents_overflow=_int(d.get("subagents_overflow")),
            ended_agents=[
                [e[0], _num(e[1]) if len(e) > 1 else 0.0]
                for e in d.get("ended_agents") or []
                if isinstance(e, list) and e and isinstance(e[0], str)
            ],
            done_calls=[c for c in d.get("done_calls") or [] if isinstance(c, str)],
        )

    def to_dict(self) -> dict:
        return {
            "schema": SCHEMA_VERSION,
            "session_id": self.session_id,
            "cwd": self.cwd,
            "project": self.project,
            "status": self.status,
            "base_status": self.base_status,
            "status_ts": self.status_ts,
            "activity_ts": self.activity_ts,
            "last_updated": self.last_updated,
            "tool_name": self.tool_name,
            "tool_fp": self.tool_fp,
            "permission_mode": self.permission_mode,
            "model": self.model,
            "effort": self.effort,
            "context_tokens": self.context_tokens,
            "topic": cap(self.topic),
            "last_prompt": cap(self.last_prompt),
            "title": self.title,
            "custom_title": self.custom_title,
            "ai_title": self.ai_title,
            "tool_count": self.tool_count,
            "started_at": self.started_at,
            "pending": self.pending,
            "last_error": self.last_error,
            "background": {"active": self.bg_active, "types": self.bg_types},
            "crons": self.crons,
            "subagents": [sa.to_dict(self.pending) for sa in self.subagents],
            "subagents_overflow": self.subagents_overflow,
            "ended_agents": self.ended_agents,
            "done_calls": self.done_calls,
        }


# ── Storage

@contextmanager
def write_lock(timeout: float = 5.0):
    """Serialize read-modify-write across concurrent hook processes.

    Yields True when the lock is held. Hooks run as parallel processes (a
    workflow can fire dozens of events at once), so every read-modify-write of
    a session file must happen under this one advisory lock. On timeout it
    yields False and the caller should skip its write rather than race.
    """
    if fcntl is None:
        yield True
        return
    monitor_dir().mkdir(parents=True, exist_ok=True)
    fd = os.open(_lock_path(), os.O_CREAT | os.O_RDWR, 0o644)
    acquired = False
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.005)
        yield acquired
    finally:
        try:
            if acquired:
                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def read_session(session_id: str) -> SessionState | None:
    try:
        data = json.loads(session_path(session_id).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    return SessionState.from_dict(data, fallback_id=session_id)


def write_session(state: SessionState) -> None:
    """Atomically replace the session file (temp file + rename)."""
    sessions_dir().mkdir(parents=True, exist_ok=True)
    tmp_dir = _tmp_dir()
    tmp_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=tmp_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state.to_dict(), f, ensure_ascii=False)
        os.replace(tmp_path, session_path(state.session_id))
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def remove_session(session_id: str) -> None:
    try:
        session_path(session_id).unlink(missing_ok=True)
    except OSError:
        pass


def list_sessions() -> list[SessionState]:
    """Read every session file. Pure read: never deletes anything."""
    sessions: list[SessionState] = []
    try:
        paths = list(sessions_dir().glob("*.json"))
    except OSError:
        return sessions
    for path in paths:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            sessions.append(SessionState.from_dict(data, fallback_id=path.stem))
    return sessions


def gc(live_ids: set[str], now: float | None = None, max_age_hours: float = GC_MAX_AGE_HOURS) -> int:
    """Delete files of sessions that are both stale and not alive.

    ``live_ids`` holds the session ids whose Claude Code process is running;
    their files are kept however old they are. Also sweeps orphaned temp files.
    Returns the number of session files removed.
    """
    now = time.time() if now is None else now
    removed = 0
    for state in list_sessions():
        if state.session_id in live_ids:
            continue
        if now - state.activity_ts > max_age_hours * 3600:
            remove_session(state.session_id)
            removed += 1
    for folder, pattern in ((_tmp_dir(), "*.tmp"), (sessions_dir(), "*.tmp")):
        try:
            for tmp in folder.glob(pattern):
                if now - tmp.stat().st_mtime > 3600:
                    tmp.unlink(missing_ok=True)
        except OSError:
            pass
    return removed
