import { describe, expect, it } from 'vitest'
import { LaserTrails, drawLaser } from '../laser'
import { parseColor } from '../laser/draw'

const T0 = 1_700_000_000_000

type Call = { op: string; args: number[]; alpha: number; width: number; stroke: string; fill: string }

/** Just enough of CanvasRenderingContext2D to record what drawLaser does. */
function mockCtx(w = 2000, h = 1200) {
  const calls: Call[] = []
  const state = { globalAlpha: 1, lineWidth: 1, strokeStyle: '#000', fillStyle: '#000' as unknown }
  const rec =
    (op: string) =>
    (...args: unknown[]) => {
      calls.push({
        op,
        args: args.filter((a): a is number => typeof a === 'number'),
        alpha: state.globalAlpha,
        width: state.lineWidth,
        stroke: String(state.strokeStyle),
        fill: String(state.fillStyle),
      })
    }
  const ctx = {
    canvas: { width: w, height: h },
    get globalAlpha() {
      return state.globalAlpha
    },
    set globalAlpha(v: number) {
      state.globalAlpha = v
    },
    get lineWidth() {
      return state.lineWidth
    },
    set lineWidth(v: number) {
      state.lineWidth = v
    },
    get strokeStyle() {
      return state.strokeStyle
    },
    set strokeStyle(v: string) {
      state.strokeStyle = v
    },
    get fillStyle() {
      return state.fillStyle
    },
    set fillStyle(v: unknown) {
      state.fillStyle = v
    },
    globalCompositeOperation: 'source-over',
    lineCap: 'butt',
    lineJoin: 'miter',
    setTransform: rec('setTransform'),
    clearRect: rec('clearRect'),
    beginPath: rec('beginPath'),
    moveTo: rec('moveTo'),
    lineTo: rec('lineTo'),
    quadraticCurveTo: rec('quadraticCurveTo'),
    arc: rec('arc'),
    closePath: rec('closePath'),
    stroke: rec('stroke'),
    fill: rec('fill'),
    createRadialGradient: () => ({ addColorStop() {} }),
  }
  return { ctx: ctx as unknown as CanvasRenderingContext2D, calls }
}

function circle(tr: LaserTrails, cx: number, cy: number, r: number, t0: number, n = 60) {
  tr.begin({ x: cx + r, y: cy }, '#ff5a36', t0)
  for (let i = 1; i <= n; i++) {
    const a = (i / n) * Math.PI * 2
    tr.move({ x: cx + Math.cos(a) * r, y: cy + Math.sin(a) * r }, t0 + i * 10)
  }
}

describe('drawLaser', () => {
  it('clears and returns false when there is nothing to draw', () => {
    const { ctx, calls } = mockCtx()
    expect(drawLaser(ctx, new LaserTrails(), { x: 0, y: 0, z: 1 }, 2, T0)).toBe(false)
    expect(calls.map((c) => c.op)).toEqual(['setTransform', 'clearRect'])
  })

  it('projects canvas coords through the camera and dpr', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 10, y: 20 }, '#ff5a36', T0)
    tr.move({ x: 30, y: 20 }, T0 + 10)
    tr.move({ x: 50, y: 40 }, T0 + 20)
    const { ctx, calls } = mockCtx()
    expect(drawLaser(ctx, tr, { x: 100, y: 50, z: 2 }, 2, T0 + 30)).toBe(true)
    const move = calls.find((c) => c.op === 'moveTo')!
    expect(move.args).toEqual([(10 * 2 + 100) * 2, (20 * 2 + 50) * 2])
    const last = calls.filter((c) => c.op === 'lineTo').at(-1)!
    expect(last.args).toEqual([(50 * 2 + 100) * 2, (40 * 2 + 50) * 2])
    // smooth: the middle sample is a quadratic control point, not a corner
    expect(calls.some((c) => c.op === 'quadraticCurveTo' && c.args[0] === (30 * 2 + 100) * 2)).toBe(true)
    // a glowing head dot while drawing
    expect(calls.some((c) => c.op === 'setTransform' && c.args[4] === (50 * 2 + 100) * 2)).toBe(true)
  })

  it('keeps line widths in screen px whatever the zoom', () => {
    const widths = (z: number) => {
      const tr = new LaserTrails()
      circle(tr, 0, 0, 100, T0)
      const { ctx, calls } = mockCtx()
      drawLaser(ctx, tr, { x: 600, y: 400, z }, 2, T0 + 700)
      return [...new Set(calls.filter((c) => c.op === 'stroke').map((c) => c.width))].sort((a, b) => a - b)
    }
    const w1 = widths(1)
    expect(widths(0.25)).toEqual(w1)
    expect(widths(4)).toEqual(w1)
    expect(Math.max(...w1)).toBeCloseTo(14 * 2, 5) // 14 px glow at dpr 2
    expect(w1).toContain(4.2 * 2) // ~4 px solid line
  })

  it('draws a fully alive stroke as one path per pass with round caps', () => {
    const tr = new LaserTrails()
    circle(tr, 0, 0, 100, T0)
    tr.end(T0 + 600)
    const { ctx, calls } = mockCtx()
    drawLaser(ctx, tr, { x: 600, y: 400, z: 1 }, 2, T0 + 1600)
    expect(calls.filter((c) => c.op === 'stroke')).toHaveLength(6)
    expect(ctx.lineCap).toBe('round')
  })

  it('splits a fading stroke into runs that thin and dim toward the tail', () => {
    const tr = new LaserTrails()
    circle(tr, 0, 0, 100, T0)
    tr.end(T0 + 600)
    const { ctx, calls } = mockCtx()
    drawLaser(ctx, tr, { x: 600, y: 400, z: 1 }, 2, T0 + 600 + 2450)
    // five passes in the stroke colour (four glow layers, then the solid line), one call per run
    const base = calls.filter((c) => c.op === 'stroke' && c.stroke === 'rgb(255,90,54)')
    expect(base.length % 5).toBe(0)
    const solid = base.slice((base.length / 5) * 4)
    expect(solid.length).toBeGreaterThan(3)
    for (let i = 1; i < solid.length; i++) {
      expect(solid[i]!.alpha).toBeGreaterThanOrEqual(solid[i - 1]!.alpha)
      expect(solid[i]!.width).toBeGreaterThanOrEqual(solid[i - 1]!.width)
    }
    expect(ctx.lineCap).toBe('butt')
    expect(calls.some((c) => c.op === 'arc')).toBe(true) // the two real ends get half-disk caps
  })

  it('stops (returns false) once everything has faded, leaving a clear canvas', () => {
    const tr = new LaserTrails()
    circle(tr, 0, 0, 100, T0)
    tr.end(T0 + 600)
    const { ctx } = mockCtx()
    expect(drawLaser(ctx, tr, { x: 0, y: 0, z: 1 }, 1, T0 + 600 + 2999)).toBe(true)
    const m = mockCtx()
    expect(drawLaser(m.ctx, tr, { x: 0, y: 0, z: 1 }, 1, T0 + 600 + 3000)).toBe(false)
    expect(m.calls.map((c) => c.op)).toEqual(['setTransform', 'clearRect'])
    expect(tr.strokes()).toHaveLength(0)
  })

  it('after the first frame clears only what it painted last frame', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 100, y: 100 }, '#ff5a36', T0)
    tr.move({ x: 200, y: 150 }, T0 + 10)
    const { ctx, calls } = mockCtx(2000, 1200)
    drawLaser(ctx, tr, { x: 0, y: 0, z: 1 }, 2, T0 + 20)
    expect(calls.find((c) => c.op === 'clearRect')!.args).toEqual([0, 0, 2000, 1200])
    calls.length = 0
    drawLaser(ctx, tr, { x: 0, y: 0, z: 1 }, 2, T0 + 36)
    // samples span 200..400 x 200..300 device px, plus the 14 px (28 device px) paint margin
    expect(calls.find((c) => c.op === 'clearRect')!.args).toEqual([172, 172, 256, 156])
    tr.cancel()
    calls.length = 0
    expect(drawLaser(ctx, tr, { x: 0, y: 0, z: 1 }, 2, T0 + 52)).toBe(false)
    expect(calls.find((c) => c.op === 'clearRect')!.args).toEqual([172, 172, 256, 156])
    calls.length = 0
    drawLaser(ctx, tr, { x: 0, y: 0, z: 1 }, 2, T0 + 68)
    expect(calls.some((c) => c.op === 'clearRect')).toBe(false) // nothing was painted: nothing to clear
  })

  it('skips strokes that are off screen but keeps animating them', () => {
    const tr = new LaserTrails()
    circle(tr, 5000, 5000, 50, T0)
    const { ctx, calls } = mockCtx(800, 600)
    expect(drawLaser(ctx, tr, { x: 0, y: 0, z: 1 }, 2, T0 + 700)).toBe(true)
    expect(calls.some((c) => c.op === 'stroke' || c.op === 'fill')).toBe(false)
  })

  it('uses the stroke colour and a light core blended from it', () => {
    const tr = new LaserTrails()
    tr.setRemote(1, { id: 'r', color: '#3b82f6', start: 0, end: null, pts: [0, 0, 0, 40, 0, 20, 80, 0, 40] }, T0)
    const { ctx, calls } = mockCtx()
    drawLaser(ctx, tr, { x: 100, y: 100, z: 1 }, 1, T0)
    const styles = new Set(calls.filter((c) => c.op === 'stroke').map((c) => c.stroke))
    expect(styles.has('rgb(59,130,246)')).toBe(true)
    const core = [...styles].find((s) => s !== 'rgb(59,130,246)')!
    // each channel 55% of the way to white: light enough to glow, not paper-white
    expect(parseColor(core)).toEqual([167, 199, 251])
  })

  it('parses the colour forms awareness may carry', () => {
    expect(parseColor('#ff5a36')).toEqual([255, 90, 54])
    expect(parseColor('#F53')).toEqual([255, 85, 51])
    expect(parseColor('#ff5a3680')).toEqual([255, 90, 54])
    expect(parseColor('rgb(1, 2, 3)')).toEqual([1, 2, 3])
    expect(parseColor('rgba(1 2 3 / 50%)')).toEqual([1, 2, 3])
    expect(parseColor('nope')).toBeNull()
  })
})
