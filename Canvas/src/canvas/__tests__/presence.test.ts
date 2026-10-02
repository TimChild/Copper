import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { Awareness, applyAwarenessUpdate, encodeAwarenessUpdate } from 'y-protocols/awareness'
import { CanvasStore } from '../doc'
import { applyOps } from '../../ops'
import { seedOps } from '../debug'
import { LaserTrails } from '../laser'
import { TOOL_KEYS } from '../components/Chrome'
import { involvesOthers, readPeers, samePeers, syncRemoteLasers, type AwarenessChanges } from '../use-presence'

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
