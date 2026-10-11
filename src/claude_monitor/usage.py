"""Fetch Claude plan usage and write it to the monitor directory.

The usage endpoint is rate-limited per login, and Claude Code itself reads it
about once a minute per machine. This hook runs on every turn of every
session, so it throttles itself on the last *attempt* (not on usage.json's
age, which a failing endpoint never refreshes) and backs off on 429/401.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from contextlib import contextmanager
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from claude_monitor.state import monitor_dir

try:
    import fcntl
except ImportError:  # pragma: no cover
    fcntl = None

API_URL = "https://api.anthropic.com/api/oauth/usage"
MIN_INTERVAL = 90.0  # between attempts, across all sessions
RATE_LIMIT_BACKOFF = 300.0  # 429 without a usable Retry-After
AUTH_BACKOFF = 600.0  # 401/403: wait for Claude Code to refresh the login
ERROR_BACKOFF = 300.0  # network errors


def usage_file() -> Path:
    return monitor_dir() / "usage.json"


def _state_file() -> Path:
    return monitor_dir() / ".usage-state.json"


def _lock_file() -> Path:
    return monitor_dir() / ".usage.lock"


@contextmanager
def _try_lock():
    """Non-blocking: if another session is already fetching, skip."""
    if fcntl is None:
        yield True
        return
    monitor_dir().mkdir(parents=True, exist_ok=True)
    fd = os.open(_lock_file(), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def _read_state() -> dict:
    try:
        data = json.loads(_state_file().read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _write_state(state: dict) -> None:
    _atomic_write(_state_file(), json.dumps(state).encode())


def _token_from_creds(creds: dict, now: float) -> str | None:
    oauth = creds.get("claudeAiOauth") if isinstance(creds, dict) else None
    if not isinstance(oauth, dict):
        return None
    expires = oauth.get("expiresAt")
    if isinstance(expires, (int, float)) and expires / 1000 < now:
        return None  # expired: Claude Code refreshes it on its next request
    token = oauth.get("accessToken")
    return token if isinstance(token, str) and token else None


def _read_oauth_token(now: float) -> str | None:
    """OAuth access token: macOS Keychain first, then the credentials file
    (used on Linux, and left behind on some macOS installs)."""
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            token = _token_from_creds(json.loads(result.stdout.strip()), now)
            if token:
                return token
    except (subprocess.SubprocessError, ValueError, OSError):
        pass  # no Keychain (Linux), locked after wake, …
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    creds_path = (Path(config).expanduser() if config else Path.home() / ".claude") / ".credentials.json"
    try:
        return _token_from_creds(json.loads(creds_path.read_text()), now)
    except (OSError, ValueError):
        return None


def _retry_after(value: str | None, now: float) -> float | None:
    if not value:
        return None
    try:
        return max(0.0, float(value))
    except ValueError:
        pass
    try:
        return max(0.0, parsedate_to_datetime(value).timestamp() - now)
    except (TypeError, ValueError):
        return None


def _fetch(token: str) -> bytes:
    req = Request(API_URL, headers={
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
    })
    with urlopen(req, timeout=10) as resp:
        return resp.read()


def fetch_and_write_usage(now: float | None = None, fetch=_fetch, read_token=_read_oauth_token) -> str:
    """Fetch usage if allowed; returns what happened (for tests and debugging)."""
    now = time.time() if now is None else now
    with _try_lock() as locked:
        if not locked:
            return "busy"
        state = _read_state()
        if now < float(state.get("next_allowed") or 0):
            return "throttled"
        # Record the attempt first: a crash or hang mustn't make every hook retry.
        state.update(last_attempt=now, next_allowed=now + MIN_INTERVAL)
        _write_state(state)

        token = read_token(now)
        if not token:
            state["last_result"] = "no-token"
            _write_state(state)
            return "no-token"
        try:
            data = fetch(token)
            json.loads(data)  # never replace good data with garbage
        except HTTPError as exc:
            if exc.code == 429:
                wait = _retry_after(exc.headers.get("Retry-After") if exc.headers else None, now)
                state["next_allowed"] = now + max(MIN_INTERVAL, wait if wait is not None else RATE_LIMIT_BACKOFF)
            elif exc.code in (401, 403):
                state["next_allowed"] = now + AUTH_BACKOFF
            else:
                state["next_allowed"] = now + ERROR_BACKOFF
            state["last_result"] = f"http-{exc.code}"
            _write_state(state)
            return state["last_result"]
        except (URLError, OSError, ValueError):
            state.update(next_allowed=now + ERROR_BACKOFF, last_result="error")
            _write_state(state)
            return "error"
        _atomic_write(usage_file(), data)
        state.update(last_success=now, last_result="ok")
        _write_state(state)
        return "ok"
