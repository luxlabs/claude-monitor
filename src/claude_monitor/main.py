"""CLI entry point for claude-monitor."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import click

SETTINGS_PATH = Path.home() / ".claude" / "settings.json"

HOOK_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "Stop",
    "SessionEnd",
    "Notification",
    "SubagentStart",
    "SubagentStop",
]

USAGE_HOOK_EVENTS = ["Stop", "UserPromptSubmit"]

HOOK_MARKER = "claude-monitor"


def _is_our_hook(h: dict) -> bool:
    """Check if a hook entry belongs to claude-monitor (flat or nested format)."""
    if not isinstance(h, dict):
        return False
    # Flat format: {"type": "command", "command": "...claude-monitor..."}
    if HOOK_MARKER in h.get("command", ""):
        return True
    # Nested format: {"hooks": [{"command": "...claude-monitor..."}], "matcher": "..."}
    for sub in h.get("hooks", []):
        if isinstance(sub, dict) and HOOK_MARKER in sub.get("command", ""):
            return True
    return False


def _get_hook_command() -> str:
    """Get the hook command that invokes our handler using absolute path."""
    import shutil

    cmd = shutil.which("claude-monitor")
    if cmd:
        return f"{cmd} hook"
    return "claude-monitor hook"


def _get_usage_hook_command() -> str:
    """Get the hook command that fetches usage data."""
    import shutil

    cmd = shutil.which("claude-monitor")
    if cmd:
        return f"{cmd} usage-hook"
    return "claude-monitor usage-hook"


def _build_hooks_config() -> dict:
    """Build the hooks configuration for all monitored events.

    Uses the nested format with matcher, matching the internal Claude Code
    hook structure: each entry has a "hooks" array and a "matcher" pattern.
    """
    command = _get_hook_command()
    usage_command = _get_usage_hook_command()
    hooks: dict[str, list[dict]] = {}

    for event in HOOK_EVENTS:
        hook_handlers = [
            {
                "type": "command",
                "command": command,
                "async": True,
            }
        ]
        # Add usage fetch hook on Stop and UserPromptSubmit
        if event in USAGE_HOOK_EVENTS:
            hook_handlers.append({
                "type": "command",
                "command": usage_command,
                "async": True,
            })

        hooks[event] = [
            {
                "matcher": ".*",
                "hooks": hook_handlers,
            }
        ]

    return hooks


def _load_settings() -> dict:
    """Load existing settings or return empty dict."""
    if SETTINGS_PATH.exists():
        try:
            return json.loads(SETTINGS_PATH.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def _save_settings(settings: dict) -> None:
    """Save settings to disk."""
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS_PATH.write_text(json.dumps(settings, indent=2) + "\n")


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
    hooks_config = _build_hooks_config()

    existing_hooks = settings.get("hooks", {})

    for event, hook_list in hooks_config.items():
        event_hooks = existing_hooks.get(event, [])
        # Remove any existing claude-monitor hooks (both flat and nested formats)
        event_hooks = [
            h for h in event_hooks
            if not _is_our_hook(h)
        ]
        # Add our hook
        event_hooks.extend(hook_list)
        existing_hooks[event] = event_hooks

    settings["hooks"] = existing_hooks
    _save_settings(settings)

    click.echo(f"Hooks installed in {SETTINGS_PATH}")
    click.echo(f"Monitoring events: {', '.join(HOOK_EVENTS)}")


@cli.command()
def uninstall() -> None:
    """Remove hooks from ~/.claude/settings.json."""
    settings = _load_settings()
    existing_hooks = settings.get("hooks", {})

    for event in HOOK_EVENTS:
        event_hooks = existing_hooks.get(event, [])
        event_hooks = [
            h for h in event_hooks
            if not _is_our_hook(h)
        ]
        if event_hooks:
            existing_hooks[event] = event_hooks
        else:
            existing_hooks.pop(event, None)

    if existing_hooks:
        settings["hooks"] = existing_hooks
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
