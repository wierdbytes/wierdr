// What the relay carries: Wierdr's agents Live Activity, sealed, and nothing else.
// The content state is the counts and time in the open and the agents sealed; the
// attributes are sealed whole (WierdrActivity/Sealed.swift). Any other field is refused,
// so plain text can't ride along under another name; the alert is one of Wierdr's few
// words and the counts (WierdrPush/Planner.swift), so a leaked grant can't put text of
// its own on a lock screen. What goes to APNs is the payload as parsed and written
// again: a duplicate key can't show APNs or iOS something else than what was checked.

export type PushKind = "start" | "broadcast";

export const MAX_PAYLOAD = 4096;

const STATE_KEYS = ["blocked", "done", "working", "idle", "at", "sealed", "kid"];
const KID = /^[0-9a-f]{8}$/;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const CHANNEL = /^[A-Za-z0-9+/]{16,64}={0,2}$/;
const TITLES = ["Wierdr", "Needs you", "Done"];

/** `ActivitySummary.line` (WierdrPush/Summary.swift): `1 needs you · 2 done · 3 working`,
 *  else `4 idle` or `No agents`. An alert's text must be the line of the counts it goes with. */
export function countsLine(s: { blocked: number; done: number; working: number; idle: number }): string {
  const parts: string[] = [];
  if (s.blocked > 0) parts.push(`${s.blocked} needs you`);
  if (s.done > 0) parts.push(`${s.done} done`);
  if (s.working > 0) parts.push(`${s.working} working`);
  if (!parts.length) parts.push(s.idle > 0 ? `${s.idle} idle` : "No agents");
  return parts.join(" · ");
}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const isCount = (v: unknown) => typeof v === "number" && Number.isInteger(v) && v >= 0 && v < 100_000;
const isTime = (v: unknown) => typeof v === "number" && Number.isInteger(v) && v >= 0 && v < 1e11;

function exactly(o: Obj, keys: string[]): string | null {
  const extra = Object.keys(o).filter((k) => !keys.includes(k));
  if (extra.length) return `unexpected ${extra.join(", ")}`;
  const missing = keys.filter((k) => !(k in o));
  return missing.length ? `missing ${missing.join(", ")}` : null;
}

function sealed(o: Obj, max: number): string | null {
  if (typeof o.sealed !== "string" || o.sealed.length > max || !BASE64.test(o.sealed)) return "bad sealed";
  if (typeof o.kid !== "string" || !KID.test(o.kid)) return "bad kid";
  return null;
}

function state(s: unknown): string | null {
  if (!isObj(s)) return "content-state: not an object";
  const e = exactly(s, STATE_KEYS);
  if (e) return `content-state: ${e}`;
  for (const k of ["blocked", "done", "working", "idle"]) if (!isCount(s[k])) return `content-state: bad ${k}`;
  if (typeof s.at !== "number" || !Number.isFinite(s.at) || s.at < 0) return "content-state: bad at";
  const e2 = sealed(s, 3400);
  return e2 ? `content-state: ${e2}` : null;
}

function alert(a: unknown, counts: Obj): string | null {
  if (!isObj(a)) return "alert: not an object";
  const extra = Object.keys(a).filter((k) => !["title", "body", "sound"].includes(k));
  if (extra.length) return `alert: unexpected ${extra.join(", ")}`;
  if (typeof a.title !== "string" || !TITLES.includes(a.title)) return "alert: bad title";
  if (a.body !== countsLine(counts as Parameters<typeof countsLine>[0])) return "alert: not the counts' line";
  if (a.sound !== undefined && a.sound !== "default") return "alert: bad sound";
  return null;
}

export type Checked = { error: string } | { error: null; text: string; channel?: string };

/** The payload to send (as parsed, written again), or why `text` can't go out as a `kind` push. */
export function checkPayload(text: string, kind: PushKind): Checked {
  let p: unknown;
  try {
    p = JSON.parse(text);
  } catch {
    return { error: "payload not JSON" };
  }
  const why = check(p, kind);
  if (why) return { error: why };
  const out = JSON.stringify(p);
  if (new TextEncoder().encode(out).length > MAX_PAYLOAD) return { error: "payload over 4 KB" };
  const aps = (p as Obj).aps as Obj;
  return { error: null, text: out, channel: kind === "start" ? (aps["input-push-channel"] as string) : undefined };
}

function check(p: unknown, kind: PushKind): string | null {
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
  if (!isTime(aps.timestamp)) return "aps: bad timestamp";
  const se = state(aps["content-state"]);
  if (se) return se;
  for (const k of ["stale-date", "dismissal-date"]) if (k in aps && !isTime(aps[k])) return `aps: bad ${k}`;
  if ("alert" in aps) {
    const ae = alert(aps.alert, aps["content-state"] as Obj);
    if (ae) return ae;
  }
  if (kind === "start") {
    if (!("alert" in aps)) return "aps: a start needs an alert";
    if (aps["attributes-type"] !== "AgentsActivityAttributes") return "aps: bad attributes-type";
    if (typeof aps["input-push-channel"] !== "string" || !CHANNEL.test(aps["input-push-channel"])) {
      return "aps: bad input-push-channel";
    }
    if (!isObj(aps.attributes)) return "attributes: not an object";
    const ae = exactly(aps.attributes, ["sealed", "kid"]) ?? sealed(aps.attributes, 1400);
    if (ae) return `attributes: ${ae}`;
  }
  return null;
}
