import { describe, expect, test } from 'claude-code/testing'
import {
  clearLabels,
  collectLabels,
  diffLabels,
  effortLabel,
  isFlagOn,
  LABEL_KEYS,
  modelName,
  providerOf,
} from '../hooks/meta'

describe('modelName', () => {
  test('names Claude ids the way pi does', () => {
    expect(modelName('claude-opus-5-5')).toBe('Claude Opus 5.5')
    expect(modelName('claude-sonnet-5-5')).toBe('Claude Sonnet 5.5')
    expect(modelName('claude-fable-5-2')).toBe('Claude Fable 5.2')
    expect(modelName('claude-haiku-4-5-20251001')).toBe('Claude Haiku 4.5')
    expect(modelName('claude-opus-4-1-20250805')).toBe('Claude Opus 4.1')
    expect(modelName('claude-opus-4')).toBe('Claude Opus 4')
    expect(modelName('claude-sonnet-4-20250514')).toBe('Claude Sonnet 4')
  })

  test('old ids put the version first', () => {
    expect(modelName('claude-3-7-sonnet-20250219')).toBe('Claude Sonnet 3.7')
    expect(modelName('claude-3-5-haiku-latest')).toBe('Claude Haiku 3.5')
    expect(modelName('claude-3-opus-20240229')).toBe('Claude Opus 3')
  })

  test('a context suffix and the cloud spellings name the same model', () => {
    expect(modelName('claude-opus-4-6[1m]')).toBe('Claude Opus 4.6')
    expect(modelName('us.anthropic.claude-opus-4-1-20250805-v1:0')).toBe('Claude Opus 4.1')
    expect(modelName('anthropic.claude-sonnet-4-5-20250929-v1:0')).toBe('Claude Sonnet 4.5')
    expect(modelName('claude-opus-4-1@20250805')).toBe('Claude Opus 4.1')
  })

  test('anything else is shown as it is', () => {
    expect(modelName('haiku')).toBe('haiku')
    expect(modelName('gpt-5.5')).toBe('gpt-5.5')
    expect(modelName('my-gateway/model')).toBe('my-gateway/model')
  })
})

describe('provider', () => {
  test('anthropic unless a cloud provider is switched on', () => {
    expect(providerOf({})).toBe('anthropic')
    expect(providerOf({ bedrock: '1' })).toBe('amazon-bedrock')
    expect(providerOf({ vertex: 'true' })).toBe('google-vertex')
    expect(providerOf({ foundry: '1' })).toBe('azure-foundry')
    expect(providerOf({ bedrock: '0', vertex: 'false' })).toBe('anthropic')
  })

  test('flags', () => {
    expect(isFlagOn(undefined)).toBe(false)
    expect(isFlagOn('')).toBe(false)
    expect(isFlagOn('off')).toBe(false)
    expect(isFlagOn('yes')).toBe(true)
  })
})

describe('effort', () => {
  test('a level or a number; nothing for none, unset or auto', () => {
    expect(effortLabel('high')).toBe('high')
    expect(effortLabel('max')).toBe('max')
    expect(effortLabel(32000)).toBe('32000')
    expect(effortLabel(undefined)).toBeUndefined()
    expect(effortLabel('unset')).toBeUndefined()
    expect(effortLabel('auto')).toBeUndefined()
    expect(effortLabel('')).toBeUndefined()
    expect(effortLabel({})).toBeUndefined()
  })
})

describe('labels', () => {
  test('everything known', () => {
    expect(
      collectLabels({
        pid: 88638,
        model: 'claude-opus-5-5',
        provider: 'anthropic',
        effort: 'high',
        ctx: 228432.4,
        ctxMax: 1_000_000,
        subagents: 2,
        session: 'b7e1',
        cache: { until: 1793534700000, ttlMs: 3_600_000 },
      }),
    ).toEqual({
      'agent.app': 'claude-code',
      'agent.pid': '88638',
      'agent.model': 'Claude Opus 5.5',
      'agent.model_id': 'claude-opus-5-5',
      'agent.provider': 'anthropic',
      'agent.effort': 'high',
      'agent.ctx': '228432',
      'agent.ctx_max': '1000000',
      'agent.subagents': '2',
      'agent.session': 'b7e1',
      'agent.cache_until': '1793534700000',
      'agent.cache_ttl': '3600000',
    })
  })

  test('what is not known is left out', () => {
    expect(collectLabels({ ctxMax: 1_000_000, subagents: 0, cache: { until: 5, ttlMs: 0 } })).toEqual({
      'agent.app': 'claude-code',
      'agent.ctx_max': '1000000',
    })
  })

  test('the diff sends changes and removes what vanished', () => {
    const before = collectLabels({ pid: 1, model: 'claude-opus-5-5', ctx: 10, ctxMax: 100 })
    const after = collectLabels({ pid: 1, model: 'claude-opus-5-5', ctxMax: 100, effort: 'max' })
    expect(diffLabels(before, after)).toEqual({ 'agent.ctx': '', 'agent.effort': 'max' })
    expect(diffLabels(after, after)).toEqual({})
  })

  test('clearing removes every owned key', () => {
    const cleared = clearLabels()
    expect(Object.keys(cleared)).toEqual([...LABEL_KEYS])
    expect(Object.values(cleared).every((v) => v === '')).toBe(true)
  })
})
