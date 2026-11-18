import { expect, mock, test } from 'claude-code/testing'

/** What the mod sent to herdr-core, one entry an `hc connect`. */
interface Sent {
  argv: string[]
  env?: Record<string, string>
  method: string
  params: Record<string, unknown>
}

const HERDR_ENV = {
  HC_TERMINAL_ID: 't9',
  HC_TERMINAL_SOCKET: '/tmp/hc-test.sock',
  HOME: '/home/me',
  WIERDR_CC_LIMITS_DOC: 'scratch-limits',
}

const RATE_LIMITS = [
  { kind: 'five_hour', percentUsed: 5, resetsAt: '2026-11-18T19:30:00.000Z' },
  { kind: 'seven_day', percentUsed: 52, resetsAt: '2026-11-22T08:00:00.000Z' },
]

const CLAUDE_JSON = JSON.stringify({
  oauthAccount: { organizationUuid: 'abc', organizationType: 'claude_max', organizationRateLimitTier: 'default_claude_max_5x' },
})

const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })

/** Stubs for everything the mod reaches, and a record of what it sent. */
function world(on: any, env: Record<string, string> = HERDR_ENV) {
  const clock = mock.clock(on, { now: 1_000_000 })
  mock.env(on, env)
  const sent: Sent[] = []
  const doc: { value: unknown; version: number } = { value: null, version: 0 }
  const session = { id: 'sess-1', model: 'claude-opus-5-5', agents: [] as Array<{ status: string }> }
  on('process.run', ($: unknown, e: { argv: string[]; init?: { stdin?: string; env?: Record<string, string> } }) => {
    if (e.argv[0] === 'hostname') return ok('box\n')
    if (e.argv[0] === '/bin/sh') return ok('4242\n')
    const req = JSON.parse(e.init?.stdin ?? '{}')
    sent.push({ argv: e.argv, env: e.init?.env, method: req.method, params: req.params })
    let result: unknown = {}
    if (req.method === 'doc.get') result = { value: doc.value, version: doc.version }
    if (req.method === 'doc.set') {
      doc.value = req.params.value
      doc.version += 1
      result = { version: doc.version }
    }
    return ok(`${JSON.stringify({ id: req.id, jsonrpc: '2.0', result })}\n`)
  })
  on('settings.read', () => ({ value: { effortLevel: 'high' } }))
  on('session.id', () => ({ value: session.id }))
  on('session.model', () => ({ value: session.model }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 1_000_000 }, rateLimits: RATE_LIMITS, cost: { usd: 0 } } }))
  on('agent.list', () => ({ value: session.agents }))
  on('fs.read', () => ({ value: CLAUDE_JSON }))
  on('session.start', () => ({ cwd: '/work' }))
  on('session.measure', ($: unknown, e: { changed: string[] }) => ({ changed: e.changed }))
  on('session.end', ($: unknown, e: { sessionId: string }) => ({ sessionId: e.sessionId }))
  on('turn.complete', () => ({ text: '' }))
  on('turn.step', async function* ($: unknown, e: { turnId: string; index: number }) {
    yield { kind: 'text', index: 0, text: 'ok' }
    return {
      turnId: e.turnId,
      index: e.index,
      answer: 'ok',
      toolUses: [],
      stopReason: 'end_turn',
      usage: {
        input_tokens: 3,
        output_tokens: 5,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 51411,
        ephemeral_5m_input_tokens: 0,
        ephemeral_1h_input_tokens: 51411,
        model: 'claude-opus-5-5',
      },
    }
  })
  const labelCalls = () => sent.filter((s) => s.method === 'terminal.label').map((s) => s.params.labels as Record<string, string>)
  return { clock, sent, doc, session, labelCalls }
}

async function runStep($: any, e: Record<string, unknown>) {
  const stream = $.turn.step(e)
  let step = await stream.next()
  while (step.done !== true) step = await stream.next()
  return step.value
}

test('an interactive session in a herdr-core terminal publishes its labels at start', async ($, on) => {
  const w = world(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  const [first] = w.sent
  expect(first?.argv).toEqual(['hc', 'connect'])
  expect(first?.env).toEqual({ HC_SOCKET: '/tmp/hc-test.sock' })
  expect(first?.method).toBe('terminal.label')
  expect(first?.params.terminal).toBe('t9')
  expect(first?.params.labels).toEqual({
    'agent.app': 'claude-code',
    'agent.pid': '4242',
    'agent.model': 'Claude Opus 5.5',
    'agent.model_id': 'claude-opus-5-5',
    'agent.provider': 'anthropic',
    'agent.effort': 'high',
    'agent.ctx': '',
    'agent.ctx_max': '1000000',
    'agent.subagents': '',
    'agent.session': 'sess-1',
    'agent.cache_until': '',
    'agent.cache_ttl': '',
  })
})

test('a request sets the cache window, the context and its effort', async ($, on) => {
  const w = world(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await runStep($, { turnId: 'turn-1', index: 0, model: 'claude-opus-5-5', effort: 'max', messageCount: 1 })
  await w.clock.advance(200)
  const last = w.labelCalls().at(-1)
  expect(last).toEqual({
    'agent.effort': 'max',
    'agent.ctx': '51414',
    'agent.cache_until': String(1_000_000 + 3_600_000),
    'agent.cache_ttl': '3600000',
  })
  // A subagent's request leaves the main loop's labels alone.
  const before = w.labelCalls().length
  await runStep($, { turnId: 'turn-1', index: 1, model: 'claude-haiku-4-5', messageCount: 1, agentId: 'a1' })
  await w.clock.advance(200)
  expect(w.labelCalls().length).toBe(before)
})

test('subagents are counted while they run, then polled until none is left', async ($, on) => {
  const w = world(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  w.session.agents = [{ status: 'running' }, { status: 'pending' }, { status: 'completed' }]
  await runStep($, { turnId: 'turn-1', index: 0, model: 'claude-haiku-4-5', messageCount: 1, agentId: 'a1' })
  await w.clock.advance(200)
  expect(w.labelCalls().at(-1)).toEqual({ 'agent.subagents': '2' })
  w.session.agents = [{ status: 'completed' }, { status: 'completed' }]
  await w.clock.advance(5_200)
  expect(w.labelCalls().at(-1)).toEqual({ 'agent.subagents': '' })
})

test('limits are folded into the document the mod is pointed at', async ($, on) => {
  const w = world(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await $.session.measure({ context: { window: 1_000_000 }, rateLimits: RATE_LIMITS, changed: ['context', 'rateLimits'] })
  await w.clock.advance(600)
  const set = w.sent.find((s) => s.method === 'doc.set')
  expect(set?.params.name).toBe('scratch-limits')
  expect(set?.params.version).toBe(0)
  const value = set?.params.value as any
  expect(value.schema).toBe(1)
  expect(value.accounts['claude.ba7816bf']).toEqual({
    provider: 'claude',
    account: 'ba7816bf',
    plan: 'max_5x',
    source: 'claude-code',
    host: 'box',
    at: 1000,
    windows: {
      '5h': { id: '5h', label: '5 hours', window_s: 18000, used: 5, resets_at: 1795030200, at: 1000 },
      '7d': { id: '7d', label: '7 days', window_s: 604800, used: 52, resets_at: 1795334400, at: 1000 },
    },
  })
})

test('quitting removes every label; /clear keeps them and republishes the new session', async ($, on) => {
  const w = world(on)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  const n = w.labelCalls().length
  w.session.id = 'sess-2'
  await $.session.end({ reason: 'clear', sessionId: 'sess-1', resume: { id: 'sess-1' } })
  expect(w.labelCalls().length).toBe(n)
  await w.clock.advance(800)
  expect(w.labelCalls().at(-1)).toEqual({ 'agent.session': 'sess-2' })

  await $.session.end({ reason: 'prompt_input_exit', sessionId: 'sess-2', resume: { id: 'sess-2' } })
  const cleared = w.labelCalls().at(-1)!
  expect(Object.keys(cleared).length).toBe(12)
  expect(Object.values(cleared).every((v) => v === '')).toBe(true)
})

test('claude -p writes no labels, but still the limits', async ($, on) => {
  const w = world(on)
  await $.session.start({ surface: null, isInteractive: false, cwd: '/work' })
  await $.session.measure({ context: { window: 200_000 }, rateLimits: RATE_LIMITS, changed: ['rateLimits'] })
  await w.clock.advance(600)
  expect(w.labelCalls()).toEqual([])
  expect(w.sent.some((s) => s.method === 'doc.set')).toBe(true)
})

test('outside a herdr-core terminal it does nothing', async ($, on) => {
  const w = world(on, { HOME: '/home/me' })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await $.session.measure({ context: { window: 200_000 }, rateLimits: RATE_LIMITS, changed: ['rateLimits'] })
  await runStep($, { turnId: 'turn-1', index: 0, model: 'claude-opus-5-5', messageCount: 1 })
  await w.clock.advance(1_000)
  expect(w.sent).toEqual([])
})
