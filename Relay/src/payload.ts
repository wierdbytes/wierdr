// What the relay carries: Wierdr's agents Live Activity, sealed, and nothing else.
// The content state is the counts and time in the open and the agents sealed;
// the attributes are sealed whole (WierdrActivity/Sealed.swift). Any other field
// is refused, so plain text can't ride along under another name.

export type PushKind = "start" | "broadcast";

export const MAX_PAYLOAD = 4096;

const STATE_KEYS = ["blocked", "done", "working", "idle", "at", "sealed", "kid"];
const KID = /^[0-9a-f]{8}$/;
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const isInt = (v: unknown) => typeof v === "number" && Number.isInteger(v) && v >= 0;

function exactly(o: Obj, keys: string[]): string | null {
  const extra = Object.keys(o).filter((k) => !keys.includes(k));
  if (extra.length) return `unexpected ${extra.join(", ")}`;
  const missing = keys.filter((k) => !(k in o));
  return missing.length ? `missing ${missing.join(", ")}` : null;
}

function sealed(o: unknown, max: number): string | null {
  if (!isObj(o)) return "not an object";
  if (typeof o.sealed !== "string" || !o.sealed || o.sealed.length > max || !BASE64.test(o.sealed)) return "bad sealed";
  if (typeof o.kid !== "string" || !KID.test(o.kid)) return "bad kid";
  return null;
}

function state(s: unknown): string | null {
  if (!isObj(s)) return "content-state: not an object";
  const e = exactly(s, STATE_KEYS);
  if (e) return `content-state: ${e}`;
  for (const k of ["blocked", "done", "working", "idle"]) if (!isInt(s[k])) return `content-state: bad ${k}`;
  if (typeof s.at !== "number" || !Number.isFinite(s.at)) return "content-state: bad at";
  const e2 = sealed(s, 3400);
  return e2 ? `content-state: ${e2}` : null;
}

function alert(a: unknown): string | null {
  if (!isObj(a)) return "alert: not an object";
  const extra = Object.keys(a).filter((k) => !["title", "body", "sound"].includes(k));
  if (extra.length) return `alert: unexpected ${extra.join(", ")}`;
  if (typeof a.title !== "string" || a.title.length > 64) return "alert: bad title";
  if (typeof a.body !== "string" || a.body.length > 160) return "alert: bad body";
  if (a.sound !== undefined && a.sound !== "default") return "alert: bad sound";
  return null;
}

/** Why `text` can't go out as a `kind` push, or null when it can. */
export function checkPayload(text: string, kind: PushKind): string | null {
  if (new TextEncoder().encode(text).length > MAX_PAYLOAD) return "payload over 4 KB";
  let p: unknown;
  try {
    p = JSON.parse(text);
  } catch {
    return "payload not JSON";
  }
  if (!isObj(p)) return "payload not an object";
  const e = exactly(p, ["aps"]);
  if (e) return `payload: ${e}`;
  const aps = p.aps;
  if (!isObj(aps)) return "aps: not an object";
  const event = aps.event;
  const allowed =
    kind === "start"
      ? ["timestamp", "event", "content-state", "input-push-channel", "attributes-type", "attributes", "alert", "stale-date"]
      : event === "end"
        ? ["timestamp", "event", "content-state", "dismissal-date"]
        : ["timestamp", "event", "content-state", "alert", "stale-date"];
  const extra = Object.keys(aps).filter((k) => !allowed.includes(k));
  if (extra.length) return `aps: unexpected ${extra.join(", ")}`;
  if (kind === "start" ? event !== "start" : event !== "update" && event !== "end") return "aps: bad event";
  if (!isInt(aps.timestamp)) return "aps: bad timestamp";
  const se = state(aps["content-state"]);
  if (se) return se;
  for (const k of ["stale-date", "dismissal-date"]) if (k in aps && !isInt(aps[k])) return `aps: bad ${k}`;
  if ("alert" in aps) {
    const ae = alert(aps.alert);
    if (ae) return ae;
  }
  if (kind === "start") {
    if (!("alert" in aps)) return "aps: a start needs an alert";
    if (aps["attributes-type"] !== "AgentsActivityAttributes") return "aps: bad attributes-type";
    if (typeof aps["input-push-channel"] !== "string" || !BASE64.test(aps["input-push-channel"])) {
      return "aps: bad input-push-channel";
    }
    if (!isObj(aps.attributes)) return "attributes: not an object";
    const ae = exactly(aps.attributes, ["sealed", "kid"]) ?? sealed(aps.attributes, 1000);
    if (ae) return `attributes: ${ae}`;
  }
  return null;
}
