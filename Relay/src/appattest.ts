// App Attest (DeviceCheck): an attestation proves a key was made in the Secure
// Enclave of an Apple device by a genuine copy of our app; assertions signed with
// it then vouch for requests. Steps as Apple's "Validating apps that connect to your
// server" lists them.
import { concat, equal, sha256, utf8, type Bytes } from "./bytes";
import { decodeCBOR, decodeCBORAt, field, type CBOR } from "./cbor";
import { children, ecdsaRaw, importECKey, isCA, parseCertificate, readTLV, signedBy } from "./der";

export class AttestError extends Error {}

export type AttestEnv = "development" | "production";

const NONCE_OID = "1.2.840.113635.100.8.2";
const AAGUID: Record<string, AttestEnv> = {
  appattestdevelop: "development",
  "appattest\0\0\0\0\0\0\0": "production",
};
/** `apple_validation_category_01` worth trusting: TestFlight, development, App Store, ad-hoc/enterprise. */
const CATEGORIES = new Set([2, 3, 4, 5]);

/** What `authData` says (WebAuthn authenticator data, App Attest's way). */
export interface AuthData {
  rpIdHash: Bytes;
  flags: number;
  counter: number;
  aaguid?: Bytes;
  credentialId?: Bytes;
  /** `apple_validation_category_01`, `apple_bundle_version_01` (iOS 27; absent before). */
  category?: number;
  bundleVersion?: string;
}

export function parseAuthData(data: Uint8Array, attested: boolean): AuthData {
  if (data.length < 37) throw new AttestError("authData too short");
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const out: AuthData = { rpIdHash: data.slice(0, 32) as Bytes, flags: data[32], counter: view.getUint32(33) };
  let at = 37;
  if (attested) {
    if (!(out.flags & 0x40)) throw new AttestError("no attested credential");
    if (data.length < 55) throw new AttestError("authData too short");
    out.aaguid = data.slice(37, 53) as Bytes;
    const n = view.getUint16(53);
    if (data.length < 55 + n) throw new AttestError("authData too short");
    out.credentialId = data.slice(55, 55 + n) as Bytes;
    at = decodeCBORAt(data, 55 + n).end; // the COSE key: the certificate's key is the one used
  }
  if (out.flags & 0x80) {
    const { value, end } = decodeCBORAt(data, at);
    at = end;
    const category = field(value, "apple_validation_category_01");
    if (category instanceof Uint8Array && category.length > 0) {
      out.category = new DataView(category.buffer, category.byteOffset, category.byteLength).getUint32(0, true);
    } else if (typeof category === "number") {
      out.category = category;
    }
    const version = field(value, "apple_bundle_version_01");
    if (typeof version === "string") out.bundleVersion = version;
  }
  if (at !== data.length) throw new AttestError("trailing authData");
  return out;
}

function checkCategory(a: AuthData) {
  if (a.category !== undefined && !CATEGORIES.has(a.category)) {
    throw new AttestError(`validation category ${a.category}`);
  }
}

export interface Attested {
  /** The attested key, `SubjectPublicKeyInfo` DER (P-256). */
  publicKey: Bytes;
  env: AttestEnv;
  category?: number;
  bundleVersion?: string;
  /** Apple's receipt (for the fraud metric, later). */
  receipt?: Bytes;
}

/** Any failure to read or check an attestation is an `AttestError` (a 403, not a 500). */
export async function verifyAttestation(opts: Parameters<typeof attestation>[0]): Promise<Attested> {
  try {
    return await attestation(opts);
  } catch (e) {
    if (e instanceof AttestError) throw e;
    throw new AttestError(`unreadable: ${(e as Error).message}`);
  }
}

async function attestation(opts: {
  attestation: Uint8Array;
  /** The key identifier the app sends: SHA-256 of the public key. */
  keyId: Uint8Array;
  /** The one-time challenge, as the app hashed it (`clientDataHash` = SHA-256 of it). */
  challenge: Uint8Array;
  /** `<team id>.<bundle id>`. */
  appId: string;
  /** Apple App Attestation Root CA, DER. */
  root: Uint8Array;
  now: Date;
}): Promise<Attested> {
  let obj: CBOR;
  try {
    obj = decodeCBOR(opts.attestation);
  } catch (e) {
    throw new AttestError(`not CBOR: ${(e as Error).message}`);
  }
  if (field(obj, "fmt") !== "apple-appattest") throw new AttestError("not apple-appattest");
  const x5c = field(field(obj, "attStmt"), "x5c");
  const authData = field(obj, "authData");
  // App Attest sends the credential certificate and Apple's intermediate, nothing else.
  if (!Array.isArray(x5c) || x5c.length !== 2 || !x5c.every((c) => c instanceof Uint8Array)) {
    throw new AttestError("not a two-certificate chain");
  }
  if (!(authData instanceof Uint8Array)) throw new AttestError("no authData");
  const receipt = field(field(obj, "attStmt"), "receipt");

  // 1. The chain: credential certificate ← intermediate ← Apple's root; only the
  //    intermediate may be a CA, the credential certificate must not be one.
  const chain = [...(x5c as Uint8Array[]).map(parseCertificate), parseCertificate(opts.root)];
  for (let i = 0; i < chain.length; i++) {
    const c = chain[i];
    if (opts.now < c.notBefore || opts.now > c.notAfter) throw new AttestError(`certificate ${i} not valid now`);
    if (i + 1 < chain.length && !(await signedBy(c, chain[i + 1]))) {
      throw new AttestError(`certificate ${i} not signed by the next`);
    }
  }
  if (isCA(chain[0])) throw new AttestError("the credential certificate is a CA");
  if (!isCA(chain[1])) throw new AttestError("the intermediate isn't a CA");
  const cred = chain[0];

  // 2–4. The nonce in the credential certificate binds authData and the challenge.
  const nonce = await sha256(concat(authData, await sha256(opts.challenge)));
  const ext = cred.extensions.get(NONCE_OID);
  if (!ext) throw new AttestError("no nonce extension");
  const [tagged] = children(readTLV(ext));
  const [octets] = tagged ? children(tagged) : [];
  if (!octets || octets.tag !== 0x04 || !equal(octets.value, nonce)) throw new AttestError("nonce mismatch");

  // 5. The key identifier is the hash of the certificate's key.
  if (!equal(await sha256(cred.publicKey), opts.keyId)) throw new AttestError("key id mismatch");

  // 6–9. authData: our App ID, a fresh key, its environment, the same credential.
  const a = parseAuthData(authData, true);
  if (!equal(a.rpIdHash, await sha256(utf8(opts.appId)))) throw new AttestError("not our App ID");
  if (a.counter !== 0) throw new AttestError("counter not 0");
  const env = AAGUID[new TextDecoder().decode(a.aaguid)];
  if (!env) throw new AttestError("unknown aaguid");
  if (!equal(a.credentialId!, opts.keyId)) throw new AttestError("credential id mismatch");
  // 10–11. What kind of build made it (iOS 27).
  checkCategory(a);

  if (cred.curve !== "1.2.840.10045.3.1.7") throw new AttestError("not a P-256 key");
  return {
    publicKey: cred.spki, env, category: a.category, bundleVersion: a.bundleVersion,
    receipt: receipt instanceof Uint8Array ? (receipt as Bytes) : undefined,
  };
}

/** Checks an assertion over `clientData`; returns its counter (which must have grown). */
export async function verifyAssertion(opts: {
  assertion: Uint8Array;
  clientData: Uint8Array;
  /** The attested key, `SubjectPublicKeyInfo` DER. */
  publicKey: Uint8Array;
  appId: string;
  previousCounter: number;
}): Promise<{ counter: number; category?: number; bundleVersion?: string }> {
  try {
    return await assertion(opts);
  } catch (e) {
    if (e instanceof AttestError) throw e;
    throw new AttestError(`unreadable: ${(e as Error).message}`);
  }
}

async function assertion(opts: Parameters<typeof verifyAssertion>[0]) {
  let obj: CBOR;
  try {
    obj = decodeCBOR(opts.assertion);
  } catch (e) {
    throw new AttestError(`not CBOR: ${(e as Error).message}`);
  }
  const signature = field(obj, "signature");
  const authData = field(obj, "authenticatorData");
  if (!(signature instanceof Uint8Array) || !(authData instanceof Uint8Array)) throw new AttestError("bad assertion");
  // The key signs nonce = SHA-256(authenticatorData ‖ SHA-256(clientData)) (ECDSA with SHA-256 over it).
  const nonce = await sha256(concat(authData, await sha256(opts.clientData)));
  const key = await importECKey(opts.publicKey, "1.2.840.10045.3.1.7");
  let ok = false;
  try {
    ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, ecdsaRaw(signature, 32), nonce);
  } catch {
    ok = false;
  }
  if (!ok) throw new AttestError("bad signature");
  const a = parseAuthData(authData, false);
  if (!equal(a.rpIdHash, await sha256(utf8(opts.appId)))) throw new AttestError("not our App ID");
  if (a.counter <= opts.previousCounter) throw new AttestError("counter didn't grow");
  checkCategory(a);
  return { counter: a.counter, category: a.category, bundleVersion: a.bundleVersion };
}
