"""Textual TUI for monitoring Claude Code sessions."""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from datetime import datetime, timezone

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Grid
from textual.coordinate import Coordinate
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Footer, Header, Label, Static

from claude_monitor import live, state
from claude_monitor.labels import format_tokens, limit_label, short_mode, short_model
from claude_monitor.live import Effective, LiveEntry, Snapshot
from claude_monitor.state import SessionState

STATUS_COLORS = {
    "PERMISSION": "red",
    "THINKING": "yellow",
    "EXECUTING": "dodger_blue",
    "COMPACTING": "dark_orange",
    "BACKGROUND": "medium_purple",
    "STARTING": "cyan",
    "WAITING": "green",
    "ENDED": "dim",
}
STATUS_ORDER = {
    "PERMISSION": 0, "THINKING": 1, "EXECUTING": 1, "COMPACTING": 1,
    "BACKGROUND": 2, "STARTING": 3, "WAITING": 4,
}
COLUMNS = (
    ("Project", "project"), ("Status", "status"), ("Tool", "tool"), ("Model", "model"),
    ("Mode", "mode"), ("Ctx", "ctx"), ("Tools", "tools"), ("Duration", "duration"),
    ("Updated", "updated"), ("Topic", "topic"),
)
SUBAGENT_ROWS = 8
POLL_INTERVAL = 5.0
HIDDEN_PROJECTS = {"ClaudeProbe"}


@dataclass
class RowMeta:
    session_id: str
    entry: LiveEntry | None


def _format_clock(ts: float) -> str:
    if not ts:
        return "-"
    return datetime.fromtimestamp(ts).strftime("%H:%M:%S")


def _format_duration(started_at: str, now: float) -> str:
    start = state.parse_iso(started_at)
    if not start:
        return "-"
    total = int(now - start)
    if total < 0:
        return "-"
    hours, rest = divmod(total, 3600)
    minutes, seconds = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{seconds:02d}" if hours else f"{minutes}:{seconds:02d}"


def _truncate(text: str, max_len: int) -> str:
    text = (text or "").replace("\n", " ").strip()
    if not text:
        return "-"
    return text if len(text) <= max_len else text[: max_len - 1] + "…"


def _escape(text: str) -> str:
    return text.replace("[", "\\[")


def _remaining(resets_at: str | None, now: float) -> str:
    ts = state.parse_iso(resets_at)
    if not ts or ts <= now:
        return ""
    minutes = int(ts - now) // 60
    days, rest = divmod(minutes, 1440)
    hours, mins = divmod(rest, 60)
    if days:
        return f"{days}d {hours}h" if hours else f"{days}d"
    return f"{hours}h {mins}m" if hours else f"{mins}m"


def usage_line(now: float) -> str:
    """One-line summary of usage.json (limits[] first, flat windows as fallback)."""
    try:
        data = json.loads((state.monitor_dir() / "usage.json").read_text())
    except (OSError, ValueError):
        return ""
    if not isinstance(data, dict):
        return ""
    parts = []
    limits = data.get("limits") if isinstance(data.get("limits"), list) else []
    for lim in limits:
        if not isinstance(lim, dict) or not isinstance(lim.get("percent"), (int, float)):
            continue
        reset = _remaining(lim.get("resets_at"), now)
        text = f"{limit_label(lim)} {int(lim['percent'])}%" + (f" · {reset}" if reset else "")
        parts.append(f"[b]{text}[/]" if lim.get("is_active") else text)
    if not parts:
        for key, label in (("five_hour", "Session"), ("seven_day", "Week")):
            window = data.get(key)
            if isinstance(window, dict) and isinstance(window.get("utilization"), (int, float)):
                reset = _remaining(window.get("resets_at"), now)
                parts.append(f"{label} {int(window['utilization'])}%" + (f" · {reset}" if reset else ""))
    return "  |  ".join(parts)


class ConfirmScreen(ModalScreen[bool]):
    """Yes/No confirmation for stopping or killing a session."""

    DEFAULT_CSS = """
    ConfirmScreen { align: center middle; }
    #dialog { grid-size: 2; grid-gutter: 1 2; padding: 1 2; width: 64; height: auto;
              border: thick $error; background: $surface; }
    #question { column-span: 2; width: 100%; content-align: center middle; }
    Button { width: 100%; }
    """
    BINDINGS = [Binding("y", "answer(True)", "Yes"), Binding("n,escape", "answer(False)", "No")]

    def __init__(self, question: str) -> None:
        super().__init__()
        self.question = question

    def compose(self) -> ComposeResult:
        yield Grid(
            Label(self.question, id="question"),
            Button("Yes", variant="error", id="yes"),
            Button("No", variant="primary", id="no"),
            id="dialog",
        )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")

    def action_answer(self, value: bool) -> None:
        self.dismiss(value)


class ClaudeMonitorApp(App):
    """TUI application for monitoring Claude Code sessions."""

    TITLE = "Claude Monitor"

    CSS = """
    DataTable { height: 1fr; }
    #usage { height: 1; padding: 0 1; color: $text-muted; }
    """

    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("i", "toggle_idle", "Show idle"),
        Binding("k", "stop", "Stop"),
        Binding("K", "kill", "Force kill"),
        Binding("y", "copy_resume", "Copy resume"),
        Binding("c", "cleanup", "Cleanup"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.snapshot: Snapshot | None = None
        self.show_all = False
        self._polling = False
        self._keys: list[str] = []
        self._cells: dict[str, tuple] = {}
        self._meta: dict[str, RowMeta] = {}

    def compose(self) -> ComposeResult:
        yield Header()
        yield DataTable(cursor_type="row")
        yield Static(id="usage")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        for label, key in COLUMNS:
            table.add_column(label, key=key)
        self.refresh_table()
        self.set_interval(1.0, self.refresh_table)
        self.set_interval(POLL_INTERVAL, self.poll_live)
        self.poll_live()

    # ── Live data

    def poll_live(self) -> None:
        if self._polling:
            return
        self._polling = True
        self.run_worker(self._poll_in_thread, thread=True, group="live")

    def _poll_in_thread(self) -> None:
        # An exception escaping a worker would quit the app: never let one out.
        try:
            snap = live.poll()
        except Exception:
            snap = None
        self.call_from_thread(self._set_snapshot, snap)

    def _set_snapshot(self, snap: Snapshot | None) -> None:
        self._polling = False
        if snap is not None:
            self.snapshot = snap  # a failed poll keeps the last one; it ages out by itself
        self.refresh_table()

    # ── Rows

    def _session_cells(self, s: SessionState | None, entry: LiveEntry | None, eff: Effective, now: float) -> tuple:
        color = STATUS_COLORS.get(eff.status, "white")
        status = f"[{color}]{eff.status}[/]"
        if s is None:
            cwd = entry.cwd if entry else ""
            name = os.path.basename(cwd.rstrip("/")) or "-"
            return (
                f"[dim]{_escape(name)}[/]", status, _escape(eff.detail or "-"), "-", "-", "-", "-",
                "-", "-", f"[dim]untracked · {_escape(entry.name if entry else '')}[/]",
            )
        if s.last_error:
            status += f" [red]⚠ {_escape(s.last_error)}[/]"
        if eff.status == "PERMISSION":
            pending_tool = next((p.get("tool") for p in s.pending.values() if p.get("tool")), "")
            tool = eff.detail or pending_tool or s.tool_name or "-"
        elif eff.status == "BACKGROUND":
            tool = f"{s.bg_active} in background"
        else:
            tool = s.tool_name or "-"
        model = short_model(s.model) + (f" · {s.effort}" if s.effort else "")
        project = s.project or os.path.basename(s.cwd.rstrip("/")) or "-"
        topic = s.title or s.topic or s.last_prompt
        return (
            _escape(project), status, _escape(tool), model, short_mode(s.permission_mode),
            format_tokens(s.context_tokens), str(s.tool_count) if s.tool_count else "-",
            _format_duration(s.started_at, now), _format_clock(s.activity_ts), _escape(_truncate(topic, 60)),
        )

    def _subagent_rows(self, s: SessionState) -> list[tuple[str, tuple]]:
        rows = []
        shown = s.subagents[:SUBAGENT_ROWS]
        extra = len(s.subagents) - len(shown) + s.subagents_overflow
        for i, sa in enumerate(shown):
            last = i == len(shown) - 1 and not extra
            prefix = "  └─ " if last else "  ├─ "
            label = sa.agent_type or sa.agent_id[:12]
            if sa.description:
                label += f": {sa.description}"
            waiting = sa.agent_id in s.pending
            rows.append((f"{s.session_id}/{sa.agent_id}", (
                prefix + _escape(_truncate(label, 40)),
                "[red]permission[/]" if waiting else "[dim]running[/]",
                _escape(sa.tool_name or "-"), "", "", "",
                str(sa.tool_count) if sa.tool_count else "-", "", _format_clock(sa.ts), "",
            )))
        if extra:
            rows.append((f"{s.session_id}/+more", (
                f"  └─ [dim]+{extra} more[/]", "", "", "", "", "", "", "", "", "",
            )))
        return rows

    def build_rows(self, now: float) -> list[tuple[str, tuple, RowMeta]]:
        snap = self.snapshot
        observed = snap.observed_at if snap else None
        entries = snap.entries if snap else {}
        sessions = {s.session_id: s for s in state.list_sessions() if s.project not in HIDDEN_PROJECTS}
        items = []
        for sid, s in sessions.items():
            entry = entries.get(sid)
            items.append((sid, s, entry, live.effective(s, entry, observed, now)))
        for sid, entry in entries.items():
            if sid not in sessions:
                items.append((sid, None, entry, live.effective(None, entry, observed, now)))
        items = [it for it in items if not it[3].hidden and (self.show_all or not it[3].stale_idle)]
        items.sort(key=lambda it: (STATUS_ORDER.get(it[3].status, 5), -(it[1].activity_ts if it[1] else 0)))
        rows = []
        for sid, s, entry, eff in items:
            meta = RowMeta(sid, entry)
            rows.append((sid, self._session_cells(s, entry, eff, now), meta))
            if s is not None:
                rows.extend((key, cells, meta) for key, cells in self._subagent_rows(s))
        return rows

    def refresh_table(self) -> None:
        now = time.time()
        rows = self.build_rows(now)
        table = self.query_one(DataTable)
        keys = [key for key, _, _ in rows]
        self._meta = {key: meta for key, _, meta in rows}
        if keys == self._keys:
            for key, cells, _ in rows:
                old = self._cells.get(key)
                for (_, col), value, before in zip(COLUMNS, cells, old or ()):
                    if value != before:
                        table.update_cell(key, col, value)
                self._cells[key] = cells
        else:
            cursor_key = self._cursor_key()
            table.clear()
            for key, cells, _ in rows:
                table.add_row(*cells, key=key)
            self._keys = keys
            self._cells = {key: cells for key, cells, _ in rows}
            if cursor_key in keys:
                table.move_cursor(row=keys.index(cursor_key))
        mode = f"live: {self.snapshot.source}" if self.snapshot else "live: off"
        idle = "showing idle" if self.show_all else "idle hidden (i)"
        line = usage_line(now)
        self.query_one("#usage", Static).update(f"{line}  [dim]{mode} · {idle}[/]" if line else f"[dim]{mode} · {idle}[/]")

    def _cursor_key(self) -> str | None:
        table = self.query_one(DataTable)
        if not self._keys or table.cursor_row is None or table.cursor_row >= len(self._keys):
            return None
        try:
            return table.coordinate_to_cell_key(Coordinate(table.cursor_row, 0)).row_key.value
        except Exception:
            return None

    def _selected(self) -> RowMeta | None:
        key = self._cursor_key()
        return self._meta.get(key) if key else None

    # ── Actions

    def action_refresh(self) -> None:
        self.poll_live()
        self.refresh_table()
        self.notify("Refreshed")

    def action_toggle_idle(self) -> None:
        self.show_all = not self.show_all
        self.refresh_table()

    def action_copy_resume(self) -> None:
        meta = self._selected()
        if meta is None:
            return
        self.copy_to_clipboard(f"claude --resume {meta.session_id}")
        self.notify(f"Copied: claude --resume {meta.session_id}")

    def action_stop(self) -> None:
        self._confirm_stop(force=False)

    def action_kill(self) -> None:
        self._confirm_stop(force=True)

    def _confirm_stop(self, force: bool) -> None:
        meta = self._selected()
        entry = meta.entry if meta else None
        if entry is None or (entry.pid is None and not entry.job_id):
            self.notify("No live process for this session", severity="warning")
            return
        if entry.kind == "background" and entry.job_id and not force:
            question = f"Stop background session {entry.name or entry.job_id} (claude stop)?"
        else:
            question = f"{'Force kill (SIGKILL)' if force else 'Terminate (SIGTERM)'} PID {entry.pid}?"

        def done(confirmed: bool | None) -> None:
            if confirmed:
                self.run_worker(lambda: self._stop_in_thread(meta.session_id, entry, force), thread=True, group="stop")

        self.push_screen(ConfirmScreen(question), done)

    def _stop_in_thread(self, session_id: str, expected: LiveEntry, force: bool) -> None:
        try:
            # Re-check right before signalling: the pid may have been reused.
            fresh = live.poll()
            current = fresh.entries.get(session_id) if fresh else None
            if current is None or current.pid != expected.pid or current.job_id != expected.job_id:
                self.call_from_thread(self.notify, "Session changed since it was listed; not stopped", severity="warning")
                return
            result = live.stop_session(current, force=force)
        except Exception as exc:
            result = f"stop failed: {exc}"
        self.call_from_thread(self.notify, result)
        self.call_from_thread(self.poll_live)

    def action_cleanup(self) -> None:
        if self.snapshot is not None:
            live_ids = set(self.snapshot.entries)
        else:
            live_ids = live.live_session_ids()
        removed = state.gc(live_ids, max_age_hours=1.0)
        self.refresh_table()
        self.notify(f"Removed {removed} stale session file(s)")


def run_tui() -> None:
    ClaudeMonitorApp().run()
