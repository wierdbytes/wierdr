// APNs for the relay: token auth (an ES256 JWT from the team's .p8 key) and the four
// calls the Mac's daemon makes (WierdrPush/APNs.swift): push-to-start to a device
// token, broadcast on a channel, create and delete a channel. Workers' fetch goes out
// over HTTP/2 in production (APNs speaks nothing else); local `wrangler dev` can't.
import { b64url, pemBody, utf8 } from "./bytes";
import type { APNsEnv } from "./grants";

export interface APNsConfig {
  /** The `.p8` key, PEM. */
  key: string;
  keyId: string;
  teamId: string;
  bundle: string;
}

/** Where a JWT is kept between isolates: APNs refuses a provider token renewed more
 *  often than every 20 minutes (`TooManyProviderTokenUpdates`). `offer` keeps the first
 *  token of a window (and key) and returns whichever is kept; `clear` drops it. */
export interface TokenStore {
  get(): Promise<StoredToken | null>;
  offer(t: StoredToken): Promise<StoredToken | null>;
  clear(): Promise<void>;
}

export interface StoredToken {
  kid: string;
  iat: number;
  token: string;
}

export class APNsFailure extends Error {
  constructor(readonly status: number, readonly reason: string) {
    super(`APNs ${status} ${reason}`);
  }
}

/** A JWT lasts its 30-minute window: every isolate in it signs the same claims, and the
 *  first one's token is shared through the store. */
const WINDOW = 30 * 60;
let cached: StoredToken | null = null;
/** How long a push-to-start may wait in APNs for a phone that's off line. */
const START_EXPIRATION = 10 * 60;

export class APNs {
  constructor(
    readonly config: APNsConfig,
    readonly store: TokenStore,
    readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    readonly now: () => number = () => Date.now() / 1000,
  ) {}

  async token(): Promise<string> {
    const iat = Math.floor(this.now() / WINDOW) * WINDOW;
    const kid = this.config.keyId;
    const fits = (t: StoredToken | null): t is StoredToken => !!t && t.iat === iat && t.kid === kid;
    if (fits(cached)) return cached.token;
    const stored = await this.store.get();
    if (fits(stored)) {
      cached = stored;
      return stored.token;
    }
    const key = await crypto.subtle.importKey("pkcs8", pemBody(this.config.key), { name: "ECDSA", namedCurve: "P-256" },
                                              false, ["sign"]);
    const input = `${b64url(utf8(JSON.stringify({ alg: "ES256", kid: this.config.keyId })))}.${b64url(
      utf8(JSON.stringify({ iss: this.config.teamId, iat })),
    )}`;
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(input)));
    const mine = { kid, iat, token: `${input}.${b64url(sig)}` };
    // Two isolates in the same window: the first one stored wins, and both use it.
    const kept = await this.store.offer(mine);
    cached = fits(kept) ? kept : mine;
    return cached.token;
  }

  private host(env: APNsEnv) {
    return env === "development" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  }

  private manage(env: APNsEnv) {
    return env === "development"
      ? "https://api-manage-broadcast.sandbox.push.apple.com:2195"
      : "https://api-manage-broadcast.push.apple.com:2196";
  }

  private async send(url: string, init: { method?: string; headers: Record<string, string>; body?: string }): Promise<Response> {
    const send = this.fetcher; // not as a method: Workers' fetch wants no `this`
    const r = await send(url, {
      method: init.method ?? "POST",
      headers: { authorization: `bearer ${await this.token()}`, ...init.headers },
      body: init.body,
    });
    if (r.status >= 200 && r.status < 300) return r;
    const text = await r.text();
    let reason = text.slice(0, 200);
    try {
      reason = (JSON.parse(text) as { reason?: string }).reason ?? reason;
    } catch {}
    if (reason === "InvalidProviderToken" || reason === "ExpiredProviderToken") {
      // A token APNs won't take: the next call signs a new one.
      cached = null;
      await this.store.clear();
    }
    throw new APNsFailure(r.status, reason);
  }

  async start(env: APNsEnv, token: string, payload: string, priority: number): Promise<void> {
    await this.send(`${this.host(env)}/3/device/${token}`, {
      headers: {
        "apns-topic": `${this.config.bundle}.push-type.liveactivity`,
        "apns-push-type": "liveactivity",
        "apns-priority": String(priority),
        "apns-expiration": String(Math.floor(this.now()) + START_EXPIRATION),
      },
      body: payload,
    });
  }

  /** An update or end on a channel that stores nothing (`apns-expiration: 0`). */
  async broadcast(env: APNsEnv, channel: string, payload: string, priority: number): Promise<void> {
    await this.send(`${this.host(env)}/4/broadcasts/apps/${this.config.bundle}`, {
      headers: {
        "apns-channel-id": channel,
        "apns-push-type": "liveactivity",
        "apns-priority": String(priority),
        "apns-expiration": "0",
      },
      body: payload,
    });
  }

  async createChannel(env: APNsEnv): Promise<string> {
    const r = await this.send(`${this.manage(env)}/1/apps/${this.config.bundle}/channels`, {
      headers: {},
      body: JSON.stringify({ "message-storage-policy": 0, "push-type": "LiveActivity" }),
    });
    const id = r.headers.get("apns-channel-id");
    if (!id) throw new APNsFailure(r.status, "NoChannelId");
    return id;
  }

  /** Every channel the app has in `env` (APNs' `all-channels`). */
  async listChannels(env: APNsEnv): Promise<string[]> {
    const r = await this.send(`${this.manage(env)}/1/apps/${this.config.bundle}/all-channels`, {
      method: "GET",
      headers: {},
    });
    const body = (await r.json()) as { channels?: unknown };
    return Array.isArray(body.channels) ? body.channels.filter((c): c is string => typeof c === "string") : [];
  }

  async deleteChannel(env: APNsEnv, channel: string): Promise<void> {
    await this.send(`${this.manage(env)}/1/apps/${this.config.bundle}/channels`, {
      method: "DELETE",
      headers: { "apns-channel-id": channel },
    });
  }
}

/** Forget the isolate's token (tests). */
export function resetTokenCache() {
  cached = null;
}
