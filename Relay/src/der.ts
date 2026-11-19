// A small DER reader and the X.509 parts App Attest needs: the signed part, the
// signature and its algorithm, the public key, validity and extensions; ECDSA
// signature checks with WebCrypto.
import type { Bytes } from "./bytes";

export class DERError extends Error {}

export interface TLV {
  /** The identifier octet(s) as read: class, constructed bit and tag number. */
  tag: number;
  /** The whole element (header and content). */
  raw: Bytes;
  /** The content. */
  value: Bytes;
}

/** Reads one element at `offset`. */
export function readTLV(bytes: Uint8Array, offset = 0): TLV & { end: number } {
  let at = offset;
  const need = (n: number) => {
    if (at + n > bytes.length) throw new DERError("truncated");
  };
  need(2);
  let tag = bytes[at++];
  if ((tag & 0x1f) === 0x1f) {
    // High tag number: base-128, kept as the bytes read.
    let b: number;
    do {
      need(1);
      b = bytes[at++];
      tag = tag * 256 + b;
    } while (b & 0x80);
  }
  need(1);
  let length = bytes[at++];
  if (length & 0x80) {
    const n = length & 0x7f;
    if (n === 0 || n > 4) throw new DERError("bad length");
    need(n);
    length = 0;
    for (let i = 0; i < n; i++) length = length * 256 + bytes[at++];
  }
  need(length);
  const end = at + length;
  return { tag, raw: bytes.slice(offset, end) as Bytes, value: bytes.slice(at, end) as Bytes, end };
}

/** The elements inside a constructed one. */
export function children(t: TLV): TLV[] {
  const out: TLV[] = [];
  let at = 0;
  while (at < t.value.length) {
    const c = readTLV(t.value, at);
    out.push(c);
    at = c.end;
  }
  return out;
}

export function oid(t: TLV): string {
  if (t.tag !== 0x06) throw new DERError("not an OID");
  const v = t.value;
  const parts: number[] = [];
  let n = 0;
  for (let i = 0; i < v.length; i++) {
    n = n * 128 + (v[i] & 0x7f);
    if (!(v[i] & 0x80)) {
      if (parts.length === 0) parts.push(n < 80 ? Math.floor(n / 40) : 2, n < 80 ? n % 40 : n - 80);
      else parts.push(n);
      n = 0;
    }
  }
  return parts.join(".");
}

function time(t: TLV): Date {
  const s = new TextDecoder().decode(t.value);
  const m =
    t.tag === 0x17
      ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s)
      : /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s);
  if (!m) throw new DERError(`bad time ${s}`);
  let year = Number(m[1]);
  if (t.tag === 0x17) year += year < 50 ? 2000 : 1900;
  return new Date(Date.UTC(year, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])));
}

export interface Certificate {
  tbs: Bytes;
  signatureAlgorithm: string;
  /** DER `ECDSA-Sig-Value`. */
  signature: Bytes;
  /** `SubjectPublicKeyInfo`, whole (WebCrypto's `spki`). */
  spki: Bytes;
  /** The key's curve OID. */
  curve: string;
  /** The public key bits (X9.62 point). */
  publicKey: Bytes;
  notBefore: Date;
  notAfter: Date;
  /** Extension OID → `extnValue` contents. */
  extensions: Map<string, Bytes>;
}

export function parseCertificate(der: Uint8Array): Certificate {
  const cert = readTLV(der);
  if (cert.tag !== 0x30 || cert.end !== der.length) throw new DERError("not a certificate");
  const [tbs, sigAlg, sig] = children(cert);
  if (!tbs || !sigAlg || !sig || sig.tag !== 0x03) throw new DERError("bad certificate");
  const fields = children(tbs);
  const i = fields[0]?.tag === 0xa0 ? 1 : 0; // [0] version
  const validity = fields[i + 3];
  const spki = fields[i + 5];
  if (!validity || !spki) throw new DERError("bad tbsCertificate");
  const [notBefore, notAfter] = children(validity);
  const [keyAlg, keyBits] = children(spki);
  const [, curve] = children(keyAlg);
  const extensions = new Map<string, Bytes>();
  const extField = fields.slice(i + 6).find((f) => f.tag === 0xa3);
  if (extField) {
    const [list] = children(extField);
    for (const ext of children(list)) {
      const parts = children(ext);
      const value = parts[parts.length - 1];
      if (value.tag !== 0x04) throw new DERError("bad extension");
      extensions.set(oid(parts[0]), value.value);
    }
  }
  return {
    tbs: tbs.raw,
    signatureAlgorithm: oid(children(sigAlg)[0]),
    signature: sig.value.slice(1) as Bytes, // BIT STRING: drop the unused-bits octet
    spki: spki.raw,
    curve: curve ? oid(curve) : "",
    publicKey: keyBits.value.slice(1) as Bytes,
    notBefore: time(notBefore),
    notAfter: time(notAfter),
    extensions,
  };
}

/** Whether `basicConstraints` (2.5.29.19) says the certificate is a CA (absent: not one). */
export function isCA(cert: Certificate): boolean {
  const ext = cert.extensions.get("2.5.29.19");
  if (!ext) return false;
  const [first] = children(readTLV(ext));
  return first?.tag === 0x01 && first.value.length === 1 && first.value[0] !== 0;
}

const CURVES: Record<string, { name: string; size: number }> = {
  "1.2.840.10045.3.1.7": { name: "P-256", size: 32 },
  "1.3.132.0.34": { name: "P-384", size: 48 },
};

const HASHES: Record<string, string> = {
  "1.2.840.10045.4.3.2": "SHA-256",
  "1.2.840.10045.4.3.3": "SHA-384",
};

/** DER `ECDSA-Sig-Value` → r ‖ s (what WebCrypto takes). */
export function ecdsaRaw(der: Uint8Array, size: number): Bytes {
  const seq = readTLV(der);
  const [r, s] = children(seq);
  if (seq.tag !== 0x30 || r?.tag !== 0x02 || s?.tag !== 0x02) throw new DERError("bad ECDSA signature");
  const out = new Uint8Array(size * 2);
  const put = (v: Uint8Array, at: number) => {
    let i = 0;
    while (i < v.length - 1 && v[i] === 0) i++;
    const x = v.subarray(i);
    if (x.length > size) throw new DERError("bad ECDSA integer");
    out.set(x, at + size - x.length);
  };
  put(r.value, 0);
  put(s.value, size);
  return out;
}

export async function importECKey(spki: Uint8Array, curveOID: string): Promise<CryptoKey> {
  const curve = CURVES[curveOID];
  if (!curve) throw new DERError(`unsupported curve ${curveOID}`);
  return crypto.subtle.importKey("spki", spki as Bytes, { name: "ECDSA", namedCurve: curve.name }, false, ["verify"]);
}

/** Whether `cert` is signed by the key in `issuer`. */
export async function signedBy(cert: Certificate, issuer: Certificate): Promise<boolean> {
  const hash = HASHES[cert.signatureAlgorithm];
  const curve = CURVES[issuer.curve];
  if (!hash || !curve) return false;
  const key = await importECKey(issuer.spki, issuer.curve);
  return crypto.subtle.verify({ name: "ECDSA", hash }, key, ecdsaRaw(cert.signature, curve.size), cert.tbs);
}
