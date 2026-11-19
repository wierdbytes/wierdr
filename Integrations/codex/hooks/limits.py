"""
ChatGPT subscription limits (Plus, Pro...) as Codex records them in the
rollout (`token_count` events' `rate_limits`), folded into the herdr-core
document @wierdbytes/pi-wierdr writes, `limits` (schema 1), so every herdr
client shows the same numbers, whichever agent read them.

The document's shape and its folding rules are pi-wierdr's (`herdr/limits.ts`),
ported line by line: several writers fold their readings into one
document, and they must agree. So is the account key: the first 8 hex
digits of sha256 of the ChatGPT account id, which pi-wierdr takes from its
own auth.json and Codex keeps in `$CODEX_HOME/auth.json`, so Codex's and
pi's readings land in one account. Pure functions, except reading auth.json.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import math
import re
from typing import Any, Dict, List, Optional, Tuple

LIMITS_DOC = "limits"
LIMITS_SCHEMA = 1
SOURCE = "codex"
PROVIDER = "codex"

# Two readings of one window can disagree on the reset by a little (Codex derives it).
SAME_WINDOW_S = 120


def _num(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if math.isfinite(value) else None
    if isinstance(value, str) and value.strip():
        try:
            n = float(value)
        except ValueError:
            return None
        return n if math.isfinite(n) else None
    return None


def _round2(n: float) -> float:
    r = math.floor(n * 100 + 0.5) / 100
    return int(r) if r == int(r) else r


def duration_label(seconds: int) -> str:
    if seconds % 86400 == 0:
        n = seconds // 86400
        return "%d day%s" % (n, "" if n == 1 else "s")
    if seconds % 3600 == 0:
        n = seconds // 3600
        return "%d hour%s" % (n, "" if n == 1 else "s")
    return "%d minutes" % round(seconds / 60)


def duration_id(seconds: int) -> str:
    if seconds % 86400 == 0:
        return "%dd" % (seconds // 86400)
    if seconds % 3600 == 0:
        return "%dh" % (seconds // 3600)
    return "%dm" % round(seconds / 60)


def codex_window(family: str, family_label: Optional[str], used: Optional[float], seconds: Optional[int], resets_at: Optional[float]):
    """pi-wierdr's `codexWindow`: the main family keeps plain ids ("5h", "7d")."""
    if used is None:
        return None
    base = duration_id(seconds) if seconds else "window"
    main = family == "codex"
    wid = base if main else "%s.%s" % (re.sub(r"[^a-z0-9_-]+", "_", family, flags=re.IGNORECASE), base)
    if main:
        label = duration_label(seconds) if seconds else "Window"
    else:
        label = ("%s %s" % (family_label or family, duration_id(seconds) if seconds else "")).strip()
    w: Dict[str, Any] = {"id": wid, "label": label, "usedPercent": _round2(used)}
    if seconds:
        w["windowSeconds"] = seconds
    if resets_at is not None:
        w["resetsAt"] = resets_at
    if used >= 100:
        w["status"] = "exhausted"
    return w


def _sort_windows(windows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return sorted(windows, key=lambda w: (w.get("windowSeconds", math.inf), w["id"]))


def reading_from_rate_limits(limits: Any) -> Optional[Dict[str, Any]]:
    """
    A reading from one `token_count` event's `rate_limits` (one limit family:
    `limit_id` "codex" or another one, named by `limit_name`); None without a
    window in it (an API key reports none).
    """
    if not isinstance(limits, dict):
        return None
    family = limits.get("limit_id") if isinstance(limits.get("limit_id"), str) and limits.get("limit_id") else "codex"
    label = limits.get("limit_name") if isinstance(limits.get("limit_name"), str) else None
    windows = []
    for slot in ("primary", "secondary"):
        raw = limits.get(slot)
        if not isinstance(raw, dict):
            continue
        minutes = _num(raw.get("window_minutes"))
        seconds = int(minutes * 60) if minutes else None
        resets = _num(raw.get("resets_at"))
        w = codex_window(family, label, _num(raw.get("used_percent")), seconds, resets)
        if w:
            windows.append(w)
    if not windows:
        return None
    reading: Dict[str, Any] = {"provider": PROVIDER, "source": SOURCE, "windows": _sort_windows(windows)}
    plan = limits.get("plan_type")
    if isinstance(plan, str) and plan:
        reading["plan"] = plan
    if limits.get("rate_limit_reached_type"):
        reading["status"] = "exhausted"
    return reading


# ============================================
# The account
# ============================================


def account_slug(account_id: Optional[str]) -> str:
    """The first 8 hex digits of sha256(account id), or `main` without one."""
    if not account_id:
        return "main"
    return hashlib.sha256(account_id.encode("utf-8")).hexdigest()[:8]


def _jwt_claims(token: Any) -> Optional[Dict[str, Any]]:
    if not isinstance(token, str):
        return None
    parts = token.split(".")
    if len(parts) < 2 or not parts[1]:
        return None
    part = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(part.encode("ascii")).decode("utf-8"))
    except Exception:
        return None
    return claims if isinstance(claims, dict) else None


def account_from_auth(text: Optional[str]) -> Dict[str, str]:
    """
    The ChatGPT account Codex signs in with, from `auth.json`'s text: `id`
    (`tokens.account_id`, else the id token's `chatgpt_account_id`) and
    `label` (the id token's e-mail). Nothing else is read; no token leaves.
    """
    if not text:
        return {}
    try:
        auth = json.loads(text)
    except Exception:
        return {}
    tokens = auth.get("tokens") if isinstance(auth, dict) else None
    if not isinstance(tokens, dict):
        return {}
    out: Dict[str, str] = {}
    claims = _jwt_claims(tokens.get("id_token")) or {}
    openai = claims.get("https://api.openai.com/auth")
    openai = openai if isinstance(openai, dict) else {}
    account = tokens.get("account_id")
    if not (isinstance(account, str) and account):
        account = openai.get("chatgpt_account_id")
    if isinstance(account, str) and account:
        out["id"] = account
    profile = claims.get("https://api.openai.com/profile")
    email = profile.get("email") if isinstance(profile, dict) else None
    if not isinstance(email, str) or not email:
        email = claims.get("email")
    if isinstance(email, str) and email:
        out["label"] = email
    return out


# ============================================
# The document (pi-wierdr's, unchanged)
# ============================================


def empty_doc() -> Dict[str, Any]:
    return {"schema": LIMITS_SCHEMA, "updated_at": 0, "accounts": {}}


def as_limits_doc(value: Any) -> Dict[str, Any]:
    """The document as stored, or an empty one when it is missing or not ours to read."""
    if not isinstance(value, dict) or value.get("schema") != LIMITS_SCHEMA or not isinstance(value.get("accounts"), dict):
        return empty_doc()
    updated = value.get("updated_at")
    return {
        "schema": LIMITS_SCHEMA,
        "updated_at": updated if isinstance(updated, (int, float)) and not isinstance(updated, bool) else 0,
        "accounts": dict(value["accounts"]),
    }


def fold_window(a: Optional[Dict[str, Any]], b: Dict[str, Any]) -> Dict[str, Any]:
    """
    Folds window reading `b` into window `a`: within one window (same reset,
    give or take two minutes) the used share only grows; a later window
    replaces it; a reading of an earlier window is dropped. A reading without
    a reset replaces a window only once its reset has passed.
    """
    if not a:
        return b
    ar, br = a.get("resets_at"), b.get("resets_at")
    if ar is not None and br is not None:
        if br > ar + SAME_WINDOW_S:
            return b
        if br < ar - SAME_WINDOW_S:
            return a
        out = dict(b)
        out["used"] = max(a.get("used", 0), b["used"])
        out["resets_at"] = max(ar, br)
        out["at"] = max(a.get("at", 0), b["at"])
        return out
    if ar is not None and br is None and b["at"] < ar:
        return a
    return b if b["at"] >= a.get("at", 0) else a


def account_key(provider: str, slug: str) -> str:
    return "%s.%s" % (provider, slug)


def fold_reading(doc: Dict[str, Any], reading: Dict[str, Any], account: Dict[str, Any], now_s: int, host: Optional[str] = None) -> Dict[str, Any]:
    """`doc` with `reading` folded in. Returns a new document; `doc` is left as it was."""
    key = account_key(reading["provider"], account["slug"])
    prev = doc["accounts"].get(key)
    prev = prev if isinstance(prev, dict) else None
    windows = dict(prev.get("windows") or {}) if prev else {}
    for w in reading["windows"]:
        status = w.get("status")
        if status is None:
            if reading.get("status") == "exhausted" and reading.get("binding") == w["id"]:
                status = "exhausted"
            elif reading.get("status"):
                status = "ok"
        nxt: Dict[str, Any] = {"id": w["id"], "label": w["label"], "used": w["usedPercent"], "at": now_s}
        if w.get("windowSeconds") is not None:
            nxt["window_s"] = w["windowSeconds"]
        if w.get("resetsAt") is not None:
            nxt["resets_at"] = int(math.floor(w["resetsAt"]))
        if status:
            nxt["status"] = status
        windows[w["id"]] = fold_window(windows.get(w["id"]), nxt)
    prev_at = prev.get("at", 0) if prev else 0
    latest = prev is None or now_s >= prev_at

    def pick(mine, theirs):
        return (mine if mine is not None else theirs) if latest else (theirs if theirs is not None else mine)

    nxt_account: Dict[str, Any] = {"provider": reading["provider"], "account": account["slug"], "at": max(prev_at, now_s), "windows": windows}
    prev = prev or {}
    label = pick(account.get("label"), prev.get("label"))
    plan = pick(reading.get("plan"), prev.get("plan"))
    status = reading.get("status") if latest else prev.get("status")
    binding = reading.get("binding") if latest else prev.get("binding")
    source = reading.get("source") if latest else prev.get("source")
    at_host = host if latest else prev.get("host")
    if label:
        nxt_account["label"] = label
    if plan:
        nxt_account["plan"] = plan
    if status:
        nxt_account["status"] = status
    if binding:
        nxt_account["binding"] = binding
    if source:
        nxt_account["source"] = source
    if at_host:
        nxt_account["host"] = at_host
    accounts = dict(doc["accounts"])
    accounts[key] = nxt_account
    return {"schema": LIMITS_SCHEMA, "updated_at": max(doc.get("updated_at", 0), now_s), "accounts": accounts}


def write_readings(core, name: str, batch: List[Tuple[Dict[str, Any], Dict[str, Any], int]], host: Optional[str], attempts: int = 5) -> bool:
    """
    Folds `(reading, account, at)` into the document at the version it read
    and writes it back, reading again when another writer came in between.
    True once it landed.
    """
    for _ in range(attempts):
        current = core.doc_get(name)
        if current is None:
            return False
        value, version = current
        doc = as_limits_doc(copy.deepcopy(value))
        for reading, account, at in batch:
            doc = fold_reading(doc, reading, account, at, host)
        result = core.doc_set(name, doc, version)
        if result == "conflict":
            continue
        return result is not None
    return False
