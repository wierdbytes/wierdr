// Challenges and grants: HMAC-signed strings, so the relay keeps no state for them.
//
//   challenge  c1.<unix seconds>.<random>.<mac>             one App Attest exchange, 5 minutes
//   grant      g2.<expiry unix seconds>.<owner>.<mac>       the right to push to a token or a channel
//
// `owner` is the App Attest key a grant was given to (its hash): a device grant comes
// from that key's assertion, a channel grant from a device grant of it. So limits count
// per key and revoking a key voids everything it got. The MAC covers the version, the
// App ID, the kind, the APNs environment, the token or channel, the owner and the expiry.
//
// Secrets: grants are made with the current one; one signed with the previous one
// (`RELAY_SECRET_PREVIOUS`, while rotating) still holds, marked stale so the app renews it.
import { b64decode, b64url, equal, sha256, utf8, type Bytes } from "./bytes";

export type GrantKind = "device" | "channel";
export type APNsEnv = "development" | "production";

export interface Secrets {
  current: string;
  previous?: string;
}

export const CHALLENGE_TTL = 5 * 60;
export const GRANT_TTL = 30 * 24 * 3600;

async function mac(secret: string, ...parts: string[]): Promise<Bytes> {
  const key = await crypto.subtle.importKey("raw", utf8(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, utf8(parts.join("\n"))));
}

const secretsOf = (s: Secrets) => [s.current, ...(s.previous ? [s.previous] : [])];

/** A key's owner id: 96 bits of the SHA-256 of its identifier, base64url. */
export async function ownerOf(keyId: Uint8Array): Promise<string> {
  return b64url(await sha256(keyId)).slice(0, 16);
}

export async function makeChallenge(secrets: Secrets, now: number): Promise<string> {
  const t = String(Math.floor(now));
  const nonce = b64url(crypto.getRandomValues(new Uint8Array(16)));
  return `c1.${t}.${nonce}.${b64url((await mac(secrets.current, "challenge", t, nonce)).slice(0, 16))}`;
}

export async function checkChallenge(secrets: Secrets, challenge: string, now: number): Promise<boolean> {
  const [v, t, nonce, sig, ...rest] = challenge.split(".");
  if (v !== "c1" || rest.length || !t || !nonce || !sig || !/^\d+$/.test(t)) return false;
  const age = now - Number(t);
  if (age < -30 || age > CHALLENGE_TTL) return false;
  const got = b64decode(sig);
  if (!got) return false;
  for (const secret of secretsOf(secrets)) {
    if (equal(got, (await mac(secret, "challenge", t, nonce)).slice(0, 16))) return true;
  }
  return false;
}

export interface GrantSubject {
  appId: string;
  kind: GrantKind;
  env: APNsEnv;
  /** The device token (lowercase hex) or channel id. */
  id: string;
}

const grantMac = (secret: string, s: GrantSubject, owner: string, exp: string) =>
  mac(secret, "wierdr-relay/grant/2", s.appId, s.kind, s.env, s.id, owner, exp);

export async function makeGrant(secrets: Secrets, subject: GrantSubject, owner: string, now: number,
                                ttl = GRANT_TTL): Promise<{ grant: string; expires: number }> {
  const expires = Math.floor(now) + ttl;
  const sig = b64url(await grantMac(secrets.current, subject, owner, String(expires)));
  return { grant: `g2.${expires}.${owner}.${sig}`, expires };
}

export type GrantCheck =
  | { status: "ok" | "expired"; owner: string; expires: number; stale: boolean }
  | { status: "bad" };

export async function checkGrant(secrets: Secrets, grant: unknown, subject: GrantSubject, now: number): Promise<GrantCheck> {
  if (typeof grant !== "string") return { status: "bad" };
  const [v, exp, owner, sig, ...rest] = grant.split(".");
  if (v !== "g2" || rest.length || !exp || !owner || !sig || !/^\d+$/.test(exp) || !/^[A-Za-z0-9_-]{16}$/.test(owner)) {
    return { status: "bad" };
  }
  const got = b64decode(sig);
  if (!got) return { status: "bad" };
  const all = secretsOf(secrets);
  for (let i = 0; i < all.length; i++) {
    if (equal(got, await grantMac(all[i], subject, owner, exp))) {
      return { status: Number(exp) <= now ? "expired" : "ok", owner, expires: Number(exp), stale: i > 0 };
    }
  }
  return { status: "bad" };
}
