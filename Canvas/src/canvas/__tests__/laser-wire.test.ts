import { describe, expect, it } from 'vitest'
import { LaserTrails, type LaserStroke } from '../laser'
import { decodeWire, encodeWire, isLaserWire, wireNewest } from '../laser/wire'

const T0 = 1_700_000_000_000.4

function stroke(n: number, ended = false): LaserStroke {
  const points = []
  for (let i = 0; i < n; i++) {
    const a = (i / n) * Math.PI * 2
    points.push({ x: 300 + Math.cos(a) * 123.456, y: -200 + Math.sin(a) * 98.765, t: T0 + i * 8.3 })
  }
  return { id: 'abc', color: '#3b82f6', points, endedAt: ended ? T0 + n * 8.3 + 40.6 : null }
}

describe('wire encoding', () => {
  it('is flat [x, y, dt, …] rounded to 0.1 px and whole ms', () => {
    const w = encodeWire(stroke(10, true))!
    expect(w.id).toBe('abc')
    expect(w.color).toBe('#3b82f6')
    expect(w.start).toBe(Math.round(T0))
    expect(Number.isInteger(w.start)).toBe(true)
    expect(Number.isInteger(w.end!)).toBe(true)
    expect(w.pts).toHaveLength(30)
    for (let i = 0; i < w.pts.length; i += 3) {
      expect(Math.round(w.pts[i]! * 10) / 10).toBe(w.pts[i])
      expect(Math.round(w.pts[i + 1]! * 10) / 10).toBe(w.pts[i + 1])
      expect(Number.isInteger(w.pts[i + 2])).toBe(true)
    }
    expect(w.pts[2]).toBe(0)
    expect(JSON.stringify(w.pts)).not.toMatch(/\d\.\d{2}/) // no float noise in the JSON
  })

  it('round-trips back to a LaserStroke', () => {
    const s = stroke(250, true)
    const back = decodeWire(encodeWire(s)!)
    expect(back.id).toBe(s.id)
    expect(back.color).toBe(s.color)
    expect(back.points).toHaveLength(250)
    back.points.forEach((p, i) => {
      const o = s.points[i]!
      expect(Math.abs(p.x - o.x)).toBeLessThanOrEqual(0.05 + 1e-9)
      expect(Math.abs(p.y - o.y)).toBeLessThanOrEqual(0.05 + 1e-9)
      expect(Math.abs(p.t - o.t)).toBeLessThanOrEqual(1)
    })
    expect(Math.abs(back.endedAt! - s.endedAt!)).toBeLessThanOrEqual(1)
    const active = decodeWire(encodeWire(stroke(5))!)
    expect(active.endedAt).toBeNull()
  })

  it('keeps at most 400 points, the newest 200 dense, the first point always', () => {
    const s = stroke(1500)
    const w = encodeWire(s)!
    const n = w.pts.length / 3
    expect(n).toBeLessThanOrEqual(400)
    expect(n).toBeGreaterThan(250)
    const back = decodeWire(w)
    // first point kept, so the stroke's extent and its fade schedule are intact
    expect(back.points[0]!.x).toBeCloseTo(s.points[0]!.x, 1)
    // the newest 200 are exactly the newest 200 samples
    const head = back.points.slice(-200)
    head.forEach((p, i) => expect(p.x).toBeCloseTo(s.points[1300 + i]!.x, 1))
    // older ones are thinned evenly and stay in order
    const dts: number[] = []
    for (let i = 2; i < w.pts.length; i += 3) dts.push(w.pts[i]!)
    for (let i = 1; i < dts.length; i++) expect(dts[i]!).toBeGreaterThanOrEqual(dts[i - 1]!)
    expect(dts.at(-1)).toBe(Math.round(T0 + 1499 * 8.3) - Math.round(T0))
    expect(JSON.stringify(w).length).toBeLessThan(9000)
  })

  it('downsamples stably while a stroke grows (old samples do not shimmer)', () => {
    const s = stroke(1200)
    const a = new Set(decodeWire(encodeWire(s)!).points.slice(0, -200).map((p) => p.x))
    s.points.push({ x: 1, y: 1, t: T0 + 1e4 }, { x: 2, y: 2, t: T0 + 1e4 + 8 })
    const b = decodeWire(encodeWire(s)!).points.slice(0, -202).map((p) => p.x)
    for (const x of b) expect(a.has(x)).toBe(true)
  })

  it('validates wires from the network', () => {
    expect(isLaserWire(encodeWire(stroke(3)))).toBe(true)
    expect(isLaserWire(null)).toBe(false)
    expect(isLaserWire({ id: 'x', start: 'now', end: null, pts: [1, 2, 3] })).toBe(false)
    expect(isLaserWire({ id: 'x', start: 1, end: null, pts: [] })).toBe(false)
    const bad = decodeWire({ id: 'x', color: '#fff', start: 0, end: null, pts: [1, 2, 0, NaN, 3, 4, 5, 6, 7, 8] })
    expect(bad.points).toEqual([
      { x: 1, y: 2, t: 0 },
      { x: 5, y: 6, t: 7 },
    ])
  })

  it('wireNewest is the last point, or end when later', () => {
    expect(wireNewest({ id: 'a', color: '', start: 100, end: null, pts: [0, 0, 0, 1, 1, 40] })).toBe(140)
    expect(wireNewest({ id: 'a', color: '', start: 100, end: 175, pts: [0, 0, 0, 1, 1, 40] })).toBe(175)
  })
})

describe('localWire', () => {
  it('returns the same object until the stroke changes', () => {
    const tr = new LaserTrails()
    expect(tr.localWire()).toBeNull()
    tr.begin({ x: 0, y: 0 }, '#ff5a36', T0)
    const a = tr.localWire(T0)
    expect(a).not.toBeNull()
    expect(tr.localWire(T0 + 5)).toBe(a)
    tr.move({ x: 10, y: 0 }, T0 + 16)
    const b = tr.localWire(T0 + 16)!
    expect(b).not.toBe(a)
    expect(b.pts).toEqual([0, 0, 0, 10, 0, 16])
    tr.end(T0 + 30)
    expect(tr.localWire(T0 + 30)!.end).toBe(Math.round(T0 + 30))
  })

  it('stays under 400 points for a long scribble', () => {
    const tr = new LaserTrails({ tailMs: 1e9 })
    tr.begin({ x: 0, y: 0 }, '#ff5a36', T0)
    for (let i = 1; i < 3000; i++) tr.move({ x: Math.sin(i / 9) * 300, y: i }, T0 + i * 8)
    const w = tr.localWire(T0 + 3000 * 8)!
    expect(w.pts.length / 3).toBeLessThanOrEqual(400)
  })
})
