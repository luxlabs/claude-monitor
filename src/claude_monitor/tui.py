"""Textual TUI for monitoring Claude Code sessions."""

from __future__ import annotations

from datetime import datetime, timezone

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.widgets import DataTable, Footer, Header

from claude_monitor.state import cleanup_old_sessions, get_sessions

STATUS_DISPLAY = {
    "WAITING": ("WAITING", "green"),
    "THINKING": ("THINKING", "yellow"),
    "EXECUTING": ("EXECUTING", "dodger_blue"),
    "PERMISSION": ("PERMISSION", "red"),
    "STARTING": ("STARTING", "cyan"),
    "ENDED": ("ENDED", "dim"),
}

MODEL_SHORT = {
    "claude-opus-4-6": "opus",
    "claude-sonnet-4-6": "sonnet",
    "claude-haiku-4-5-20251001": "haiku",
}

MODE_SHORT = {
    "default": "default",
    "plan": "plan",
    "acceptEdits": "autoEdit",
    "dontAsk": "dontAsk",
    "bypassPermissions": "bypass",
}


def _format_time(iso_str: str) -> str:
    """Format ISO timestamp to HH:MM:SS."""
    try:
        dt = datetime.fromisoformat(iso_str)
        local = dt.astimezone()
        return local.strftime("%H:%M:%S")
    except (ValueError, TypeError):
        return "-"


def _format_duration(started_at: str) -> str:
    """Format duration since started_at as HH:MM:SS or MM:SS."""
    try:
        start = datetime.fromisoformat(started_at)
        delta = datetime.now(timezone.utc) - start
        total_secs = int(delta.total_seconds())
        if total_secs < 0:
            return "-"
        hours, remainder = divmod(total_secs, 3600)
        minutes, seconds = divmod(remainder, 60)
        if hours > 0:
            return f"{hours}:{minutes:02d}:{seconds:02d}"
        return f"{minutes}:{seconds:02d}"
    except (ValueError, TypeError):
        return "-"


def _short_model(model: str) -> str:
    """Shorten model name."""
    if not model:
        return "-"
    return MODEL_SHORT.get(model, model.split("-")[-1] if "-" in model else model)


def _short_mode(mode: str) -> str:
    """Shorten permission mode."""
    if not mode:
        return "-"
    return MODE_SHORT.get(mode, mode)


def _truncate(text: str, max_len: int = 30) -> str:
    """Truncate text with ellipsis."""
    if not text:
        return "-"
    text = text.replace("\n", " ").strip()
    if len(text) <= max_len:
        return text
    return text[: max_len - 1] + "\u2026"


def _status_text(status: str) -> str:
    label, _ = STATUS_DISPLAY.get(status, (status, "white"))
    return label


class ClaudeMonitorApp(App):
    """TUI application for monitoring Claude Code sessions."""

    TITLE = "Claude Monitor"

    CSS = """
    DataTable {
        height: 1fr;
    }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("c", "cleanup", "Cleanup"),
    ]

    def compose(self) -> ComposeResult:
        yield Header()
        yield DataTable()
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns(
            "Project", "Status", "Tool", "Model", "Mode",
            "Tools", "Duration", "Updated", "Topic",
        )
        table.cursor_type = "row"
        self._refresh_table()
        self.set_interval(1.0, self._refresh_table)

    def _refresh_table(self) -> None:
        table = self.query_one(DataTable)
        table.clear()

        sessions = get_sessions()
        for s in sessions:
            status_label = _status_text(s.status)
            _, color = STATUS_DISPLAY.get(s.status, (s.status, "white"))

            styled_status = f"[{color}]{status_label}[/]"
            tool = s.tool_name or "-"
            model = _short_model(s.model)
            mode = _short_mode(s.permission_mode)
            tools = str(s.tool_count) if s.tool_count else "-"
            duration = _format_duration(s.started_at)
            updated = _format_time(s.last_updated)
            project = s.project or s.cwd or "-"
            topic = _truncate(s.topic, 50) if s.topic else _truncate(s.last_prompt, 50)

            table.add_row(
                project, styled_status, tool, model, mode,
                tools, duration, updated, topic,
            )

            # Render subagents as indented child rows
            for i, sa in enumerate(s.subagents):
                is_last = i == len(s.subagents) - 1
                prefix = "  \u2514\u2500 " if is_last else "  \u251c\u2500 "
                sa_name = f"{prefix}{sa.agent_type or sa.agent_id[:12]}"
                sa_status = f"[dim]{sa.status}[/]"
                sa_updated = _format_time(sa.last_updated)

                table.add_row(
                    sa_name, sa_status, "-", "", "",
                    "", "", sa_updated, "",
                )

    def action_refresh(self) -> None:
        self._refresh_table()
        self.notify("Refreshed")

    def action_cleanup(self) -> None:
        removed = cleanup_old_sessions(max_age_hours=1.0)
        self._refresh_table()
        self.notify(f"Cleaned up {removed} old session(s)")


def run_tui() -> None:
    app = ClaudeMonitorApp()
    app.run()
