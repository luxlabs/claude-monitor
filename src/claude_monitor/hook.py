"""Hook handler: one Claude Code hook event (JSON on stdin) -> session state file.

    gather_facts()  reads the transcript tail etc., outside the lock
    reduce()        pure: (state, event, facts, now) -> new state
    handle_hook()   lock -> read -> reduce -> write

Hooks run as parallel async processes, so events can be processed out of
order. Two clocks keep that safe: ``status_ts`` orders main-status changes
(subagent and metadata events never move it), and every pending permission
prompt carries its own ``since``. ``now`` is taken when the hook process
starts, which is the closest thing to the event time we get.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
import sys
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from claude_monitor import state as st
from claude_monitor.state import (
    BACKGROUND,
    COMPACTING,
    DONE_CALLS_LIMIT,
    ENDED_AGENTS_LIMIT,
    EXECUTING,
    STARTING,
    SUBAGENT_LIMIT,
    THINKING,
    WAITING,
    SessionState,
    SubagentState,
    cap,
    iso,
)

# Tools that wait for the user without raising a PermissionRequest.
USER_INPUT_TOOLS = {"ExitPlanMode", "AskUserQuestion"}

# Only these events may create a state file, so a late event can't resurrect
# a session after its SessionEnd removed the file.
CREATING_EVENTS = {"SessionStart", "UserPromptSubmit"}
TURN_BOUNDARY_EVENTS = {"SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "PostCompact"}

REORDER_WINDOW = 3.0  # a different tool call this long after a prompt means it was answered
RESUME_RACE_WINDOW = 10.0  # SessionStart(resume) can land after the first prompt

# background_tasks entries (Stop / SubagentStop input)
INACTIVE_TASK_STATUSES = {
    "completed", "complete", "done", "failed", "error", "killed",
    "stopped", "cancelled", "canceled", "idle",
}
PASSIVE_TASK_TYPES = {"shell", "monitor"}  # long-lived helpers: not "work in progress"
AGENT_TASK_TYPES = {"subagent", "teammate"}

_IDE_TAG_RE = re.compile(r"<ide_\w+>.*?</ide_\w+>", re.DOTALL)
_SYSTEM_TAG_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL)
# Prompts Claude Code submits on its own: background-agent reports,
# teammate messages, messages from other sessions.
_INJECTED_RE = re.compile(r"^\s*<(task-notification|teammate-message|cross-session-message)\b")
_COMMAND_NAME_RE = re.compile(r"<command-name>(.*?)</command-name>", re.DOTALL)
_COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.DOTALL)


# ── Prompt text

def clean_prompt(text: str) -> str:
    """Strip IDE context and system reminders; render slash commands as typed."""
    text = _IDE_TAG_RE.sub("", text or "")
    text = _SYSTEM_TAG_RE.sub("", text)
    name = _COMMAND_NAME_RE.search(text)
    if name:
        args = _COMMAND_ARGS_RE.search(text)
        return f"{name.group(1).strip()} {args.group(1).strip() if args else ''}".strip()
    return text.strip()


def is_injected(text: str) -> bool:
    return bool(_INJECTED_RE.match(text or ""))


def _content_to_text(content) -> str:
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


def fingerprint(data: dict) -> str:
    """Identify one tool call across PreToolUse/PermissionRequest/PostToolUse
    (PermissionRequest carries no tool_use_id, but it does carry tool_input)."""
    tool_input = data.get("tool_input")
    if tool_input is None:
        return ""
    try:
        raw = json.dumps(tool_input, sort_keys=True, default=str)
    except (TypeError, ValueError):
        raw = repr(tool_input)
    return hashlib.sha1(f"{data.get('tool_name', '')}|{raw}".encode()).hexdigest()[:12]


# ── Facts gathered outside the lock

@dataclass
class Facts:
    project: str = ""
    ai_title: str = ""
    last_prompt: str = ""  # latest human prompt recorded in the transcript
    model: str = ""  # model of the latest main-chain response
    context_tokens: int = 0
    agent_description: str = ""


def _worktree_repo(git_file: Path) -> str:
    """Repository name for a linked worktree's ``.git`` file, else ""."""
    try:
        text = git_file.read_text().strip()
    except OSError:
        return ""
    m = re.match(r"gitdir:\s*(.+)", text)
    if not m:
        return ""
    gitdir = Path(m.group(1).strip())
    if not gitdir.is_absolute():
        gitdir = (git_file.parent / gitdir).resolve()
    parts = gitdir.parts
    # <repo>/.git/worktrees/<name>  (submodules use .git/modules/… instead)
    if len(parts) >= 4 and parts[-2] == "worktrees" and parts[-3] == ".git":
        return parts[-4]
    return ""


def project_name(cwd: str) -> str:
    """Git root name ("repo/worktree" inside a linked worktree), else the cwd basename."""
    if not cwd:
        return ""
    p = Path(cwd)
    for d in [p, *p.parents]:
        git = d / ".git"
        try:
            if git.is_dir():
                return d.name
            if git.is_file():
                repo = _worktree_repo(git)
                return f"{repo}/{d.name}" if repo else d.name
        except OSError:
            break
        if d == d.parent:
            break
    return p.name


def _usage_tokens(usage) -> int:
    if not isinstance(usage, dict):
        return 0
    keys = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")
    return sum(v for k in keys if isinstance(v := usage.get(k), int))


def scan_transcript_tail(path: str, start: int = 64 * 1024, limit: int = 1024 * 1024) -> Facts:
    """Latest title, human prompt, model and context size from the transcript tail.

    Reads 64 KB and doubles up to 1 MB until the model and a prompt turn up.
    Splits on b"\\n" only: transcript lines may contain raw U+2028/U+2029.
    """
    facts = Facts()
    if not path:
        return facts
    try:
        size = Path(path).stat().st_size
    except OSError:
        return facts
    window = start
    while True:
        facts = Facts()
        user_text = ""
        try:
            with open(path, "rb") as f:
                offset = max(0, size - window)
                f.seek(offset)
                chunk = f.read()
        except OSError:
            return facts
        lines = chunk.split(b"\n")
        if offset > 0:
            lines = lines[1:]  # first line is partial
        for raw in lines:
            if not raw.strip():
                continue
            try:
                obj = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            kind = obj.get("type")
            if kind == "ai-title":
                title = obj.get("aiTitle")
                if isinstance(title, str) and title.strip():
                    facts.ai_title = title.strip()
            elif kind == "last-prompt":
                prompt = obj.get("lastPrompt")
                if isinstance(prompt, str) and prompt.strip():
                    facts.last_prompt = clean_prompt(prompt)
            elif kind == "assistant" and not obj.get("isSidechain"):
                msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
                model = msg.get("model")
                if isinstance(model, str) and model and model != "<synthetic>":
                    facts.model = model
                    tokens = _usage_tokens(msg.get("usage"))
                    if tokens:
                        facts.context_tokens = tokens
            elif kind == "user":
                if any(obj.get(k) for k in ("isMeta", "isSidechain", "isCompactSummary",
                                             "isVisibleInTranscriptOnly", "isVirtual")):
                    continue
                origin = obj.get("origin")
                if isinstance(origin, dict) and origin.get("kind") not in (None, "human"):
                    continue
                msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
                text = _content_to_text(msg.get("content"))
                if is_injected(text) or text.lstrip().startswith("<local-command"):
                    continue
                cleaned = clean_prompt(text)
                if cleaned:
                    user_text = cleaned
        if not facts.last_prompt:
            facts.last_prompt = user_text  # transcripts without last-prompt entries
        if (facts.model and facts.last_prompt) or window >= size or window >= limit:
            return facts
        window *= 2


def read_agent_description(transcript_path: str, agent_id: str) -> str:
    """Description of a subagent from Claude Code's per-agent meta file, if any."""
    if not transcript_path or not agent_id:
        return ""
    p = Path(transcript_path)
    candidates = (
        p.with_suffix("") / "subagents" / f"agent-{agent_id}.meta.json",
        p.parent / f"agent-{agent_id}.meta.json",  # transcript_path is a subagent's own
    )
    for meta in candidates:
        try:
            data = json.loads(meta.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and isinstance(data.get("description"), str):
            return data["description"].strip()
    return ""


def gather_facts(event: str, data: dict) -> Facts:
    agent_id = data.get("agent_id")
    transcript = data.get("transcript_path") if isinstance(data.get("transcript_path"), str) else ""
    if agent_id:
        facts = Facts()
        if event in ("SubagentStart", "PreToolUse"):
            facts.agent_description = read_agent_description(transcript, agent_id)
        return facts
    facts = scan_transcript_tail(transcript) if event in TURN_BOUNDARY_EVENTS else Facts()
    cwd = data.get("cwd")
    if isinstance(cwd, str) and cwd:
        facts.project = project_name(cwd)
    return facts


# ── Reducer helpers

def _set_status(s: SessionState, status: str, now: float, tool: str | None = None, fp: str = "") -> bool:
    """Apply a main-status transition unless a later one was already applied."""
    if now < s.status_ts:
        return False
    s.base_status = status
    s.status_ts = now
    s.tool_name = tool
    s.tool_fp = fp
    return True


def _remember_done(s: SessionState, key: str, fp: str) -> None:
    if fp:
        s.done_calls = (s.done_calls + [f"{key}:{fp}"])[-DONE_CALLS_LIMIT:]


def _clear_pending_for_call(s: SessionState, key: str, fp: str, now: float) -> None:
    """A call by this agent finished: its prompt (if it was this call's) is resolved."""
    p = s.pending.get(key)
    if p is None:
        return
    if not p.get("fp") or p.get("fp") == fp or now - float(p.get("since") or 0) >= REORDER_WINDOW:
        del s.pending[key]


def _clear_pending_on_new_call(s: SessionState, key: str, fp: str, now: float) -> None:
    """A new call by this agent: the earlier prompt was denied, unless this is
    the same call's PreToolUse delivered late."""
    p = s.pending.get(key)
    if p is None:
        return
    if p.get("fp") and p.get("fp") == fp:
        return
    if now - float(p.get("since") or 0) >= REORDER_WINDOW:
        del s.pending[key]


def _clear_main_pending(s: SessionState, now: float) -> None:
    p = s.pending.get("main")
    if p is not None and now >= float(p.get("since") or 0):
        del s.pending["main"]


def _add_subagent(s: SessionState, agent_id: str, agent_type, description: str, now: float) -> SubagentState | None:
    if len(s.subagents) >= SUBAGENT_LIMIT:
        s.subagents_overflow += 1
        return None
    sa = SubagentState(
        agent_id=agent_id,
        agent_type=agent_type if isinstance(agent_type, str) else "",
        description=cap(description, 200),
        started_at=iso(now),
        ts=now,
    )
    s.subagents.append(sa)
    return sa


def _task_active(task: dict) -> bool:
    return str(task.get("status") or "").lower() not in INACTIVE_TASK_STATUSES


def _apply_background_tasks(s: SessionState, tasks, now: float, reconcile: bool, stopping: str = "") -> None:
    """Update the background summary; on Stop also reconcile the subagent list.

    ``stopping`` is the agent whose SubagentStop carried the list: Claude Code
    still reports it as running there, so it must not count.
    """
    if isinstance(tasks, list) and stopping:
        tasks = [t for t in tasks if not (isinstance(t, dict) and t.get("id") == stopping)]
    if not isinstance(tasks, list):
        if reconcile:
            # No task registry info (older Claude Code): subagents were turn-scoped.
            s.subagents = []
            s.subagents_overflow = 0
            s.bg_active = 0
            s.bg_types = {}
        return
    active = [t for t in tasks if isinstance(t, dict) and _task_active(t)]
    s.bg_types = dict(Counter(str(t.get("type") or "task") for t in active))
    s.bg_active = sum(1 for t in active if t.get("type") not in PASSIVE_TASK_TYPES)
    if not reconcile:
        return
    if s.bg_active == 0:
        s.subagents = []
        s.subagents_overflow = 0
        return
    # Workflow agents aren't listed one by one, so keep what we track and
    # only add agents we missed (e.g. the monitor started mid-session).
    for t in active:
        tid = t.get("id")
        if t.get("type") not in AGENT_TASK_TYPES or not isinstance(tid, str) or not tid:
            continue
        if s.find_subagent(tid) is None and s.ended_at(tid) is None:
            _add_subagent(s, tid, t.get("agent_type") or t.get("type"), str(t.get("description") or ""), now)


# ── Subagent events

def _subagent_start(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    agent_id = data.get("agent_id")
    if not isinstance(agent_id, str) or not agent_id:
        return
    ended = s.ended_at(agent_id)
    if ended is not None:
        if now <= ended:
            return  # the original start, delivered after the stop
        s.ended_agents = [e for e in s.ended_agents if e[0] != agent_id]  # resumed agent
    sa = s.find_subagent(agent_id)
    if sa is None:
        _add_subagent(s, agent_id, data.get("agent_type"), facts.agent_description, now)
        return
    if not sa.agent_type and isinstance(data.get("agent_type"), str):
        sa.agent_type = data["agent_type"]
    if not sa.description and facts.agent_description:
        sa.description = cap(facts.agent_description, 200)
    sa.ts = max(sa.ts, now)


def _subagent_stop(s: SessionState, data: dict, now: float) -> None:
    agent_id = data.get("agent_id")
    if isinstance(agent_id, str) and agent_id:
        before = len(s.subagents)
        s.subagents = [sa for sa in s.subagents if sa.agent_id != agent_id]
        if len(s.subagents) == before and s.subagents_overflow > 0:
            s.subagents_overflow -= 1
        s.pending.pop(agent_id, None)
        s.ended_agents = ([e for e in s.ended_agents if e[0] != agent_id] + [[agent_id, now]])[-ENDED_AGENTS_LIMIT:]
    # SubagentStop's background_tasks covers the whole session. The status is
    # left alone: the report-back turn that follows ends with its own Stop.
    _apply_background_tasks(s, data.get("background_tasks"), now, reconcile=False,
                            stopping=agent_id if isinstance(agent_id, str) else "")


def _subagent_event(s: SessionState, event: str, data: dict, facts: Facts, now: float, agent_id: str) -> None:
    """Any event fired inside a subagent: never touches the main status, tool,
    counters, cwd, mode or effort — only the agent's row and its prompts."""
    if s.ended_at(agent_id) is not None:
        s.pending.pop(agent_id, None)  # late event from a finished agent
        return
    sa = s.find_subagent(agent_id)
    if sa is None:
        sa = _add_subagent(s, agent_id, data.get("agent_type"), facts.agent_description, now)
    tool = data.get("tool_name") if isinstance(data.get("tool_name"), str) else ""
    fp = fingerprint(data)
    if event == "PreToolUse":
        if tool in USER_INPUT_TOOLS:
            s.pending[agent_id] = {"tool": tool, "fp": fp, "since": now}
        else:
            _clear_pending_on_new_call(s, agent_id, fp, now)
        if sa is not None:
            if now >= sa.ts:
                sa.tool_name = tool or None
            if not sa.description and facts.agent_description:
                sa.description = cap(facts.agent_description, 200)
    elif event in ("PostToolUse", "PostToolUseFailure", "PermissionDenied"):
        _clear_pending_for_call(s, agent_id, fp, now)
        _remember_done(s, agent_id, fp)
        if sa is not None:
            if event != "PermissionDenied":
                sa.tool_count += 1
            if now >= sa.ts:
                sa.tool_name = None
    elif event == "PermissionRequest":
        if f"{agent_id}:{fp}" not in s.done_calls:
            s.pending[agent_id] = {"tool": tool, "fp": fp, "since": now}
    elif event == "Elicitation":
        s.pending[agent_id] = {"tool": "elicitation", "fp": "", "since": now}
    elif event == "ElicitationResult":
        if (s.pending.get(agent_id) or {}).get("tool") == "elicitation":
            del s.pending[agent_id]
    if sa is not None:
        sa.ts = max(sa.ts, now)


# ── Main-agent events

def _on_session_start(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    model = data.get("model")
    if isinstance(model, str) and model:
        s.model = model
    if data.get("source") == "compact":
        if s.base_status == COMPACTING:
            _set_status(s, THINKING, now)
        return
    # startup | resume | clear | fork: nothing carries over from a previous run
    s.pending.clear()
    s.subagents = []
    s.subagents_overflow = 0
    s.ended_agents = []
    s.done_calls = []
    s.bg_active = 0
    s.bg_types = {}
    s.crons = 0
    s.last_error = ""
    if s.base_status in (THINKING, EXECUTING, COMPACTING, BACKGROUND) and now - s.status_ts < RESUME_RACE_WINDOW:
        return  # a resumed session's first prompt was processed first
    _set_status(s, STARTING, now)


def _on_prompt(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    raw = data.get("prompt") if isinstance(data.get("prompt"), str) else ""
    cleaned = clean_prompt(raw)
    if cleaned and not is_injected(raw) and not is_injected(cleaned):
        s.topic = cap(cleaned)
        s.last_prompt = cap(raw.strip())
        s.last_error = ""
    _clear_main_pending(s, now)
    _set_status(s, THINKING, now)


def _on_pre_tool(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    tool = data.get("tool_name") if isinstance(data.get("tool_name"), str) else ""
    fp = fingerprint(data)
    if tool in USER_INPUT_TOOLS:
        if now >= s.status_ts:
            s.pending["main"] = {"tool": tool, "fp": fp, "since": now}
    else:
        _clear_pending_on_new_call(s, "main", fp, now)
    _set_status(s, EXECUTING, now, tool or None, fp)


def _on_permission_request(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    tool = data.get("tool_name") if isinstance(data.get("tool_name"), str) else ""
    fp = fingerprint(data)
    if f"main:{fp}" in s.done_calls:
        return  # the call already finished: this is a late delivery
    same_call = bool(fp) and fp == s.tool_fp
    if now < s.status_ts and not same_call:
        return  # happened before a later transition (e.g. the turn's Stop)
    s.pending["main"] = {"tool": tool, "fp": fp, "since": now}
    if tool and now >= s.status_ts:
        s.tool_name = tool


def _on_post_tool(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    fp = fingerprint(data)
    if data.get("hook_event_name") != "PermissionDenied":
        s.tool_count += 1
    _clear_pending_for_call(s, "main", fp, now)
    _remember_done(s, "main", fp)
    _set_status(s, THINKING, now)


def _on_stop(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    _clear_main_pending(s, now)
    s.last_error = ""
    _apply_background_tasks(s, data.get("background_tasks"), now, reconcile=True)
    crons = data.get("session_crons")
    if isinstance(crons, list):
        s.crons = len(crons)
    _set_status(s, BACKGROUND if s.bg_active > 0 else WAITING, now)


def _on_stop_failure(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    _clear_main_pending(s, now)
    error = data.get("error")
    s.last_error = error if isinstance(error, str) and error else "unknown"
    _set_status(s, WAITING, now)


def _on_notification(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    kind = data.get("notification_type")
    if kind == "idle_prompt":
        # Since 2.1.288 it fires only when nothing, background agents
        # included, is running: the session is truly waiting for the user.
        if now < s.status_ts:
            return  # delivered after the session had already moved on
        s.pending.clear()
        s.subagents = []
        s.subagents_overflow = 0
        s.bg_active = 0
        s.bg_types = {}
        if s.base_status != WAITING:
            _set_status(s, WAITING, now)
    elif kind == "permission_prompt":
        # Secondary signal; it matters for prompts that raise no
        # PermissionRequest, e.g. the sandbox network prompt mid-Bash.
        if "main" not in s.pending and s.base_status == EXECUTING and now >= s.status_ts:
            s.pending["main"] = {"tool": s.tool_name or "", "fp": "", "since": now}


def _on_elicitation(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    if now >= s.status_ts:
        s.pending["main"] = {"tool": "elicitation", "fp": "", "since": now}


def _on_elicitation_result(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    if (s.pending.get("main") or {}).get("tool") == "elicitation":
        del s.pending["main"]


def _on_pre_compact(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    _set_status(s, COMPACTING, now)


def _on_post_compact(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    s.context_tokens = 0  # unknown until the next response
    if s.base_status == COMPACTING:
        _set_status(s, THINKING if data.get("trigger") == "auto" else WAITING, now)


def _on_model_switch(s: SessionState, data: dict, facts: Facts, now: float) -> None:
    to_model = data.get("to_model")
    if isinstance(to_model, str) and to_model:
        s.model = to_model
    tokens = data.get("context_tokens")
    if isinstance(tokens, int) and tokens > 0:
        s.context_tokens = tokens


_MAIN_HANDLERS = {
    "SessionStart": _on_session_start,
    "UserPromptSubmit": _on_prompt,
    "PreToolUse": _on_pre_tool,
    "PermissionRequest": _on_permission_request,
    "PostToolUse": _on_post_tool,
    "PostToolUseFailure": _on_post_tool,
    "PermissionDenied": _on_post_tool,
    "Stop": _on_stop,
    "StopFailure": _on_stop_failure,
    "Notification": _on_notification,
    "Elicitation": _on_elicitation,
    "ElicitationResult": _on_elicitation_result,
    "PreCompact": _on_pre_compact,
    "PostCompact": _on_post_compact,
    "PostModelSwitch": _on_model_switch,
}


def _apply_main_metadata(s: SessionState, data: dict, facts: Facts) -> None:
    cwd = data.get("cwd")
    if isinstance(cwd, str) and cwd and (cwd != s.cwd or not s.project):
        s.cwd = cwd
        s.project = facts.project or s.project
    mode = data.get("permission_mode")
    if isinstance(mode, str) and mode:
        s.permission_mode = mode
    effort = data.get("effort")
    level = effort.get("level") if isinstance(effort, dict) else effort
    if isinstance(level, str) and level:
        s.effort = level
    title = data.get("session_title")
    if isinstance(title, str) and title.strip():
        s.custom_title = cap(title.strip(), 200)
    if facts.ai_title:
        s.ai_title = cap(facts.ai_title, 200)
    if facts.model and not s.model:
        s.model = facts.model
    if facts.context_tokens:
        s.context_tokens = facts.context_tokens
    if facts.last_prompt and not s.topic:
        s.topic = cap(facts.last_prompt)


def reduce(state: SessionState | None, data: dict, facts: Facts, now: float) -> SessionState | None:
    """Return the session state after ``data``; None means "don't write"."""
    event = data.get("hook_event_name") or ""
    session_id = data.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return None
    if state is None:
        if event not in CREATING_EVENTS:
            return None
        state = SessionState(session_id=session_id, started_at=iso(now))
    s = copy.deepcopy(state)
    s.activity_ts = max(s.activity_ts, now)

    if event == "SubagentStart":
        _subagent_start(s, data, facts, now)
        return s
    if event == "SubagentStop":
        _subagent_stop(s, data, now)
        return s
    agent_id = data.get("agent_id")
    if isinstance(agent_id, str) and agent_id:
        _subagent_event(s, event, data, facts, now, agent_id)
        return s

    _apply_main_metadata(s, data, facts)
    handler = _MAIN_HANDLERS.get(event)
    if handler is not None:
        handler(s, data, facts, now)
    return s


# ── Entry points

def handle_hook(data: dict, now: float | None = None) -> None:
    now = time.time() if now is None else now
    session_id = data.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return
    event = data.get("hook_event_name") or ""
    if event == "SessionEnd":
        # Registered synchronously (async hooks are killed when `claude -p`
        # exits), so this must stay fast: no transcript reads.
        with st.write_lock(timeout=1.0):
            st.remove_session(session_id)
        return
    facts = gather_facts(event, data)
    with st.write_lock() as locked:
        if not locked:
            return
        new = reduce(st.read_session(session_id), data, facts, now)
        if new is not None:
            st.write_session(new)
        if event == "SessionStart" and data.get("source") != "compact":
            try:
                from claude_monitor.live import live_session_ids

                st.gc(live_session_ids() | {session_id}, now)
            except Exception:
                pass


def main() -> None:
    """Entry point: read one event from stdin. Never prints, never fails."""
    now = time.time()
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            return
        data = json.loads(raw)
        if isinstance(data, dict):
            handle_hook(data, now)
    except Exception:
        pass


if __name__ == "__main__":
    main()
