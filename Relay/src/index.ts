// Wierdr's push relay (Cloudflare Worker): the Mac's `wierdr-push` decides what the
// agents Live Activity shows and when; the relay signs it with our APNs key and sends
// it, as only our team's key can reach an App Store copy of Wierdr. See docs/relay.md.
//
//   POST /v1/challenge          app     → a one-time challenge for App Attest
//   POST /v1/attest             app     → registers an attested App Attest key
//   POST /v1/devices            app     → a grant for its push-to-start token (assertion-signed)
//   POST /v1/grants/check       app     → whether its grant still holds (or wants renewing)
//   POST /v1/start              daemon  → push-to-start on a token (its device grant, the channel's)
//   POST /v1/channels           daemon  → a new broadcast channel (a device grant) and its grant
//   POST /v1/broadcast          daemon  → an update or end on a channel (its grant)
//   POST /v1/channels/delete    daemon  → deletes a channel (its grant, even expired)
//   POST /v1/admin/channels     admin   → APNs' channels against the ledger; purge unknown ones
//   POST /v1/admin/keys/revoke  admin   → revokes an App Attest key (its grants stop working)
//   cron (hourly)                       → deletes channels older than their grant, prunes tables
import { APNs, APNsFailure, type StoredToken, type TokenStore } from "./apns";
import { AttestError, verifyAssertion, verifyAttestation } from "./appattest";
import { b64decode, b64encode, b64url, equal, pemBody, sha256, utf8 } from "./bytes";
import {
  checkChallenge, checkGrant, GRANT_TTL, makeChallenge, makeGrant, ownerOf,
  type APNsEnv, type GrantKind, type Secrets,
} from "./grants";
import { checkPayload, type PushKind } from "./payload";
import { APP_ATTEST_ROOT } from "./roots";

export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

/** The part of D1 the relay uses. */
export interface Database {
  prepare(sql: string): {
    bind(...values: unknown[]): {
      first<T = Record<string, unknown>>(): Promise<T | null>;
      all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
      run(): Promise<{ meta: { changes: number } }>;
    };
  };
}

export interface Env {
  DB: Database;
  /** The app's calls: per client address and per App Attest key. */
  LIMIT_APP: RateLimiter;
  /** Attestations (each checks a certificate chain): per client address. */
  LIMIT_ATTEST: RateLimiter;
  /** The daemon's calls: per device token or channel. */
  LIMIT_PUSH: RateLimiter;
  /** The APNs `.p8` key (PEM), a secret. */
  APNS_KEY: string;
  APNS_KEY_ID: string;
  TEAM_ID: string;
  BUNDLE: string;
  /** Signs challenges and grants (a secret). */
  RELAY_SECRET: string;
  /** The one before, while rotating: its grants still hold, marked for renewal. */
  RELAY_SECRET_PREVIOUS?: string;
  /** Bearer token of the admin routes (a secret; unset: no admin routes). */
  ADMIN_TOKEN?: string;
}

/** Distinct tokens one App Attest key may get grants for in 30 days. */
const TOKENS_PER_KEY = 5;
/** Channels one key may have made in a day, and may have alive at once. */
const CHANNELS_PER_KEY_DAY = 30;
const LIVE_CHANNELS_PER_KEY = 20;
/** Live channels the relay keeps per environment (APNs allows 10,000 per app). */
const LIVE_CHANNELS_PER_APP = 8000;
/** A channel outlives its grant by a day, then the cron deletes it. */
const CHANNEL_LIFETIME = GRANT_TTL + 86400;
/** Subrequests one invocation spends on deletions (the free plan allows 50 in all). */
const DELETES_PER_RUN = 40;
const MAX_BODY = 20_000;
const DAY = 86400;

class Refusal extends Error {
  constructor(readonly status: number, readonly code: string, message?: string) {
    super(message ?? code);
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export interface Deps {
  now: () => number;
  fetcher: typeof fetch;
}

const liveDeps = (): Deps => ({
  now: () => Date.now() / 1000,
  // fetch called as another object's method throws "Illegal invocation" in Workers.
  fetcher: (input, init) => fetch(input, init),
});

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, liveDeps());
  },
  async scheduled(_event: unknown, env: Env, ctx: { waitUntil(p: Promise<unknown>): void }): Promise<void> {
    ctx.waitUntil(sweep(env, liveDeps()));
  },
};

export async function handle(request: Request, env: Env, deps: Deps): Promise<Response> {
  const path = new URL(request.url).pathname;
  try {
    if (request.method === "GET" && path === "/") return new Response("Wierdr push relay\n");
    if (request.method !== "POST") throw new Refusal(405, "method_not_allowed");
    const route = ROUTES[path];
    if (!route) throw new Refusal(404, "not_found");
    const raw = await readBody(request);
    return json(await route({ request, env, deps, raw }));
  } catch (e) {
    if (e instanceof Refusal) return json({ error: e.code, message: e.message }, e.status);
    if (e instanceof APNsFailure) {
      console.log(`${path}: ${e.message}`);
      return json({ error: "apns", status: e.status, reason: e.reason }, 502);
    }
    console.error(`${path}: ${(e as Error).stack ?? e}`);
    return json({ error: "internal" }, 500);
  }
}

/** The body's bytes, refused past 20 KB before it's read whole when the length is declared. */
async function readBody(request: Request): Promise<Uint8Array<ArrayBuffer>> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY) throw new Refusal(413, "too_large");
  const raw = new Uint8Array(await request.arrayBuffer());
  if (raw.length > MAX_BODY) throw new Refusal(413, "too_large");
  return raw;
}

interface Call {
  request: Request;
  env: Env;
  deps: Deps;
  /** The body's bytes (an assertion signs exactly these). */
  raw: Uint8Array<ArrayBuffer>;
}

const ROUTES: Record<string, (c: Call) => Promise<unknown>> = {
  "/v1/challenge": async ({ request, env, deps }) => {
    await limit(env.LIMIT_APP, `ip:${client(request)}`);
    return { challenge: await makeChallenge(secrets(env), deps.now()) };
  },

  "/v1/attest": async ({ request, env, deps, raw }) => {
    await limit(env.LIMIT_ATTEST, `ip:${client(request)}`);
    const b = body(raw);
    const keyId = keyIdOf(b.key_id);
    const challenge = str(b.challenge, "challenge");
    if (!(await checkChallenge(secrets(env), challenge, deps.now()))) throw new Refusal(400, "bad_challenge");
    const attestation = bytes(b.attestation, "attestation");
    let a;
    try {
      a = await verifyAttestation({
        attestation, keyId, challenge: utf8(challenge), appId: appId(env), root: pemBody(APP_ATTEST_ROOT),
        now: new Date(deps.now() * 1000),
      });
    } catch (e) {
      if (e instanceof AttestError) throw new Refusal(403, "bad_attestation", e.message);
      throw e;
    }
    const id = b64encode(keyId);
    const t = Math.floor(deps.now());
    await env.DB.prepare(
      "INSERT INTO attest_keys (key_id, owner, public_key, env, category, bundle_version, receipt, counter, created, used) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?) ON CONFLICT(key_id) DO NOTHING",
    ).bind(id, await ownerOf(keyId), b64encode(a.publicKey), a.env, a.category ?? null, a.bundleVersion ?? null,
           a.receipt ? b64encode(a.receipt) : null, t, t).run();
    const row = await env.DB.prepare("SELECT public_key FROM attest_keys WHERE key_id = ?").bind(id)
      .first<{ public_key: string }>();
    if (row?.public_key !== b64encode(a.publicKey)) throw new Refusal(409, "key_conflict");
    return { ok: true, env: a.env };
  },

  "/v1/devices": async ({ request, env, deps, raw }) => {
    await limit(env.LIMIT_APP, `ip:${client(request)}`);
    const b = body(raw);
    const keyId = keyIdOf(b.key_id);
    const id = b64encode(keyId); // one spelling per key, whatever base64 the client sent
    await limit(env.LIMIT_APP, `key:${id}`);
    if (!(await checkChallenge(secrets(env), str(b.challenge, "challenge"), deps.now()))) {
      throw new Refusal(400, "bad_challenge");
    }
    const apnsEnv = environment(b.env);
    const token = deviceToken(b.token);
    const key = await env.DB.prepare(
      "SELECT owner, public_key, env, category, counter, revoked FROM attest_keys WHERE key_id = ?",
    ).bind(id).first<{ owner: string; public_key: string; env: string; category: number | null; counter: number; revoked: number }>();
    if (!key) throw new Refusal(401, "unknown_key", "attest the key first");
    if (key.revoked) throw new Refusal(403, "key_revoked");
    // App Attest's development environment gets no production token's grant; a TestFlight
    // or App Store copy (categories 2 and 4) only production ones. A production key from
    // any other build may hold either: Xcode's export of a development build attests in
    // production too.
    if ((key.env === "development" && apnsEnv === "production") ||
        ((key.category === 2 || key.category === 4) && apnsEnv !== "production")) {
      throw new Refusal(403, "env_mismatch", `a ${key.env} key (category ${key.category ?? "?"}), a ${apnsEnv} token`);
    }
    const assertion = bytes(request.headers.get("x-wierdr-assertion"), "assertion");
    let counter: number;
    try {
      ({ counter } = await verifyAssertion({
        assertion, clientData: raw, publicKey: b64decode(key.public_key)!, appId: appId(env),
        previousCounter: key.counter,
      }));
    } catch (e) {
      if (e instanceof AttestError) throw new Refusal(403, "bad_assertion", e.message);
      throw e;
    }
    const t = Math.floor(deps.now());
    const done = await env.DB.prepare("UPDATE attest_keys SET counter = ?, used = ? WHERE key_id = ? AND counter < ?")
      .bind(counter, t, id, counter).run();
    if (done.meta.changes !== 1) throw new Refusal(409, "replayed");
    // A key gets grants for its own few tokens, not for any it learns.
    const tokenHash = b64url(await sha256(utf8(token)));
    const known = await env.DB.prepare("SELECT 1 AS k FROM device_tokens WHERE owner = ? AND token = ? AND env = ?")
      .bind(key.owner, tokenHash, apnsEnv).first();
    if (!known) {
      const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM device_tokens WHERE owner = ? AND last_seen > ?")
        .bind(key.owner, t - 30 * DAY).first<{ n: number }>();
      if ((n?.n ?? 0) >= TOKENS_PER_KEY) throw new Refusal(429, "too_many_tokens", `${TOKENS_PER_KEY} in 30 days`);
    }
    await env.DB.prepare(
      "INSERT INTO device_tokens (owner, token, env, first_seen, last_seen) VALUES (?, ?, ?, ?, ?) " +
        "ON CONFLICT(owner, token, env) DO UPDATE SET last_seen = excluded.last_seen",
    ).bind(key.owner, tokenHash, apnsEnv, t, t).run();
    return makeGrant(secrets(env), subject(env, "device", apnsEnv, token), key.owner, deps.now());
  },

  "/v1/grants/check": async ({ request, env, deps, raw }) => {
    await limit(env.LIMIT_APP, `ip:${client(request)}`);
    const b = body(raw);
    const apnsEnv = environment(b.env);
    const g = await grant(env, deps, b.grant, subject(env, "device", apnsEnv, deviceToken(b.token)));
    return { ok: true, expires: g.expires, renew: g.stale || g.expires - deps.now() < 10 * DAY };
  },

  "/v1/start": async ({ env, deps, raw }) => {
    const b = daemonBody(env, raw);
    const apnsEnv = environment(b.env);
    const token = deviceToken(b.token);
    const channel = channelId(b.channel);
    await grant(env, deps, b.grant, subject(env, "device", apnsEnv, token));
    await grant(env, deps, b.channel_grant, subject(env, "channel", apnsEnv, channel));
    await limit(env.LIMIT_PUSH, `start:${token}`);
    const p = pushPayload(b.payload, "start");
    if (p.channel !== channel) throw new Refusal(400, "bad_payload", "input-push-channel isn't the channel");
    await apns(env, deps).start(apnsEnv, token, p.text, priority(b.priority));
    return { ok: true };
  },

  "/v1/channels": async ({ env, deps, raw }) => {
    const b = daemonBody(env, raw);
    const apnsEnv = environment(b.env);
    const token = deviceToken(b.token);
    const { owner } = await grant(env, deps, b.grant, subject(env, "device", apnsEnv, token));
    await limit(env.LIMIT_PUSH, `channels:${token}`);
    const t = Math.floor(deps.now());
    const mine = await env.DB.prepare(
      "SELECT SUM(created > ?) AS today, SUM(deleted IS NULL) AS live FROM channels WHERE owner = ? AND created > ?",
    ).bind(t - DAY, owner, t - CHANNEL_LIFETIME).first<{ today: number | null; live: number | null }>();
    if ((mine?.today ?? 0) >= CHANNELS_PER_KEY_DAY) throw new Refusal(429, "channel_quota", `${CHANNELS_PER_KEY_DAY} a day`);
    if ((mine?.live ?? 0) >= LIVE_CHANNELS_PER_KEY) throw new Refusal(429, "channel_limit", `${LIVE_CHANNELS_PER_KEY} alive`);
    const all = await env.DB.prepare("SELECT COUNT(*) AS n FROM channels WHERE env = ? AND deleted IS NULL")
      .bind(apnsEnv).first<{ n: number }>();
    if ((all?.n ?? 0) >= LIVE_CHANNELS_PER_APP) {
      console.error(`channels full in ${apnsEnv}: ${all?.n}`);
      throw new Refusal(503, "channels_full");
    }
    const channel = await apns(env, deps).createChannel(apnsEnv);
    await env.DB.prepare("INSERT INTO channels (id, env, owner, created) VALUES (?, ?, ?, ?) ON CONFLICT(id, env) DO NOTHING")
      .bind(channel, apnsEnv, owner, t).run();
    return { channel, ...(await makeGrant(secrets(env), subject(env, "channel", apnsEnv, channel), owner, deps.now())) };
  },

  "/v1/broadcast": async ({ env, deps, raw }) => {
    const b = daemonBody(env, raw);
    const apnsEnv = environment(b.env);
    const channel = channelId(b.channel);
    await grant(env, deps, b.grant, subject(env, "channel", apnsEnv, channel));
    await limit(env.LIMIT_PUSH, `broadcast:${channel}`);
    const p = pushPayload(b.payload, "broadcast");
    await apns(env, deps).broadcast(apnsEnv, channel, p.text, priority(b.priority));
    return { ok: true };
  },

  "/v1/channels/delete": async ({ env, deps, raw }) => {
    const b = daemonBody(env, raw);
    const apnsEnv = environment(b.env);
    const channel = channelId(b.channel);
    // An expired grant or a revoked key may still clean up.
    await grant(env, deps, b.grant, subject(env, "channel", apnsEnv, channel), { expired: true, revoked: true });
    await limit(env.LIMIT_PUSH, `delete:${channel}`);
    await deleteChannel(env, deps, apnsEnv, channel);
    return { ok: true };
  },

  "/v1/admin/channels": async ({ request, env, deps, raw }) => {
    admin(request, env);
    const b = body(raw);
    const apnsEnv = environment(b.env);
    const listed = await apns(env, deps).listChannels(apnsEnv);
    const rows = await env.DB.prepare("SELECT id FROM channels WHERE env = ? AND deleted IS NULL").bind(apnsEnv)
      .all<{ id: string }>();
    const known = new Set(rows.results.map((r) => r.id));
    const unknown = listed.filter((c) => !known.has(c));
    const gone = [...known].filter((c) => !listed.includes(c));
    const t = Math.floor(deps.now());
    for (const c of gone) {
      await env.DB.prepare("UPDATE channels SET deleted = ? WHERE id = ? AND env = ?").bind(t, c, apnsEnv).run();
    }
    let purged = 0;
    if (b.purge === true) {
      for (const c of unknown.slice(0, DELETES_PER_RUN)) {
        await apns(env, deps).deleteChannel(apnsEnv, c).then(() => purged++, () => {});
      }
    }
    return { listed: listed.length, live: known.size - gone.length, unknown: unknown.length, purged };
  },

  "/v1/admin/keys/revoke": async ({ request, env, raw }) => {
    admin(request, env);
    const owner = str(body(raw).owner, "owner");
    const r = await env.DB.prepare("UPDATE attest_keys SET revoked = 1 WHERE owner = ?").bind(owner).run();
    return { revoked: r.meta.changes };
  },
};

/** The hourly cron: channels past their grant go (APNs keeps 10,000 at most), old rows too. */
export async function sweep(env: Env, deps: Deps): Promise<{ deleted: number }> {
  const t = Math.floor(deps.now());
  const old = await env.DB.prepare(
    "SELECT id, env FROM channels WHERE deleted IS NULL AND created < ? ORDER BY created LIMIT ?",
  ).bind(t - CHANNEL_LIFETIME, DELETES_PER_RUN).all<{ id: string; env: APNsEnv }>();
  let deleted = 0;
  for (const c of old.results) {
    try {
      await deleteChannel(env, deps, c.env, c.id);
      deleted++;
    } catch (e) {
      console.log(`sweep: ${c.id}: ${(e as Error).message}`);
    }
  }
  await env.DB.prepare("DELETE FROM channels WHERE deleted IS NOT NULL AND deleted < ?").bind(t - 30 * DAY).run();
  await env.DB.prepare("DELETE FROM device_tokens WHERE last_seen < ?").bind(t - 60 * DAY).run();
  await env.DB.prepare("DELETE FROM attest_keys WHERE used < ? AND revoked = 0").bind(t - 400 * DAY).run();
  return { deleted };
}

/** Deletes on APNs (a channel APNs no longer has counts as deleted) and in the ledger. */
async function deleteChannel(env: Env, deps: Deps, apnsEnv: APNsEnv, channel: string) {
  try {
    await apns(env, deps).deleteChannel(apnsEnv, channel);
  } catch (e) {
    const gone = e instanceof APNsFailure &&
      (e.status === 404 || ["BadChannelId", "ChannelNotRegistered", "InvalidChannelId"].includes(e.reason));
    if (!gone) throw e;
  }
  await env.DB.prepare("UPDATE channels SET deleted = ? WHERE id = ? AND env = ? AND deleted IS NULL")
    .bind(Math.floor(deps.now()), channel, apnsEnv).run();
}

const appId = (env: Env) => `${env.TEAM_ID}.${env.BUNDLE}`;
const secrets = (env: Env): Secrets => ({ current: env.RELAY_SECRET, previous: env.RELAY_SECRET_PREVIOUS || undefined });
const subject = (env: Env, kind: GrantKind, apnsEnv: APNsEnv, id: string) => ({ appId: appId(env), kind, env: apnsEnv, id });

function apns(env: Env, deps: Deps): APNs {
  const store: TokenStore = {
    get: () => env.DB.prepare("SELECT kid, iat, token FROM apns_jwt WHERE id = ?").bind(1).first<StoredToken>(),
    offer: async (t) => {
      // The first token of a window (or of a new key) stays; a later one doesn't replace it.
      await env.DB.prepare(
        "INSERT INTO apns_jwt (id, kid, iat, token) VALUES (1, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET " +
          "kid = excluded.kid, iat = excluded.iat, token = excluded.token " +
          "WHERE apns_jwt.iat < excluded.iat OR apns_jwt.kid != excluded.kid",
      ).bind(t.kid, t.iat, t.token).run();
      return env.DB.prepare("SELECT kid, iat, token FROM apns_jwt WHERE id = ?").bind(1).first<StoredToken>();
    },
    clear: async () => {
      await env.DB.prepare("DELETE FROM apns_jwt WHERE id = ?").bind(1).run();
    },
  };
  return new APNs({ key: env.APNS_KEY, keyId: env.APNS_KEY_ID, teamId: env.TEAM_ID, bundle: env.BUNDLE }, store,
                  deps.fetcher, deps.now);
}

async function limit(limiter: RateLimiter, key: string) {
  if (!(await limiter.limit({ key })).success) throw new Refusal(429, "rate_limited");
}

/** A grant that holds, its owner's key not revoked. */
async function grant(env: Env, deps: Deps, value: unknown, s: ReturnType<typeof subject>,
                     allow: { expired?: boolean; revoked?: boolean } = {}) {
  // The message names the grant's kind: a start carries two, and the daemon must know which failed.
  const g = await checkGrant(secrets(env), value, s, deps.now());
  if (g.status === "bad") throw new Refusal(403, "bad_grant", `${s.kind} grant`);
  if (g.status === "expired" && !allow.expired) throw new Refusal(403, "grant_expired", `${s.kind} grant`);
  if (!allow.revoked) {
    const key = await env.DB.prepare("SELECT revoked FROM attest_keys WHERE owner = ?").bind(g.owner)
      .first<{ revoked: number }>();
    if (!key || key.revoked) throw new Refusal(403, "key_revoked", `${s.kind} grant`);
  }
  return g;
}

function admin(request: Request, env: Env) {
  const got = request.headers.get("authorization") ?? "";
  if (!env.ADMIN_TOKEN || !equal(utf8(got), utf8(`Bearer ${env.ADMIN_TOKEN}`))) throw new Refusal(404, "not_found");
}

/** The client's address, an IPv6 one by its /64 (one host has the whole of it). */
function client(request: Request): string {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  if (!ip.includes(":")) return ip;
  const [head, tail = ""] = ip.split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const full = [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right];
  return `${full.slice(0, 4).map((h) => h.toLowerCase().replace(/^0+(?=.)/, "")).join(":")}::/64`;
}

function body(raw: Uint8Array): Record<string, unknown> {
  try {
    const b = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw));
    if (typeof b === "object" && b !== null && !Array.isArray(b)) return b;
  } catch {}
  throw new Refusal(400, "bad_json");
}

/** A daemon's call: for this relay's app. */
function daemonBody(env: Env, raw: Uint8Array): Record<string, unknown> {
  const b = body(raw);
  if (b.bundle !== env.BUNDLE) throw new Refusal(400, "bad_bundle", `this relay is for ${env.BUNDLE}`);
  return b;
}

function str(v: unknown, name: string): string {
  if (typeof v !== "string" || !v) throw new Refusal(400, `bad_${name}`);
  return v;
}

function bytes(v: unknown, name: string): Uint8Array<ArrayBuffer> {
  const out = typeof v === "string" ? b64decode(v) : null;
  if (!out || out.length === 0) throw new Refusal(400, `bad_${name}`);
  return out;
}

function keyIdOf(v: unknown): Uint8Array<ArrayBuffer> {
  const k = bytes(v, "key_id");
  if (k.length !== 32) throw new Refusal(400, "bad_key_id");
  return k;
}

function environment(v: unknown): APNsEnv {
  if (v !== "development" && v !== "production") throw new Refusal(400, "bad_env");
  return v;
}

function deviceToken(v: unknown): string {
  if (typeof v !== "string" || !/^[0-9a-fA-F]{64,512}$/.test(v)) throw new Refusal(400, "bad_token");
  return v.toLowerCase();
}

function channelId(v: unknown): string {
  if (typeof v !== "string" || !/^[A-Za-z0-9+/]{16,64}={0,2}$/.test(v)) throw new Refusal(400, "bad_channel");
  return v;
}

function priority(v: unknown): number {
  if (v === undefined) return 10;
  if (v !== 5 && v !== 10) throw new Refusal(400, "bad_priority");
  return v;
}

function pushPayload(v: unknown, kind: PushKind): { text: string; channel?: string } {
  if (typeof v !== "string") throw new Refusal(400, "bad_payload");
  const p = checkPayload(v, kind);
  if (p.error !== null) throw new Refusal(400, "bad_payload", p.error);
  return p;
}
