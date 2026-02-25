"""Fetch Claude Code usage data and write to monitor directory."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from urllib.request import Request, urlopen

MONITOR_DIR = Path.home() / ".claude" / "monitor"
USAGE_FILE = MONITOR_DIR / "usage.json"
API_URL = "https://api.anthropic.com/api/oauth/usage"


def _read_oauth_token() -> str | None:
    """Read OAuth access token from macOS Keychain."""
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return None
        creds = json.loads(result.stdout.strip())
        return creds.get("claudeAiOauth", {}).get("accessToken")
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return None


def fetch_and_write_usage() -> None:
    """Fetch usage data from Claude API and write to usage.json atomically."""
    token = _read_oauth_token()
    if not token:
        return

    req = Request(API_URL, headers={
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
    })

    with urlopen(req, timeout=10) as resp:
        data = resp.read()

    # Validate JSON
    json.loads(data)

    # Atomic write
    MONITOR_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=MONITOR_DIR, suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp_path, USAGE_FILE)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
