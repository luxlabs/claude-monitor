"""CLI entry point for claude-monitor."""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

import click

SETTINGS_PATH = Path.home() / ".claude" / "settings.json"

HOOK_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PermissionDenied",  # auto mode refused a call: the tool never runs
    "PostToolUse",
    "PostToolUseFailure",  # tool failures no longer fire PostToolUse
    "Stop",
    "StopFailure",  # API errors end the turn without a Stop
    "SessionEnd",
    "Notification",
    "SubagentStart",
    "SubagentStop",
    "Elicitation",  # MCP server waiting on the user
    "ElicitationResult",  # user answered the MCP prompt
    "PreCompact",
    "PostCompact",
    "PostModelSwitch",  # /model, opusplan, automatic fallback (Claude Code 2.1.251+)
]

# SessionEnd runs synchronously: `claude -p` kills async hooks still running
# when it exits, which would leave the session's file behind.
SYNC_EVENTS = {"SessionEnd"}

# Refresh usage when a turn ends (Stop / StopFailure) or a new prompt starts.
# The usage hook throttles itself, so many sessions don't hammer the endpoint.
USAGE_HOOK_EVENTS = ["Stop", "StopFailure", "UserPromptSubmit"]

MIN_CLAUDE_VERSION = (2, 1, 251)

HOOK_MARKER = "claude-monitor"


class SettingsError(click.ClickException):
    pass


def _is_our_hook(h: dict) -> bool:
    """Check if a hook entry belongs to claude-monitor (flat or nested format)."""
    if not isinstance(h, dict):
        return False
    if HOOK_MARKER in str(h.get("command", "")):
        return True
    for sub in h.get("hooks", []) if isinstance(h.get("hooks"), list) else []:
        if isinstance(sub, dict) and HOOK_MARKER in str(sub.get("command", "")):
            return True
    return False


def _command(subcommand: str) -> str:
    """Absolute, shell-quoted command (paths with spaces break shell-form hooks)."""
    path = shutil.which("claude-monitor")
    return f"{shlex.quote(path)} {subcommand}" if path else f"claude-monitor {subcommand}"


def _build_hooks_config() -> dict:
    """Hook entries for every monitored event, in Claude Code's nested format."""
    command = _command("hook")
    usage_command = _command("usage-hook")
    hooks: dict[str, list[dict]] = {}
    for event in HOOK_EVENTS:
        handler: dict = {"type": "command", "command": command}
        if event not in SYNC_EVENTS:
            handler["async"] = True
        handlers = [handler]
        if event in USAGE_HOOK_EVENTS:
            handlers.append({"type": "command", "command": usage_command, "async": True})
        hooks[event] = [{"matcher": ".*", "hooks": handlers}]
    return hooks


def _load_settings() -> dict:
    """Load settings; refuse to continue if the file exists but can't be parsed."""
    if not SETTINGS_PATH.exists():
        return {}
    try:
        data = json.loads(SETTINGS_PATH.read_text())
    except (OSError, ValueError) as exc:
        raise SettingsError(f"Cannot read {SETTINGS_PATH} ({exc}); fix it and retry. Nothing was changed.")
    if not isinstance(data, dict):
        raise SettingsError(f"{SETTINGS_PATH} is not a JSON object; nothing was changed.")
    return data


def _save_settings(settings: dict) -> None:
    """Atomic write that keeps every key we didn't touch."""
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=SETTINGS_PATH.parent, prefix=".settings.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(settings, indent=2) + "\n")
        if SETTINGS_PATH.exists():
            os.chmod(tmp, SETTINGS_PATH.stat().st_mode & 0o777)
        os.replace(tmp, SETTINGS_PATH)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _strip_our_hooks(existing: dict) -> dict:
    """Remove claude-monitor entries from every event, dropping emptied events."""
    cleaned = {}
    for event, entries in existing.items():
        if not isinstance(entries, list):
            cleaned[event] = entries
            continue
        kept = [h for h in entries if not _is_our_hook(h)]
        if kept:
            cleaned[event] = kept
    return cleaned


def _claude_version() -> tuple[int, ...] | None:
    try:
        out = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", out.stdout)
    return tuple(int(x) for x in m.groups()) if m else None


@click.group(invoke_without_command=True)
@click.pass_context
def cli(ctx: click.Context) -> None:
    """Monitor active Claude Code sessions in a TUI."""
    if ctx.invoked_subcommand is None:
        from claude_monitor.tui import run_tui

        run_tui()


@cli.command()
def install() -> None:
    """Install hooks into ~/.claude/settings.json."""
    settings = _load_settings()
    existing = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    hooks = _strip_our_hooks(existing)
    for event, entries in _build_hooks_config().items():
        hooks[event] = hooks.get(event, []) + entries
    settings["hooks"] = hooks
    _save_settings(settings)

    click.echo(f"Hooks installed in {SETTINGS_PATH}")
    click.echo(f"Monitoring events: {', '.join(HOOK_EVENTS)}")
    version = _claude_version()
    minimum = ".".join(map(str, MIN_CLAUDE_VERSION))
    if version is None:
        click.echo(f"Note: couldn't run `claude --version`; claude-monitor needs Claude Code {minimum} or later.")
    elif version < MIN_CLAUDE_VERSION:
        click.echo(
            f"Warning: Claude Code {'.'.join(map(str, version))} is older than {minimum}; "
            "update it (older versions may reject newer hook events such as PostModelSwitch)."
        )


@cli.command()
def uninstall() -> None:
    """Remove hooks from ~/.claude/settings.json."""
    settings = _load_settings()
    existing = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    hooks = _strip_our_hooks(existing)
    if hooks:
        settings["hooks"] = hooks
    else:
        settings.pop("hooks", None)
    _save_settings(settings)
    click.echo(f"Hooks removed from {SETTINGS_PATH}")


@cli.command()
def hook() -> None:
    """Process a hook event from stdin (internal use)."""
    from claude_monitor.hook import main as hook_main

    hook_main()


@cli.command("usage-hook")
def usage_hook() -> None:
    """Fetch usage data from Claude API and write to monitor dir (internal use)."""
    from claude_monitor.usage import fetch_and_write_usage

    try:
        fetch_and_write_usage()
    except Exception:
        pass
