import { describe, expect, it } from 'vitest'
import { LIVE_KEEP_MS, MAX_MOUNTED, planLiveFrames, rankFrames, type LiveEntry } from '../frames'

const visible = { x: 0, y: 0, w: 2000, h: 1000 }
const at = (id: string, x: number, y = 0, w = 900, h = 600) => ({ id, x, y, w, h })
const none = new Map<string, LiveEntry>()

describe('ranking frames for a page', () => {
  it('puts frames already live first, then the nearest the middle', () => {
    const frames = [at('a', 0), at('b', 600), at('c', 1500)]
    expect(rankFrames(frames, { visible, zoom: 1, active: null, mounted: new Set() })).toEqual(['b', 'a', 'c'])
    expect(rankFrames(frames, { visible, zoom: 1, active: null, mounted: new Set(['c']) })).toEqual(['c', 'b', 'a'])
    expect(rankFrames(frames, { visible, zoom: 1, active: 'b', mounted: new Set() })).toEqual(['a', 'c'])
  })
})

describe('planning live frames over time', () => {
  it('makes new pages only once the view has settled', () => {
    const frames = [at('a', 100)]
    const moving = planLiveFrames(frames, { visible, zoom: 1, active: null, settled: false, now: 0, prev: none })
    expect([...moving.mounted.keys()]).toEqual([])
    const still = planLiveFrames(frames, { visible, zoom: 1, active: null, settled: true, now: 200, prev: none })
    expect([...still.mounted.keys()]).toEqual(['a'])
    expect(still.mounted.get('a')).toEqual({ since: 200, lastWanted: 200 })
  })

  it('keeps the page of a frame that left the screen for a while, then lets it go', () => {
    const frames = [at('a', 100)]
    const prev = new Map([['a', { since: 0, lastWanted: 1000 }]])
    const gone = { x: 50000, y: 0, w: 2000, h: 1000 }
    const kept = planLiveFrames(frames, { visible: gone, zoom: 1, active: null, settled: true, now: 2000, prev })
    expect(kept.mounted.has('a')).toBe(true)
    expect(kept.mounted.get('a')!.lastWanted).toBe(1000)
    expect(kept.next).toBe(1000 + LIVE_KEEP_MS)
    expect(kept.dropped).toEqual([])
    const later = planLiveFrames(frames, { visible: gone, zoom: 1, active: null, settled: true, now: 1000 + LIVE_KEEP_MS, prev: kept.mounted })
    expect(later.mounted.size).toBe(0)
    expect(later.dropped).toEqual(['a'])
    expect(later.next).toBeNull()
  })

  it('panning back to a kept frame keeps its page (no reload) even while moving', () => {
    const frames = [at('a', 100)]
    const prev = new Map([['a', { since: 0, lastWanted: 1000 }]])
    const back = planLiveFrames(frames, { visible, zoom: 1, active: null, settled: false, now: 3000, prev })
    expect(back.mounted.get('a')).toEqual({ since: 0, lastWanted: 3000 })
  })

  it('never goes over budget: a wanted frame takes the slot of the one wanted longest ago', () => {
    const frames = Array.from({ length: MAX_MOUNTED + 2 }, (_, i) => at(`f${i}`, 30000 + i * 1000))
    // The budget is full of frames that left the screen, wanted at different times.
    const prev = new Map(frames.slice(0, MAX_MOUNTED).map((f, i) => [f.id, { since: 0, lastWanted: 100 + i }] as const))
    const onScreen = [...frames, at('new', 100)]
    const plan = planLiveFrames(onScreen, { visible, zoom: 1, active: null, settled: true, now: 500, prev })
    expect(plan.mounted.size).toBe(MAX_MOUNTED)
    expect(plan.mounted.has('new')).toBe(true)
    expect(plan.dropped).toEqual(['f0'])
  })

  it('always keeps the frame in use and a pinned one, without refreshing a pinned one', () => {
    const frames = [at('use', 90000), at('hold', 80000), at('a', 100)]
    const prev = new Map([['hold', { since: 0, lastWanted: 50 }]])
    const plan = planLiveFrames(frames, { visible, zoom: 0.1, active: 'use', pinned: new Set(['hold']), settled: false, now: 9000, prev })
    expect([...plan.mounted.keys()]).toEqual(['use', 'hold'])
    expect(plan.mounted.get('hold')!.lastWanted).toBe(50)
    expect(plan.mounted.get('use')!.lastWanted).toBe(9000)
  })

  it('drops pages of frames that are gone from the board', () => {
    const prev = new Map([['gone', { since: 0, lastWanted: 100 }]])
    const plan = planLiveFrames([], { visible, zoom: 1, active: null, settled: true, now: 200, prev })
    expect(plan.dropped).toEqual(['gone'])
  })

  it('zoomed out past legibility, frames stop being wanted but keep their pages a while', () => {
    const frames = [at('a', 100)]
    const prev = new Map([['a', { since: 0, lastWanted: 100 }]])
    const plan = planLiveFrames(frames, { visible: { x: -5000, y: -5000, w: 20000, h: 10000 }, zoom: 0.1, active: null, settled: true, now: 500, prev })
    expect(plan.mounted.get('a')!.lastWanted).toBe(100)
    expect(plan.next).toBe(100 + LIVE_KEEP_MS)
  })
})
