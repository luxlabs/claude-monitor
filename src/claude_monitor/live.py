"""Live session data from Claude Code, merged with the hook-written state.

Hooks give the detail (tool, topic, title, subagents); ``claude agents --json``
gives what hooks can't: which sessions are alive, their exact PID, and whether
Claude Code is waiting on the user. ``effective()`` combines the two with the
rules in the README; LiveSessions.swift/Merge.swift mirror this module and both
are checked against ``tests/fixtures/merge_cases.json``.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from claude_monitor.state import (
    BACKGROUND,
    COMPACTING,
    EXECUTING,
    PERMISSION,
    STARTING,
    THINKING,
    WAITING,
    SessionState,
)

FRESH_MARGIN = 2.0  # live data must postdate the hook's last transition by this much
SNAPSHOT_MAX_AGE = 15.0  # older snapshots are ignored (hooks-only mode)
ABSENT_GRACE = 90.0  # hook activity this recent keeps an unlisted session visible
BACKGROUND_DECAY = 1800.0  # BACKGROUND with no agent activity for 30 min shows as WAITING
IDLE_HIDE_AFTER = 4 * 3600.0  # idle sessions older than this are hidden unless "show all"
LEGACY_ACTIVE_HIDE = 3600.0  # hooks-only mode: an active status this old is presumed dead
POLL_TIMEOUT = 5.0

_LEGACY_ACTIVE = {THINKING, EXECUTING, PERMISSION, STARTING, COMPACTING}
_CLAUDE_CANDIDATES = (
    "~/.local/bin/claude",
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    "~/.claude/local/claude",
)


@dataclass(frozen=True)
class LiveEntry:
    session_id: str
    pid: int | None = None
    status: str | None = None  # busy | waiting | idle (while the process is alive)
    waiting_for: str | None = None
    kind: str = "interactive"  # interactive | background
    job_id: str | None = None  # background short id, for `claude stop <id>`
    state: str | None = None  # background: working | blocked | done | failed | stopped
    name: str = ""
    cwd: str = ""
    started_at: float = 0.0  # epoch seconds

    @classmethod
    def from_agents_json(cls, d: dict) -> LiveEntry | None:
        sid = d.get("sessionId")
        if not isinstance(sid, str) or not sid:
            return None
        pid = d.get("pid")
        started = d.get("startedAt")
        return cls(
            session_id=sid,
            pid=pid if isinstance(pid, int) and pid > 0 else None,
            status=d.get("status") if isinstance(d.get("status"), str) else None,
            waiting_for=d.get("waitingFor") if isinstance(d.get("waitingFor"), str) else None,
            kind="background" if d.get("kind") == "background" else "interactive",
            job_id=d.get("id") if isinstance(d.get("id"), str) else None,
            state=d.get("state") if isinstance(d.get("state"), str) else None,
            name=d.get("name") if isinstance(d.get("name"), str) else "",
            cwd=d.get("cwd") if isinstance(d.get("cwd"), str) else "",
            started_at=started / 1000 if isinstance(started, (int, float)) else 0.0,
        )


@dataclass(frozen=True)
class Snapshot:
    observed_at: float
    entries: dict[str, LiveEntry] = field(default_factory=dict)
    source: str = "agents"  # "agents" (claude agents --json) | "registry" (fallback)


@dataclass(frozen=True)
class Effective:
    status: str
    detail: str | None = None  # e.g. "permission prompt" from waitingFor
    hidden: bool = False  # not shown at all (presumed dead)
    legacy: bool = False  # no fresh live data: hooks-only mode
    untracked: bool = False  # live session with no hook state file
    stale_idle: bool = False  # idle for a long time: hidden unless "show all"


# ── Locating and calling `claude`

_resolved_claude: str | None | bool = False  # False = not looked up yet


def resolve_claude() -> str | None:
    """Find the `claude` binary once: env override, PATH, known installs, login shell."""
    global _resolved_claude
    if _resolved_claude is not False:
        return _resolved_claude  # type: ignore[return-value]
    candidates = [os.environ.get("CLAUDE_MONITOR_CLAUDE_BIN"), shutil.which("claude")]
    candidates += [os.path.expanduser(p) for p in _CLAUDE_CANDIDATES]
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            _resolved_claude = path
            return path
    try:
        out = subprocess.run(
            ["/bin/zsh", "-lc", "command -v claude"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5,
        )
        lines = out.stdout.strip().splitlines()
        path = lines[-1].strip() if lines else ""
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            _resolved_claude = path
            return path
    except (OSError, subprocess.SubprocessError):
        pass
    _resolved_claude = None
    return None


def _claude_env() -> dict[str, str]:
    # A poll every few seconds must not trigger update checks.
    return {**os.environ, "DISABLE_AUTOUPDATER": "1"}


def parse_agents_json(text: str, observed_at: float) -> Snapshot | None:
    try:
        data = json.loads(text)
    except ValueError:
        return None
    if not isinstance(data, list):
        return None
    entries: dict[str, LiveEntry] = {}
    for item in data:
        if not isinstance(item, dict):
            continue
        entry = LiveEntry.from_agents_json(item)
        if entry is None:
            continue
        prev = entries.get(entry.session_id)
        # One conversation can briefly have two rows (e.g. a phantom twin
        # after backgrounding): prefer the one with a live process.
        if prev is None or (prev.pid is None and entry.pid is not None):
            entries[entry.session_id] = entry
    return Snapshot(observed_at=observed_at, entries=entries, source="agents")


def poll(timeout: float = POLL_TIMEOUT) -> Snapshot | None:
    """One live snapshot: `claude agents --json`, else the session registry."""
    observed_at = time.time()  # start of the call: freshness checks stay conservative
    claude = resolve_claude()
    if claude:
        try:
            proc = subprocess.run(
                [claude, "agents", "--json"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                timeout=timeout, env=_claude_env(),
            )
            if proc.returncode == 0:
                snap = parse_agents_json(proc.stdout, observed_at)
                if snap is not None:
                    return snap
        except (OSError, subprocess.SubprocessError):
            pass
    return read_registry(observed_at)


# ── Fallback: Claude Code's per-process registry (~/.claude/sessions/<pid>.json)

def registry_dir() -> Path:
    base = os.environ.get("CLAUDE_CONFIG_DIR")
    return (Path(base).expanduser() if base else Path.home() / ".claude") / "sessions"


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by someone we can't signal
    except OSError:
        return False
    return True


def _process_start_times(pids: list[int]) -> dict[int, float]:
    """Start time (epoch) per pid via one `ps` call; {} if unavailable."""
    if not pids:
        return {}
    try:
        out = subprocess.run(
            ["ps", "-o", "pid=,lstart=", "-p", ",".join(str(p) for p in pids)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    starts: dict[int, float] = {}
    for line in out.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        try:
            starts[int(parts[0])] = time.mktime(time.strptime(parts[1].strip(), "%a %b %d %H:%M:%S %Y"))
        except ValueError:
            continue
    return starts


def _registry_records() -> list[dict]:
    records = []
    try:
        paths = list(registry_dir().glob("*.json"))
    except OSError:
        return records
    for path in paths:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and isinstance(data.get("pid"), int) and isinstance(data.get("sessionId"), str):
            records.append(data)
    return records


def live_session_ids() -> set[str]:
    """Session ids whose registry pid is alive (cheap; used by the hook's GC)."""
    return {r["sessionId"] for r in _registry_records() if pid_alive(r["pid"])}


def read_registry(observed_at: float, check_start_times: bool = True) -> Snapshot | None:
    all_records = _registry_records()
    try:
        has_files = any(registry_dir().glob("*.json"))
    except OSError:
        has_files = False
    if not all_records and has_files:
        return None  # unknown format: fall back to hooks-only rather than "nobody is alive"
    if not registry_dir().exists():
        return None
    records = [r for r in all_records if pid_alive(r["pid"])]
    starts = _process_start_times([r["pid"] for r in records]) if check_start_times else {}
    entries: dict[str, LiveEntry] = {}
    best_updated: dict[str, float] = {}
    for r in records:
        started_ms = r.get("startedAt")
        started = started_ms / 1000 if isinstance(started_ms, (int, float)) else 0.0
        proc_start = starts.get(r["pid"])
        # Entries survive unclean exits, so a recycled pid can look alive:
        # the process must have started before the session registered.
        if proc_start is not None and started and proc_start > started + 5:
            continue
        sid = r["sessionId"]
        updated = r.get("updatedAt") if isinstance(r.get("updatedAt"), (int, float)) else 0
        if sid in entries and best_updated.get(sid, 0) >= updated:
            continue
        job_id = r.get("jobId") if isinstance(r.get("jobId"), str) else None
        entries[sid] = LiveEntry(
            session_id=sid,
            pid=r["pid"],
            status=r.get("status") if isinstance(r.get("status"), str) else None,
            waiting_for=r.get("waitingFor") if isinstance(r.get("waitingFor"), str) else None,
            kind="interactive" if r.get("kind") == "interactive" or not job_id else "background",
            job_id=job_id,
            name=r.get("name") if isinstance(r.get("name"), str) else "",
            cwd=r.get("cwd") if isinstance(r.get("cwd"), str) else "",
            started_at=started,
        )
        best_updated[sid] = updated
    return Snapshot(observed_at=observed_at, entries=entries, source="registry")


# ── Merge

def _live_only_status(live: LiveEntry) -> str:
    if live.status == "waiting":
        return WAITING if live.waiting_for == "dialog open" else PERMISSION
    if live.status == "busy":
        return THINKING
    if live.status == "idle":
        return WAITING
    if live.state == "blocked":
        return PERMISSION
    if live.state == "working":
        return THINKING
    return WAITING


def effective(
    hook: SessionState | None,
    live: LiveEntry | None,
    observed_at: float | None,
    now: float,
) -> Effective:
    """The status to display for one session (see the README's merge table)."""
    if hook is None:
        if live is None:
            return Effective(WAITING, hidden=True)
        status = _live_only_status(live)
        return Effective(
            status,
            detail=live.waiting_for if status == PERMISSION else None,
            untracked=True,
            stale_idle=status == WAITING,  # idle for an unknown time
        )

    def result(status: str, detail: str | None = None, *, hidden: bool = False, legacy: bool = False) -> Effective:
        age = now - hook.activity_ts
        if legacy and status in _LEGACY_ACTIVE and age > LEGACY_ACTIVE_HIDE:
            hidden = True
        return Effective(
            status, detail, hidden=hidden, legacy=legacy,
            stale_idle=status == WAITING and age > IDLE_HIDE_AFTER,
        )

    base = hook.base_status
    if base == BACKGROUND and now - hook.activity_ts > BACKGROUND_DECAY:
        base = WAITING
    hook_status = PERMISSION if hook.pending else base

    if observed_at is None or now - observed_at > SNAPSHOT_MAX_AGE:
        return result(hook_status, legacy=True)
    if live is None:
        return result(hook_status, hidden=now - hook.activity_ts >= ABSENT_GRACE)

    latest = max([hook.status_ts] + [float(p.get("since") or 0) for p in hook.pending.values()])
    if observed_at <= latest + FRESH_MARGIN:
        return result(hook_status)  # live data predates the hook's last change

    if live.status == "waiting":
        if live.waiting_for != "dialog open":  # a dialog the user opened isn't a request
            return result(PERMISSION, live.waiting_for)
        return result(hook_status)
    if live.status == "idle":
        if base in (THINKING, EXECUTING, STARTING, COMPACTING):
            return result(WAITING)  # e.g. Esc: the turn ended without a Stop hook
        return result(base)  # pending prompts were answered: Claude Code isn't waiting
    if live.status == "busy":
        if base in (WAITING, STARTING):
            return result(THINKING)  # work started without a prompt (/loop, auto-continue…)
        return result(base)
    if live.state == "blocked":
        return result(PERMISSION, live.waiting_for)
    return result(hook_status)


# ── Actions

def stop_session(entry: LiveEntry, force: bool = False) -> str:
    """Stop a session; returns a short message. Background sessions must go
    through `claude stop`: the supervisor respawns workers that get killed."""
    if entry.kind == "background" and entry.job_id and not force:
        claude = resolve_claude()
        if not claude:
            return "claude binary not found"
        try:
            proc = subprocess.run(
                [claude, "stop", entry.job_id],
                stdin=subprocess.DEVNULL, capture_output=True, text=True,
                timeout=15, env=_claude_env(),
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return f"claude stop failed: {exc}"
        return "stopped" if proc.returncode == 0 else (proc.stderr.strip() or "claude stop failed")
    if not entry.pid:
        return "no process"
    try:
        os.kill(entry.pid, signal.SIGKILL if force else signal.SIGTERM)
    except OSError as exc:
        return f"kill failed: {exc}"
    return "killed" if force else "terminated"
