/**
 * What each of Claude Code's subagents and teammates runs with, for
 * `agent.subagents_meta`: its title and name, its status and since when, its
 * model, effort and context, and when it started, so a reader shows them as
 * fully as pi's sub-agents, which have a terminal and labels of their own.
 *
 * Claude Code's own OSC 7501 records tell of an agent only while it works: a
 * subagent's record is keyed by its `$.agent.list()` id, a teammate's by its
 * task's id (`t` and 8 base-36 characters), which no API gives, so a reader
 * joins that one by its title (the agent's `description`); and a teammate
 * between turns (`idle`, waiting for a message) has no record at all. This
 * lists every agent alive.
 *
 * Fed from three places: `agent.spawn`'s answer (its id, model, the time), its
 * loop's `turn.step`s (the model and effort a request names, the context its
 * usage reports, as for the main loop) and `$.agent.list()` (id, status, name,
 * description; from 2.1.327 also the model, the effort sent, the context
 * window and the start time).
 *
 * Pure: the wiring lives in `register.ts`.
 */

import { effortLabel } from './meta'

/**
 * The statuses of an agent that is still there: queued, running, waiting on
 * its own background work, or a teammate idle between turns. `completed`,
 * `failed` and `killed` ones are gone.
 */
export const LIVE_STATUSES: ReadonlySet<string> = new Set(['pending', 'running', 'waiting', 'idle'])

/** What one subagent runs with, as far as the mod has seen. */
export interface SubagentState {
  /** The Agent call's `description`: what it shows as (its 7501 record's title). */
  title?: string
  /** What SendMessage addresses it by (a teammate's name). */
  name?: string
  /** `$.agent.list()`'s status: `pending`, `running`, `waiting`, `idle`. */
  status?: string
  /** When it got that status, as far as the mod saw (epoch ms). */
  since?: number
  /** The model id. */
  model?: string
  effort?: string
  /** Tokens in its context now. */
  ctx?: number
  /** Its model's context window. */
  ctxMax?: number
  /** When it started (epoch ms). */
  started?: number
}

/** One of `$.agent.list()`'s agents: the fields read here, those after `name` from 2.1.327 on. */
export interface ListedAgent {
  id?: string
  status?: string
  description?: string
  name?: string
  startTime?: number
  model?: string
  effort?: unknown
  contextWindowSize?: number
  /** Its latest request's input and all its output: an upper bound of its context. */
  tokenCount?: number
  lastRequest?: { model?: string; effort?: unknown }
}

/** What a request's usage reports (`turn.step`'s result). */
export interface StepUsage {
  input_tokens?: number
  cache_read_input_tokens?: number
  cache_creation_input_tokens?: number
  model?: string
}

const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n)
const text = (s: unknown): string | undefined => (typeof s === 'string' && s.trim() !== '' ? s.trim() : undefined)

interface Entry extends SubagentState {
  /** `ctx` came from a request's usage, exact; the list's `tokenCount` only stands in until then. */
  measured?: boolean
}

export class SubagentTracker {
  private readonly agents = new Map<string, Entry>()
  /** The ids the last list read named alive, in its order. */
  private live: string[] = []

  private entry(id: string): Entry {
    let e = this.agents.get(id)
    if (!e) {
      e = {}
      this.agents.set(id, e)
    }
    return e
  }

  /** `status` from `at` on, unless it already had it. */
  private static setStatus(e: Entry, status: string, at: number | undefined): void {
    if (e.status === status) return
    e.status = status
    e.since = finite(at) ? at : undefined
  }

  /** `agent.spawn` answered: the agent's id, the model it resolved to, now. */
  spawned(id: string | undefined, model: string | undefined, at: number | undefined): void {
    if (!text(id)) return
    const e = this.entry(id!)
    if (text(model)) e.model = text(model)
    if (finite(at) && e.started === undefined) e.started = at
    if (e.status === undefined) SubagentTracker.setStatus(e, 'running', at)
  }

  /** A request of its loop goes out: the model and effort it names; it runs (a teammate woken). */
  requested(id: string, model: unknown, effort: unknown, at?: number): void {
    const e = this.entry(id)
    if (text(model)) e.model = text(model)
    e.effort = effortLabel(effort)
    SubagentTracker.setStatus(e, 'running', at)
  }

  /** Its request came back: the context is the usage's input side, as the main loop's. */
  answered(id: string, usage: StepUsage | null | undefined): void {
    if (!usage) return
    const e = this.entry(id)
    if (text(usage.model)) e.model = text(usage.model)
    const n = (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0)
    if (finite(n) && n > 0) {
      e.ctx = n
      e.measured = true
    }
  }

  /**
   * `$.agent.list()` read at `at`: takes what it knows of the live agents and
   * forgets the others (finished ones; a workflow's agents and the engine's
   * forks, which step under ids it never names). Answers how many are alive.
   */
  listed(list: readonly ListedAgent[] | undefined, at?: number): number {
    if (!Array.isArray(list)) return this.live.length
    const live: string[] = []
    for (const a of list) {
      if (!a || typeof a.status !== 'string' || !LIVE_STATUSES.has(a.status)) continue
      const id = text(a.id)
      // One without an id counts, but has nothing to be found by.
      live.push(id ?? '')
      if (!id) continue
      const fresh = !this.agents.has(id)
      const e = this.entry(id)
      if (finite(a.startTime) && a.startTime > 0) e.started = a.startTime
      // First seen running: since it started, when the list says.
      SubagentTracker.setStatus(e, a.status, fresh && a.status !== 'idle' && e.started !== undefined ? e.started : at)
      if (text(a.description)) e.title = text(a.description)
      if (text(a.name)) e.name = text(a.name)
      if (text(a.model)) e.model = text(a.model)
      if (finite(a.contextWindowSize) && a.contextWindowSize > 0) e.ctxMax = a.contextWindowSize
      if (a.lastRequest && 'effort' in a.lastRequest) e.effort = effortLabel(a.lastRequest.effort)
      else if (e.effort === undefined) e.effort = effortLabel(a.effort)
      if (!e.measured && finite(a.tokenCount) && a.tokenCount > 0) e.ctx = a.tokenCount
    }
    const keep = new Set(live)
    for (const id of [...this.agents.keys()]) if (!keep.has(id)) this.agents.delete(id)
    this.live = live
    return live.length
  }

  /** The live agents' states by id, sorted, as the last list read named them. */
  snapshot(): Record<string, SubagentState> {
    const out: Record<string, SubagentState> = {}
    for (const id of [...this.live].sort()) {
      if (!id) continue
      const { measured: _, ...state } = this.agents.get(id) ?? {}
      out[id] = state
    }
    return out
  }

  /** The conversation is replaced (`/clear`, `/resume`): nothing of the old one is running. */
  reset(): void {
    this.agents.clear()
    this.live = []
  }
}
