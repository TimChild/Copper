import { afterEach, describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { Awareness, applyAwarenessUpdate, encodeAwarenessUpdate } from 'y-protocols/awareness'
import { CanvasStore } from '../doc'
import { applyOps } from '../../ops'
import { seedOps } from '../debug'
import { LaserTrails } from '../laser'
import { TOOL_KEYS } from '../components/Chrome'
import { Controller } from '../../controller'
import { involvesOthers, readPeers, samePeers, syncRemoteLasers, type AwarenessChanges } from '../use-presence'
import { createPresenceReporter, facepilePeople, hostPresence, mergePresence } from '../presence'

const T0 = 1_700_000_000_000

/** Copy `from`'s own state into `to`, the way the relayed socket would; returns the change `to` saw. */
function relay(from: Awareness, to: Awareness): AwarenessChanges {
  let seen: AwarenessChanges = { added: [], updated: [], removed: [] }
  const grab = (c: AwarenessChanges) => {
    seen = c
  }
  to.on('change', grab)
  applyAwarenessUpdate(to, encodeAwarenessUpdate(from, [from.clientID]), 'relay')
  to.off('change', grab)
  return seen
}

describe('presence messages', () => {
  afterEach(() => vi.useRealTimers())

  it('debounces and diffs people, ignoring cursor-only changes', () => {
    vi.useFakeTimers()
    const posted: unknown[] = []
    const reporter = createPresenceReporter(people => posted.push(people), 400)
    const ada = { id: 'ada', name: 'Ada', color: '#2f6fdf', kind: 'human' as const }
    reporter.update([ada])
    reporter.update([ada])
    vi.advanceTimersByTime(399)
    expect(posted).toEqual([])
    vi.advanceTimersByTime(1)
    expect(posted).toEqual([[ada]])
    reporter.update([ada])
    vi.advanceTimersByTime(500)
    expect(posted).toHaveLength(1)
    reporter.update([])
    vi.advanceTimersByTime(400)
    expect(posted).toEqual([[ada], []])
  })

  it('orders a facepile and reports overflow after four circles', () => {
    const people = Array.from({ length: 6 }, (_, i) => ({
      id: `p${i}`,
      name: `Person ${i}`,
      color: `#${i}${i}${i}`,
      kind: 'human' as const,
      cursor: null,
      selection: [],
    }))
    const out = facepilePeople(people)
    expect(out.shown.map(p => p.id)).toEqual(['p0', 'p1', 'p2', 'p3'])
    expect(out.overflow).toBe(2)
    expect(hostPresence(mergePresence(people.slice(0, 1), []))).toEqual([
      { id: 'p0', name: 'Person 0', color: '#000', kind: 'human' },
    ])
  })
})

describe('presence re-renders', () => {
  it('ignores changes that only involve this client', () => {
    expect(involvesOthers({ added: [], updated: [7], removed: [] }, 7)).toBe(false)
    expect(involvesOthers({ added: [], updated: [7, 9], removed: [] }, 7)).toBe(true)
    expect(involvesOthers({ added: [], updated: [], removed: [3] }, 7)).toBe(true)
    expect(involvesOthers(undefined, 7)).toBe(true)
  })

  it('keeps the peer list when a peer only moved its laser', () => {
    const me = new Awareness(new Y.Doc())
    const ada = new Awareness(new Y.Doc())
    ada.setLocalState({ user: { id: 'ada', name: 'Ada', color: '#2f6fdf' }, cursor: { x: 10, y: 20 }, selection: ['n1'], laser: null })
    relay(ada, me)
    const before = readPeers(me)
    expect(before).toHaveLength(1)
    const trails = new LaserTrails()
    trails.begin({ x: 0, y: 0 }, '#2f6fdf', T0)
    trails.move({ x: 40, y: 0 }, T0 + 16)
    ada.setLocalStateField('laser', trails.localWire(T0 + 16))
    relay(ada, me)
    expect(samePeers(before, readPeers(me))).toBe(true)
    ada.setLocalStateField('cursor', { x: 11, y: 20 })
    relay(ada, me)
    expect(samePeers(before, readPeers(me))).toBe(false)
  })
})

describe('two-client awareness presence', () => {
  it('shows client A with its cursor in client B presence()', () => {
    const a = new Controller()
    const b = new Controller()
    try {
      a.init({ docId: 'room', name: 'Board', kind: 'shared', me: { id: 'a', name: 'Ada', color: '#2f6fdf' } })
      b.init({ docId: 'room', name: 'Board', kind: 'shared', me: { id: 'b', name: 'Bea', color: '#d6336c' } })
      const source = a.session!.awareness
      const target = b.session!.awareness
      applyAwarenessUpdate(target, encodeAwarenessUpdate(source, [source.clientID]), 'relay')
      source.setLocalStateField('cursor', { x: 42, y: 84 })
      applyAwarenessUpdate(target, encodeAwarenessUpdate(source, [source.clientID]), 'relay')
      expect(b.presence()).toContainEqual({ id: 'a', name: 'Ada', color: '#2f6fdf', kind: 'human', cursor: { x: 42, y: 84 } })
      source.setLocalState(null)
      applyAwarenessUpdate(target, encodeAwarenessUpdate(source, [source.clientID]), 'relay')
      expect(b.presence()).toEqual([])
    } finally {
      a.session?.destroy()
      b.session?.destroy()
    }
  })
})

describe('the laser over awareness', () => {
  it('draws a peer’s stroke from its awareness, and lets it fade when it goes', () => {
    const me = new Awareness(new Y.Doc())
    const ada = new Awareness(new Y.Doc())
    const hers = new LaserTrails()
    const mine = new LaserTrails()
    const now = Date.now()
    hers.begin({ x: 0, y: 0 }, '#2f6fdf', now)
    hers.move({ x: 50, y: 10 }, now + 16)
    hers.move({ x: 100, y: 40 }, now + 32)
    ada.setLocalState({ user: { id: 'ada', name: 'Ada', color: '#2f6fdf' }, cursor: null, laser: hers.localWire(now + 32) })
    syncRemoteLasers(me, mine, relay(ada, me))
    const strokes = mine.strokes()
    expect(strokes).toHaveLength(1)
    expect(strokes[0]).toMatchObject({ color: '#2f6fdf', endedAt: null })
    expect(strokes[0]!.points.map(p => [p.x, p.y])).toEqual([
      [0, 0],
      [50, 10],
      [100, 40],
    ])
    // Released: the copy here ends too, then fades on its own schedule.
    hers.end(now + 40)
    ada.setLocalStateField('laser', hers.localWire(now + 40))
    syncRemoteLasers(me, mine, relay(ada, me))
    expect(mine.strokes()[0]!.endedAt).not.toBeNull()
    expect(mine.hasVisible()).toBe(true)
    ada.setLocalStateField('laser', null)
    syncRemoteLasers(me, mine, relay(ada, me))
    mine.prune(Date.now() + 10_000)
    expect(mine.hasVisible(Date.now() + 10_000)).toBe(false)
  })

  it('never draws our own stroke twice', () => {
    const me = new Awareness(new Y.Doc())
    const mine = new LaserTrails()
    me.setLocalState({ laser: { id: 'x', color: '#f00', start: T0, end: null, pts: [0, 0, 0, 5, 5, 10] } })
    syncRemoteLasers(me, mine, { added: [], updated: [me.clientID], removed: [] })
    expect(mine.strokes()).toHaveLength(0)
  })

  it('is on K, and the board starts with no laser in awareness', async () => {
    expect(TOOL_KEYS.k).toBe('laser')
    expect(TOOL_KEYS.l).toBe('link')
    const { Controller } = await import('../../controller')
    const c = new Controller()
    const g = globalThis as { window?: unknown }
    const had = 'window' in g
    if (!had) g.window = {}
    try {
      c.init({ docId: 'd', me: { id: 'u', name: 'U', color: '#000' } })
      expect(c.session!.awareness.getLocalState()).toMatchObject({ laser: null, cursor: null })
    } finally {
      c.session?.destroy()
      if (!had) delete g.window
    }
  })
})

describe('the perf seed', () => {
  it('builds a big board with valid ops', () => {
    const store = new CanvasStore(new Y.Doc())
    const out = applyOps({ store, viewportCenter: () => ({ x: 0, y: 0 }) }, { ops: seedOps({ stickies: 40, frames: 4, arrows: 10 }) })
    expect(out.errors).toEqual([])
    expect(store.liveAll().filter(s => s.type === 'sticky')).toHaveLength(40)
    expect(store.liveAll().filter(s => s.type === 'arrow')).toHaveLength(10)
  })
})
