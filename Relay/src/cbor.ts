// A small CBOR (RFC 8949) decoder: what App Attest's attestation and assertion
// objects use (maps, arrays, byte and text strings, integers). Definite lengths only.

export type CBOR = number | string | Uint8Array | boolean | null | undefined | CBOR[] | Map<CBOR, CBOR>;

export class CBORError extends Error {}

/** Decodes one item starting at `offset`; returns it and where it ends. */
export function decodeCBORAt(bytes: Uint8Array, offset = 0): { value: CBOR; end: number } {
  let at = offset;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const need = (n: number) => {
    if (at + n > bytes.length) throw new CBORError("truncated");
  };
  const argument = (info: number): number => {
    if (info < 24) return info;
    const sizes: Record<number, number> = { 24: 1, 25: 2, 26: 4, 27: 8 };
    const size = sizes[info];
    if (!size) throw new CBORError(info === 31 ? "indefinite length" : "bad argument");
    need(size);
    let n: number;
    if (size === 1) n = view.getUint8(at);
    else if (size === 2) n = view.getUint16(at);
    else if (size === 4) n = view.getUint32(at);
    else {
      const big = view.getBigUint64(at);
      if (big > BigInt(Number.MAX_SAFE_INTEGER)) throw new CBORError("integer too large");
      n = Number(big);
    }
    at += size;
    return n;
  };
  const item = (depth: number): CBOR => {
    if (depth > 16) throw new CBORError("too deep");
    need(1);
    const first = bytes[at++];
    const major = first >> 5;
    const info = first & 31;
    switch (major) {
      case 0:
        return argument(info);
      case 1:
        return -1 - argument(info);
      case 2: {
        const n = argument(info);
        need(n);
        const out = bytes.slice(at, at + n);
        at += n;
        return out;
      }
      case 3: {
        const n = argument(info);
        need(n);
        const out = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes.subarray(at, at + n));
        at += n;
        return out;
      }
      case 4: {
        const n = argument(info);
        const out: CBOR[] = [];
        for (let i = 0; i < n; i++) out.push(item(depth + 1));
        return out;
      }
      case 5: {
        const n = argument(info);
        const out = new Map<CBOR, CBOR>();
        for (let i = 0; i < n; i++) {
          const k = item(depth + 1);
          out.set(k, item(depth + 1));
        }
        return out;
      }
      case 6:
        argument(info); // a tag: the item it tags stands for it
        return item(depth + 1);
      default: {
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        if (info === 23) return undefined;
        if (info === 25 || info === 26 || info === 27) {
          const size = info === 25 ? 2 : info === 26 ? 4 : 8;
          need(size);
          const v = size === 2 ? half(view.getUint16(at)) : size === 4 ? view.getFloat32(at) : view.getFloat64(at);
          at += size;
          return v;
        }
        throw new CBORError("unsupported simple value");
      }
    }
  };
  const value = item(0);
  return { value, end: at };
}

/** Decodes a whole buffer that is exactly one item. */
export function decodeCBOR(bytes: Uint8Array): CBOR {
  const { value, end } = decodeCBORAt(bytes);
  if (end !== bytes.length) throw new CBORError("trailing bytes");
  return value;
}

function half(h: number): number {
  const exp = (h >> 10) & 0x1f;
  const frac = h & 0x3ff;
  const sign = h & 0x8000 ? -1 : 1;
  if (exp === 0) return sign * 2 ** -14 * (frac / 1024);
  if (exp === 31) return frac ? NaN : sign * Infinity;
  return sign * 2 ** (exp - 15) * (1 + frac / 1024);
}

/** A map's value under a text key. */
export function field(map: CBOR, key: string): CBOR {
  return map instanceof Map ? map.get(key) : undefined;
}
