// Bytes: base64 (standard and URL-safe), UTF-8, SHA-256, comparisons.

export type Bytes = Uint8Array<ArrayBuffer>;

export const utf8 = (s: string): Bytes => new TextEncoder().encode(s) as Bytes;

export function b64encode(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export const b64url = (bytes: Uint8Array): string =>
  b64encode(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Standard or URL-safe base64, padded or not; null when it isn't base64. */
export function b64decode(text: string): Bytes | null {
  if (!/^[A-Za-z0-9+/_-]*={0,2}$/.test(text)) return null;
  const t = text.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  if (t.length % 4 === 1) return null;
  try {
    const s = atob(t + "===".slice(0, (4 - (t.length % 4)) % 4));
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

export function concat(...parts: Uint8Array[]): Bytes {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** Same bytes, in time that doesn't depend on where they differ. */
export function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

export async function sha256(data: Uint8Array): Promise<Bytes> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data as Bytes));
}

/** The DER body of a PEM block. */
export function pemBody(pem: string): Bytes {
  const body = pem.replace(/-----(BEGIN|END)[^-]*-----/g, "").replace(/\s+/g, "");
  const der = b64decode(body);
  if (!der) throw new Error("not PEM");
  return der;
}
