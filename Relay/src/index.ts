// Wierdr's push relay (Cloudflare Worker): the Mac's `wierdr-push` decides what the
// agents Live Activity shows and when; the relay signs it with our APNs key and sends
// it, as only our team's key can reach an App Store copy of Wierdr. See docs/relay.md.
//
//   POST /v1/challenge          app     → a challenge for App Attest
//   POST /v1/attest             app     → registers an attested App Attest key
//   POST /v1/devices            app     → a grant for its push-to-start token (assertion-signed)
//   POST /v1/grants/check       app     → whether its grant still holds (or wants renewing)
//   POST /v1/start              daemon  → push-to-start on a token (its device grant, the channel's)
//   POST /v1/channels           daemon  → a new broadcast channel (a device grant) and its grant
//   POST /v1/broadcast          daemon  → an update or end on a channel (its grant)
//   POST /v1/channels/delete    daemon  → deletes a channel (its grant, even expired)
//   POST /v1/admin/channels     admin   → APNs' channels against the ledger; purge unknown ones
//   POST /v1/admin/keys/revoke  admin   → revokes an App Attest key (its grants stop, its channels go)
//   cron (hourly)                       → deletes revoked keys' channels and those past their grant, prunes
//
// Runs on the Workers Free plan: 100,000 requests a day, 50 subrequests a request (D1
// queries count), so writes go in batches and a sweep deletes a few channels at a time.
import { APNs, APNsFailure, type StoredToken, type TokenStore } from "./apns";
import { AttestError, verifyAssertion, verifyAttestation } from "./appattest";
import { b64decode, b64encode, b64url, equal, pemBody, sha256, utf8 } from "./bytes";
import {
  ATTEST_CHALLENGE_TTL, checkChallenge, checkGrant, GRANT_TTL, makeChallenge, makeGrant, ownerOf,
  type APNsEnv, type GrantCheck, type GrantKind, type Secrets,
} from "./grants";
import { checkPayload, type PushKind } from "./payload";
import { APP_ATTEST_ROOT } from "./roots";

export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Statement {
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
  run(): Promise<{ meta: { changes: number } }>;
}

/** The part of D1 the relay uses. */
export interface Database {
  prepare(sql: string): { bind(...values: unknown[]): Statement };
  /** Several writes in one round trip (one subrequest). */
  batch(statements: Statement[]): Promise<unknown[]>;
}

export interface Env {
  DB: Database;
  /** Every call: per client address, before anything is read. */
  LIMIT_IP: RateLimiter;
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
  /** The one before, while rotating (at least 31 days): its grants still hold, marked for renewal. */
  RELAY_SECRET_PREVIOUS?: string;
  /** Bearer token of the admin routes (a secret; unset: no admin routes). */
  ADMIN_TOKEN?: string;
}

/** Distinct tokens one App Attest key may get grants for in 30 days. */
const TOKENS_PER_KEY = 5;
/** Channels one key may have made in a day. */
const CHANNELS_PER_KEY_DAY = 30;
/** Channels a key may have alive: what a daemon needs (a running one and a spare, a few
 *  Macs); 2 until APNs has taken a start to one of its tokens (made-up tokens never get
 *  there). Past it the key's oldest channel older than 8 hours goes (a younger one may
 *  carry another Mac's activity). */
const LIVE_CHANNELS_PER_KEY = 6;
const LIVE_CHANNELS_UNVERIFIED = 2;
/** Live channels the relay keeps per environment (APNs allows 10,000 per app); an alarm at half. */
const LIVE_CHANNELS_PER_APP = 8000;
/** Attestations a day, for everyone: new keys aren't free for someone making many. */
const ATTESTS_PER_DAY = 1000;
/** Push-to-starts one token may get in an hour (an activity starts a few times a day). */
const STARTS_PER_HOUR = 12;
/** A channel outlives its grant by a day, then the cron deletes it. */
const CHANNEL_LIFETIME = GRANT_TTL + 86400;
/** Channel deletions a sweep or purge makes (subrequests: 50 a request on the Free plan). */
const DELETES_PER_RUN = 20;
/** A grant this close to its end is renewed when used. */
const RENEW_WITHIN = 10 * 86400;
const MAX_BODY = 20_000;
const DAY = 86400;

class Refusal extends Error {
  constructor(readonly status: number, readonly code: string, message?: string, readonly extra: Record<string, unknown> = {}) {
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
    await limit(env.LIMIT_IP, `any:${client(request)}`);
    const raw = await readBody(request);
    return json(await route({ request, env, deps, raw }));
  } catch (e) {
    if (e instanceof Refusal) return json({ error: e.code, message: e.message, ...e.extra }, e.status);
    if (e instanceof APNsFailure) {
      console.log(`${path}: ${e.message}`);
      return json({ error: "apns", status: e.status, reason: e.reason }, 502);
    }
    console.error(`${path}: ${(e as Error).stack ?? e}`);
    return json({ error: "internal" }, 500);
  }
}

/** The body's bytes, at most 20 KB: refused by its declared length, or once that many came. */
async function readBody(request: Request): Promise<Uint8Array<ArrayBuffer>> {
  if (Number(request.headers.get("content-length") ?? "0") > MAX_BODY) throw new Refusal(413, "too_large");
  const chunks: Uint8Array[] = [];
  let n = 0;
  if (request.body) {
    const reader = request.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      n += value.length;
      if (n > MAX_BODY) {
        await reader.cancel();
        throw new Refusal(413, "too_large");
      }
      chunks.push(value);
    }
  }
  const out = new Uint8Array(n);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
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
    // A day: what Apple attested may come again later (the relay was out of reach).
    if (!(await checkChallenge(secrets(env), challenge, deps.now(), ATTEST_CHALLENGE_TTL))) {
      throw new Refusal(400, "bad_challenge");
    }
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
    const known = await env.DB.prepare("SELECT public_key FROM attest_keys WHERE key_id = ?").bind(id)
      .first<{ public_key: string }>();
    if (known) {
      if (known.public_key !== b64encode(a.publicKey)) throw new Refusal(409, "key_conflict");
      return { ok: true, env: a.env };
    }
    const day = Math.floor(t / DAY);
    const count = await env.DB.prepare(
      "INSERT INTO daily (day, attests) VALUES (?, 1) ON CONFLICT(day) DO UPDATE SET attests = attests + 1 RETURNING attests",
    ).bind(day).first<{ attests: number }>();
    const n = count?.attests ?? 0;
    if (n === ATTESTS_PER_DAY / 2) console.error(`attestations today: ${n} of ${ATTESTS_PER_DAY}`);
    if (n > ATTESTS_PER_DAY) throw new Refusal(503, "attest_budget", "too many new keys today");
    await env.DB.prepare(
      "INSERT INTO attest_keys (key_id, owner, public_key, env, category, bundle_version, receipt, counter, created, used) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?) ON CONFLICT(key_id) DO NOTHING",
    ).bind(id, await ownerOf(keyId), b64encode(a.publicKey), a.env, a.category ?? null, a.bundleVersion ?? null,
           a.receipt ? b64encode(a.receipt) : null, t, t).run();
    return { ok: true, env: a.env };
  },

  "/v1/devices": async ({ request, env, deps, raw }) => {
    await limit(env.LIMIT_APP, `ip:${client(request)}`);
    const b = body(raw);
    // What the assertion is for, in what it signs: no other route can take it.
    if (b.op !== "devices") throw new Refusal(400, "bad_op");
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
    if (!key) throw new Refusal(401, "key_unknown", "attest the key first");
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
    const tokenHash = await hashed(token);
    const tokens = await env.DB.prepare(
      "SELECT SUM(token = ? AND env = ?) AS mine, COUNT(*) AS n FROM device_tokens WHERE owner = ? AND last_seen > ?",
    ).bind(tokenHash, apnsEnv, key.owner, t - 30 * DAY).first<{ mine: number | null; n: number }>();
    if (!tokens?.mine && (tokens?.n ?? 0) >= TOKENS_PER_KEY) {
      throw new Refusal(429, "too_many_tokens", `${TOKENS_PER_KEY} in 30 days`);
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
    return { ok: true, expires: g.expires, renew: g.stale || g.expires - deps.now() < RENEW_WITHIN };
  },

  "/v1/start": async ({ env, deps, raw }) => {
    const b = daemonBody(env, raw);
    const apnsEnv = environment(b.env);
    const token = deviceToken(b.token);
    const channel = channelId(b.channel);
    const device = subject(env, "device", apnsEnv, token);
    const g = await grant(env, deps, b.grant, device);
    await grant(env, deps, b.channel_grant, subject(env, "channel", apnsEnv, channel));
    // A channel the relay deleted (its key's limit, the cron) takes no start: the activity
    // would never hear from it. The daemon reads it as the channel's grant refused.
    const live = await env.DB.prepare("SELECT deleted FROM channels WHERE id = ? AND env = ?").bind(channel, apnsEnv)
      .first<{ deleted: number | null }>();
    if (!live || live.deleted !== null) throw new Refusal(403, "bad_grant", "channel deleted", { grant: "channel" });
    await limit(env.LIMIT_PUSH, `start:${token}`);
    const p = pushPayload(b.payload, "start");
    if (p.channel !== channel) throw new Refusal(400, "bad_payload", "input-push-channel isn't the channel");
    const t = Math.floor(deps.now());
    const tokenHash = await hashed(token);
    const starts = await env.DB.prepare(
      "INSERT INTO starts (token, hour, n) VALUES (?, ?, 1) ON CONFLICT(token, hour) DO UPDATE SET n = n + 1 RETURNING n",
    ).bind(tokenHash, Math.floor(t / 3600)).first<{ n: number }>();
    if ((starts?.n ?? 0) > STARTS_PER_HOUR) throw new Refusal(429, "start_quota", `${STARTS_PER_HOUR} an hour`);
    await apns(env, deps).start(apnsEnv, token, p.text, priority(b.priority));
    // APNs took a start to it: a real device's token (its key may keep more channels).
    await env.DB.prepare("UPDATE device_tokens SET verified = 1 WHERE owner = ? AND token = ? AND env = ? AND verified = 0")
      .bind(g.owner, tokenHash, apnsEnv).run();
    return { ok: true, ...(await renewal(env, deps, g, device)) };
  },

  "/v1/channels": async ({ env, deps, raw }) => {
    const b = daemonBody(env, raw);
    const apnsEnv = environment(b.env);
    const token = deviceToken(b.token);
    const device = subject(env, "device", apnsEnv, token);
    const g = await grant(env, deps, b.grant, device);
    await limit(env.LIMIT_PUSH, `channels:${token}`);
    const t = Math.floor(deps.now());
    const mine = await env.DB.prepare(
      "SELECT SUM(created > ?) AS today, SUM(deleted IS NULL) AS live, " +
        "(SELECT MAX(verified) FROM device_tokens WHERE owner = ?) AS verified FROM channels WHERE owner = ? AND created > ?",
    ).bind(t - DAY, g.owner, g.owner, t - CHANNEL_LIFETIME)
      .first<{ today: number | null; live: number | null; verified: number | null }>();
    if ((mine?.today ?? 0) >= CHANNELS_PER_KEY_DAY) throw new Refusal(429, "channel_quota", `${CHANNELS_PER_KEY_DAY} a day`);
    const most = mine?.verified ? LIVE_CHANNELS_PER_KEY : LIVE_CHANNELS_UNVERIFIED;
    const all = await env.DB.prepare("SELECT COUNT(*) AS n FROM channels WHERE env = ? AND deleted IS NULL")
      .bind(apnsEnv).first<{ n: number }>();
    const n = all?.n ?? 0;
    if (n >= LIVE_CHANNELS_PER_APP / 2) console.error(`live channels in ${apnsEnv}: ${n} of ${LIVE_CHANNELS_PER_APP}`);
    if (n >= LIVE_CHANNELS_PER_APP) throw new Refusal(503, "channels_full");
    if ((mine?.live ?? 0) >= most) {
      // At its limit the key's oldest channels go (one a lost daemon state left behind, most
      // likely), not ones from the last 8 hours (an activity lives that long).
      const want = (mine?.live ?? 0) - most + 1;
      const old = await env.DB.prepare(
        "SELECT id FROM channels WHERE owner = ? AND env = ? AND deleted IS NULL AND created < ? ORDER BY created LIMIT ?",
      ).bind(g.owner, apnsEnv, t - 8 * 3600, want).all<{ id: string }>();
      if (old.results.length < want) throw new Refusal(429, "channel_limit", `${most} alive`);
      for (const c of old.results) await deleteChannel(env, deps, apnsEnv, c.id);
    }
    const channel = await apns(env, deps).createChannel(apnsEnv);
    await env.DB.prepare("INSERT INTO channels (id, env, owner, created) VALUES (?, ?, ?, ?) ON CONFLICT(id, env) DO NOTHING")
      .bind(channel, apnsEnv, g.owner, t).run();
    return {
      channel,
      ...(await makeGrant(secrets(env), subject(env, "channel", apnsEnv, channel), g.owner, deps.now())),
      ...(await renewal(env, deps, g, device)),
    };
  },

  "/v1/broadcast": async ({ env, deps, raw }) => {
    const b = daemonBody(env, raw);
    const apnsEnv = environment(b.env);
    const channel = channelId(b.channel);
    const s = subject(env, "channel", apnsEnv, channel);
    const g = await grant(env, deps, b.grant, s);
    await limit(env.LIMIT_PUSH, `broadcast:${channel}`);
    const p = pushPayload(b.payload, "broadcast");
    await apns(env, deps).broadcast(apnsEnv, channel, p.text, priority(b.priority));
    return { ok: true, ...(await renewal(env, deps, g, s)) };
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
    const listedAt = Math.floor(deps.now());
    const listed = new Set(await apns(env, deps).listChannels(apnsEnv));
    const rows = await env.DB.prepare("SELECT id, created FROM channels WHERE env = ? AND deleted IS NULL").bind(apnsEnv)
      .all<{ id: string; created: number }>();
    const known = new Set(rows.results.map((r) => r.id));
    const unknown = [...listed].filter((c) => !known.has(c));
    // Gone from APNs: only ones made before the list was taken (a newer one may not be in it).
    const gone = rows.results.filter((r) => !listed.has(r.id) && r.created < listedAt).map((r) => r.id);
    const t = Math.floor(deps.now());
    if (gone.length) {
      await env.DB.batch(gone.map((c) =>
        env.DB.prepare("UPDATE channels SET deleted = ? WHERE id = ? AND env = ?").bind(t, c, apnsEnv)));
    }
    let purged = 0;
    if (b.purge === true) {
      for (const c of unknown.slice(0, DELETES_PER_RUN)) {
        await apns(env, deps).deleteChannel(apnsEnv, c).then(() => purged++, () => {});
      }
    }
    return { listed: listed.size, live: known.size - gone.length, unknown: unknown.length, purged };
  },

  "/v1/admin/keys/revoke": async ({ request, env, raw }) => {
    admin(request, env);
    const owner = str(body(raw).owner, "owner");
    const r = await env.DB.prepare("UPDATE attest_keys SET revoked = 1 WHERE owner = ?").bind(owner).run();
    // Its channels go with the next sweeps.
    return { revoked: r.meta.changes };
  },
};

/** The hourly cron: revoked keys' channels first, then those past their grant (APNs keeps
 *  10,000 at most), a few a run; a deletion that fails waits longer each time and is given
 *  up after 10 tries; old rows go. */
export async function sweep(env: Env, deps: Deps): Promise<{ deleted: number; failed: number }> {
  const t = Math.floor(deps.now());
  const due = await env.DB.prepare(
    "SELECT c.id, c.env, c.tries FROM channels c LEFT JOIN attest_keys k ON k.owner = c.owner " +
      "WHERE c.deleted IS NULL AND (c.next_try IS NULL OR c.next_try <= ?) " +
      "AND (k.owner IS NULL OR k.revoked = 1 OR c.created < ?) " +
      "ORDER BY (k.owner IS NULL OR k.revoked = 1) DESC, c.created LIMIT ?",
  ).bind(t, t - CHANNEL_LIFETIME, DELETES_PER_RUN).all<{ id: string; env: APNsEnv; tries: number }>();
  const writes: Statement[] = [];
  let deleted = 0;
  let failed = 0;
  for (const c of due.results) {
    try {
      await apnsDelete(env, deps, c.env, c.id);
      writes.push(env.DB.prepare("UPDATE channels SET deleted = ? WHERE id = ? AND env = ?").bind(t, c.id, c.env));
      deleted++;
    } catch (e) {
      failed++;
      const tries = c.tries + 1;
      console.log(`sweep: ${c.id} (${tries}): ${(e as Error).message}`);
      writes.push(tries >= 10
        ? env.DB.prepare("UPDATE channels SET deleted = ?, tries = ? WHERE id = ? AND env = ?").bind(t, tries, c.id, c.env)
        : env.DB.prepare("UPDATE channels SET tries = ?, next_try = ? WHERE id = ? AND env = ?")
            .bind(tries, t + 3600 * 2 ** Math.min(tries, 6), c.id, c.env));
    }
  }
  writes.push(
    env.DB.prepare("DELETE FROM channels WHERE deleted IS NOT NULL AND deleted < ?").bind(t - 30 * DAY),
    env.DB.prepare("DELETE FROM device_tokens WHERE last_seen < ?").bind(t - 60 * DAY),
    env.DB.prepare("DELETE FROM attest_keys WHERE used < ? AND revoked = 0").bind(t - 400 * DAY),
    env.DB.prepare("DELETE FROM starts WHERE hour < ?").bind(Math.floor(t / 3600) - 48),
    env.DB.prepare("DELETE FROM daily WHERE day < ?").bind(Math.floor(t / DAY) - 30),
  );
  await env.DB.batch(writes);
  return { deleted, failed };
}

/** Deletes on APNs; a channel APNs no longer has counts as deleted. */
async function apnsDelete(env: Env, deps: Deps, apnsEnv: APNsEnv, channel: string) {
  try {
    await apns(env, deps).deleteChannel(apnsEnv, channel);
  } catch (e) {
    const gone = e instanceof APNsFailure &&
      (e.status === 404 || ["BadChannelId", "ChannelNotRegistered", "InvalidChannelId"].includes(e.reason));
    if (!gone) throw e;
  }
}

/** Deletes on APNs and in the ledger. */
async function deleteChannel(env: Env, deps: Deps, apnsEnv: APNsEnv, channel: string) {
  await apnsDelete(env, deps, apnsEnv, channel);
  await env.DB.prepare("UPDATE channels SET deleted = ? WHERE id = ? AND env = ? AND deleted IS NULL")
    .bind(Math.floor(deps.now()), channel, apnsEnv).run();
}

const appId = (env: Env) => `${env.TEAM_ID}.${env.BUNDLE}`;
const secrets = (env: Env): Secrets => ({ current: env.RELAY_SECRET, previous: env.RELAY_SECRET_PREVIOUS || undefined });
const subject = (env: Env, kind: GrantKind, apnsEnv: APNsEnv, id: string) => ({ appId: appId(env), kind, env: apnsEnv, id });
const hashed = async (token: string) => b64url(await sha256(utf8(token)));

/** A fresh grant for what `g` was for, when it's near its end or signed with the old secret:
 *  a daemon that keeps using it keeps it (without Wierdr being opened). */
async function renewal(env: Env, deps: Deps, g: Extract<GrantCheck, { owner: string }>, s: ReturnType<typeof subject>) {
  if (!g.stale && g.expires - deps.now() >= RENEW_WITHIN) return {};
  return { renewed: (await makeGrant(secrets(env), s, g.owner, deps.now())).grant };
}

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
    clear: async (token) => {
      await env.DB.prepare("DELETE FROM apns_jwt WHERE id = 1 AND token = ?").bind(token).run();
    },
  };
  return new APNs({ key: env.APNS_KEY, keyId: env.APNS_KEY_ID, teamId: env.TEAM_ID, bundle: env.BUNDLE }, store,
                  deps.fetcher, deps.now);
}

async function limit(limiter: RateLimiter, key: string) {
  if (!(await limiter.limit({ key })).success) throw new Refusal(429, "rate_limited");
}

/** A grant that holds, its owner's key known and not revoked. A refusal names the grant's
 *  kind (`grant`: a start carries two). */
async function grant(env: Env, deps: Deps, value: unknown, s: ReturnType<typeof subject>,
                     allow: { expired?: boolean; revoked?: boolean } = {}) {
  const g = await checkGrant(secrets(env), value, s, deps.now());
  const whose = { grant: s.kind };
  if (g.status === "bad") throw new Refusal(403, "bad_grant", `${s.kind} grant`, whose);
  if (g.status === "expired" && !allow.expired) throw new Refusal(403, "grant_expired", `${s.kind} grant`, whose);
  if (!allow.revoked) {
    const key = await env.DB.prepare("SELECT revoked FROM attest_keys WHERE owner = ?").bind(g.owner)
      .first<{ revoked: number }>();
    if (!key) throw new Refusal(403, "key_unknown", `${s.kind} grant`, whose);
    if (key.revoked) throw new Refusal(403, "key_revoked", `${s.kind} grant`, whose);
  }
  return g;
}

function admin(request: Request, env: Env) {
  const got = request.headers.get("authorization") ?? "";
  if (!env.ADMIN_TOKEN || !equal(utf8(got), utf8(`Bearer ${env.ADMIN_TOKEN}`))) throw new Refusal(404, "not_found");
}

/** The client's address: IPv4 as it is (an IPv4-mapped IPv6 one too), IPv6 by its /64
 *  (one host has the whole of it). */
export function client(request: Request): string {
  const ip = (request.headers.get("cf-connecting-ip") ?? "unknown").toLowerCase();
  const mapped = /^(?:0{0,4}:){0,5}(?:0{0,4}:)?ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(ip.replace(/^::/, "0::"));
  if (mapped) return mapped[1];
  if (!ip.includes(":")) return ip;
  const [head, tail = ""] = ip.split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const full = [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right];
  return `${full.slice(0, 4).map((h) => h.replace(/^0+(?=.)/, "")).join(":")}::/64`;
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
