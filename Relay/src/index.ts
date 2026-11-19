// Wierdr's push relay (Cloudflare Worker): the Mac's `wierdr-push` decides what the
// agents Live Activity shows and when; the relay signs it with our APNs key and sends
// it, as only our team's key can reach an App Store copy of Wierdr. See docs/relay.md.
//
//   POST /v1/challenge         app     → a one-time challenge for App Attest
//   POST /v1/attest            app     → registers an attested App Attest key
//   POST /v1/devices           app     → a grant for its push-to-start token (assertion-signed)
//   POST /v1/start             daemon  → push-to-start on a token (its device grant)
//   POST /v1/channels          daemon  → a new broadcast channel (a device grant) and its grant
//   POST /v1/broadcast         daemon  → an update or end on a channel (its grant)
//   POST /v1/channels/delete   daemon  → deletes a channel (its grant)
import { APNs, APNsFailure, type TokenStore } from "./apns";
import { AttestError, verifyAssertion, verifyAttestation } from "./appattest";
import { b64decode, b64encode, b64url, pemBody, sha256, utf8 } from "./bytes";
import { checkChallenge, checkGrant, makeChallenge, makeGrant, type APNsEnv, type GrantKind } from "./grants";
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
      run(): Promise<{ meta: { changes: number } }>;
    };
  };
}

export interface Env {
  DB: Database;
  /** The app's calls: per client address (challenge, attest), per App Attest key (devices). */
  LIMIT_APP: RateLimiter;
  /** The daemon's calls: per device token or channel. */
  LIMIT_PUSH: RateLimiter;
  /** The APNs `.p8` key (PEM), a secret. */
  APNS_KEY: string;
  APNS_KEY_ID: string;
  TEAM_ID: string;
  BUNDLE: string;
  /** Signs challenges and grants (a secret; changing it voids every grant). */
  RELAY_SECRET: string;
}

/** Channels one device may have made in a day (an activity takes one; a busy day takes a few). */
const CHANNELS_PER_DAY = 100;
const MAX_BODY = 20_000;

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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // fetch called as another object's method throws "Illegal invocation" in Workers.
    return handle(request, env, { now: () => Date.now() / 1000, fetcher: (input, init) => fetch(input, init) });
  },
};

export async function handle(request: Request, env: Env, deps: Deps): Promise<Response> {
  const path = new URL(request.url).pathname;
  try {
    if (request.method === "GET" && path === "/") return new Response("Wierdr push relay\n");
    if (request.method !== "POST") throw new Refusal(405, "method_not_allowed");
    const text = await request.text();
    if (text.length > MAX_BODY) throw new Refusal(413, "too_large");
    const route = ROUTES[path];
    if (!route) throw new Refusal(404, "not_found");
    return json(await route({ request, env, deps, text }));
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

interface Call {
  request: Request;
  env: Env;
  deps: Deps;
  text: string;
}

const ROUTES: Record<string, (c: Call) => Promise<unknown>> = {
  "/v1/challenge": async ({ request, env, deps }) => {
    await limit(env.LIMIT_APP, `challenge:${client(request)}`);
    return { challenge: await makeChallenge(env.RELAY_SECRET, deps.now()) };
  },

  "/v1/attest": async ({ request, env, deps, text }) => {
    await limit(env.LIMIT_APP, `attest:${client(request)}`);
    const b = body(text);
    const challenge = str(b.challenge, "challenge");
    if (!(await checkChallenge(env.RELAY_SECRET, challenge, deps.now()))) throw new Refusal(400, "bad_challenge");
    const keyId = bytes(b.key_id, "key_id");
    if (keyId.length !== 32) throw new Refusal(400, "bad_key_id");
    const attestation = bytes(b.attestation, "attestation");
    let attested;
    try {
      attested = await verifyAttestation({
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
      "INSERT INTO attest_keys (key_id, public_key, env, counter, created, used) VALUES (?, ?, ?, 0, ?, ?) " +
        "ON CONFLICT(key_id) DO NOTHING",
    ).bind(id, b64encode(attested.publicKey), attested.env, t, t).run();
    const row = await env.DB.prepare("SELECT public_key FROM attest_keys WHERE key_id = ?").bind(id)
      .first<{ public_key: string }>();
    if (row?.public_key !== b64encode(attested.publicKey)) throw new Refusal(409, "key_conflict");
    return { ok: true, env: attested.env };
  },

  "/v1/devices": async ({ request, env, deps, text }) => {
    const b = body(text);
    const keyIdText = str(b.key_id, "key_id");
    await limit(env.LIMIT_APP, `devices:${keyIdText}`);
    if (!(await checkChallenge(env.RELAY_SECRET, str(b.challenge, "challenge"), deps.now()))) {
      throw new Refusal(400, "bad_challenge");
    }
    const apnsEnv = environment(b.env);
    const token = deviceToken(b.token);
    const keyId = bytes(b.key_id, "key_id");
    const row = await env.DB.prepare("SELECT public_key, env, counter FROM attest_keys WHERE key_id = ?")
      .bind(b64encode(keyId)).first<{ public_key: string; env: string; counter: number }>();
    if (!row) throw new Refusal(401, "unknown_key", "attest the key first");
    // A key from App Attest's development environment gets no grant for a production token
    // (a TestFlight or App Store copy attests in production). A production key may hold
    // either: Xcode's export of a development build attests in production too.
    if (row.env === "development" && apnsEnv === "production") {
      throw new Refusal(403, "env_mismatch", "a development key, a production token");
    }
    const assertion = bytes(request.headers.get("x-wierdr-assertion"), "assertion");
    let counter: number;
    try {
      ({ counter } = await verifyAssertion({
        assertion, clientData: utf8(text), publicKey: b64decode(row.public_key)!, appId: appId(env),
        previousCounter: row.counter,
      }));
    } catch (e) {
      if (e instanceof AttestError) throw new Refusal(403, "bad_assertion", e.message);
      throw e;
    }
    const t = Math.floor(deps.now());
    const done = await env.DB.prepare("UPDATE attest_keys SET counter = ?, used = ? WHERE key_id = ? AND counter < ?")
      .bind(counter, t, b64encode(keyId), counter).run();
    if (done.meta.changes !== 1) throw new Refusal(409, "replayed");
    return makeGrant(env.RELAY_SECRET, "device", apnsEnv, token, deps.now());
  },

  "/v1/start": async ({ env, deps, text }) => {
    const b = body(text);
    const apnsEnv = environment(b.env);
    const token = deviceToken(b.token);
    await grant(env, deps, b.grant, "device", apnsEnv, token);
    await limit(env.LIMIT_PUSH, `start:${token}`);
    const payload = pushPayload(b.payload, "start");
    await apns(env, deps).start(apnsEnv, token, payload, priority(b.priority));
    return { ok: true };
  },

  "/v1/channels": async ({ env, deps, text }) => {
    const b = body(text);
    const apnsEnv = environment(b.env);
    const token = deviceToken(b.token);
    await grant(env, deps, b.grant, "device", apnsEnv, token);
    await limit(env.LIMIT_PUSH, `channels:${token}`);
    const day = Math.floor(deps.now() / 86400);
    const device = b64url(await sha256(utf8(token))).slice(0, 22);
    const row = await env.DB.prepare(
      "INSERT INTO channel_quota (device, day, n) VALUES (?, ?, 1) " +
        "ON CONFLICT(device, day) DO UPDATE SET n = n + 1 RETURNING n",
    ).bind(device, day).first<{ n: number }>();
    if ((row?.n ?? 0) > CHANNELS_PER_DAY) throw new Refusal(429, "channel_quota", `${CHANNELS_PER_DAY} a day`);
    if ((row?.n ?? 0) === 1) await env.DB.prepare("DELETE FROM channel_quota WHERE day < ?").bind(day - 1).run();
    const channel = await apns(env, deps).createChannel(apnsEnv);
    return { channel, ...(await makeGrant(env.RELAY_SECRET, "channel", apnsEnv, channel, deps.now())) };
  },

  "/v1/broadcast": async ({ env, deps, text }) => {
    const b = body(text);
    const apnsEnv = environment(b.env);
    const channel = channelId(b.channel);
    await grant(env, deps, b.grant, "channel", apnsEnv, channel);
    await limit(env.LIMIT_PUSH, `broadcast:${channel}`);
    const payload = pushPayload(b.payload, "broadcast");
    await apns(env, deps).broadcast(apnsEnv, channel, payload, priority(b.priority));
    return { ok: true };
  },

  "/v1/channels/delete": async ({ env, deps, text }) => {
    const b = body(text);
    const apnsEnv = environment(b.env);
    const channel = channelId(b.channel);
    await grant(env, deps, b.grant, "channel", apnsEnv, channel, true);
    await limit(env.LIMIT_PUSH, `delete:${channel}`);
    await apns(env, deps).deleteChannel(apnsEnv, channel);
    return { ok: true };
  },
};

const appId = (env: Env) => `${env.TEAM_ID}.${env.BUNDLE}`;

function apns(env: Env, deps: Deps): APNs {
  const store: TokenStore = {
    get: () => env.DB.prepare("SELECT iat, token FROM apns_jwt WHERE id = ?").bind(1).first<{ iat: number; token: string }>(),
    put: async (iat, token) => {
      await env.DB.prepare(
        "INSERT INTO apns_jwt (id, iat, token) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET iat = excluded.iat, token = excluded.token",
      ).bind(iat, token).run();
    },
  };
  return new APNs({ key: env.APNS_KEY, keyId: env.APNS_KEY_ID, teamId: env.TEAM_ID, bundle: env.BUNDLE }, store,
                  deps.fetcher, deps.now);
}

async function limit(limiter: RateLimiter, key: string) {
  if (!(await limiter.limit({ key })).success) throw new Refusal(429, "rate_limited");
}

async function grant(env: Env, deps: Deps, value: unknown, kind: GrantKind, apnsEnv: APNsEnv, id: string,
                     expiredOK = false) {
  const r = await checkGrant(env.RELAY_SECRET, value, kind, apnsEnv, id, deps.now());
  if (r === "bad") throw new Refusal(403, "bad_grant");
  if (r === "expired" && !expiredOK) throw new Refusal(403, "grant_expired");
}

function client(request: Request): string {
  return request.headers.get("cf-connecting-ip") ?? "unknown";
}

function body(text: string): Record<string, unknown> {
  try {
    const b = JSON.parse(text);
    if (typeof b === "object" && b !== null && !Array.isArray(b)) return b;
  } catch {}
  throw new Refusal(400, "bad_json");
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

function pushPayload(v: unknown, kind: PushKind): string {
  if (typeof v !== "string") throw new Refusal(400, "bad_payload");
  const why = checkPayload(v, kind);
  if (why) throw new Refusal(400, "bad_payload", why);
  return v;
}
