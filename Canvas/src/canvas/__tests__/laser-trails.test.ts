import { describe, expect, it } from 'vitest'
import { LaserTrails } from '../laser'
import { fillLife, pointLife } from '../laser/trails'
import { DEFAULT_TIMING } from '../laser/types'

const T0 = 1_700_000_000_000
const timing = DEFAULT_TIMING

function lives(tr: LaserTrails, now: number): number[] {
  const s = tr.strokes().at(-1)!
  const out: number[] = []
  fillLife(s, now, tr, out)
  return out
}

describe('drawing', () => {
  it('starts a stroke with one point and the default timings', () => {
    const tr = new LaserTrails()
    expect([tr.holdMs, tr.fadeMs, tr.tailMs]).toEqual([2000, 1000, 4000])
    const id = tr.begin({ x: 10, y: 20 }, '#ff5a36', T0)
    expect(id).toMatch(/\w+/)
    const s = tr.strokes()[0]!
    expect(s.points).toEqual([{ x: 10, y: 20, t: T0 }])
    expect(s.endedAt).toBeNull()
    expect(tr.hasVisible(T0 + 60_000)).toBe(true) // still held down: visible however long
  })

  it('ignores moves under 1.5 px from the last kept point, scaled by zoom', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.move({ x: 1, y: 1 }, T0 + 10) // 1.41 px
    expect(tr.strokes()[0]!.points).toHaveLength(1)
    tr.move({ x: 1.5, y: 0 }, T0 + 20)
    expect(tr.strokes()[0]!.points).toHaveLength(2)
    tr.setZoom(4) // 1.5 screen px = 0.375 world px
    tr.move({ x: 1.9, y: 0 }, T0 + 30)
    expect(tr.strokes()[0]!.points).toHaveLength(3)
    tr.setZoom(0.25) // 6 world px
    tr.move({ x: 7, y: 0 }, T0 + 40)
    expect(tr.strokes()[0]!.points).toHaveLength(3)
    tr.move({ x: 8, y: 0 }, T0 + 50)
    expect(tr.strokes()[0]!.points).toHaveLength(4)
  })

  it('keeps times monotonic and ignores moves after end', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.move({ x: 10, y: 0 }, T0 - 50)
    expect(tr.strokes()[0]!.points[1]!.t).toBe(T0)
    tr.end(T0 + 100)
    tr.move({ x: 20, y: 0 }, T0 + 120)
    expect(tr.strokes()[0]!.points).toHaveLength(2)
  })

  it('caps a local stroke at 2000 points, dropping the oldest', () => {
    const tr = new LaserTrails({ tailMs: 1e9 })
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    for (let i = 1; i <= 2500; i++) tr.move({ x: i * 2, y: 0 }, T0 + i)
    const pts = tr.strokes()[0]!.points
    expect(pts).toHaveLength(2000)
    expect(pts.at(-1)!.x).toBe(5000)
    expect(pts[0]!.x).toBe(1002)
  })
})

describe('tail fade while drawing', () => {
  it('fades points older than tailMs over fadeMs, at exact ms', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.move({ x: 10, y: 0 }, T0 + 3000)
    expect(lives(tr, T0 + 4000)).toEqual([1, 1])
    expect(lives(tr, T0 + 4500)[0]).toBeCloseTo(0.5, 9)
    expect(lives(tr, T0 + 4750)[0]).toBeCloseTo(0.25, 9)
    expect(lives(tr, T0 + 5000)).toEqual([0, 1])
    expect(lives(tr, T0 + 7000)).toEqual([0, 1])
    expect(lives(tr, T0 + 7500)[1]).toBeCloseTo(0.5, 9)
    expect(lives(tr, T0 + 8000)).toEqual([0, 0])
    expect(tr.hasVisible(T0 + 8000)).toBe(true) // the head dot still shows while held
  })

  it('prunes fully faded tail points but keeps the head', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.move({ x: 10, y: 0 }, T0 + 1000)
    tr.move({ x: 20, y: 0 }, T0 + 2000)
    tr.prune(T0 + 4999)
    expect(tr.strokes()[0]!.points).toHaveLength(3)
    tr.prune(T0 + 5000) // the first point is now tail + fade old
    expect(tr.strokes()[0]!.points.map((p) => p.x)).toEqual([10, 20])
    tr.prune(T0 + 60_000)
    expect(tr.strokes()[0]!.points.map((p) => p.x)).toEqual([20])
  })
})

describe('release: hold, fade, prune', () => {
  function released(): LaserTrails {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.move({ x: 50, y: 0 }, T0 + 500)
    tr.move({ x: 100, y: 0 }, T0 + 1000)
    tr.end(T0 + 1000)
    return tr
  }
  const E = T0 + 1000

  it('holds the whole stroke for holdMs', () => {
    const tr = released()
    expect(tr.strokes()[0]!.endedAt).toBe(E)
    expect(lives(tr, E)).toEqual([1, 1, 1])
    expect(lives(tr, E + 1000)).toEqual([1, 1, 1])
    expect(lives(tr, E + 2000)).toEqual([1, 1, 1])
  })

  it('fades over fadeMs, tail first, the head 40% of fadeMs later', () => {
    const tr = released()
    // tail (u = 0) fades over [E+2000, E+2600]; head (u = 1) over [E+2400, E+3000]
    const at2300 = lives(tr, E + 2300)
    expect(at2300[0]).toBeCloseTo(0.5, 9)
    expect(at2300[2]).toBe(1)
    const at2500 = lives(tr, E + 2500)
    expect(at2500[0]).toBeCloseTo(1 / 6, 9)
    expect(at2500[1]).toBeCloseTo(1 - (500 - 200) / 600, 9)
    expect(at2500[2]).toBeCloseTo(5 / 6, 9)
    expect(lives(tr, E + 2600)[0]).toBe(0)
    expect(lives(tr, E + 2700)[2]).toBeCloseTo(0.5, 9)
    expect(lives(tr, E + 2999)[2]).toBeGreaterThan(0)
    expect(lives(tr, E + 3000)).toEqual([0, 0, 0])
  })

  it('is visible until E + hold + fade and pruned exactly then', () => {
    const tr = released()
    expect(tr.hasVisible(E + 2999)).toBe(true)
    tr.prune(E + 2999)
    expect(tr.strokes()).toHaveLength(1)
    expect(tr.localWire(E + 2999)).not.toBeNull()
    expect(tr.hasVisible(E + 3000)).toBe(false)
    expect(tr.localWire(E + 3000)).toBeNull()
    tr.prune(E + 3000)
    expect(tr.strokes()).toHaveLength(0)
    expect(tr.localWire(E)).toBeNull()
  })

  it('freezes the tail fade at release', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.move({ x: 100, y: 0 }, T0 + 4500)
    tr.end(T0 + 4500) // the first point is half faded at release
    expect(pointLife(tr.strokes()[0]!, 0, T0 + 4500, timing)).toBeCloseTo(0.5, 9)
    expect(pointLife(tr.strokes()[0]!, 0, T0 + 6000, timing)).toBeCloseTo(0.5, 9) // still holding
    expect(pointLife(tr.strokes()[0]!, 1, T0 + 6000, timing)).toBe(1)
  })

  it('honours custom timings', () => {
    const tr = new LaserTrails({ holdMs: 100, fadeMs: 50, tailMs: 1000 })
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.end(T0 + 10)
    expect(tr.hasVisible(T0 + 159)).toBe(true)
    expect(tr.hasVisible(T0 + 160)).toBe(false)
  })

  it('a click (one point) is a dot that holds and fades like a stroke', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 5, y: 5 }, '#f00', T0)
    tr.end(T0 + 80)
    expect(lives(tr, T0 + 80 + 2000)).toEqual([1])
    expect(lives(tr, T0 + 80 + 2700)[0]).toBeCloseTo(0.5, 9)
    expect(tr.hasVisible(T0 + 80 + 3000)).toBe(false)
  })
})

describe('begin and cancel', () => {
  it('a new local stroke leaves the previous one fading on its own schedule', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.end(T0 + 100)
    tr.begin({ x: 50, y: 50 }, '#f00', T0 + 500)
    expect(tr.strokes()).toHaveLength(2)
    tr.prune(T0 + 100 + 3000)
    expect(tr.strokes()).toHaveLength(1)
    expect(tr.strokes()[0]!.points[0]!.x).toBe(50)
  })

  it('begin while the previous stroke is still down releases it first', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.begin({ x: 9, y: 9 }, '#f00', T0 + 200)
    expect(tr.strokes()[0]!.endedAt).toBe(T0 + 200)
  })

  it('cancel drops the local stroke at once', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.move({ x: 10, y: 0 }, T0 + 10)
    tr.cancel()
    expect(tr.strokes()).toHaveLength(0)
    expect(tr.localWire(T0 + 20)).toBeNull()
    expect(tr.hasVisible(T0 + 20)).toBe(false)
  })
})
