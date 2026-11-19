// Challenges and grants: HMAC-signed strings, so the relay keeps no state for them.
//
//   challenge  c1.<unix seconds>.<random>.<mac>       one App Attest exchange, 5 minutes
//   grant      g1.<expiry unix seconds>.<mac>        the right to push to a token or a channel
//
// A device grant is handed to an attested app for its push-to-start token; the app
// puts it in its Mac's `wierdr-push` document, so the Mac's daemon can start the
// activity there and make channels for it. A channel grant comes with each channel.
import { b64decode, b64url, equal, utf8, type Bytes } from "./bytes";

export type GrantKind = "device" | "channel";
export type APNsEnv = "development" | "production";

export const CHALLENGE_TTL = 5 * 60;
export const GRANT_TTL = 30 * 24 * 3600;

async function mac(secret: string, ...parts: string[]): Promise<Bytes> {
  const key = await crypto.subtle.importKey("raw", utf8(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, utf8(parts.join("\n"))));
}

export async function makeChallenge(secret: string, now: number): Promise<string> {
  const t = String(Math.floor(now));
  const nonce = b64url(crypto.getRandomValues(new Uint8Array(16)));
  return `c1.${t}.${nonce}.${b64url((await mac(secret, "challenge", t, nonce)).slice(0, 16))}`;
}

export async function checkChallenge(secret: string, challenge: string, now: number): Promise<boolean> {
  const [v, t, nonce, sig, ...rest] = challenge.split(".");
  if (v !== "c1" || rest.length || !t || !nonce || !sig || !/^\d+$/.test(t)) return false;
  const age = now - Number(t);
  if (age < -30 || age > CHALLENGE_TTL) return false;
  const want = (await mac(secret, "challenge", t, nonce)).slice(0, 16);
  const got = b64decode(sig);
  return !!got && equal(got, want);
}

export async function makeGrant(secret: string, kind: GrantKind, env: APNsEnv, id: string, now: number,
                                ttl = GRANT_TTL): Promise<{ grant: string; expires: number }> {
  const expires = Math.floor(now) + ttl;
  return { grant: `g1.${expires}.${b64url(await mac(secret, "grant", kind, env, id, String(expires)))}`, expires };
}

export async function checkGrant(secret: string, grant: unknown, kind: GrantKind, env: APNsEnv, id: string,
                                 now: number): Promise<"ok" | "expired" | "bad"> {
  if (typeof grant !== "string") return "bad";
  const [v, exp, sig, ...rest] = grant.split(".");
  if (v !== "g1" || rest.length || !exp || !sig || !/^\d+$/.test(exp)) return "bad";
  const got = b64decode(sig);
  if (!got || !equal(got, await mac(secret, "grant", kind, env, id, exp))) return "bad";
  return Number(exp) <= now ? "expired" : "ok";
}
