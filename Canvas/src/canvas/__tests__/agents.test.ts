import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { AGENT_TTL_MS, liveAgents, readAgent, readAgents, toEpochMs, writeAgent } from '../agents'

describe('readAgent', () => {
  it('reads a well-formed entry', () => {
    expect(readAgent('a', { name: 'Scout', color: '#f00', cursor: { x: 1, y: 2 }, status: 'writing', updatedAt: 1_700_000_000_000 })).toEqual({
      id: 'a',
      name: 'Scout',
      color: '#f00',
      cursor: { x: 1, y: 2 },
      status: 'writing',
      updatedAt: 1_700_000_000_000,
    })
  })

  it('normalises malformed values instead of failing', () => {
    expect(readAgent('a', { name: '  ', cursor: { x: 'no' }, status: 'dancing', updatedAt: '2024-01-01T00:00:00Z' })).toEqual({
      id: 'a',
      name: 'Agent',
      color: '',
      cursor: null,
      status: 'idle',
      updatedAt: Date.parse('2024-01-01T00:00:00Z'),
    })
    expect(readAgent('a', 42)).toBeNull()
  })

  it('reads a nested Y.Map too', () => {
    const doc = new Y.Doc()
    const map = doc.getMap<unknown>('agents')
    const m = new Y.Map<unknown>()
    map.set('x', m)
    m.set('name', 'Nested')
    expect(readAgents(map)[0]?.name).toBe('Nested')
  })
})

describe('toEpochMs', () => {
  it('accepts ms, seconds and ISO strings', () => {
    expect(toEpochMs(1_700_000_000_000)).toBe(1_700_000_000_000)
    expect(toEpochMs(1_700_000_000)).toBe(1_700_000_000_000)
    expect(toEpochMs('nope')).toBe(0)
    expect(toEpochMs(undefined)).toBe(0)
  })
})

describe('liveAgents', () => {
  const now = 10_000_000
  const agent = (id: string, name: string, status: 'idle' | 'writing', age: number) => ({
    id,
    name,
    color: '',
    cursor: null,
    status,
    updatedAt: now - age,
  })

  it('hides stale entries and puts busy agents first, then by name', () => {
    const out = liveAgents(
      [agent('1', 'Zed', 'idle', 0), agent('2', 'Bo', 'idle', 10), agent('3', 'Max', 'writing', 5), agent('4', 'Old', 'writing', AGENT_TTL_MS + 1)],
      now
    )
    expect(out.map(a => a.name)).toEqual(['Max', 'Bo', 'Zed'])
  })
})

describe('writeAgent', () => {
  it('merges a patch into the whole entry and stamps the time', () => {
    const map = new Y.Doc().getMap<unknown>('agents')
    writeAgent(map, 'a', { name: 'Scout', color: '#0f0', cursor: { x: 1.4, y: 2.6 }, status: 'thinking' }, 100)
    writeAgent(map, 'a', { status: 'writing' }, 200)
    expect(map.get('a')).toEqual({ name: 'Scout', color: '#0f0', cursor: { x: 1, y: 3 }, status: 'writing', updatedAt: 200 })
    writeAgent(map, 'a', { cursor: null }, 300)
    expect((map.get('a') as { cursor: unknown }).cursor).toBeNull()
  })
})
