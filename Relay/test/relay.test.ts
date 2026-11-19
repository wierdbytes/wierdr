import { Database as SQLite } from "bun:sqlite";
import { beforeEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { APNs, resetTokenCache, type StoredToken, type TokenStore } from "../src/apns";
import { b64decode, b64encode, b64url, concat, sha256, utf8 } from "../src/bytes";
import { checkChallenge, checkGrant, makeChallenge, makeGrant, ownerOf } from "../src/grants";
import { checkPayload } from "../src/payload";
import { handle, sweep, type Database, type Env, type RateLimiter } from "../src/index";

// MARK: Fakes

/** D1 over bun:sqlite, with the relay's schema. */
function database(): { db: Database; sql: SQLite } {
  const sql = new SQLite(":memory:");
  sql.exec(readFileSync(new URL("../schema.sql", import.meta.url), "utf8"));
  const db: Database = {
    prepare: (q) => ({
      bind: (...values) => ({
        first: async <T>() => (sql.query(q).get(...(values as never[])) as T) ?? null,
        all: async <T>() => ({ results: sql.query(q).all(...(values as never[])) as T[] }),
        run: async () => ({ meta: { changes: sql.query(q).run(...(values as never[])).changes } }),
      }),
    }),
  };
  return { db, sql };
}

let limited: string[];
const recording = (): RateLimiter => ({ limit: async ({ key }) => (limited.push(key), { success: true }) });

interface Sent {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string;
}

let sent: Sent[];
let reply: (s: Sent) => Response;
let now: number;
let env: Env;
let sql: SQLite;
let channelCount: number;

const fetcher = (async (url: string, init: RequestInit) => {
  const s: Sent = { url, method: init.method ?? "GET", headers: init.headers as Record<string, string>, body: init.body as string };
  sent.push(s);
  return reply(s);
}) as unknown as typeof fetch;

async function p8(): Promise<string> {
  const k = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", k.privateKey)) as ArrayBuffer);
  return `-----BEGIN PRIVATE KEY-----\n${b64encode(der)}\n-----END PRIVATE KEY-----\n`;
}

const APP_ID = "AUL4CCB2XY.pw.xff.wierdr";

beforeEach(async () => {
  const d = database();
  sql = d.sql;
  sent = [];
  limited = [];
  channelCount = 0;
  reply = (s) =>
    new Response(null, {
      status: 200,
      headers: s.url.endsWith("/channels") && s.method === "POST" ? { "apns-channel-id": `CHANNEL${String(++channelCount).padStart(10, "0")}ab==` } : {},
    });
  now = 1_800_000_000;
  resetTokenCache();
  env = {
    DB: d.db, LIMIT_APP: recording(), LIMIT_ATTEST: recording(), LIMIT_PUSH: recording(), APNS_KEY: await p8(),
    APNS_KEY_ID: "KEY1234567", TEAM_ID: "AUL4CCB2XY", BUNDLE: "pw.xff.wierdr", RELAY_SECRET: "test secret",
    ADMIN_TOKEN: "admin token",
  };
});

async function call(path: string, body: unknown, headers: Record<string, string> = {}) {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  const r = await handle(new Request(`https://relay.test${path}`, { method: "POST", body: text, headers }), env,
                         { now: () => now, fetcher });
  return { status: r.status, json: (await r.json()) as Record<string, any> };
}

// MARK: An App Attest key of our own (the relay sees it as attested)

/** Minimal CBOR encoding: text-keyed maps of byte strings. */
function cbor(map: Record<string, Uint8Array>): Uint8Array {
  const head = (major: number, n: number) =>
    n < 24 ? [(major << 5) | n] : n < 256 ? [(major << 5) | 24, n] : [(major << 5) | 25, n >> 8, n & 255];
  const parts: number[] = [...head(5, Object.keys(map).length)];
  for (const [k, v] of Object.entries(map)) {
    const kb = utf8(k);
    parts.push(...head(3, kb.length), ...kb, ...head(2, v.length), ...v);
  }
  return new Uint8Array(parts);
}

/** r ‖ s → DER ECDSA-Sig-Value (App Attest signs in DER). */
function der(raw: Uint8Array): Uint8Array {
  const int = (x: Uint8Array) => {
    let i = 0;
    while (i < x.length - 1 && x[i] === 0) i++;
    const v = x[i] & 0x80 ? [0, ...x.subarray(i)] : [...x.subarray(i)];
    return [0x02, v.length, ...v];
  };
  const body = [...int(raw.subarray(0, 32)), ...int(raw.subarray(32))];
  return new Uint8Array([0x30, body.length, ...body]);
}

async function attestedKey(keyEnv = "development", category: number | null = 3) {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const spki = new Uint8Array((await crypto.subtle.exportKey("spki", pair.publicKey)) as ArrayBuffer);
  const id = crypto.getRandomValues(new Uint8Array(32));
  const keyId = b64encode(id);
  const owner = await ownerOf(id);
  sql.query("INSERT INTO attest_keys (key_id, owner, public_key, env, category, counter, created, used) VALUES (?, ?, ?, ?, ?, 0, 0, 0)")
    .run(keyId, owner, b64encode(spki), keyEnv, category);
  let counter = 0;
  return {
    keyId,
    owner,
    /** The assertion App Attest would make over `clientData`. */
    async assert(clientData: string, count = ++counter): Promise<string> {
      const authData = concat(await sha256(utf8(APP_ID)), new Uint8Array([0x40, 0, 0, 0, count]));
      const nonce = await sha256(concat(authData, await sha256(utf8(clientData))));
      const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, nonce));
      return b64encode(cbor({ signature: der(sig), authenticatorData: authData }));
    },
  };
}

const token = "80777b53e4b407886b965da507d10e3d1052b1fe3d6e9b38f6a95fe42116941cf75e59ff663b93cea18a46b6e5c85d986d36df9b79b900a7b2db76cb88d4680b4";
const tokenN = (n: number) => n.toString(16).padStart(2, "0").repeat(40);

async function registerWith(key: Awaited<ReturnType<typeof attestedKey>>, t = token, apnsEnv = "development") {
  const { json: c } = await call("/v1/challenge", {});
  const body = JSON.stringify({ challenge: c.challenge, key_id: key.keyId, token: t, env: apnsEnv });
  return call("/v1/devices", body, { "x-wierdr-assertion": await key.assert(body) });
}

async function register(keyEnv = "development", apnsEnv = "development") {
  const key = await attestedKey(keyEnv);
  return { key, ...(await registerWith(key, token, apnsEnv)) };
}

async function channelFor(grant: string) {
  return call("/v1/channels", { bundle: "pw.xff.wierdr", env: "development", token, grant });
}

/** A payload as WierdrPush/Payloads.swift makes them (sealed). */
function payload(event: "start" | "update" | "end", extra: Record<string, unknown> = {}, channel = "CHANNEL0000000001ab==") {
  const aps: Record<string, unknown> = {
    timestamp: now, event, "content-state": { blocked: 1, done: 0, working: 2, idle: 3, at: now + 0.25, sealed: "c2VhbGVk", kid: "ab12cd34" },
    ...(event === "end" ? { "dismissal-date": now } : { "stale-date": now + 1500 }),
  };
  if (event === "start") {
    Object.assign(aps, {
      "input-push-channel": channel, "attributes-type": "AgentsActivityAttributes",
      attributes: { sealed: "c2VhbGVk", kid: "ab12cd34" }, alert: { title: "Wierdr", body: "1 needs you · 2 working", sound: "default" },
    });
  }
  return JSON.stringify({ aps: { ...aps, ...extra } });
}

/** A registered device with a channel: what a start needs. */
async function ready() {
  const r = await register();
  const ch = await channelFor(r.json.grant);
  sent = [];
  const start = {
    bundle: "pw.xff.wierdr", env: "development", token, grant: r.json.grant, channel: ch.json.channel,
    channel_grant: ch.json.grant, payload: payload("start", {}, ch.json.channel), priority: 10,
  };
  return { key: r.key, grant: r.json.grant, channel: ch.json.channel, channelGrant: ch.json.grant, start };
}

// MARK: Tests

describe("the app's registration", () => {
  test("an attested key's assertion gets a grant for the token, named after the key", async () => {
    const r = await register();
    expect(r.status).toBe(200);
    expect(r.json.grant).toStartWith(`g2.${now + 30 * 24 * 3600}.${r.key.owner}.`);
    const g = await checkGrant({ current: "test secret" }, r.json.grant, { appId: APP_ID, kind: "device", env: "development", id: token }, now);
    expect(g.status).toBe("ok");
  });

  test("the same assertion twice is refused (the counter)", async () => {
    const key = await attestedKey();
    const { json: c } = await call("/v1/challenge", {});
    const body = JSON.stringify({ challenge: c.challenge, key_id: key.keyId, token, env: "development" });
    const assertion = await key.assert(body);
    expect((await call("/v1/devices", body, { "x-wierdr-assertion": assertion })).status).toBe(200);
    const again = await call("/v1/devices", body, { "x-wierdr-assertion": assertion });
    expect(again.status).toBe(403);
    expect(again.json.error).toBe("bad_assertion");
  });

  test("an assertion over other bytes is refused", async () => {
    const key = await attestedKey();
    const { json: c } = await call("/v1/challenge", {});
    const body = JSON.stringify({ challenge: c.challenge, key_id: key.keyId, token, env: "development" });
    const r = await call("/v1/devices", body + " ", { "x-wierdr-assertion": await key.assert(body) });
    expect(r.json.error).toBe("bad_assertion");
  });

  test("a key the relay never saw attested must attest first", async () => {
    const { json: c } = await call("/v1/challenge", {});
    const body = JSON.stringify({ challenge: c.challenge, key_id: b64encode(new Uint8Array(32)), token, env: "development" });
    const r = await call("/v1/devices", body, { "x-wierdr-assertion": "AA==" });
    expect(r.status).toBe(401);
    expect(r.json.error).toBe("unknown_key");
  });

  test("environments: development keys no production token; TestFlight and App Store builds only production", async () => {
    expect((await register("development", "production")).json.error).toBe("env_mismatch");
    expect((await register("production", "development")).status).toBe(200); // Xcode's export of a dev build
    const store = await attestedKey("production", 4);
    expect((await registerWith(store, token, "development")).json.error).toBe("env_mismatch");
    expect((await registerWith(store, token, "production")).status).toBe(200);
  });

  test("a key gets grants for 5 tokens in 30 days, not for any it learns", async () => {
    const key = await attestedKey();
    for (let i = 0; i < 5; i++) expect((await registerWith(key, tokenN(i))).status).toBe(200);
    expect((await registerWith(key, tokenN(0))).status).toBe(200); // a known one, again
    const sixth = await registerWith(key, tokenN(5));
    expect(sixth.status).toBe(429);
    expect(sixth.json.error).toBe("too_many_tokens");
  });

  test("a revoked key gets nothing, and its grants stop working", async () => {
    const { key, grant, start } = await ready();
    expect((await call("/v1/admin/keys/revoke", { owner: key.owner }, { authorization: "Bearer admin token" })).json.revoked).toBe(1);
    expect((await registerWith(key)).json.error).toBe("key_revoked");
    expect((await call("/v1/start", start)).json.error).toBe("key_revoked");
    expect((await channelFor(grant)).json.error).toBe("key_revoked");
    // Cleaning up still works.
    const del = await call("/v1/channels/delete", { bundle: "pw.xff.wierdr", env: "development", channel: start.channel, grant: start.channel_grant });
    expect(del.status).toBe(200);
  });

  test("an old challenge is refused", async () => {
    const key = await attestedKey();
    const { json: c } = await call("/v1/challenge", {});
    now += 600;
    const body = JSON.stringify({ challenge: c.challenge, key_id: key.keyId, token, env: "development" });
    expect((await call("/v1/devices", body, { "x-wierdr-assertion": await key.assert(body) })).json.error).toBe("bad_challenge");
  });

  test("attestations that don't verify are 403s, garbage too", async () => {
    const { json: c } = await call("/v1/challenge", {});
    const keyId = b64encode(new Uint8Array(32));
    for (const attestation of ["oA==", b64encode(new Uint8Array([0xa1, 0x63, 0x66, 0x6d, 0x74, 0x6f, ...utf8("apple-appattest")])), "AAAA"]) {
      const r = await call("/v1/attest", { challenge: c.challenge, key_id: keyId, attestation });
      expect(r.status).toBe(403);
      expect(r.json.error).toBe("bad_attestation");
    }
    expect((await call("/v1/attest", { challenge: c.challenge, key_id: "AAAA", attestation: "oA==" })).json.error).toBe("bad_key_id");
  });

  test("a key counts once against its limit, however its base64 is spelled; an IPv6 client by its /64", async () => {
    const key = await attestedKey();
    const { json: c } = await call("/v1/challenge", {}, { "cf-connecting-ip": "2001:db8:0:1:aaaa::1" });
    const urlSafe = b64url(b64decode(key.keyId)!);
    const body = JSON.stringify({ challenge: c.challenge, key_id: urlSafe, token, env: "development" });
    await call("/v1/devices", body, { "x-wierdr-assertion": await key.assert(body), "cf-connecting-ip": "2001:db8:0:1:bbbb::2" });
    expect(limited).toContain(`key:${key.keyId}`);
    expect(limited.filter((k) => k.startsWith("ip:"))).toEqual(["ip:2001:db8:0:1::/64", "ip:2001:db8:0:1::/64"]);
  });

  test("the app checks its grant: good, to renew (old secret, near its end), or refused", async () => {
    const { grant } = (await register()).json;
    const check = (g: string) => call("/v1/grants/check", { env: "development", token, grant: g });
    expect((await check(grant)).json).toEqual({ ok: true, expires: now + 30 * 24 * 3600, renew: false });
    now += 25 * 24 * 3600;
    expect((await check(grant)).json.renew).toBe(true);
    now -= 25 * 24 * 3600;
    env.RELAY_SECRET_PREVIOUS = env.RELAY_SECRET;
    env.RELAY_SECRET = "new secret";
    expect((await check(grant)).json.renew).toBe(true);
    env.RELAY_SECRET_PREVIOUS = undefined;
    expect((await check(grant)).json.error).toBe("bad_grant");
  });

  test("a body past 20 KB is refused before it's read", async () => {
    const r = await call("/v1/challenge", "x".repeat(10), { "content-length": "25000" });
    expect(r.status).toBe(413);
  });
});

describe("the daemon's pushes", () => {
  test("a start goes to APNs with its token, topic, type, expiration and a provider token", async () => {
    const { start } = await ready();
    const r = await call("/v1/start", start);
    expect(r.status).toBe(200);
    expect(sent).toHaveLength(1);
    expect(sent[0].url).toBe(`https://api.sandbox.push.apple.com/3/device/${token}`);
    expect(sent[0].headers["apns-topic"]).toBe("pw.xff.wierdr.push-type.liveactivity");
    expect(sent[0].headers["apns-push-type"]).toBe("liveactivity");
    expect(sent[0].headers["apns-priority"]).toBe("10");
    expect(sent[0].headers["apns-expiration"]).toBe(String(now + 600));
    expect(JSON.parse(sent[0].body!)).toEqual(JSON.parse(start.payload));
    const jwt = sent[0].headers.authorization.replace("bearer ", "");
    const [h, c] = jwt.split(".").slice(0, 2).map((p) => JSON.parse(new TextDecoder().decode(b64decode(p)!)));
    expect(h).toEqual({ alg: "ES256", kid: "KEY1234567" });
    expect(c.iss).toBe("AUL4CCB2XY");
  });

  test("what goes out is the payload as parsed: a duplicate key can't smuggle plain text", async () => {
    const { start } = await ready();
    const dup = start.payload.replace('"attributes":', '"attributes":{"host":"mentoair"},"attributes":');
    expect(dup).toContain("mentoair");
    expect((await call("/v1/start", { ...start, payload: dup })).status).toBe(200);
    expect(sent[0].body).not.toContain("mentoair");
  });

  test("a start needs the channel's grant, and the payload's channel must be that channel", async () => {
    const { start } = await ready();
    expect((await call("/v1/start", { ...start, channel_grant: start.grant })).json.error).toBe("bad_grant");
    const other = payload("start", {}, "OTHERCHANNEL0000ab==");
    expect((await call("/v1/start", { ...start, payload: other })).json.error).toBe("bad_payload");
    expect((await call("/v1/start", { ...start, bundle: "com.example" })).json.error).toBe("bad_bundle");
    expect(sent).toHaveLength(0);
  });

  test("the provider token: one per half hour and key, the first stored wins, renewed after a refusal", async () => {
    const stored: { t: StoredToken | null } = { t: null };
    const store: TokenStore = {
      get: async () => stored.t,
      offer: async (t) => (stored.t && stored.t.iat >= t.iat && stored.t.kid === t.kid ? stored.t : (stored.t = t)),
      clear: async () => void (stored.t = null),
    };
    const config = { key: env.APNS_KEY, keyId: "K1", teamId: "T", bundle: "b" };
    const clock = () => now;
    const a = new APNs(config, store, fetcher, clock);
    const first = await a.token();
    resetTokenCache(); // another isolate, which signed its own before seeing the first
    stored.t = null;
    const theirs = await new APNs(config, store, fetcher, clock).token();
    resetTokenCache();
    expect(await a.token()).toBe(theirs); // the one stored wins
    expect(first).not.toBe(theirs);
    resetTokenCache();
    expect(await new APNs({ ...config, keyId: "K2" }, store, fetcher, clock).token()).not.toBe(theirs); // a new key
    reply = () => new Response(JSON.stringify({ reason: "InvalidProviderToken" }), { status: 403 });
    await expect(a.start("development", token, "{}", 10)).rejects.toThrow("InvalidProviderToken");
    expect(stored.t).toBeNull();
  });

  test("no grant, no push; another token's grant neither", async () => {
    const { start } = await ready();
    expect((await call("/v1/start", { ...start, grant: "g2.9999999999.AAAAAAAAAAAAAAAA.AAAA" })).json.error).toBe("bad_grant");
    const owner = (await register()).key.owner;
    const other = await makeGrant({ current: "test secret" }, { appId: APP_ID, kind: "device", env: "development", id: tokenN(9) }, owner, now);
    expect((await call("/v1/start", { ...start, grant: other.grant })).json.error).toBe("bad_grant");
    const old = await makeGrant({ current: "test secret" }, { appId: APP_ID, kind: "device", env: "development", id: token }, owner, now - 31 * 24 * 3600);
    expect((await call("/v1/start", { ...start, grant: old.grant })).json.error).toBe("grant_expired");
    expect(sent).toHaveLength(0);
  });

  test("only sealed Wierdr payloads with Wierdr's words go out", async () => {
    const { start } = await ready();
    const plain = JSON.stringify({ aps: { timestamp: now, event: "start", "content-state": { agents: [{ title: "secret" }] } } });
    expect((await call("/v1/start", { ...start, payload: plain })).json.error).toBe("bad_payload");
    const phishing = payload("start", { alert: { title: "Apple ID", body: "Verify your account at evil.example" } }, start.channel);
    expect((await call("/v1/start", { ...start, payload: phishing })).json.error).toBe("bad_payload");
    expect(sent).toHaveLength(0);
  });

  test("a channel: made with a device grant, then updates, an end and its deletion with its own", async () => {
    const r = await register();
    const made = await channelFor(r.json.grant);
    expect(made.status).toBe(200);
    expect(made.json.grant).toStartWith(`g2.${now + 30 * 24 * 3600}.${r.key.owner}.`);
    expect(sent[0].url).toBe("https://api-manage-broadcast.sandbox.push.apple.com:2195/1/apps/pw.xff.wierdr/channels");
    expect(JSON.parse(sent[0].body!)).toEqual({ "message-storage-policy": 0, "push-type": "LiveActivity" });
    const ch = { bundle: "pw.xff.wierdr", env: "development", channel: made.json.channel, grant: made.json.grant };
    expect((await call("/v1/broadcast", { ...ch, payload: payload("update"), priority: 5 })).status).toBe(200);
    expect(sent[1].url).toBe("https://api.sandbox.push.apple.com/4/broadcasts/apps/pw.xff.wierdr");
    expect(sent[1].headers["apns-channel-id"]).toBe(made.json.channel);
    expect(sent[1].headers["apns-expiration"]).toBe("0");
    expect(sent[1].headers["apns-priority"]).toBe("5");
    expect((await call("/v1/broadcast", { ...ch, payload: payload("end") })).status).toBe(200);
    expect((await call("/v1/channels/delete", ch)).status).toBe(200);
    expect(sent[3].method).toBe("DELETE");
    expect(sql.query("SELECT deleted FROM channels").get()).toEqual({ deleted: now });
    expect((await call("/v1/broadcast", { ...ch, grant: r.json.grant, payload: payload("update") })).json.error).toBe("bad_grant");
  });

  test("channels a key may make: 30 a day, 20 alive, 8000 for the app; a failed one costs nothing", async () => {
    const { key, json } = await register();
    reply = () => new Response(JSON.stringify({ reason: "InternalServerError" }), { status: 500 });
    expect((await channelFor(json.grant)).status).toBe(502);
    expect(sql.query("SELECT COUNT(*) AS n FROM channels").get()).toEqual({ n: 0 });
    reply = (s) => new Response(null, { status: 200, headers: { "apns-channel-id": `CHANNEL${String(++channelCount).padStart(10, "0")}ab==` } });
    const add = sql.query("INSERT INTO channels (id, env, owner, created, deleted) VALUES (?, 'development', ?, ?, ?)");
    for (let i = 0; i < 20; i++) add.run(`X${i}`, key.owner, now - 2 * 86400, null);
    expect((await channelFor(json.grant)).json.error).toBe("channel_limit");
    sql.query("UPDATE channels SET deleted = ?").run(now);
    for (let i = 0; i < 30; i++) add.run(`Y${i}`, key.owner, now - 100, now - 50);
    expect((await channelFor(json.grant)).json.error).toBe("channel_quota");
    sql.query("DELETE FROM channels").run();
    for (let i = 0; i < 8000; i++) add.run(`Z${i}`, "someone", now - 2 * 86400, null);
    expect((await channelFor(json.grant)).status).toBe(503);
  });

  test("deleting a channel APNs no longer has still counts", async () => {
    const { channel, channelGrant } = await ready();
    reply = () => new Response(JSON.stringify({ reason: "BadChannelId" }), { status: 400 });
    const r = await call("/v1/channels/delete", { bundle: "pw.xff.wierdr", env: "development", channel, grant: channelGrant });
    expect(r.status).toBe(200);
    expect(sql.query("SELECT deleted FROM channels").get()).toEqual({ deleted: now });
  });

  test("APNs refusals come back as they are (the daemon reads BadDeviceToken, Unregistered …)", async () => {
    const { start } = await ready();
    reply = () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
    const r = await call("/v1/start", start);
    expect(r.status).toBe(502);
    expect(r.json).toEqual({ error: "apns", status: 410, reason: "Unregistered" });
  });

  test("over the limit: 429", async () => {
    const { start } = await ready();
    env.LIMIT_PUSH = { limit: async () => ({ success: false }) };
    expect((await call("/v1/start", start)).status).toBe(429);
  });
});

describe("upkeep", () => {
  test("the cron deletes channels past their grant and forgets old rows", async () => {
    const add = sql.query("INSERT INTO channels (id, env, owner, created, deleted) VALUES (?, 'development', 'o', ?, ?)");
    add.run("OLD", now - 32 * 86400, null);
    add.run("NEW", now - 86400, null);
    add.run("GONE", now - 90 * 86400, now - 40 * 86400);
    expect((await sweep(env, { now: () => now, fetcher })).deleted).toBe(1);
    expect(sent.map((s) => [s.method, s.headers["apns-channel-id"]])).toEqual([["DELETE", "OLD"]]);
    expect(sql.query("SELECT id, deleted FROM channels ORDER BY id").all()).toEqual([
      { id: "NEW", deleted: null }, { id: "OLD", deleted: now },
    ]);
  });

  test("admin: APNs' channels against the ledger, unknown ones purged; no token, no route", async () => {
    sql.query("INSERT INTO channels (id, env, owner, created) VALUES ('KNOWN', 'development', 'o', ?), ('LOST', 'development', 'o', ?)").run(now, now);
    reply = (s) => s.url.endsWith("/all-channels")
      ? new Response(JSON.stringify({ channels: ["KNOWN", "STRAY1", "STRAY2"] }))
      : new Response(null, { status: 200 });
    expect((await call("/v1/admin/channels", { env: "development" })).status).toBe(404);
    const r = await call("/v1/admin/channels", { env: "development", purge: true }, { authorization: "Bearer admin token" });
    expect(r.json).toEqual({ listed: 3, live: 1, unknown: 2, purged: 2 });
    expect(sent.filter((s) => s.method === "DELETE").map((s) => s.headers["apns-channel-id"])).toEqual(["STRAY1", "STRAY2"]);
    expect(sql.query("SELECT deleted FROM channels WHERE id = 'LOST'").get()).toEqual({ deleted: now });
  });
});

describe("grants and challenges", () => {
  const s = { appId: APP_ID, kind: "device" as const, env: "development" as const, id: "abc" };
  test("a grant is bound to its app, kind, environment, id and owner", async () => {
    const { grant } = await makeGrant({ current: "k" }, s, "AAAAAAAAAAAAAAAA", 1000);
    expect((await checkGrant({ current: "k" }, grant, s, 1001)).status).toBe("ok");
    for (const other of [{ ...s, kind: "channel" as const }, { ...s, env: "production" as const }, { ...s, id: "abd" }, { ...s, appId: "X.y" }]) {
      expect((await checkGrant({ current: "k" }, grant, other, 1001)).status).toBe("bad");
    }
    expect((await checkGrant({ current: "other" }, grant, s, 1001)).status).toBe("bad");
    expect((await checkGrant({ current: "k" }, grant.replace(".AAAAAAAAAAAAAAAA.", ".BAAAAAAAAAAAAAAA."), s, 1001)).status).toBe("bad");
    expect((await checkGrant({ current: "k" }, grant.replace(/^g2\.\d+/, "g2.99999999999"), s, 1001)).status).toBe("bad");
    const rotated = await checkGrant({ current: "new", previous: "k" }, grant, s, 1001);
    expect(rotated.status === "ok" && rotated.stale).toBe(true);
  });

  test("a challenge lasts five minutes and can't be forged", async () => {
    const c = await makeChallenge({ current: "k" }, 1000);
    expect(await checkChallenge({ current: "k" }, c, 1200)).toBe(true);
    expect(await checkChallenge({ current: "k" }, c, 1400)).toBe(false);
    expect(await checkChallenge({ current: "other" }, c, 1001)).toBe(false);
    expect(await checkChallenge({ current: "new", previous: "k" }, c, 1001)).toBe(true);
    expect(await checkChallenge({ current: "k" }, c.replace(/^c1\.\d+/, "c1.1100"), 1101)).toBe(false);
  });
});

describe("payloads", () => {
  test("what Swift makes passes (test/fixtures/swift-payloads.json, from WIERDR_WRITE_FIXTURES=1 swift test)", () => {
    const f = JSON.parse(readFileSync(new URL("./fixtures/swift-payloads.json", import.meta.url), "utf8")) as Record<string, string>;
    const start = checkPayload(f.start, "start");
    expect(start.error).toBeNull();
    expect(start.error === null && start.channel).toBe(f.channel);
    for (const name of ["update", "update_alert", "end"]) expect(checkPayload(f[name], "broadcast").error).toBeNull();
    // Nothing of an agent's in the open.
    for (const name of ["start", "update", "update_alert", "end"]) {
      for (const secret of ["rm -rf", "mentoair", "wierdr", "Opus", "lf/t9"]) expect(f[name]).not.toContain(secret);
    }
  });

  test("a start, an update and an end as the daemon makes them pass", () => {
    expect(checkPayload(payload("start"), "start").error).toBeNull();
    expect(checkPayload(payload("update"), "broadcast").error).toBeNull();
    expect(checkPayload(payload("update", { alert: { title: "Needs you", body: "1 needs you · 2 working", sound: "default" } }), "broadcast").error).toBeNull();
    expect(checkPayload(payload("update", { alert: { title: "Done", body: "1 done" } }), "broadcast").error).toBeNull();
    expect(checkPayload(payload("end"), "broadcast").error).toBeNull();
  });

  test("anything else doesn't", () => {
    const cases: [string, string][] = [
      [payload("update"), "start"],
      [payload("start"), "broadcast"],
      [payload("update", { "content-state": { blocked: 1, done: 0, working: 0, idle: 0, at: 1, agents: [] } }), "broadcast"],
      [payload("update", { "content-state": { blocked: 1, done: 0, working: 0, idle: 0, at: 1, sealed: "x", kid: "ab12cd34", title: "x" } }), "broadcast"],
      [payload("update", { "content-state": { blocked: -1, done: 0, working: 0, idle: 0, at: 1, sealed: "eA==", kid: "ab12cd34" } }), "broadcast"],
      [payload("update", { "content-state": { blocked: 1.5, done: 0, working: 0, idle: 0, at: 1, sealed: "eA==", kid: "ab12cd34" } }), "broadcast"],
      [payload("update", { "content-state": { blocked: 1, done: 0, working: 0, idle: 0, at: 1, sealed: "eA==", kid: "AB12CD34" } }), "broadcast"],
      [payload("update", { "content-state": { blocked: 1, done: 0, working: 0, idle: 0, at: 1, sealed: "A".repeat(3404), kid: "ab12cd34" } }), "broadcast"],
      [payload("update", { alert: { title: "Wierdr", body: "1 working", sound: "loud" } }), "broadcast"],
      [payload("update", { alert: { title: "Needs you", body: "Allow rm -rf? — wierdr" } }), "broadcast"],
      [payload("end", { alert: { title: "Done", body: "1 done" } }), "broadcast"],
      [payload("update", { secret: "Allow rm -rf?" }), "broadcast"],
      [payload("start", { alert: undefined }), "start"],
      [payload("start", { attributes: { host: "mentoair" } }), "start"],
      [payload("start", { "input-push-channel": "" }), "start"],
      [JSON.stringify({ aps: {}, extra: 1 }), "broadcast"],
      ["{", "broadcast"],
      [payload("update", { "stale-date": "soon" }), "broadcast"],
      [payload("update", { padding: "x".repeat(5000) }), "broadcast"],
    ];
    for (const [text, kind] of cases) expect(checkPayload(text, kind as "start" | "broadcast").error).not.toBeNull();
  });
});

test("a refused grant says whose: a start carries two", async () => {
  const { start } = await ready();
  const bad = await call("/v1/start", { ...start, channel_grant: start.grant });
  expect(bad.json).toEqual({ error: "bad_grant", message: "channel grant" });
  expect((await call("/v1/start", { ...start, grant: start.channel_grant })).json.message).toBe("device grant");
});
