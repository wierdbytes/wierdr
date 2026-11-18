import { describe, expect, test } from 'claude-code/testing'
import { collectLabels, subagentsMetaLabel } from '../hooks/meta'
import { SubagentTracker } from '../hooks/subagents'

/** `$.agent.list()`'s entry on 2.1.327 (live, an Explore agent after its first request). */
const LISTED = {
  id: 'afb09f7b0628fd476',
  description: 'Look around',
  type: 'Explore',
  status: 'running',
  kind: 'local_agent',
  taskStatus: 'running',
  label: 'Look around',
  startTime: 1795030972758,
  cwd: '/private/tmp/wierdrtest-cc',
  model: 'claude-haiku-5-5',
  contextWindowSize: 1000000,
  tokenCount: 16085,
  tokenSamples: [0, 16085],
  lastRequest: { at: 1795030972802, model: 'claude-haiku-5-5', effort: 'medium', cacheTtl: '5m' },
  hasRow: true,
}

/** A teammate between turns, as 2.1.327 lists it (live, `Agent` with a `name`, agent teams on). */
const TEAMMATE = {
  id: 'ahelper-c2e58121067329e7',
  teammateId: 'helper@session-60e03445',
  description: 'Helper',
  type: 'teammate',
  status: 'idle',
  name: 'helper',
  kind: 'in_process_teammate',
  taskStatus: 'running',
  label: 'Helper',
  startTime: 1795033739159,
  model: 'claude-haiku-5-5',
  contextWindowSize: 1000000,
  tokenCount: 35722,
  lastRequest: { at: 1795033739208, model: 'claude-haiku-5-5', effort: 'medium', cacheTtl: '5m' },
  hasRow: true,
}

/** That request's usage (`turn.step`'s result, live). */
const USAGE = {
  input_tokens: 2,
  output_tokens: 323,
  cache_read_input_tokens: 0,
  cache_creation_input_tokens: 15743,
  model: 'claude-haiku-5-5',
}

describe('SubagentTracker', () => {
  test('the list tells the model, the effort sent, the window and the start', () => {
    const t = new SubagentTracker()
    expect(t.listed([LISTED, { id: 'a2', status: 'completed' }])).toBe(1)
    expect(t.snapshot()).toEqual({
      afb09f7b0628fd476: {
        title: 'Look around',
        status: 'running',
        since: 1795030972758,
        model: 'claude-haiku-5-5',
        effort: 'medium',
        ctxMax: 1000000,
        started: 1795030972758,
        ctx: 16085,
      },
    })
  })

  test("a request's usage is its context, exact, over the list's token count", () => {
    const t = new SubagentTracker()
    t.spawned('afb09f7b0628fd476', 'claude-haiku-5-5', 1795030972785)
    t.requested('afb09f7b0628fd476', 'claude-haiku-5-5', 'medium')
    t.answered('afb09f7b0628fd476', USAGE)
    // Nothing shows before a list read names it running.
    expect(t.snapshot()).toEqual({})
    t.listed([LISTED], 1795030973000)
    expect(t.snapshot().afb09f7b0628fd476).toEqual({
      title: 'Look around',
      status: 'running',
      // Running since the spawn said so.
      since: 1795030972785,
      model: 'claude-haiku-5-5',
      effort: 'medium',
      ctx: 15745,
      ctxMax: 1000000,
      started: 1795030972758,
    })
    // Later list reads keep the measured context.
    t.listed([{ ...LISTED, tokenCount: 17125 }])
    expect(t.snapshot().afb09f7b0628fd476?.ctx).toBe(15745)
  })

  test("2.1.319's list (id and status only): the spawn and the steps tell it all", () => {
    const t = new SubagentTracker()
    t.spawned('a1', 'claude-opus-5-5', 5000)
    t.requested('a1', 'claude-opus-5-5', 'high')
    t.answered('a1', { input_tokens: 10, cache_read_input_tokens: 900, cache_creation_input_tokens: 90 })
    expect(t.listed([{ id: 'a1', status: 'waiting', description: 'Count', name: 'counter' }, { status: 'pending' }], 6000)).toBe(2)
    expect(t.snapshot()).toEqual({
      a1: { title: 'Count', name: 'counter', status: 'waiting', since: 6000, model: 'claude-opus-5-5', effort: 'high', ctx: 1000, started: 5000 },
    })
  })

  test('a teammate between turns stays, idle since its turn ended, and runs again when woken', () => {
    const t = new SubagentTracker()
    t.spawned(TEAMMATE.id, 'claude-haiku-5-5', 1795033739160)
    expect(t.listed([{ ...TEAMMATE, status: 'running' }], 1795033739500)).toBe(1)
    expect(t.snapshot()[TEAMMATE.id]).toMatchObject({ title: 'Helper', name: 'helper', status: 'running', since: 1795033739160 })
    expect(t.listed([TEAMMATE, { id: 'a2', status: 'completed' }], 1795033741000)).toBe(1)
    expect(t.snapshot()[TEAMMATE.id]).toMatchObject({ status: 'idle', since: 1795033741000, ctxMax: 1000000, started: 1795033739159 })
    // The list stays idle: so does its time.
    t.listed([TEAMMATE], 1795033746000)
    expect(t.snapshot()[TEAMMATE.id]?.since).toBe(1795033741000)
    // A message wakes it: its first request says it runs, before the next list read.
    t.requested(TEAMMATE.id, 'claude-haiku-5-5', 'medium', 1795033750000)
    expect(t.snapshot()[TEAMMATE.id]).toMatchObject({ status: 'running', since: 1795033750000 })
    // Seen idle first (the mod loaded between its turns): idle from then on.
    const u = new SubagentTracker()
    u.listed([TEAMMATE], 1795033760000)
    expect(u.snapshot()[TEAMMATE.id]).toMatchObject({ status: 'idle', since: 1795033760000 })
  })

  test('agents that are gone are forgotten, and so are ids the list never names', () => {
    const t = new SubagentTracker()
    t.requested('workflow-1', 'claude-opus-5-5', 'high')
    t.listed([LISTED, { id: 'a2', status: 'running' }])
    expect(Object.keys(t.snapshot())).toEqual(['a2', 'afb09f7b0628fd476'])
    t.listed([{ ...LISTED, status: 'completed' }, { id: 'a2', status: 'running' }, { id: 'a3', status: 'killed' }, { id: 'a4', status: 'failed' }])
    expect(Object.keys(t.snapshot())).toEqual(['a2'])
    // Coming back (a teammate's next turn) starts afresh from the list.
    t.listed([LISTED])
    expect(t.snapshot().afb09f7b0628fd476?.ctx).toBe(16085)
    // A list that can't be read changes nothing.
    expect(t.listed(undefined)).toBe(1)
    t.reset()
    expect(t.snapshot()).toEqual({})
  })

  test('an effort a request carries none of is dropped; auto and unset are none', () => {
    const t = new SubagentTracker()
    t.listed([{ id: 'a1', status: 'running', effort: 'high' }])
    expect(t.snapshot().a1?.effort).toBe('high')
    t.requested('a1', 'claude-haiku-5-5', undefined)
    expect(t.snapshot().a1?.effort).toBeUndefined()
    t.listed([{ id: 'a1', status: 'running', lastRequest: { model: 'claude-haiku-5-5', effort: 'auto' } }])
    expect(t.snapshot().a1?.effort).toBeUndefined()
  })
})

describe('agent.subagents_meta', () => {
  test('one JSON object by id, named as the agent labels are', () => {
    const label = subagentsMetaLabel({
      ahelper: { title: 'Helper', name: 'helper', status: 'idle', since: 9.6, model: 'claude-opus-5-5', effort: 'max', ctx: 1200.4, ctxMax: 200000, started: 7 },
      afb09f7b0628fd476: {
        title: 'Look around',
        status: 'running',
        since: 1795030972758,
        model: 'claude-haiku-5-5',
        effort: 'medium',
        ctx: 15745,
        ctxMax: 1000000,
        started: 1795030972758,
      },
    })
    expect(label).toBe(
      '{"afb09f7b0628fd476":{"title":"Look around","status":"running","since":1795030972758,"model":"Claude Haiku 5.5","model_id":"claude-haiku-5-5","effort":"medium","ctx":15745,"ctx_max":1000000,"started":1795030972758},' +
        '"ahelper":{"title":"Helper","name":"helper","status":"idle","since":10,"model":"Claude Opus 5.5","model_id":"claude-opus-5-5","effort":"max","ctx":1200,"ctx_max":200000,"started":7}}',
    )
  })

  test("without the list's window, the session's for the session's model only", () => {
    const main = { model: 'claude-opus-5-5', ctxMax: 1_000_000 }
    expect(JSON.parse(subagentsMetaLabel({ a1: { model: 'claude-opus-5-5' } }, main)!)).toEqual({
      a1: { model: 'Claude Opus 5.5', model_id: 'claude-opus-5-5', ctx_max: 1000000 },
    })
    expect(JSON.parse(subagentsMetaLabel({ a1: { model: 'claude-haiku-5-5' } }, main)!)).toEqual({
      a1: { model: 'Claude Haiku 5.5', model_id: 'claude-haiku-5-5' },
    })
    expect(JSON.parse(subagentsMetaLabel({ a1: {} }, main)!)).toEqual({ a1: {} })
  })

  test('none running: no label', () => {
    expect(subagentsMetaLabel(undefined)).toBeUndefined()
    expect(subagentsMetaLabel({})).toBeUndefined()
    expect(collectLabels({ subagentsMeta: {} })).toEqual({ 'agent.app': 'claude-code' })
    expect(collectLabels({ model: 'claude-opus-5-5', ctxMax: 1000, subagents: 1, subagentsMeta: { a1: { model: 'claude-opus-5-5' } } })).toEqual({
      'agent.app': 'claude-code',
      'agent.model': 'Claude Opus 5.5',
      'agent.model_id': 'claude-opus-5-5',
      'agent.ctx_max': '1000',
      'agent.subagents': '1',
      'agent.subagents_meta': '{"a1":{"model":"Claude Opus 5.5","model_id":"claude-opus-5-5","ctx_max":1000}}',
    })
  })
})
