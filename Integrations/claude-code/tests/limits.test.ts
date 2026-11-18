import { describe, expect, test } from 'claude-code/testing'
import {
  accountFromConfig,
  accountSlug,
  asLimitsDoc,
  emptyDoc,
  foldReading,
  foldWindow,
  isoToUnix,
  planOf,
  readingFromRateLimits,
} from '../hooks/limits'

describe('readingFromRateLimits', () => {
  test('five_hour and seven_day as pi-herdr names them; spend_limit left out', () => {
    const reading = readingFromRateLimits(
      [
        { kind: 'seven_day', percentUsed: 52, resetsAt: '2026-11-22T08:00:00.000Z' },
        { kind: 'five_hour', percentUsed: 5.5, resetsAt: '2026-11-18T19:30:00.000Z' },
        { kind: 'spend_limit', percentUsed: 12 },
      ],
      'max_5x',
    )
    expect(reading).toEqual({
      provider: 'claude',
      source: 'claude-code',
      plan: 'max_5x',
      windows: [
        { id: '5h', label: '5 hours', windowSeconds: 18000, usedPercent: 5.5, resetsAt: 1795030200 },
        { id: '7d', label: '7 days', windowSeconds: 604800, usedPercent: 52, resetsAt: isoToUnix('2026-11-22T08:00:00.000Z') },
      ],
    })
  })

  test('a window past 100 % is exhausted; one without a reset has none', () => {
    const reading = readingFromRateLimits([{ kind: 'five_hour', percentUsed: 100 }])
    expect(reading?.windows).toEqual([{ id: '5h', label: '5 hours', windowSeconds: 18000, usedPercent: 100, status: 'exhausted' }])
  })

  test('off a subscription there is no reading', () => {
    expect(readingFromRateLimits([])).toBeNull()
    expect(readingFromRateLimits(undefined)).toBeNull()
    expect(readingFromRateLimits([{ kind: 'spend_limit', percentUsed: 40 }])).toBeNull()
  })
})

describe('the account', () => {
  test('the slug is pi-herdr\'s: sha256, 8 hex digits, or main', async () => {
    expect(await accountSlug('abc')).toBe('ba7816bf')
    expect(await accountSlug('3f2a9c1e-5b7d-4e8a-9c21-6d0f4b8a7e13')).toBe('c3c54697')
    expect(await accountSlug(undefined)).toBe('main')
    expect(await accountSlug('')).toBe('main')
  })

  test('plans as the limits readers name them', () => {
    expect(planOf('claude_max', 'default_claude_max_5x')).toBe('max_5x')
    expect(planOf('claude_max', 'default_claude_max_20x')).toBe('max_20x')
    expect(planOf('claude_max', null)).toBe('max')
    expect(planOf('claude_pro', 'default_claude_pro')).toBe('pro')
    expect(planOf('claude_team', undefined)).toBe('team')
    expect(planOf(undefined, 'default_claude_max_5x')).toBeUndefined()
  })

  test('the signed-in account from ~/.claude.json', () => {
    const text = JSON.stringify({
      numStartups: 3,
      oauthAccount: {
        organizationUuid: 'org-1',
        organizationType: 'claude_max',
        organizationRateLimitTier: 'default_claude_max_20x',
        emailAddress: 'someone@example.com',
      },
    })
    expect(accountFromConfig(text)).toEqual({ organizationId: 'org-1', plan: 'max_20x' })
    expect(accountFromConfig(JSON.stringify({ numStartups: 1 }))).toEqual({})
    expect(accountFromConfig('{not json')).toEqual({})
    expect(accountFromConfig(undefined)).toEqual({})
  })
})

describe('the document', () => {
  const reading = readingFromRateLimits(
    [
      { kind: 'five_hour', percentUsed: 8, resetsAt: '2026-11-18T19:30:00.000Z' },
      { kind: 'seven_day', percentUsed: 52, resetsAt: '2026-11-22T08:00:00.000Z' },
    ],
    'max_5x',
  )!

  test('a first reading makes the account', () => {
    const doc = foldReading(emptyDoc(), reading, { slug: '849d2d8c' }, 1795023971, 'mentoair')
    expect(doc).toEqual({
      schema: 1,
      updated_at: 1795023971,
      accounts: {
        'claude.849d2d8c': {
          provider: 'claude',
          account: '849d2d8c',
          plan: 'max_5x',
          source: 'claude-code',
          host: 'mentoair',
          at: 1795023971,
          windows: {
            '5h': { id: '5h', label: '5 hours', window_s: 18000, used: 8, resets_at: 1795030200, at: 1795023971 },
            '7d': { id: '7d', label: '7 days', window_s: 604800, used: 52, resets_at: isoToUnix('2026-11-22T08:00:00.000Z'), at: 1795023971 },
          },
        },
      },
    })
  })

  test('pi-herdr\'s reading of the same account folds with ours', () => {
    const pi = asLimitsDoc({
      schema: 1,
      updated_at: 1795023000,
      accounts: {
        'claude.849d2d8c': {
          provider: 'claude', account: '849d2d8c', status: 'ok', binding: '5h', source: 'header', host: 'mentoair', at: 1795023000,
          windows: {
            '5h': { id: '5h', label: '5 hours', window_s: 18000, used: 9, resets_at: 1795030200, status: 'ok', at: 1795023000 },
          },
        },
        'codex.1a2b3c4d': { provider: 'codex', account: '1a2b3c4d', at: 1795000000, windows: {} },
      },
    })
    const doc = foldReading(pi, reading, { slug: '849d2d8c' }, 1795023971, 'mentoair')
    const account = doc.accounts['claude.849d2d8c']!
    // Within one window the used share only grows.
    expect(account.windows['5h']!.used).toBe(9)
    expect(account.windows['5h']!.at).toBe(1795023971)
    expect(account.windows['7d']!.used).toBe(52)
    expect(account.plan).toBe('max_5x')
    expect(account.source).toBe('claude-code')
    // Other accounts stay as they were.
    expect(doc.accounts['codex.1a2b3c4d']).toEqual(pi.accounts['codex.1a2b3c4d'])
  })

  test('a later window replaces an earlier one; an older reading is dropped', () => {
    const a = { id: '5h', label: '5 hours', used: 90, resets_at: 1000, at: 500 }
    expect(foldWindow(a, { id: '5h', label: '5 hours', used: 3, resets_at: 19000, at: 1200 }).used).toBe(3)
    expect(foldWindow(a, { id: '5h', label: '5 hours', used: 3, resets_at: 100, at: 1200 })).toBe(a)
  })

  test('a document that is not schema 1 starts empty', () => {
    expect(asLimitsDoc(null)).toEqual(emptyDoc())
    expect(asLimitsDoc({ schema: 2, accounts: {} })).toEqual(emptyDoc())
  })
})
