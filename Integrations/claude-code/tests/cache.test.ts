import { describe, expect, test } from 'claude-code/testing'
import { CacheTracker, requestTtl, TTL_1H, TTL_5M } from '../hooks/cache'

describe('requestTtl', () => {
  test('the lifetime the request wrote', () => {
    expect(requestTtl({ cache_read_input_tokens: 10, cache_creation_input_tokens: 500, ephemeral_1h_input_tokens: 500, ephemeral_5m_input_tokens: 0 }, undefined)).toBe(TTL_1H)
    expect(requestTtl({ cache_read_input_tokens: 0, cache_creation_input_tokens: 500, ephemeral_1h_input_tokens: 0, ephemeral_5m_input_tokens: 500 }, TTL_1H)).toBe(TTL_5M)
  })

  test('a write that names no lifetime is five minutes, or the last one seen', () => {
    expect(requestTtl({ cache_read_input_tokens: 0, cache_creation_input_tokens: 500 }, undefined)).toBe(TTL_5M)
    expect(requestTtl({ cache_read_input_tokens: 0, cache_creation_input_tokens: 500 }, TTL_1H)).toBe(TTL_1H)
  })

  test('a read alone keeps the last lifetime; unknown without one', () => {
    expect(requestTtl({ cache_read_input_tokens: 900, cache_creation_input_tokens: 0 }, TTL_1H)).toBe(TTL_1H)
    expect(requestTtl({ cache_read_input_tokens: 900, cache_creation_input_tokens: 0 }, undefined)).toBeUndefined()
  })

  test('no cache activity, no usage: nothing', () => {
    expect(requestTtl({ cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }, TTL_1H)).toBeUndefined()
    expect(requestTtl(null, TTL_1H)).toBeUndefined()
  })
})

describe('CacheTracker', () => {
  const wrote1h = { cache_read_input_tokens: 0, cache_creation_input_tokens: 51411, ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 51411 }
  const readOnly = { cache_read_input_tokens: 51411, cache_creation_input_tokens: 0 }

  test('expiry counts from when the request was sent', () => {
    const c = new CacheTracker()
    expect(c.window).toBeUndefined()
    c.begin(1_000)
    // No entry yet: a first request only writes one.
    expect(c.window).toBeUndefined()
    c.end(wrote1h)
    expect(c.window).toEqual({ until: 1_000 + TTL_1H, ttlMs: TTL_1H })
  })

  test('a request in flight refreshes the entry at once', () => {
    const c = new CacheTracker()
    c.begin(1_000)
    c.end(wrote1h)
    c.begin(60_000)
    expect(c.window).toEqual({ until: 60_000 + TTL_1H, ttlMs: TTL_1H })
    c.end(readOnly)
    expect(c.window).toEqual({ until: 60_000 + TTL_1H, ttlMs: TTL_1H })
  })

  test('a request that did not touch the cache, or failed, leaves the last entry', () => {
    const c = new CacheTracker()
    c.begin(1_000)
    c.end(wrote1h)
    c.begin(5_000)
    c.end({ cache_read_input_tokens: 0, cache_creation_input_tokens: 0 })
    expect(c.window).toEqual({ until: 1_000 + TTL_1H, ttlMs: TTL_1H })
    c.begin(9_000)
    c.abort()
    expect(c.window).toEqual({ until: 1_000 + TTL_1H, ttlMs: TTL_1H })
  })

  test('a new conversation forgets the entry, not the lifetime', () => {
    const c = new CacheTracker()
    c.begin(1_000)
    c.end(wrote1h)
    c.reset()
    expect(c.window).toBeUndefined()
    c.begin(2_000)
    c.end(readOnly)
    expect(c.window).toEqual({ until: 2_000 + TTL_1H, ttlMs: TTL_1H })
  })
})
