import { describe, expect, it } from 'vitest'
import { LaserTrails, type LaserWire } from '../laser'

const LOCAL = 1_700_000_000_000 // our clock
const SKEW = 3 * 3600_000 + 1234 // the peer's clock runs 3 h ahead

function wire(over: Partial<LaserWire> = {}): LaserWire {
  // A stroke the peer drew over 1 s (on its own clock).
  return {
    id: 'w1',
    color: '#22c55e',
    start: LOCAL + SKEW - 1000,
    end: null,
    pts: [0, 0, 0, 50, 0, 500, 100, 0, 1000],
    ...over,
  }
}

const remote = (tr: LaserTrails) => tr.strokes().find((s) => s.color === '#22c55e')

describe('remote clock skew', () => {
  it('anchors the newest point to our receipt time, keeping relative offsets', () => {
    const tr = new LaserTrails()
    tr.setRemote(7, wire(), LOCAL)
    const s = remote(tr)!
    expect(s.points.map((p) => p.t)).toEqual([LOCAL - 1000, LOCAL - 500, LOCAL])
    expect(s.endedAt).toBeNull()
  })

  it('works the same for a peer whose clock is behind ours', () => {
    const tr = new LaserTrails()
    tr.setRemote(7, wire({ start: LOCAL - 86_400_000 }), LOCAL)
    expect(remote(tr)!.points.map((p) => p.t)).toEqual([LOCAL - 1000, LOCAL - 500, LOCAL])
  })

  it('maps end by the same rule, so hold and fade run on our clock', () => {
    const tr = new LaserTrails()
    // released 100 ms after its last point; that release is the newest moment, so it is "now"
    tr.setRemote(7, wire({ end: LOCAL + SKEW + 100 }), LOCAL)
    const s = remote(tr)!
    expect(s.endedAt).toBe(LOCAL)
    expect(s.points.at(-1)!.t).toBe(LOCAL - 100)
    expect(tr.hasVisible(LOCAL + 2999)).toBe(true)
    expect(tr.hasVisible(LOCAL + 3000)).toBe(false)
  })

  it('an update of the same stroke keeps the first anchor (no drift from latency)', () => {
    const tr = new LaserTrails()
    tr.setRemote(7, wire(), LOCAL)
    // 200 ms later on both clocks the peer has one more point and has released; it reaches us 30 ms late
    const w2 = wire({ pts: [0, 0, 0, 50, 0, 500, 100, 0, 1000, 150, 0, 1200], end: LOCAL + SKEW + 200 })
    tr.setRemote(7, w2, LOCAL + 230)
    const s = remote(tr)!
    expect(s.points.at(-1)!.t).toBe(LOCAL + 200)
    expect(s.endedAt).toBe(LOCAL + 200)
  })

  it('a later copy that arrives faster lowers the offset (never maps into the future)', () => {
    const tr = new LaserTrails()
    tr.setRemote(7, wire(), LOCAL + 80) // first copy was 80 ms in flight
    expect(remote(tr)!.points.at(-1)!.t).toBe(LOCAL + 80)
    const w2 = wire({ pts: [0, 0, 0, 50, 0, 500, 100, 0, 1000, 150, 0, 1100] })
    tr.setRemote(7, w2, LOCAL + 110) // this one only 10 ms
    expect(remote(tr)!.points.at(-1)!.t).toBe(LOCAL + 110)
    expect(remote(tr)!.points[0]!.t).toBe(LOCAL + 110 - 1100)
  })

  it('a re-sent unchanged wire (e.g. a cursor update) never extends the stroke', () => {
    const tr = new LaserTrails()
    const ended = wire({ end: LOCAL + SKEW })
    tr.setRemote(7, ended, LOCAL)
    tr.setRemote(7, { ...ended }, LOCAL + 1500)
    tr.setRemote(7, { ...ended }, LOCAL + 2900)
    expect(remote(tr)!.endedAt).toBe(LOCAL)
    tr.prune(LOCAL + 3000)
    expect(remote(tr)).toBeUndefined()
    tr.setRemote(7, { ...ended }, LOCAL + 4000) // after it faded: not resurrected
    expect(remote(tr)).toBeUndefined()
    expect(tr.hasVisible(LOCAL + 4000)).toBe(false)
  })
})

describe('setRemote', () => {
  it('a new wire id replaces the client stroke; the old one finishes its own fade', () => {
    const tr = new LaserTrails()
    tr.setRemote(7, wire({ end: LOCAL + SKEW }), LOCAL)
    tr.setRemote(7, wire({ id: 'w2', color: '#a855f7', start: LOCAL + SKEW + 500, pts: [9, 9, 0] }), LOCAL + 500)
    const list = tr.strokes()
    expect(list).toHaveLength(2)
    expect(list.map((s) => s.id)).toEqual(['w1', 'w2'])
    tr.prune(LOCAL + 3000)
    expect(tr.strokes().map((s) => s.id)).toEqual(['w2'])
  })

  it('a new id while the old stroke never got its end releases the old one now', () => {
    const tr = new LaserTrails()
    tr.setRemote(7, wire(), LOCAL)
    tr.setRemote(7, wire({ id: 'w2', start: LOCAL + SKEW + 40, pts: [9, 9, 0] }), LOCAL + 40)
    expect(tr.strokes()[0]!.endedAt).toBe(LOCAL + 40)
  })

  it('null lets an ended stroke finish on its schedule, then forgets the client', () => {
    const tr = new LaserTrails()
    tr.setRemote(7, wire({ end: LOCAL + SKEW }), LOCAL)
    tr.setRemote(7, null, LOCAL + 500)
    expect(tr.strokes()).toHaveLength(1)
    expect(tr.strokes()[0]!.endedAt).toBe(LOCAL)
    expect(tr.hasVisible(LOCAL + 2999)).toBe(true)
    tr.prune(LOCAL + 3000)
    expect(tr.strokes()).toHaveLength(0)
    expect(tr.hasVisible(LOCAL + 3000)).toBe(false)
  })

  it('null on a stroke still being drawn releases it now: it holds and fades, not vanishes', () => {
    const tr = new LaserTrails()
    tr.setRemote('peer', wire(), LOCAL)
    tr.setRemote('peer', null, LOCAL + 300)
    const s = tr.strokes()[0]!
    expect(s.endedAt).toBe(LOCAL + 300)
    expect(tr.hasVisible(LOCAL + 300 + 2999)).toBe(true)
    expect(tr.hasVisible(LOCAL + 300 + 3000)).toBe(false)
  })

  it('null (or undefined) for an unknown client is a no-op', () => {
    const tr = new LaserTrails()
    let n = 0
    tr.subscribe(() => n++)
    tr.setRemote(1, null, LOCAL)
    tr.setRemote(2, undefined as unknown as null, LOCAL)
    expect(n).toBe(0)
  })

  it('treats numeric and string client ids alike and keeps clients apart', () => {
    const tr = new LaserTrails()
    tr.setRemote(7, wire(), LOCAL)
    tr.setRemote('7', wire({ pts: [0, 0, 0, 1, 1, 1000, 2, 2, 1010] }), LOCAL + 10)
    expect(tr.strokes()).toHaveLength(1)
    tr.setRemote(8, wire(), LOCAL)
    expect(tr.strokes()).toHaveLength(2)
  })

  it('ignores malformed wires', () => {
    const tr = new LaserTrails()
    tr.setRemote(7, { id: 'x' } as unknown as LaserWire, LOCAL)
    tr.setRemote(7, wire({ pts: [] }), LOCAL)
    tr.setRemote(7, wire({ start: Number.NaN }), LOCAL)
    expect(tr.strokes()).toHaveLength(0)
  })
})
