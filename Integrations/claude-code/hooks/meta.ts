/**
 * What Claude Code tells herdr about itself, as terminal labels.
 *
 * Claude Code reports its status over OSC 7501 on its own (`status.app` =
 * `claude-code`, idle / working / blocked…), but that report has no room for
 * the model, the effort or the context size. They travel as `agent.*` labels
 * on the herdr-core terminal instead, the same keys @wierdbytes/pi-herdr
 * writes for pi, so herdr's agent lists and Wierdr read both alike.
 *
 * Pure functions only: the wiring lives in `register.ts`.
 */

import type { SubagentState } from './subagents'

/** Every label this mod owns. Removing all of them clears Claude's trace. */
export const LABEL_KEYS = [
  'agent.app',
  'agent.pid',
  'agent.model',
  'agent.model_id',
  'agent.provider',
  'agent.effort',
  'agent.ctx',
  'agent.ctx_max',
  'agent.subagents',
  'agent.subagents_meta',
  'agent.session',
  'agent.cache_until',
  'agent.cache_ttl',
] as const

export type LabelKey = (typeof LABEL_KEYS)[number]
export type Labels = Partial<Record<LabelKey, string>>

/** `agent.app`: who wrote the labels. */
export const APP = 'claude-code'

const cap = (word: string) => word.charAt(0).toUpperCase() + word.slice(1)

/**
 * A Claude model id as people say it, the way pi names Anthropic's models:
 * `claude-opus-5-5` → `Claude Opus 5.5`, `claude-haiku-4-5-20251001` →
 * `Claude Haiku 4.5`, `claude-3-7-sonnet-20250219` → `Claude Sonnet 3.7`.
 * Bedrock's and Vertex's spellings (`us.anthropic.claude-…-v1:0`,
 * `claude-…@20250805`) and a context suffix (`[1m]`) name the same model.
 * Anything else (an alias, another vendor's id) is shown as it is.
 */
export function modelName(id: string): string {
  let s = id.trim().toLowerCase()
  s = s.replace(/\[[^\]]*\]$/, '')
  s = s.replace(/^(?:[a-z]{2,4}\.)?anthropic\./, '')
  s = s.replace(/@.*$/, '')
  s = s.replace(/-v\d+(?::\d+)?$/, '')
  s = s.replace(/-(?:\d{8}|latest)$/, '')
  // claude-<family>-<major>[-<minor>]: claude-opus-4-5, claude-opus-4
  let m = /^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?$/.exec(s)
  if (m) return `Claude ${cap(m[1]!)} ${m[2]}${m[3] !== undefined ? `.${m[3]}` : ''}`
  // claude-<major>[-<minor>]-<family>: claude-3-5-sonnet
  m = /^claude-(\d+)(?:-(\d{1,2}))?-([a-z]+)$/.exec(s)
  if (m) return `Claude ${cap(m[3]!)} ${m[1]}${m[2] !== undefined ? `.${m[2]}` : ''}`
  return id
}

/** An environment flag as Claude Code reads one: set and not `0` / `false` / `no` / `off`. */
export function isFlagOn(value: string | undefined): boolean {
  if (value === undefined) return false
  const v = value.trim().toLowerCase()
  return v !== '' && v !== '0' && v !== 'false' && v !== 'no' && v !== 'off'
}

export interface ProviderEnv {
  bedrock?: string
  vertex?: string
  foundry?: string
}

/**
 * Who serves the model, as a pi provider id that herdr's provider marks know:
 * `anthropic` (the Claude API, a claude.ai subscription), `amazon-bedrock`
 * (aws mark), `google-vertex` (google), `azure-foundry` (azure).
 */
export function providerOf(env: ProviderEnv): string {
  if (isFlagOn(env.bedrock)) return 'amazon-bedrock'
  if (isFlagOn(env.vertex)) return 'google-vertex'
  if (isFlagOn(env.foundry)) return 'azure-foundry'
  return 'anthropic'
}

/**
 * The effort a request names (`high`, `max`, a token budget), as a label;
 * undefined for none, and for `unset` / `auto` (`CLAUDE_CODE_EFFORT_LEVEL`).
 */
export function effortLabel(effort: unknown): string | undefined {
  if (typeof effort === 'number') return Number.isFinite(effort) ? String(effort) : undefined
  if (typeof effort !== 'string') return undefined
  const e = effort.trim()
  if (e === '' || e === 'unset' || e === 'auto') return undefined
  return e
}

export interface MetaInputs {
  /** Claude's pid: the terminal's foreground pid while it runs. */
  pid?: number | string
  /** The model id. */
  model?: string
  provider?: string
  effort?: string
  /** Tokens in the context now; undefined while unknown. */
  ctx?: number
  /** The context window. */
  ctxMax?: number
  /** Subagents and teammates alive: queued, running, waiting, or a teammate idle between turns. */
  subagents?: number
  /** What each of them runs with, by id (`SubagentTracker.snapshot`). */
  subagentsMeta?: Record<string, SubagentState>
  /** `$.session.id()`: `claude --resume <id>` opens it again. */
  session?: string
  /** The main loop's prompt cache: its expiry (epoch ms) and lifetime (ms). */
  cache?: { until: number; ttlMs: number }
}

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)

/** The labels for this moment. A key left out means "not known now" and gets removed. */
export function collectLabels(inputs: MetaInputs): Labels {
  const labels: Labels = { 'agent.app': APP }
  if (inputs.pid !== undefined && String(inputs.pid) !== '') labels['agent.pid'] = String(inputs.pid)
  if (inputs.model) {
    labels['agent.model'] = modelName(inputs.model)
    labels['agent.model_id'] = inputs.model
  }
  if (inputs.provider) labels['agent.provider'] = inputs.provider
  if (inputs.effort) labels['agent.effort'] = inputs.effort
  if (finite(inputs.ctx) && inputs.ctx >= 0) labels['agent.ctx'] = String(Math.round(inputs.ctx))
  if (finite(inputs.ctxMax) && inputs.ctxMax > 0) labels['agent.ctx_max'] = String(Math.round(inputs.ctxMax))
  if (finite(inputs.subagents) && inputs.subagents > 0) labels['agent.subagents'] = String(inputs.subagents)
  const subagentsMeta = subagentsMetaLabel(inputs.subagentsMeta, inputs)
  if (subagentsMeta) labels['agent.subagents_meta'] = subagentsMeta
  if (inputs.session) labels['agent.session'] = inputs.session
  const cache = inputs.cache
  if (cache && finite(cache.until) && finite(cache.ttlMs) && cache.ttlMs > 0) {
    labels['agent.cache_until'] = String(Math.round(cache.until))
    labels['agent.cache_ttl'] = String(Math.round(cache.ttlMs))
  }
  return labels
}

/**
 * `agent.subagents_meta`: for each subagent or teammate alive, by its
 * `$.agent.list()` id (a subagent's OSC 7501 record has the same key; a
 * teammate's record is its task's, found by `title`): `title` (its
 * description, the record's title), `name`, `status` (`pending`, `running`,
 * `waiting`, `idle`) and `since` (epoch ms), then what the agent's own labels
 * say of the agent: `model` and `model_id`, `effort`, `ctx` and `ctx_max`, and
 * `started` (epoch ms). JSON, the ids sorted; a field not known is left out.
 * The window, when the list doesn't give it (before 2.1.327), is the session's
 * for the session's model. Undefined when none is alive.
 */
export function subagentsMetaLabel(
  agents: Record<string, SubagentState> | undefined,
  main: { model?: string; ctxMax?: number } = {},
): string | undefined {
  if (!agents) return undefined
  const ids = Object.keys(agents).filter((id) => id !== '').sort()
  if (ids.length === 0) return undefined
  const out: Record<string, Record<string, string | number>> = {}
  for (const id of ids) {
    const a = agents[id]!
    const entry: Record<string, string | number> = {}
    if (a.title) entry.title = a.title
    if (a.name) entry.name = a.name
    if (a.status) entry.status = a.status
    if (finite(a.since) && a.since > 0) entry.since = Math.round(a.since)
    if (a.model) {
      entry.model = modelName(a.model)
      entry.model_id = a.model
    }
    if (a.effort) entry.effort = a.effort
    if (finite(a.ctx) && a.ctx >= 0) entry.ctx = Math.round(a.ctx)
    const window = finite(a.ctxMax) && a.ctxMax > 0 ? a.ctxMax : a.model && a.model === main.model ? main.ctxMax : undefined
    if (finite(window) && window > 0) entry.ctx_max = Math.round(window)
    if (finite(a.started) && a.started > 0) entry.started = Math.round(a.started)
    out[id] = entry
  }
  return JSON.stringify(out)
}

/**
 * What to send to go from `prev` (what the terminal has) to `next`: changed
 * keys with their value, vanished keys as `""` (hc's "remove"). Empty when
 * nothing changed, so callers can skip the round trip.
 */
export function diffLabels(prev: Labels, next: Labels): Record<string, string> {
  const out: Record<string, string> = {}
  for (const key of LABEL_KEYS) {
    const before = prev[key]
    const after = next[key]
    if (after !== undefined && after !== before) out[key] = after
    else if (after === undefined && before !== undefined) out[key] = ''
  }
  return out
}

/** Every owned key set to `""`: removes them all. */
export function clearLabels(): Record<string, string> {
  return Object.fromEntries(LABEL_KEYS.map((key) => [key, '']))
}
