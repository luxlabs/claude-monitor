"""Display labels shared by the TUI; mirrored by Labels.swift in the macOS app.

Both implementations are checked against ``tests/fixtures/labels.json``.
"""

from __future__ import annotations

import re

MODEL_FAMILIES = ("opus", "sonnet", "haiku", "fable", "mythos")

# "claude-opus-5-5[1m]" -> opus 5.5; the look-aheads stop a date suffix such
# as "-20250514" from being read as a minor version.
_MODEL_RE = re.compile(r"(opus|sonnet|haiku|fable|mythos)-(\d{1,2})(?!\d)(?:-(\d{1,2})(?!\d))?")
# Pre-4 ids put the version first: "claude-3-5-sonnet-20241022".
_LEGACY_MODEL_RE = re.compile(r"claude-(\d)(?:-(\d))?-(opus|sonnet|haiku)")

MODE_LABELS = {
    "default": "manual",  # shown as "Manual" by Claude Code itself
    "plan": "plan",
    "acceptEdits": "accept",
    "auto": "auto",
    "dontAsk": "dontAsk",  # its own locked-down mode, not an alias of auto
    "bypassPermissions": "bypass",
}


def short_model(model: str) -> str:
    """Family plus version, e.g. ``claude-opus-5-5[1m]`` -> ``opus 5.5``."""
    if not model:
        return "-"
    lowered = model.lower()
    m = _MODEL_RE.search(lowered)
    if m:
        family, major, minor = m.groups()
        return f"{family} {major}.{minor}" if minor else f"{family} {major}"
    m = _LEGACY_MODEL_RE.search(lowered)
    if m:
        major, minor, family = m.groups()
        return f"{family} {major}.{minor}" if minor else f"{family} {major}"
    for family in MODEL_FAMILIES:
        if family in lowered:
            return family
    return model


def short_mode(mode: str) -> str:
    if not mode:
        return "-"
    return MODE_LABELS.get(mode, mode)


def limit_label(limit: dict) -> str:
    """Label for one entry of the usage API's ``limits[]`` array."""
    kind = limit.get("kind") or ""
    scope = limit.get("scope") if isinstance(limit.get("scope"), dict) else {}
    model = scope.get("model") if isinstance(scope.get("model"), dict) else {}
    scoped_name = model.get("display_name") if isinstance(model.get("display_name"), str) else ""
    if kind == "session":
        return "Session"
    if kind == "weekly_all":
        return "Week"
    if kind == "weekly_scoped":
        return f"Week ({scoped_name})" if scoped_name else "Week (model)"
    if kind == "spend_limit":
        return "Spend"
    return kind.replace("_", " ").capitalize() if kind else "Limit"


def format_tokens(count: int) -> str:
    if not count or count < 0:
        return "-"
    if count < 1000:
        return str(count)
    if count < 1_000_000:
        # Half-up (not Python's half-even) so Swift's rounding gives the same.
        return f"{int(count / 1000 + 0.5)}k"
    return f"{count / 1_000_000:.1f}M"
