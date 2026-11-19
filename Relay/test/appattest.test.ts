import { describe, expect, test } from "bun:test";
import { AttestError, parseAuthData, verifyAssertion, verifyAttestation } from "../src/appattest";
import { b64decode, equal, pemBody, sha256, utf8, type Bytes } from "../src/bytes";
import { decodeCBOR, field } from "../src/cbor";
import { parseCertificate } from "../src/der";
import { APP_ATTEST_ROOT } from "../src/roots";
import vectors from "./fixtures/appattest.json";

const root = pemBody(APP_ATTEST_ROOT);

function chain(attestation: Uint8Array): Bytes[] {
  return field(field(decodeCBOR(attestation), "attStmt"), "x5c") as Bytes[];
}

async function real(name: "ios27_debug" | "ios27_release") {
  const v = vectors[name];
  const attestation = b64decode(v.attestation)!;
  const keyId = await sha256(parseCertificate(chain(attestation)[0]).publicKey);
  return { attestation, keyId, challenge: utf8(v.challenge), appId: v.app_id, root, now: new Date(v.at) };
}

describe("attestation (real ones, iOS 27)", () => {
  test("a development build's checks out: its key, category and bundle version", async () => {
    const o = await real("ios27_debug");
    const r = await verifyAttestation(o);
    expect(r.env).toBe("development");
    expect(r.category).toBe(3);
    expect(r.bundleVersion).toBe("1");
    expect(equal(r.publicKey, parseCertificate(chain(o.attestation)[0]).spki)).toBe(true);
  });

  test("a release build's too (no extensions)", async () => {
    const r = await verifyAttestation(await real("ios27_release"));
    expect(r.env).toBe("development");
    expect(r.category).toBeUndefined();
  });

  const refusals: [string, (o: Awaited<ReturnType<typeof real>>) => void, string][] = [
    ["another challenge", (o) => (o.challenge = utf8("not it")), "nonce mismatch"],
    ["another app", (o) => (o.appId = "AUL4CCB2XY.pw.xff.wierdr"), "not our App ID"],
    ["another key id", (o) => (o.keyId = new Uint8Array(32) as Bytes), "key id mismatch"],
    ["an expired chain", (o) => (o.now = new Date("2030-01-01")), "not valid now"],
    ["another root", (o) => (o.root = chain(o.attestation)[1]), "not signed by the next"],
  ];
  for (const [name, change, message] of refusals) {
    test(`is refused for ${name}`, async () => {
      const o = await real("ios27_debug");
      change(o);
      expect(verifyAttestation(o)).rejects.toThrow(message);
    });
  }

  test("a tampered one is refused", async () => {
    const o = await real("ios27_debug");
    const bad = o.attestation.slice();
    bad[bad.length - 40] ^= 1; // inside authData
    o.attestation = bad;
    expect(verifyAttestation(o)).rejects.toBeInstanceOf(AttestError);
  });
});

describe("assertion (a real one)", () => {
  const v = vectors.assertion;
  const [h, p, s] = v.jwt.split(".");
  const publicKey = parseCertificate(pemBody(v.cert)).spki;
  const base = { assertion: b64decode(s)!, clientData: utf8(`${h}.${p}`), publicKey, appId: v.app_id, previousCounter: 0 };

  test("checks out over its client data", async () => {
    expect((await verifyAssertion(base)).counter).toBe(1);
  });
  test("not over other data", async () => {
    expect(verifyAssertion({ ...base, clientData: utf8("other") })).rejects.toThrow("bad signature");
  });
  test("not twice (its counter must grow)", async () => {
    expect(verifyAssertion({ ...base, previousCounter: 1 })).rejects.toThrow("counter");
  });
  test("not for another app", async () => {
    expect(verifyAssertion({ ...base, appId: "AUL4CCB2XY.pw.xff.wierdr" })).rejects.toThrow("App ID");
  });
});

test("iOS 27's authData extensions", () => {
  const hex =
    "4eb12f0f254ec95897e10fc295ff0b7138007a58d514fe3a659efbcac7e5855ac000000001a2776170706c655f62756e646c655f76657273696f6e5f30316131781c6170706c655f76616c69646174696f6e5f63617465676f72795f30314403000000";
  const a = parseAuthData(new Uint8Array(hex.match(/../g)!.map((b) => parseInt(b, 16))), false);
  expect(a.counter).toBe(1);
  expect(a.category).toBe(3);
  expect(a.bundleVersion).toBe("1");
});

describe("the chain's shape", () => {
  /** The attestation with its x5c replaced. */
  async function withChain(x5c: Uint8Array[]) {
    const o = await real("ios27_debug");
    const map = decodeCBOR(o.attestation) as Map<unknown, unknown>;
    // Re-encode: fmt, attStmt {x5c, receipt}, authData (definite lengths).
    const enc = (v: unknown): number[] => {
      const head = (major: number, n: number) =>
        n < 24 ? [(major << 5) | n] : n < 256 ? [(major << 5) | 24, n] : n < 65536 ? [(major << 5) | 25, n >> 8, n & 255]
          : [(major << 5) | 26, (n >>> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255];
      if (typeof v === "string") { const b = utf8(v); return [...head(3, b.length), ...b]; }
      if (v instanceof Uint8Array) return [...head(2, v.length), ...v];
      if (Array.isArray(v)) return [...head(4, v.length), ...v.flatMap(enc)];
      if (v instanceof Map) return [...head(5, v.size), ...[...v].flatMap(([k, x]) => [...enc(k), ...enc(x)])];
      throw new Error("unsupported");
    };
    const stmt = map.get("attStmt") as Map<unknown, unknown>;
    stmt.set("x5c", x5c);
    o.attestation = new Uint8Array(enc(map)) as Bytes;
    return o;
  }

  test("re-encoded unchanged it still checks out (the encoder is right)", async () => {
    const o = await real("ios27_debug");
    await verifyAttestation(await withChain(chain(o.attestation)));
  });

  test("a chain of three (a leaf posing as an issuer) is refused", async () => {
    const o = await real("ios27_debug");
    const [leaf, intermediate] = chain(o.attestation);
    expect(verifyAttestation(await withChain([leaf, leaf, intermediate]))).rejects.toThrow("two-certificate");
  });

  test("garbage certificates are an AttestError, not a crash", async () => {
    const o = await real("ios27_debug");
    expect(verifyAttestation(await withChain([new Uint8Array([0x30, 0x03, 1, 2, 3]), chain(o.attestation)[1]])))
      .rejects.toBeInstanceOf(AttestError);
  });
});
