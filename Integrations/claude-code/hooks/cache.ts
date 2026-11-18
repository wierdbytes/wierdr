/**
 * When the main conversation's prompt cache expires, and how long it lives
 * from a refresh, as `agent.cache_until` / `agent.cache_ttl`.
 *
 * The same reading as pi-statusline's countdown and pi-herdr's `cache.ts`: a
 * cache entry's lifetime restarts every time a request reads or writes it, at
 * the moment the request is sent. Claude Code says what each request did in
 * the `turn.step` result's usage: `ephemeral_1h_input_tokens` > 0 means it
 * wrote one-hour entries (Claude Code's default on a claude.ai subscription),
 * `ephemeral_5m_input_tokens` > 0 five-minute ones. A request that only read
 * the cache refreshed an entry written with the last lifetime seen.
 *
 * Main loop only: subagents keep caches of their own.
 */

export const TTL_5M = 5 * 60_000
export const TTL_1H = 60 * 60_000

/** The cache fields of a `turn.step` result's usage. */
export interface CacheUsage {
  cache_read_input_tokens?: number | null
  cache_creation_input_tokens?: number | null
  ephemeral_5m_input_tokens?: number
  ephemeral_1h_input_tokens?: number
}

export interface CacheWindow {
  /** Expiry, epoch ms. */
  until: number
  /** Lifetime from a refresh, ms. */
  ttlMs: number
}

const n = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : 0)

/**
 * The lifetime a request gave the cache: undefined when it didn't touch the
 * cache, or only read it and no earlier write told the lifetime.
 */
export function requestTtl(usage: CacheUsage | null | undefined, lastTtl: number | undefined): number | undefined {
  if (!usage) return undefined
  const read = n(usage.cache_read_input_tokens)
  const write = n(usage.cache_creation_input_tokens)
  if (read + write <= 0) return undefined
  if (n(usage.ephemeral_1h_input_tokens) > 0) return TTL_1H
  if (n(usage.ephemeral_5m_input_tokens) > 0) return TTL_5M
  // A write that named no lifetime is the API's default, five minutes.
  if (write > 0) return lastTtl ?? TTL_5M
  return lastTtl
}

/** The main loop's cache entry across its requests. */
export class CacheTracker {
  /** What the last finished request left. */
  private settled: CacheWindow | undefined
  /** A request in flight: when it was sent. */
  private inflightAt: number | undefined
  private lastTtl: number | undefined

  /** The entry now; an expired one still answers with its (past) expiry. */
  get window(): CacheWindow | undefined {
    // A request in flight refreshes the entry the moment it is sent; without
    // an entry it only writes one, and its own usage tells once it lands.
    if (this.settled && this.inflightAt !== undefined && this.inflightAt > this.settled.until - this.settled.ttlMs) {
      return { until: this.inflightAt + this.settled.ttlMs, ttlMs: this.settled.ttlMs }
    }
    return this.settled
  }

  /** A request is sent at `at` (epoch ms). */
  begin(at: number): void {
    this.inflightAt = at
  }

  /** The request sent at `begin` finished with `usage` (null: no response). */
  end(usage: CacheUsage | null | undefined): void {
    const at = this.inflightAt
    this.inflightAt = undefined
    if (at === undefined) return
    const ttl = requestTtl(usage, this.lastTtl)
    if (ttl === undefined) return
    this.lastTtl = ttl
    this.settled = { until: at + ttl, ttlMs: ttl }
  }

  /** A request ended without a response (aborted, failed). */
  abort(): void {
    this.inflightAt = undefined
  }

  /**
   * A new conversation (`/clear`, `/resume`): nothing is known of its cache.
   * The lifetime stays: the same process writes with the same one.
   */
  reset(): void {
    this.settled = undefined
    this.inflightAt = undefined
  }
}
