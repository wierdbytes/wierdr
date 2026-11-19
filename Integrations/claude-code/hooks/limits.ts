/**
 * Claude subscription limits (Pro, Max) as Claude Code reports them
 * (`session.measure`, `$.session.usage().rateLimits`), folded into the
 * herdr-core document @wierdbytes/pi-wierdr writes, `limits` (schema 1), so
 * every herdr client shows the same numbers, whichever agent read them.
 *
 * The document's shape and its folding rules are pi-wierdr's (`herdr/limits.ts`),
 * copied here: several writers fold their readings into one document, and
 * they must agree. The account key is too: the first 8 hex digits of
 * sha256 of the Anthropic organization id, which pi-wierdr reads from the
 * `anthropic-organization-id` header and Claude Code keeps as
 * `oauthAccount.organizationUuid` in `~/.claude.json`, so Claude Code's and
 * pi's readings land in one account.
 *
 * Pure functions (sha256 through `crypto.subtle`). The writing lives in
 * `limits-publisher.ts`.
 */

/** The herdr-core document the limits live in. */
export const LIMITS_DOC = 'limits'
export const LIMITS_SCHEMA = 1

export type LimitStatus = 'ok' | 'warning' | 'exhausted'

export interface ReadingWindow {
  /** Stable within the account: `5h`, `7d`. */
  id: string
  label: string
  windowSeconds?: number
  /** Share of the window used, in percent. Can exceed 100. */
  usedPercent: number
  /** Unix seconds. */
  resetsAt?: number
  status?: LimitStatus
}

export interface LimitReading {
  provider: string
  /** Who read it: pi-wierdr writes `header` / `stream`, this mod `claude-code`. */
  source: string
  plan?: string
  /** The window that limits the account right now. */
  binding?: string
  status?: LimitStatus
  windows: ReadingWindow[]
}

export interface LimitAccount {
  /** The first 8 hex digits of sha256(account id), or `main`. */
  slug: string
  label?: string
}

// ============================================
// Reading Claude Code's rate limits
// ============================================

/** One of `$.session.usage().rateLimits`. */
export interface RateLimitLike {
  kind?: string
  percentUsed?: number
  resetsAt?: string
}

/** Claude Code's window kinds → the document's window ids (pi-wierdr's header claims). */
const WINDOWS: Record<string, { id: string; label: string; seconds: number }> = {
  five_hour: { id: '5h', label: '5 hours', seconds: 18_000 },
  seven_day: { id: '7d', label: '7 days', seconds: 604_800 },
}

const round2 = (n: number) => Math.round(n * 100) / 100

/** An ISO 8601 time as unix seconds; undefined when it doesn't parse. */
export function isoToUnix(iso: string | undefined): number | undefined {
  if (typeof iso !== 'string' || iso === '') return undefined
  const ms = Date.parse(iso)
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : undefined
}

/**
 * A subscription reading from Claude Code's rate limits; null off a
 * subscription (none reported) and for a gateway's `spend_limit` alone.
 */
export function readingFromRateLimits(rateLimits: readonly RateLimitLike[] | undefined, plan?: string): LimitReading | null {
  if (!Array.isArray(rateLimits)) return null
  const windows: ReadingWindow[] = []
  const seen = new Set<string>()
  for (const r of rateLimits) {
    const w = r && typeof r.kind === 'string' ? WINDOWS[r.kind] : undefined
    if (!w || seen.has(w.id)) continue
    if (typeof r.percentUsed !== 'number' || !Number.isFinite(r.percentUsed)) continue
    seen.add(w.id)
    const used = round2(r.percentUsed)
    const win: ReadingWindow = { id: w.id, label: w.label, windowSeconds: w.seconds, usedPercent: used }
    const resetsAt = isoToUnix(r.resetsAt)
    if (resetsAt !== undefined) win.resetsAt = resetsAt
    if (used >= 100) win.status = 'exhausted'
    windows.push(win)
  }
  if (!windows.length) return null
  windows.sort((a, b) => (a.windowSeconds ?? Infinity) - (b.windowSeconds ?? Infinity) || a.id.localeCompare(b.id))
  const reading: LimitReading = { provider: 'claude', source: 'claude-code', windows }
  if (plan) reading.plan = plan
  return reading
}

// ============================================
// The account
// ============================================

/** The first 8 hex digits of sha256(`accountId`), or `main` without one: pi-wierdr's `accountSlug`. */
export async function accountSlug(accountId: string | undefined): Promise<string> {
  if (!accountId) return 'main'
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(accountId))
  return Array.from(new Uint8Array(digest).slice(0, 4), (b) => b.toString(16).padStart(2, '0')).join('')
}

/**
 * The plan as the limits readers name it (`Limits.planName` in Wierdr, the
 * desktop's limits mod): `organizationType` without its `claude_` prefix,
 * with Max's tier when `organizationRateLimitTier` tells it, so Max 20x
 * reads as Ultra: `claude_max` + `default_claude_max_20x` → `max_20x`.
 */
export function planOf(organizationType: unknown, rateLimitTier?: unknown): string | undefined {
  if (typeof organizationType !== 'string' || organizationType.trim() === '') return undefined
  let plan = organizationType.trim().toLowerCase().replace(/^claude[_ ]/, '')
  const tier = typeof rateLimitTier === 'string' ? /_(\d+x)$/.exec(rateLimitTier.trim().toLowerCase()) : null
  if (tier && !plan.endsWith(tier[1]!)) plan = `${plan}_${tier[1]}`
  return plan
}

export interface ConfigAccount {
  /** `oauthAccount.organizationUuid`. */
  organizationId?: string
  plan?: string
}

/** The signed-in claude.ai account in `~/.claude.json`'s text; empty when none or unreadable. */
export function accountFromConfig(text: string | undefined): ConfigAccount {
  if (typeof text !== 'string' || text === '') return {}
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return {}
  }
  const oauth = (parsed as { oauthAccount?: Record<string, unknown> } | null)?.oauthAccount
  if (!oauth || typeof oauth !== 'object') return {}
  const out: ConfigAccount = {}
  if (typeof oauth.organizationUuid === 'string' && oauth.organizationUuid !== '') out.organizationId = oauth.organizationUuid
  const plan = planOf(oauth.organizationType, oauth.organizationRateLimitTier)
  if (plan) out.plan = plan
  return out
}

// ============================================
// The document (pi-wierdr's, unchanged)
// ============================================

/** One usage window as the document keeps it. Times are unix seconds. */
export interface DocWindow {
  id: string
  label: string
  window_s?: number
  used: number
  resets_at?: number
  status?: LimitStatus
  /** When this window was last read. */
  at: number
}

export interface DocAccount {
  provider: string
  account: string
  label?: string
  plan?: string
  status?: LimitStatus
  binding?: string
  /** Last reading of any window. */
  at: number
  /** The machine that read it. */
  host?: string
  source?: string
  windows: Record<string, DocWindow>
}

export interface LimitsDoc {
  schema: typeof LIMITS_SCHEMA
  /** Last write, unix seconds. */
  updated_at: number
  accounts: Record<string, DocAccount>
}

export const emptyDoc = (): LimitsDoc => ({ schema: LIMITS_SCHEMA, updated_at: 0, accounts: {} })

/** The document as stored, or an empty one when it is missing or not ours to read. */
export function asLimitsDoc(value: unknown): LimitsDoc {
  const v = value as Partial<LimitsDoc> | null | undefined
  if (!v || typeof v !== 'object' || v.schema !== LIMITS_SCHEMA || !v.accounts || typeof v.accounts !== 'object') return emptyDoc()
  return { schema: LIMITS_SCHEMA, updated_at: typeof v.updated_at === 'number' ? v.updated_at : 0, accounts: { ...v.accounts } }
}

// Two readings of one window can disagree on the reset by a little.
const SAME_WINDOW_S = 120

/**
 * Folds window reading `b` into window `a`: within one window (same reset,
 * give or take two minutes) the used share only grows; a later window
 * replaces it; a reading of an earlier window is dropped. A reading without a
 * reset replaces a window only once its reset has passed.
 */
export function foldWindow(a: DocWindow | undefined, b: DocWindow): DocWindow {
  if (!a) return b
  if (a.resets_at !== undefined && b.resets_at !== undefined) {
    if (b.resets_at > a.resets_at + SAME_WINDOW_S) return b
    if (b.resets_at < a.resets_at - SAME_WINDOW_S) return a
    return {
      ...b,
      used: Math.max(a.used, b.used),
      resets_at: Math.max(a.resets_at, b.resets_at),
      at: Math.max(a.at, b.at),
    }
  }
  if (a.resets_at !== undefined && b.resets_at === undefined && b.at < a.resets_at) return a
  return b.at >= a.at ? b : a
}

/** The document key of an account. */
export const accountKey = (provider: string, slug: string) => `${provider}.${slug}`

/** `doc` with `reading` folded in. Returns a new document; `doc` is left as it was. */
export function foldReading(doc: LimitsDoc, reading: LimitReading, account: LimitAccount, nowS: number, host?: string): LimitsDoc {
  const key = accountKey(reading.provider, account.slug)
  const prev = doc.accounts[key]
  const windows: Record<string, DocWindow> = { ...(prev?.windows ?? {}) }
  for (const w of reading.windows) {
    const status = w.status ?? (reading.status === 'exhausted' && reading.binding === w.id ? 'exhausted' : reading.status ? 'ok' : undefined)
    const next: DocWindow = { id: w.id, label: w.label, used: w.usedPercent, at: nowS }
    if (w.windowSeconds !== undefined) next.window_s = w.windowSeconds
    if (w.resetsAt !== undefined) next.resets_at = Math.floor(w.resetsAt)
    if (status) next.status = status
    windows[w.id] = foldWindow(windows[w.id], next)
  }
  const latest = !prev || nowS >= prev.at
  const pick = <T>(mine: T | undefined, theirs: T | undefined) => (latest ? (mine ?? theirs) : (theirs ?? mine))
  const next: DocAccount = { provider: reading.provider, account: account.slug, at: Math.max(prev?.at ?? 0, nowS), windows }
  const label = pick(account.label, prev?.label)
  const plan = pick(reading.plan, prev?.plan)
  const status = latest ? reading.status : prev?.status
  const binding = latest ? reading.binding : prev?.binding
  const source = latest ? reading.source : prev?.source
  const at = latest ? host : prev?.host
  if (label) next.label = label
  if (plan) next.plan = plan
  if (status) next.status = status
  if (binding) next.binding = binding
  if (source) next.source = source
  if (at) next.host = at
  return { schema: LIMITS_SCHEMA, updated_at: Math.max(doc.updated_at, nowS), accounts: { ...doc.accounts, [key]: next } }
}
