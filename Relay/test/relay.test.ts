import { Database as SQLite } from "bun:sqlite";
import { beforeEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resetTokenCache } from "../src/apns";
import { b64decode, b64encode, concat, sha256, utf8 } from "../src/bytes";
import { checkChallenge, checkGrant, makeChallenge, makeGrant } from "../src/grants";
import { checkPayload } from "../src/payload";
import { handle, type Database, type Env, type RateLimiter } from "../src/index";

// MARK: Fakes

/** D1 over bun:sqlite, with the relay's schema. */
function database(): { db: Database; sql: SQLite } {
  const sql = new SQLite(":memory:");
  sql.exec(readFileSync(new URL("../schema.sql", import.meta.url), "utf8"));
  const db: Database = {
    prepare: (q) => ({
      bind: (...values) => ({
        first: async <T>() => (sql.query(q).get(...(values as never[])) as T) ?? null,
        run: async () => ({ meta: { changes: sql.query(q).run(...(values as never[])).changes } }),
      }),
    }),
  };
  return { db, sql };
}

const allow: RateLimiter = { limit: async () => ({ success: true }) };

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

const fetcher = (async (url: string, init: RequestInit) => {
  const s: Sent = { url, method: init.method ?? "GET", headers: init.headers as Record<string, string>, body: init.body as string };
  sent.push(s);
  return reply(s);
}) as unknown as typeof fetch;

async function p8(): Promise<string> {
  const k = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", k.privateKey));
  return `-----BEGIN PRIVATE KEY-----\n${b64encode(der)}\n-----END PRIVATE KEY-----\n`;
}

beforeEach(async () => {
  const d = database();
  sql = d.sql;
  sent = [];
  reply = (s) => new Response(null, { status: 200, headers: s.url.includes("/channels") ? { "apns-channel-id": "CHANNEL123456789abc==" } : {} });
  now = 1_800_000_000;
  resetTokenCache();
  env = {
    DB: d.db, LIMIT_APP: allow, LIMIT_PUSH: allow, APNS_KEY: await p8(), APNS_KEY_ID: "KEY1234567", TEAM_ID: "AUL4CCB2XY",
    BUNDLE: "pw.xff.wierdr", RELAY_SECRET: "test secret",
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
    n < 24 ? [major << 5 | n] : n < 256 ? [major << 5 | 24, n] : [major << 5 | 25, n >> 8, n & 255];
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

async function attestedKey(apnsEnv = "development") {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", pair.publicKey));
  const keyId = b64encode(crypto.getRandomValues(new Uint8Array(32)));
  sql.query("INSERT INTO attest_keys VALUES (?, ?, ?, 0, 0, 0)").run(keyId, b64encode(spki), apnsEnv);
  let counter = 0;
  return {
    keyId,
    /** The assertion App Attest would make over `clientData`. */
    async assert(clientData: string, count = ++counter): Promise<string> {
      const authData = concat(await sha256(utf8("AUL4CCB2XY.pw.xff.wierdr")), new Uint8Array([0x40, 0, 0, 0, count]));
      const nonce = await sha256(concat(authData, await sha256(utf8(clientData))));
      const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, nonce));
      return b64encode(cbor({ signature: der(sig), authenticatorData: authData }));
    },
  };
}

const token = "80777b53e4b407886b965da507d10e3d1052b1fe3d6e9b38f6a95fe42116941cf75e59ff663b93cea18a46b6e5c85d986d36df9b79b900a7b2db76cb88d4680b4";

async function register(keyEnv = "development", apnsEnv = "development") {
  const key = await attestedKey(keyEnv);
  const { json: c } = await call("/v1/challenge", {});
  const body = JSON.stringify({ challenge: c.challenge, key_id: key.keyId, token, env: apnsEnv });
  return { key, body, ...(await call("/v1/devices", body, { "x-wierdr-assertion": await key.assert(body) })) };
}

/** A payload as WierdrPush/Payloads.swift makes them (sealed). */
function payload(event: "start" | "update" | "end", extra: Record<string, unknown> = {}) {
  const aps: Record<string, unknown> = {
    timestamp: now, event, "content-state": { blocked: 1, done: 0, working: 2, idle: 3, at: now, sealed: "c2VhbGVk", kid: "ab12cd34" },
    ...(event === "end" ? { "dismissal-date": now } : { "stale-date": now + 1500 }),
  };
  if (event === "start") {
    Object.assign(aps, {
      "input-push-channel": "CHANNEL123456789abc==", "attributes-type": "AgentsActivityAttributes",
      attributes: { sealed: "c2VhbGVk", kid: "ab12cd34" }, alert: { title: "Wierdr", body: "1 needs you · 2 working", sound: "default" },
    });
  }
  return JSON.stringify({ aps: { ...aps, ...extra } });
}

// MARK: Tests

describe("the app's registration", () => {
  test("an attested key's assertion gets a grant for the token", async () => {
    const r = await register();
    expect(r.status).toBe(200);
    expect(await checkGrant("test secret", r.json.grant, "device", "development", token, now)).toBe("ok");
    expect(r.json.expires).toBe(now + 30 * 24 * 3600);
  });

  test("the same assertion twice is refused (the counter)", async () => {
    const { key, body } = await register();
    const again = await call("/v1/devices", body, { "x-wierdr-assertion": await key.assert(body, 1) });
    expect(again.status).toBe(403);
    expect(again.json.error).toBe("bad_assertion");
  });

  test("an assertion over other data is refused", async () => {
    const key = await attestedKey();
    const { json: c } = await call("/v1/challenge", {});
    const body = JSON.stringify({ challenge: c.challenge, key_id: key.keyId, token, env: "development" });
    const r = await call("/v1/devices", body, { "x-wierdr-assertion": await key.assert(body.replace("development", "production")) });
    expect(r.json.error).toBe("bad_assertion");
  });

  test("a key the relay never saw attested must attest first", async () => {
    const { json: c } = await call("/v1/challenge", {});
    const body = JSON.stringify({ challenge: c.challenge, key_id: b64encode(new Uint8Array(32)), token, env: "development" });
    const r = await call("/v1/devices", body, { "x-wierdr-assertion": "AA==" });
    expect(r.status).toBe(401);
    expect(r.json.error).toBe("unknown_key");
  });

  test("a production key (Xcode's export attests in production) gets a development grant", async () => {
    expect((await register("production")).status).toBe(200);
  });

  test("a development key gets no production grant", async () => {
    const key = await attestedKey("development");
    const { json: c } = await call("/v1/challenge", {});
    const body = JSON.stringify({ challenge: c.challenge, key_id: key.keyId, token, env: "production" });
    const r = await call("/v1/devices", body, { "x-wierdr-assertion": await key.assert(body) });
    expect(r.json.error).toBe("env_mismatch");
  });

  test("an old challenge is refused", async () => {
    const key = await attestedKey();
    const { json: c } = await call("/v1/challenge", {});
    now += 600;
    const body = JSON.stringify({ challenge: c.challenge, key_id: key.keyId, token, env: "development" });
    expect((await call("/v1/devices", body, { "x-wierdr-assertion": await key.assert(body) })).json.error).toBe("bad_challenge");
  });

  test("an attestation that doesn't verify is refused", async () => {
    const { json: c } = await call("/v1/challenge", {});
    const r = await call("/v1/attest", { challenge: c.challenge, key_id: b64encode(new Uint8Array(32)), attestation: "oA==" });
    expect(r.status).toBe(403);
    expect(r.json.error).toBe("bad_attestation");
  });
});

describe("the daemon's pushes", () => {
  test("a start goes to APNs with its token, topic, type and a provider token", async () => {
    const { json: g } = await register();
    const r = await call("/v1/start", { env: "development", token, grant: g.grant, payload: payload("start"), priority: 10 });
    expect(r.status).toBe(200);
    expect(sent).toHaveLength(1);
    expect(sent[0].url).toBe(`https://api.sandbox.push.apple.com/3/device/${token}`);
    expect(sent[0].headers["apns-topic"]).toBe("pw.xff.wierdr.push-type.liveactivity");
    expect(sent[0].headers["apns-push-type"]).toBe("liveactivity");
    expect(sent[0].headers["apns-priority"]).toBe("10");
    expect(sent[0].body).toBe(payload("start"));
    const jwt = sent[0].headers.authorization.replace("bearer ", "");
    const [h, c] = jwt.split(".").slice(0, 2).map((p) => JSON.parse(new TextDecoder().decode(b64decode(p)!)));
    expect(h).toEqual({ alg: "ES256", kid: "KEY1234567" });
    expect(c.iss).toBe("AUL4CCB2XY");
  });

  test("the provider token is reused within its half hour, then renewed", async () => {
    const { json: g } = await register();
    const start = { env: "development", token, grant: g.grant, payload: payload("start") };
    now = Math.floor(now / 1800) * 1800 + 10;
    await call("/v1/start", start);
    resetTokenCache(); // another isolate: it finds the token in D1
    await call("/v1/start", start);
    now += 1800;
    await call("/v1/start", start);
    const tokens = sent.map((s) => s.headers.authorization);
    expect(tokens[0]).toBe(tokens[1]);
    expect(tokens[2]).not.toBe(tokens[0]);
  });

  test("no grant, no push; another token's grant neither", async () => {
    const start = { env: "development", token, payload: payload("start") };
    expect((await call("/v1/start", { ...start, grant: "g1.9999999999.AAAA" })).json.error).toBe("bad_grant");
    const other = await makeGrant("test secret", "device", "development", "ab".repeat(40), now);
    expect((await call("/v1/start", { ...start, grant: other.grant })).json.error).toBe("bad_grant");
    const old = await makeGrant("test secret", "device", "development", token, now - 31 * 24 * 3600);
    expect((await call("/v1/start", { ...start, grant: old.grant })).json.error).toBe("grant_expired");
    expect(sent).toHaveLength(0);
  });

  test("only sealed Wierdr payloads go out", async () => {
    const { json: g } = await register();
    const plain = JSON.stringify({ aps: { timestamp: now, event: "start", "content-state": { agents: [{ title: "secret" }] } } });
    const r = await call("/v1/start", { env: "development", token, grant: g.grant, payload: plain });
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("bad_payload");
    expect(sent).toHaveLength(0);
  });

  test("a channel: made with a device grant, then updates, an end and its deletion with its own", async () => {
    const { json: g } = await register();
    const made = await call("/v1/channels", { env: "development", token, grant: g.grant });
    expect(made.status).toBe(200);
    expect(made.json.channel).toBe("CHANNEL123456789abc==");
    expect(sent[0].url).toBe("https://api-manage-broadcast.sandbox.push.apple.com:2195/1/apps/pw.xff.wierdr/channels");
    expect(JSON.parse(sent[0].body!)).toEqual({ "message-storage-policy": 0, "push-type": "LiveActivity" });
    const ch = { env: "development", channel: made.json.channel, grant: made.json.grant };
    expect((await call("/v1/broadcast", { ...ch, payload: payload("update"), priority: 5 })).status).toBe(200);
    expect(sent[1].url).toBe("https://api.sandbox.push.apple.com/4/broadcasts/apps/pw.xff.wierdr");
    expect(sent[1].headers["apns-channel-id"]).toBe("CHANNEL123456789abc==");
    expect(sent[1].headers["apns-expiration"]).toBe("0");
    expect(sent[1].headers["apns-priority"]).toBe("5");
    expect((await call("/v1/broadcast", { ...ch, payload: payload("end") })).status).toBe(200);
    expect((await call("/v1/channels/delete", ch)).status).toBe(200);
    expect(sent[3].method).toBe("DELETE");
    // The device grant isn't a channel's.
    expect((await call("/v1/broadcast", { ...ch, grant: g.grant, payload: payload("update") })).json.error).toBe("bad_grant");
  });

  test("a device makes at most 100 channels a day", async () => {
    const { json: g } = await register();
    const device = (await call("/v1/channels", { env: "development", token, grant: g.grant })).status;
    expect(device).toBe(200);
    sql.query("UPDATE channel_quota SET n = 100").run();
    const r = await call("/v1/channels", { env: "development", token, grant: g.grant });
    expect(r.status).toBe(429);
    expect(r.json.error).toBe("channel_quota");
  });

  test("APNs refusals come back as they are (the daemon reads BadDeviceToken, Unregistered …)", async () => {
    const { json: g } = await register();
    reply = () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
    const r = await call("/v1/start", { env: "development", token, grant: g.grant, payload: payload("start") });
    expect(r.status).toBe(502);
    expect(r.json).toEqual({ error: "apns", status: 410, reason: "Unregistered" });
  });

  test("over the limit: 429", async () => {
    const { json: g } = await register();
    env.LIMIT_PUSH = { limit: async () => ({ success: false }) };
    expect((await call("/v1/start", { env: "development", token, grant: g.grant, payload: payload("start") })).status).toBe(429);
  });
});

describe("grants and challenges", () => {
  test("a grant is bound to its kind, environment and id", async () => {
    const { grant } = await makeGrant("s", "device", "development", "abc", 1000);
    expect(await checkGrant("s", grant, "device", "development", "abc", 1001)).toBe("ok");
    expect(await checkGrant("s", grant, "channel", "development", "abc", 1001)).toBe("bad");
    expect(await checkGrant("s", grant, "device", "production", "abc", 1001)).toBe("bad");
    expect(await checkGrant("s", grant, "device", "development", "abd", 1001)).toBe("bad");
    expect(await checkGrant("other", grant, "device", "development", "abc", 1001)).toBe("bad");
    expect(await checkGrant("s", grant.replace(/^g1\.\d+/, "g1.99999999999"), "device", "development", "abc", 1001)).toBe("bad");
  });

  test("a challenge lasts five minutes and can't be forged", async () => {
    const c = await makeChallenge("s", 1000);
    expect(await checkChallenge("s", c, 1200)).toBe(true);
    expect(await checkChallenge("s", c, 1400)).toBe(false);
    expect(await checkChallenge("other", c, 1001)).toBe(false);
    expect(await checkChallenge("s", c.replace(/^c1\.\d+/, "c1.1100"), 1101)).toBe(false);
  });
});

describe("payloads", () => {
  test("a start, an update and an end as the daemon makes them pass", () => {
    expect(checkPayload(payload("start"), "start")).toBeNull();
    expect(checkPayload(payload("update"), "broadcast")).toBeNull();
    expect(checkPayload(payload("update", { alert: { title: "Needs you", body: "1 needs you", sound: "default" } }), "broadcast")).toBeNull();
    expect(checkPayload(payload("end"), "broadcast")).toBeNull();
  });

  test("anything else doesn't", () => {
    const cases: [string, string][] = [
      [payload("update"), "start"],
      [payload("start"), "broadcast"],
      [payload("update", { "content-state": { blocked: 1, done: 0, working: 0, idle: 0, at: 1, agents: [] } }), "broadcast"],
      [payload("update", { "content-state": { blocked: 1, done: 0, working: 0, idle: 0, at: 1, sealed: "x", kid: "ab12cd34", title: "x" } }), "broadcast"],
      [payload("update", { alert: { title: "x".repeat(65), body: "" } }), "broadcast"],
      [payload("update", { secret: "Allow rm -rf?" }), "broadcast"],
      [payload("start", { attributes: { host: "mentoair" } }), "start"],
      [JSON.stringify({ aps: {}, extra: 1 }), "broadcast"],
      ["{", "broadcast"],
      [payload("update", { "stale-date": "soon" }), "broadcast"],
    ];
    for (const [text, kind] of cases) expect(checkPayload(text, kind as "start" | "broadcast")).not.toBeNull();
  });
});
