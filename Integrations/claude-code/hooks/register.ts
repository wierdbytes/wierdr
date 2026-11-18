/**
 * cc — tells herdr which model, effort and context size Claude Code runs
 * with, as `agent.*` labels on the herdr-core terminal it runs in, and folds
 * the claude.ai subscription limits into herdr-core's `limits` document: what
 * @wierdbytes/pi-herdr does for pi, with the same keys and the same document,
 * so herdr's agent lists, the desktop and Wierdr read both alike.
 *
 * Claude Code already reports its status (idle, working, blocked) over OSC
 * 7501; this adds what that report has no room for.
 *
 * Wiring only. The labels are built in `meta.ts` and written in
 * `publisher.ts`, the subagents' models and contexts are kept in
 * `subagents.ts`, the cache window is `cache.ts`, the limits are read in
 * `limits.ts` and written in `limits-publisher.ts`, `hc.ts` speaks
 * herdr-core's JSON-RPC through `hc connect`.
 *
 * Mods API rules this file follows: every call is spelled `$.namespace.method`
 * where it is made, and the helpers that take `$` are declared at the top
 * level, never inside `register`. Closures made inside a hook keep its `$`
 * for the timers and the writes that run after it returned.
 */

import type { EngineInterface, On } from 'claude-code'
import { CacheTracker, type CacheUsage } from './cache'
import { docOf, parseReply, requestLine, type RpcReply, setResultOf } from './hc'
import { accountFromConfig, accountSlug, LIMITS_DOC, type LimitsDoc, type RateLimitLike, readingFromRateLimits } from './limits'
import { LimitsPublisher } from './limits-publisher'
import { collectLabels, effortLabel, type MetaInputs, providerOf } from './meta'
import { LabelPublisher } from './publisher'
import { type ListedAgent, SubagentTracker } from './subagents'
import type { After, Cancelable } from './timer'

type Api = EngineInterface

/** How long one `hc connect` may take. */
const HC_TIMEOUT_MS = 3000
/** How often `agent.subagents` is re-read while subagents or teammates are alive. */
const SUBAGENT_POLL_MS = 5000
/** How long the signed-in account read from `~/.claude.json` is trusted. */
const ACCOUNT_TTL_MS = 10 * 60_000

// ============================================
// What the hooks reach through `$`
// ============================================

interface RunInit {
  stdin?: string
  timeoutMs?: number
  env?: Record<string, string>
}

/** Running a program and the clock, kept from one hook's `$` for the work that outlives it. */
interface Io {
  run(argv: string[], init: RunInit): Promise<{ exitCode: number; stdout: string }>
  after: After
}

function ioOf($: Api): Io {
  return {
    run: (argv, init) => $.process.run(argv, init),
    after: (ms, fn) => $.clock.after(ms, fn),
  }
}

interface StartEnv {
  terminal?: string
  socket?: string
  home?: string
  configDir?: string
  limitsDoc?: string
  hostname?: string
  effort?: string
  provider: string
}

/** The environment variables this mod reads, each named where it is read. */
async function readEnv($: Api): Promise<StartEnv> {
  const [terminal, socket, home, configDir, limitsDoc, hostname, effort, bedrock, vertex, foundry] = await Promise.all([
    $.env.get('HC_TERMINAL_ID'),
    $.env.get('HC_TERMINAL_SOCKET'),
    $.env.get('HOME'),
    $.env.get('CLAUDE_CONFIG_DIR'),
    $.env.get('WIERDR_CC_LIMITS_DOC'),
    $.env.get('HOSTNAME'),
    $.env.get('CLAUDE_CODE_EFFORT_LEVEL'),
    $.env.get('CLAUDE_CODE_USE_BEDROCK'),
    $.env.get('CLAUDE_CODE_USE_VERTEX'),
    $.env.get('CLAUDE_CODE_USE_FOUNDRY'),
  ])
  return { terminal, socket, home, configDir, limitsDoc, hostname, effort, provider: providerOf({ bedrock, vertex, foundry }) }
}

/** The effort the user set: `CLAUDE_CODE_EFFORT_LEVEL` over the `effortLevel` setting. */
async function configuredEffort($: Api, envEffort: string | undefined): Promise<string | undefined> {
  if (envEffort !== undefined && envEffort.trim() !== '') return effortLabel(envEffort)
  try {
    return effortLabel(await $.settings.read({ key: 'effortLevel' }))
  } catch {
    return undefined
  }
}

/**
 * Claude's own pid, which herdr-core reports as the terminal's foreground
 * pid: the parent of a program `$.process.run` starts. (`$.process.hookEnv()`
 * has it as `CLAUDE_PID` too, but 2.1.319 has no such method, and a module
 * naming a method its Claude Code lacks doesn't load at all.)
 */
async function claudePid($: Api): Promise<string | undefined> {
  try {
    const out = await $.process.run(['/bin/sh', '-c', 'echo $PPID'], { timeoutMs: 2000 })
    const pid = out.stdout.trim()
    return out.exitCode === 0 && /^\d+$/.test(pid) ? pid : undefined
  } catch {
    return undefined
  }
}

interface Snapshot {
  session?: string
  model?: string
  context?: { tokens?: number; window?: number }
  rateLimits?: readonly RateLimitLike[]
}

/** The session's id, model and usage now; a field that can't be read is left out. */
async function snapshot($: Api): Promise<Snapshot> {
  const [session, model, usage] = await Promise.all([
    $.session.id().catch(() => undefined),
    $.session.model().catch(() => undefined),
    $.session.usage().catch(() => undefined),
  ])
  return { session, model, context: usage?.context, rateLimits: usage?.rateLimits }
}

/** The session's subagents and teammates, or undefined when they can't be read. */
async function agentList($: Api): Promise<readonly ListedAgent[] | undefined> {
  try {
    const list = await $.agent.list()
    return Array.isArray(list) ? (list as readonly ListedAgent[]) : undefined
  } catch {
    return undefined
  }
}

/** `$.clock.now()`, or undefined without a clock. */
async function nowOf($: Api): Promise<number | undefined> {
  try {
    return await $.clock.now()
  } catch {
    return undefined
  }
}

async function readText($: Api, path: string): Promise<string | undefined> {
  try {
    const text = await $.fs.read(path)
    return typeof text === 'string' ? text : undefined
  } catch {
    return undefined
  }
}

// ============================================
// herdr-core through `hc connect`
// ============================================

/** herdr-core's JSON-RPC, one `hc connect` a request, on the core the terminal belongs to. */
class Hc {
  private nextId = 1

  constructor(
    private readonly io: Io,
    /** `HC_TERMINAL_SOCKET`: handed to hc as `HC_SOCKET`, so it reaches that core. */
    private readonly socket: string,
    /** `hc` on PATH, then `~/.local/bin/hc`; one that can't start is dropped. */
    private readonly bins: string[],
  ) {}

  async call(method: string, params: Record<string, unknown>): Promise<RpcReply> {
    const id = this.nextId++
    const stdin = requestLine(id, method, params)
    while (this.bins.length) {
      const bin = this.bins[0]!
      try {
        const out = await this.io.run([bin, 'connect'], { stdin, timeoutMs: HC_TIMEOUT_MS, env: { HC_SOCKET: this.socket } })
        return parseReply(out.stdout, id)
      } catch (err) {
        if (/time/i.test(String((err as Error)?.message ?? err)) || this.bins.length === 1) return { ok: false, error: 'unreachable' }
        this.bins.shift()
      }
    }
    return { ok: false, error: 'unreachable' }
  }

  async label(terminal: string, labels: Record<string, string>): Promise<boolean> {
    return (await this.call('terminal.label', { terminal, labels })).ok
  }

  async getDoc(name: string) {
    return docOf(await this.call('doc.get', { name }))
  }

  async setDoc(name: string, value: LimitsDoc, version: number) {
    return setResultOf(await this.call('doc.set', { name, value, version }))
  }
}

// ============================================
// The hooks
// ============================================

export function register(on: On): void {
  /** The interactive session's labels; unset outside herdr-core and for `claude -p`. */
  let labels: LabelPublisher | undefined
  let limits: LimitsPublisher | undefined
  /** Reads the session (id, model, usage) and republishes; set once the interactive session started. */
  let refresh: (() => Promise<void>) | undefined
  /** Re-reads `agent.subagents`; set with `refresh`. */
  let countAgents: (() => Promise<void>) | undefined
  /** Queues a limits reading; set when the session started in herdr-core. */
  let recordLimits: ((rateLimits: readonly RateLimitLike[] | undefined) => Promise<void>) | undefined
  let after: After | undefined
  let startPoll: (() => void) | undefined

  const meta: MetaInputs = {}
  const cache = new CacheTracker()
  const subagents = new SubagentTracker()
  /** The model and effort the session last named: a change means /model or /effort. */
  let sessionModel: string | undefined
  let settingEffort: string | undefined
  /** The first measurement is written whatever it changed. */
  let measured = false
  let poll: Cancelable | undefined
  /** Polls left before a spawn that never showed up stops the subagent poll. */
  let expectSpawn = 0

  const publish = () => labels?.publish(collectLabels({ ...meta, cache: cache.window, subagentsMeta: subagents.snapshot() }))

  const stopPoll = () => {
    try {
      poll?.cancel()
    } catch {
      // Already stopped.
    }
    poll = undefined
  }

  on('session.start', async ($, e, next) => {
    try {
      const env = await readEnv($)
      // Outside a herdr-core terminal there is nobody to tell.
      if (!env.terminal || !env.socket) return next(e)
      const io = ioOf($)
      after = io.after
      const bins = ['hc']
      if (env.home) bins.push(`${env.home}/.local/bin/hc`)
      const hc = new Hc(io, env.socket, bins)
      const terminal = env.terminal

      // Every session writes the limits, `claude -p` too: it spends the same subscription.
      const docName = env.limitsDoc || LIMITS_DOC
      const publisher = new LimitsPublisher(
        { get: () => hc.getDoc(docName), set: (value, version) => hc.setDoc(docName, value, version) },
        io.after,
      )
      limits = publisher
      publisher.host = env.hostname
      void io
        .run(['hostname'], { timeoutMs: 2000 })
        .then((out) => {
          const name = out.stdout.trim()
          if (out.exitCode === 0 && name) publisher.host = name
        })
        .catch(() => undefined)
      const configPath = `${env.configDir || env.home || ''}/.claude.json`
      let account: { slug: string; plan?: string; at: number } | undefined
      recordLimits = async (rateLimits) => {
        // Off a claude.ai subscription Claude Code reports no windows.
        if (!Array.isArray(rateLimits) || rateLimits.length === 0) return
        const now = await $.clock.now()
        if (!account || now - account.at > ACCOUNT_TTL_MS) {
          const found = accountFromConfig(await readText($, configPath))
          account = { slug: await accountSlug(found.organizationId), plan: found.plan, at: now }
        }
        const reading = readingFromRateLimits(rateLimits, account.plan)
        if (reading) publisher.record(reading, { slug: account.slug }, now)
      }

      // Only the interactive session owns the terminal: `claude -p` runs
      // started inside it must not overwrite its labels.
      if (!e.isInteractive) return next(e)

      labels = new LabelPublisher((change) => hc.label(terminal, change), io.after)
      meta.provider = env.provider
      const [pid, effort] = await Promise.all([claudePid($), configuredEffort($, env.effort)])
      meta.pid = pid
      meta.effort = settingEffort = effort

      let refreshing = false
      refresh = async () => {
        if (refreshing) return
        refreshing = true
        try {
          const [now, effortNow] = await Promise.all([snapshot($), configuredEffort($, env.effort)])
          if (now.session) meta.session = now.session
          if (now.model && now.model !== sessionModel) meta.model = sessionModel = now.model
          if (effortNow !== settingEffort) meta.effort = settingEffort = effortNow
          if (now.context) {
            meta.ctx = now.context.tokens
            if (now.context.window) meta.ctxMax = now.context.window
          }
          publish()
        } finally {
          refreshing = false
        }
      }

      let counting = false
      countAgents = async () => {
        if (counting) return
        counting = true
        try {
          const [list, at] = await Promise.all([agentList($), nowOf($)])
          if (list === undefined) return
          const n = subagents.listed(list, at)
          meta.subagents = n
          publish()
          if (n > 0) {
            expectSpawn = 0
            startPoll?.()
          } else if (expectSpawn > 0) expectSpawn--
          else stopPoll()
        } finally {
          counting = false
        }
      }
      startPoll = () => {
        poll ??= $.clock.every(SUBAGENT_POLL_MS, () => void countAgents?.())
      }

      await refresh()
      await countAgents()
      await labels.flush()
    } catch {
      // herdr-core missing or a read refused: Claude Code goes on as without the mod.
    }
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    if (labels) {
      meta.ctx = e.context?.tokens
      if (e.context?.window) meta.ctxMax = e.context.window
      publish()
    }
    if (recordLimits && (!measured || e.changed?.includes('rateLimits'))) {
      measured = true
      void recordLimits(e.rateLimits).catch(() => undefined)
    }
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    // Subagents' requests: their model, effort and context, and their count.
    if (!labels || e.agentId !== undefined) {
      const agent = labels ? e.agentId : undefined
      if (agent !== undefined) {
        subagents.requested(agent, e.model, e.effort, await nowOf($))
        publish()
      }
      const result = yield* next(e)
      if (agent !== undefined) {
        subagents.answered(agent, result?.usage)
        publish()
      }
      void countAgents?.().catch(() => undefined)
      return result
    }
    try {
      cache.begin(await $.clock.now())
    } catch {
      // No clock: the request's own usage still tells once it lands.
    }
    if (e.model) meta.model = e.model
    meta.effort = effortLabel(e.effort)
    publish()
    let result
    try {
      result = yield* next(e)
    } catch (err) {
      cache.abort()
      publish()
      throw err
    }
    const usage = result?.usage
    cache.end(usage as CacheUsage | null | undefined)
    if (usage) {
      const tokens = (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0)
      if (tokens > 0) meta.ctx = tokens
    }
    publish()
    void countAgents?.().catch(() => undefined)
    return result
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    // Claude Code measures only when a window moves a whole point; every
    // turn's end says the numbers still hold, so `at` stays fresh.
    if (recordLimits) {
      void $.session
        .usage()
        .then((usage) => recordLimits?.(usage.rateLimits))
        .catch(() => undefined)
    }
    if (labels && e.agentId === undefined) {
      void refresh?.().catch(() => undefined)
      void countAgents?.().catch(() => undefined)
    }
    return result
  })

  // `/model`, `/effort`, `/clear`… change what the labels say without a turn.
  on('command.run', async ($, e, next) => {
    const result = await next(e)
    if (labels) void refresh?.().catch(() => undefined)
    return result
  })

  on('agent.spawn', async ($, e, next) => {
    // A resumed subagent is counted already.
    const fresh = labels !== undefined && !e.resume
    if (fresh) {
      expectSpawn = 2
      startPoll?.()
      try {
        after?.(300, () => void countAgents?.())
      } catch {
        // The poll catches it.
      }
    }
    const result = await next(e)
    // Its id, its model and when it started (the list has the start too from 2.1.327 on).
    const spawned = result as { agentId?: string; model?: string } | undefined
    if (fresh && spawned?.agentId) {
      subagents.spawned(spawned.agentId, spawned.model, await nowOf($))
      publish()
    }
    return result
  })

  on('session.end', async ($, e, next) => {
    stopPoll()
    if (e.reason === 'clear' || e.reason === 'resume') {
      // The process goes on under another session id: keep the labels (no
      // flicker) and let the next reads republish, the new id among them.
      labels?.cancel()
      cache.reset()
      subagents.reset()
      meta.ctx = undefined
      meta.subagents = 0
      if (labels) {
        try {
          after?.(500, () => void refresh?.())
        } catch {
          // The next turn republishes.
        }
      }
      return next(e)
    }
    // Quitting: remove every label, write the last reading, within the
    // budget all session.end hooks share.
    const owned = labels
    labels = undefined
    const budget = Math.max(100, (next.budget?.remainingMs ?? 1500) - 250)
    await Promise.race([
      Promise.all([owned?.clear(), limits?.flush()]).catch(() => undefined),
      $.clock.sleep(budget).catch(() => undefined),
    ])
    limits?.cancel()
    return next(e)
  })
}
