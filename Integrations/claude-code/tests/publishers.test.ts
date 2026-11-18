import { describe, expect, test } from 'claude-code/testing'
import { parseReply, requestLine, docOf, setResultOf } from '../hooks/hc'
import { readingFromRateLimits, type LimitsDoc } from '../hooks/limits'
import { type Doc, LimitsPublisher } from '../hooks/limits-publisher'
import { clearLabels } from '../hooks/meta'
import { LabelPublisher } from '../hooks/publisher'
import type { After } from '../hooks/timer'

/** A fake `$.clock.after`: `run()` fires what is due. */
function fakeTimers() {
  const due: Array<{ fn: () => void; live: boolean }> = []
  const after: After = (_ms, fn) => {
    const t = { fn, live: true }
    due.push(t)
    return { cancel: () => (t.live = false) }
  }
  const run = async () => {
    for (const t of due.splice(0)) if (t.live) t.fn()
    for (let i = 0; i < 10; i++) await Promise.resolve()
  }
  return { after, run, pending: () => due.filter((t) => t.live).length }
}

describe('LabelPublisher', () => {
  test('the first write sends every key; changes within the window collapse', async () => {
    const sent: Record<string, string>[] = []
    const timers = fakeTimers()
    const p = new LabelPublisher(async (l) => (sent.push(l), true), timers.after)
    p.publish({ 'agent.app': 'claude-code', 'agent.ctx': '1' })
    p.publish({ 'agent.app': 'claude-code', 'agent.ctx': '2' })
    expect(timers.pending()).toBe(1)
    await timers.run()
    expect(sent).toEqual([{ ...clearLabels(), 'agent.app': 'claude-code', 'agent.ctx': '2' }])

    p.publish({ 'agent.app': 'claude-code', 'agent.ctx': '2' })
    await timers.run()
    expect(sent.length).toBe(1)

    p.publish({ 'agent.app': 'claude-code', 'agent.effort': 'high' })
    await timers.run()
    expect(sent[1]).toEqual({ 'agent.ctx': '', 'agent.effort': 'high' })
  })

  test('a failed write is retried as a difference next time', async () => {
    const sent: Record<string, string>[] = []
    let ok = false
    const timers = fakeTimers()
    const p = new LabelPublisher(async (l) => (sent.push(l), ok), timers.after)
    p.publish({ 'agent.app': 'claude-code' })
    await p.flush()
    ok = true
    p.publish({ 'agent.app': 'claude-code', 'agent.ctx': '5' })
    await p.flush()
    expect(sent[1]).toEqual({ ...clearLabels(), 'agent.app': 'claude-code', 'agent.ctx': '5' })
  })

  test('clear removes everything and stops; cancel drops the queue', async () => {
    const sent: Record<string, string>[] = []
    const timers = fakeTimers()
    const p = new LabelPublisher(async (l) => (sent.push(l), true), timers.after)
    p.publish({ 'agent.app': 'claude-code' })
    await p.flush()
    p.publish({ 'agent.app': 'claude-code', 'agent.ctx': '9' })
    p.cancel()
    await timers.run()
    expect(sent.length).toBe(1)
    await p.clear()
    expect(sent[1]).toEqual(clearLabels())
    p.publish({ 'agent.app': 'claude-code' })
    await timers.run()
    expect(sent.length).toBe(2)
  })
})

describe('LimitsPublisher', () => {
  const reading = readingFromRateLimits([{ kind: 'five_hour', percentUsed: 10, resetsAt: '2026-11-18T19:30:00.000Z' }])!

  test('readings within the window go out as one write at the version read', async () => {
    const sets: Array<{ value: LimitsDoc; version: number }> = []
    const timers = fakeTimers()
    const p = new LimitsPublisher(
      {
        get: async () => ({ value: null, version: 0 }),
        set: async (value, version) => (sets.push({ value, version }), 1),
      },
      timers.after,
    )
    p.host = 'box'
    p.record(reading, { slug: 'main' }, 1_000_000)
    p.record({ ...reading, windows: [{ ...reading.windows[0]!, usedPercent: 12 }] }, { slug: 'main' }, 2_000_000)
    await timers.run()
    await p.flush()
    expect(sets.length).toBe(1)
    expect(sets[0]!.version).toBe(0)
    const account = sets[0]!.value.accounts['claude.main']!
    expect(account.windows['5h']!.used).toBe(12)
    expect(account.at).toBe(2000)
    expect(account.host).toBe('box')
  })

  test('a conflict reads again and retries', async () => {
    const docs: Doc[] = [{ value: null, version: 3 }, { value: null, version: 4 }]
    const versions: number[] = []
    const timers = fakeTimers()
    const p = new LimitsPublisher(
      {
        get: async () => docs.shift(),
        set: async (_value, version) => (versions.push(version), version === 3 ? 'conflict' : version + 1),
      },
      timers.after,
    )
    p.record(reading, { slug: 'main' }, 1_000_000)
    await p.flush()
    expect(versions).toEqual([3, 4])
  })
})

describe('hc connect', () => {
  test('the request line', () => {
    expect(requestLine(7, 'doc.get', { name: 'limits' })).toBe('{"jsonrpc":"2.0","id":7,"method":"doc.get","params":{"name":"limits"}}\n')
  })

  test('answers', () => {
    const got = parseReply('{"id":1,"jsonrpc":"2.0","result":{"value":{"schema":1},"version":12394}}\n', 1)
    expect(got).toEqual({ ok: true, result: { value: { schema: 1 }, version: 12394 } })
    expect(docOf(got)).toEqual({ value: { schema: 1 }, version: 12394 })
    const conflict = parseReply('{"id":2,"jsonrpc":"2.0","error":{"code":-32000,"message":"conflict","data":{"kind":"conflict"}}}', 2)
    expect(conflict).toEqual({ ok: false, error: 'conflict' })
    expect(setResultOf(conflict)).toBe('conflict')
    expect(setResultOf(parseReply('{"id":3,"result":{"version":5}}', 3))).toBe(5)
    expect(docOf(parseReply('{"id":4,"result":{"version":0}}', 4))).toEqual({ value: null, version: 0 })
  })

  test('no answer to this request', () => {
    expect(parseReply('', 1)).toEqual({ ok: false, error: 'bad_reply' })
    expect(parseReply('{"error":{"kind":"unavailable"}}', 1)).toEqual({ ok: false, error: 'bad_reply' })
    expect(parseReply('{"id":9,"result":{}}', 1)).toEqual({ ok: false, error: 'bad_reply' })
  })
})
