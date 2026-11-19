"""
What Codex tells herdr about itself, as `agent.*` labels on its herdr-core
terminal: the keys and value shapes @wierdbytes/pi-wierdr writes for pi and
the Claude Code mod `cc` for Claude, so a herdr agent list and Wierdr read
all three alike. Pure functions.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Iterable, Mapping, Optional

APP = "codex"

# Every label pi-wierdr owns, and `agent.subagents_meta` (the sub-agents' rows,
# as the Claude Code mod writes it). Codex writes all but the cache ones
# (OpenAI reports no cache lifetime); a full write clears those too, so
# nothing an earlier agent in this terminal left stays behind.
LABEL_KEYS = (
    "agent.app",
    "agent.pid",
    "agent.model",
    "agent.model_id",
    "agent.provider",
    "agent.effort",
    "agent.ctx",
    "agent.ctx_max",
    "agent.subagents",
    "agent.subagents_meta",
    "agent.session",
    "agent.cache_until",
    "agent.cache_ttl",
)

# Codex's levels that mean "no reasoning": shown as no effort, like pi's `off`.
NO_EFFORT = ("", "none")

_VERSIONED = re.compile(r"^gpt-(\d+(?:\.\d+)*)(?:-(.+))?$", re.IGNORECASE)


def _words(rest: str) -> str:
    return " ".join(w[:1].upper() + w[1:] for w in re.split(r"[-_\s]+", rest) if w)


def model_name(slug: Optional[str], display_name: Optional[str] = None) -> Optional[str]:
    """
    The model as pi names OpenAI's: `GPT-<version>` and the variant in words,
    `gpt-6.1-sol` / Codex's "GPT-6.1-Sol" -> "GPT-6.1 Sol", `gpt-5.3-codex`
    -> "GPT-5.3 Codex". Codex's display name wins when it says more ("GPT-6.1
    Terra" stays); anything else is its display name or its slug.
    """
    display = display_name.strip() if isinstance(display_name, str) else ""
    m = _VERSIONED.match(display)
    if m:
        version, rest = m.group(1), m.group(2)
        return "GPT-%s %s" % (version, rest.replace("-", " ").strip()) if rest else "GPT-%s" % version
    if display.upper().startswith("GPT-") and " " in display:
        return display
    if isinstance(slug, str) and slug:
        m = _VERSIONED.match(slug.strip())
        if m:
            version, rest = m.group(1), m.group(2)
            return "GPT-%s %s" % (version, _words(rest)) if rest else "GPT-%s" % version
    if display:
        return display
    return slug or None


def effort_label(effort: Optional[str]) -> Optional[str]:
    if not isinstance(effort, str):
        return None
    effort = effort.strip()
    return None if effort.lower() in NO_EFFORT else effort


def build_labels(
    *,
    pid: int,
    session: Optional[str],
    model_id: Optional[str],
    model_display: Optional[str] = None,
    provider: Optional[str] = None,
    effort: Optional[str] = None,
    ctx: Optional[int] = None,
    ctx_max: Optional[int] = None,
    subagents: Optional[int] = None,
    subagents_meta: Optional[str] = None,
) -> Dict[str, str]:
    """Every label Codex owns, `""` for the ones it has no value for."""
    labels = {k: "" for k in LABEL_KEYS}
    labels["agent.app"] = APP
    labels["agent.pid"] = str(pid)
    name = model_name(model_id, model_display)
    if name:
        labels["agent.model"] = name
    if model_id:
        labels["agent.model_id"] = model_id
    labels["agent.provider"] = provider or "openai"
    e = effort_label(effort)
    if e:
        labels["agent.effort"] = e
    if isinstance(ctx, int) and ctx > 0:
        labels["agent.ctx"] = str(ctx)
    if isinstance(ctx_max, int) and ctx_max > 0:
        labels["agent.ctx_max"] = str(ctx_max)
    if isinstance(subagents, int) and subagents > 0:
        labels["agent.subagents"] = str(subagents)
    if subagents_meta:
        labels["agent.subagents_meta"] = subagents_meta
    if session:
        labels["agent.session"] = session
    return labels


def owns(current: Mapping[str, Any], pid: int, session: Optional[str]) -> bool:
    """The terminal carries this Codex's labels already (same app, pid and session)."""
    return (
        current.get("agent.app") == APP
        and current.get("agent.pid") == str(pid)
        and (session is None or current.get("agent.session") == session)
    )


def diff(current: Mapping[str, Any], wanted: Mapping[str, str], keys: Optional[Iterable[str]] = None) -> Dict[str, str]:
    """
    The `terminal.label` request that turns `current` into `wanted` for
    `keys` (all of `wanted` by default): changed values, and `""` for a key
    to remove only when it is there.
    """
    out: Dict[str, str] = {}
    for key in keys if keys is not None else wanted.keys():
        value = wanted.get(key, "")
        have = current.get(key)
        have = have if isinstance(have, str) else ""
        if value != have:
            out[key] = value
    return out


def removal(current: Mapping[str, Any]) -> Dict[str, str]:
    """Removes every label Codex owns that the terminal still has."""
    return {k: "" for k in LABEL_KEYS if isinstance(current.get(k), str) and current.get(k) != ""}
