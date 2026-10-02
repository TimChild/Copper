/**
 * drawLaser: paints every laser stroke into a screen-space 2D canvas.
 *
 * Each stroke is a quadratic-midpoint spline through its samples (smooth, C1 at every joint),
 * stroked in six passes: four widening, fainter glow layers in the stroke colour (stacked they
 * fall off softly; no shadowBlur, which is slow in WebKit), a solid ~4 px line in the colour and a
 * thin light core. Points carry a
 * life in [0, 1] (see `fillLife`); segments are grouped into runs of equal quantised life, and each
 * run is one path with butt ends so neighbouring runs abut without overlapping (no beading where
 * alpha < 1). Only the stroke's two real ends get round caps. Life drops alpha and thins the
 * width, and the core thins fastest so a fading stroke cools from white-hot to plain colour.
 * While a stroke is still being drawn its head carries a small glowing dot.
 *
 * Widths are CSS px times `dpr` and ignore zoom, so the laser reads the same at any zoom. No
 * allocations per frame beyond growing the scratch buffers and a per-colour palette cache.
 */
import { fillLife, type LaserTrails } from './trails'
import { DEFAULT_LASER_COLOR, type LaserStroke, type LaserTiming, type LaserView } from './types'

type Pass = {
  /** width in CSS px at full life */
  w: number
  /** alpha at full life */
  a: number
  /** 0 = the stroke colour, 1 = the near-white core tint */
  tone: 0 | 1
  /** width share left at life 0 (width = w * (thin + (1 - thin) * life)) */
  thin: number
}

const PASSES: readonly Pass[] = [
  { w: 14, a: 0.06, tone: 0, thin: 0.45 },
  { w: 10.5, a: 0.08, tone: 0, thin: 0.45 },
  { w: 7.5, a: 0.13, tone: 0, thin: 0.45 },
  { w: 5.6, a: 0.26, tone: 0, thin: 0.4 },
  { w: 4.2, a: 1, tone: 0, thin: 0.35 },
  { w: 1.15, a: 0.9, tone: 1, thin: 0 },
]

/** Share of white mixed into the colour for the core: light enough to glow, not paper-white. */
const CORE_MIX = 0.55
/** Life levels; runs break where the level changes. */
const LEVELS = 24
/** Head dot glow radius, CSS px. */
const HEAD_R = 12
/** A click (one-sample stroke) draws its dot this much wider than the line. */
const DOT_SCALE = 1.6
/** Paint reach beyond a stroke's samples (glow, head dot, click dot), CSS px. */
const MARGIN = 14

type Palette = {
  base: string
  core: string
  rgb: [number, number, number]
  coreRgb: [number, number, number]
  head: CanvasGradient | null
  headKey: number
  headCtx: CanvasRenderingContext2D | null
}

let X = new Float32Array(0)
let Y = new Float32Array(0)
let L = new Float32Array(0)
let Q = new Uint8Array(0)
let RUN = new Int32Array(0)

/** Device-px bounds painted this frame: minX, minY, maxX, maxY. */
const frame = new Float64Array(4)
/** What each context painted last frame, so the next frame only clears that. */
const lastPaint = new WeakMap<CanvasRenderingContext2D, Float64Array>()

function ensure(n: number): void {
  if (X.length >= n + 1) return
  let c = 256
  while (c < n + 1) c *= 2
  X = new Float32Array(c)
  Y = new Float32Array(c)
  L = new Float32Array(c)
  Q = new Uint8Array(c)
  RUN = new Int32Array(c + 1)
}

/**
 * Draw every visible stroke of `trails` at `now` into `ctx` (a canvas sized at `dpr` device px
 * per CSS px), through the camera `view`. First clears what it painted last time (the whole canvas
 * on the first call for a context; the canvas is assumed to be the laser's alone). Returns true
 * while anything is still visible or animating, i.e. while the caller should draw again next frame.
 */
export function drawLaser(
  ctx: CanvasRenderingContext2D,
  trails: LaserTrails,
  view: LaserView,
  dpr: number,
  now: number
): boolean {
  trails.prune(now)
  const canvas = ctx.canvas
  const w = canvas.width
  const h = canvas.height
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.globalAlpha = 1
  ctx.globalCompositeOperation = 'source-over'
  // Clear only what the previous frame painted (the whole canvas the first time): a full clear of
  // a Retina-sized canvas is a large share of a frame in WebKit's CPU canvas.
  let last = lastPaint.get(ctx)
  if (!last) {
    ctx.clearRect(0, 0, w, h)
    last = new Float64Array([Infinity, Infinity, -Infinity, -Infinity])
    lastPaint.set(ctx, last)
  } else if (last[2]! > last[0]!) {
    const x0 = Math.max(0, Math.floor(last[0]!))
    const y0 = Math.max(0, Math.floor(last[1]!))
    const x1 = Math.min(w, Math.ceil(last[2]!))
    const y1 = Math.min(h, Math.ceil(last[3]!))
    if (x1 > x0 && y1 > y0) ctx.clearRect(x0, y0, x1 - x0, y1 - y0)
  }
  frame[0] = Infinity
  frame[1] = Infinity
  frame[2] = -Infinity
  frame[3] = -Infinity
  const list = trails.strokes()
  if (list.length > 0) {
    const d = Number.isFinite(dpr) && dpr > 0 ? dpr : 1
    ctx.lineJoin = 'round'
    for (let i = 0; i < list.length; i++) drawStroke(ctx, list[i]!, view, d, now, trails, w, h)
    ctx.globalAlpha = 1
  }
  last.set(frame)
  return list.length > 0 && trails.hasVisible(now)
}

function drawStroke(
  ctx: CanvasRenderingContext2D,
  s: LaserStroke,
  view: LaserView,
  dpr: number,
  now: number,
  timing: LaserTiming,
  cw: number,
  ch: number
): void {
  const pts = s.points
  const n = pts.length
  if (n === 0) return
  ensure(n)
  const first = fillLife(s, now, timing, L)
  const active = s.endedAt === null
  if (first >= n && !active) return

  // Project into device px and quantise life.
  const k = view.z * dpr
  const ox = view.x * dpr
  const oy = view.y * dpr
  let minX = Infinity
  let minY = Infinity
  let maxX = -Infinity
  let maxY = -Infinity
  const from = Math.min(first, n - 1)
  for (let i = from; i < n; i++) {
    const p = pts[i]!
    const x = p.x * k + ox
    const y = p.y * k + oy
    X[i] = x
    Y[i] = y
    Q[i] = Math.round(L[i]! * LEVELS)
    if (x < minX) minX = x
    if (x > maxX) maxX = x
    if (y < minY) minY = y
    if (y > maxY) maxY = y
  }
  const m = MARGIN * dpr
  if (maxX < -m || maxY < -m || minX > cw + m || minY > ch + m) return
  if (minX - m < frame[0]!) frame[0] = minX - m
  if (minY - m < frame[1]!) frame[1] = minY - m
  if (maxX + m > frame[2]!) frame[2] = maxX + m
  if (maxY + m > frame[3]!) frame[3] = maxY + m

  const pal = palette(ctx, s.color)

  if (first < n) {
    if (n === 1) {
      drawDot(ctx, pal, X[0]!, Y[0]!, L[0]!, dpr)
    } else {
      // Runs of equal level over segments first..n-1 (segment i is the curve around point i).
      let runs = 0
      RUN[0] = first
      for (let i = first + 1; i < n; i++) {
        if (Q[i] !== Q[i - 1]) RUN[++runs] = i
      }
      RUN[++runs] = n
      const single = runs === 1
      ctx.lineCap = single ? 'round' : 'butt'
      for (let pi = 0; pi < PASSES.length; pi++) {
        const pass = PASSES[pi]!
        const color = pass.tone === 0 ? pal.base : pal.core
        ctx.strokeStyle = color
        for (let r = 0; r < runs; r++) {
          const a = RUN[r]!
          const b = RUN[r + 1]! - 1
          const life = Q[a]! / LEVELS
          if (life <= 0) continue
          const lw = pass.w * (pass.thin + (1 - pass.thin) * life) * dpr
          if (lw < 0.05) continue
          ctx.globalAlpha = pass.a * life
          ctx.lineWidth = lw
          ctx.beginPath()
          trace(ctx, n, a, b)
          ctx.stroke()
        }
        if (!single) {
          // Round off the two real ends without overlapping the butt ends of the runs.
          ctx.fillStyle = color
          const tl = Q[first]! / LEVELS
          if (tl > 0) {
            const sx = first === 0 ? X[0]! : (X[first - 1]! + X[first]!) / 2
            const sy = first === 0 ? Y[0]! : (Y[first - 1]! + Y[first]!) / 2
            const dx = first === 0 ? X[1]! - X[0]! : X[first]! - X[first - 1]!
            const dy = first === 0 ? Y[1]! - Y[0]! : Y[first]! - Y[first - 1]!
            halfDisk(ctx, sx, sy, (pass.w * (pass.thin + (1 - pass.thin) * tl) * dpr) / 2, dx, dy, true, pass.a * tl)
          }
          const hl = Q[n - 1]! / LEVELS
          if (hl > 0) {
            const dx = X[n - 1]! - X[n - 2]!
            const dy = Y[n - 1]! - Y[n - 2]!
            halfDisk(ctx, X[n - 1]!, Y[n - 1]!, (pass.w * (pass.thin + (1 - pass.thin) * hl) * dpr) / 2, dx, dy, false, pass.a * hl)
          }
        }
      }
    }
  }

  if (active) drawHead(ctx, pal, X[n - 1]!, Y[n - 1]!, dpr)
}

/** Path for segments a..b of the midpoint spline through X/Y[0..n). */
function trace(ctx: CanvasRenderingContext2D, n: number, a: number, b: number): void {
  if (a === 0) ctx.moveTo(X[0]!, Y[0]!)
  else ctx.moveTo((X[a - 1]! + X[a]!) / 2, (Y[a - 1]! + Y[a]!) / 2)
  for (let i = a; i <= b; i++) {
    if (i === 0) ctx.lineTo((X[0]! + X[1]!) / 2, (Y[0]! + Y[1]!) / 2)
    else if (i < n - 1) ctx.quadraticCurveTo(X[i]!, Y[i]!, (X[i]! + X[i + 1]!) / 2, (Y[i]! + Y[i + 1]!) / 2)
    else ctx.lineTo(X[i]!, Y[i]!)
  }
}

function halfDisk(
  ctx: CanvasRenderingContext2D,
  cx: number,
  cy: number,
  r: number,
  dx: number,
  dy: number,
  back: boolean,
  alpha: number
): void {
  if (r < 0.025 || alpha <= 0) return
  const a = Math.atan2(dy, dx)
  ctx.globalAlpha = alpha
  ctx.beginPath()
  if (back) ctx.arc(cx, cy, r, a + Math.PI / 2, a + (3 * Math.PI) / 2)
  else ctx.arc(cx, cy, r, a - Math.PI / 2, a + Math.PI / 2)
  ctx.closePath()
  ctx.fill()
}

/** A one-sample stroke (a click): the same passes as round dots. */
function drawDot(
  ctx: CanvasRenderingContext2D,
  pal: Palette,
  x: number,
  y: number,
  life: number,
  dpr: number
): void {
  for (let pi = 0; pi < PASSES.length; pi++) {
    const pass = PASSES[pi]!
    const r = (DOT_SCALE * pass.w * (pass.thin + (1 - pass.thin) * life) * dpr) / 2
    if (r < 0.025) continue
    ctx.globalAlpha = pass.a * life
    ctx.fillStyle = pass.tone === 0 ? pal.base : pal.core
    ctx.beginPath()
    ctx.arc(x, y, r, 0, Math.PI * 2)
    ctx.fill()
  }
}

/** The glowing bead at the head of a stroke still being drawn. */
function drawHead(
  ctx: CanvasRenderingContext2D,
  pal: Palette,
  x: number,
  y: number,
  dpr: number
): void {
  const r = HEAD_R * dpr
  if (pal.head === null || pal.headKey !== dpr || pal.headCtx !== ctx) {
    const g = ctx.createRadialGradient(0, 0, 0, 0, 0, r)
    const [cr, cg, cb] = pal.coreRgb
    const [br, bg, bb] = pal.rgb
    g.addColorStop(0, `rgba(${cr},${cg},${cb},1)`)
    g.addColorStop(0.1, `rgba(${cr},${cg},${cb},1)`)
    g.addColorStop(0.19, `rgba(${br},${bg},${bb},1)`)
    g.addColorStop(0.3, `rgba(${br},${bg},${bb},1)`)
    g.addColorStop(0.37, `rgba(${br},${bg},${bb},0.5)`)
    g.addColorStop(0.55, `rgba(${br},${bg},${bb},0.18)`)
    g.addColorStop(0.8, `rgba(${br},${bg},${bb},0.05)`)
    g.addColorStop(1, `rgba(${br},${bg},${bb},0)`)
    pal.head = g
    pal.headKey = dpr
    pal.headCtx = ctx
  }
  ctx.globalAlpha = 1
  ctx.fillStyle = pal.head
  ctx.setTransform(1, 0, 0, 1, x, y)
  ctx.beginPath()
  ctx.arc(0, 0, r, 0, Math.PI * 2)
  ctx.fill()
  ctx.setTransform(1, 0, 0, 1, 0, 0)
}

const palettes = new Map<string, Palette>()

function palette(ctx: CanvasRenderingContext2D, color: string): Palette {
  const hit = palettes.get(color)
  if (hit) return hit
  const rgb = parseColor(color) ?? viaContext(ctx, color) ?? parseColor(DEFAULT_LASER_COLOR)!
  const coreRgb: [number, number, number] = [
    Math.round(rgb[0] + (255 - rgb[0]) * CORE_MIX),
    Math.round(rgb[1] + (255 - rgb[1]) * CORE_MIX),
    Math.round(rgb[2] + (255 - rgb[2]) * CORE_MIX),
  ]
  const p: Palette = {
    base: `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`,
    core: `rgb(${coreRgb[0]},${coreRgb[1]},${coreRgb[2]})`,
    rgb,
    coreRgb,
    head: null,
    headKey: 0,
    headCtx: null,
  }
  if (palettes.size >= 64) palettes.clear()
  palettes.set(color, p)
  return p
}

const clamp255 = (v: number): number => Math.max(0, Math.min(255, Math.round(v)))

/** #rgb, #rgba, #rrggbb, #rrggbbaa, rgb()/rgba() with commas or spaces. Alpha is ignored. */
export function parseColor(c: string): [number, number, number] | null {
  if (typeof c !== 'string') return null
  const s = c.trim().toLowerCase()
  const hex = /^#([0-9a-f]{3,8})$/.exec(s)
  if (hex) {
    const h = hex[1]!
    if (h.length === 3 || h.length === 4) {
      return [parseInt(h[0]! + h[0]!, 16), parseInt(h[1]! + h[1]!, 16), parseInt(h[2]! + h[2]!, 16)]
    }
    if (h.length === 6 || h.length === 8) {
      return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]
    }
    return null
  }
  const fn = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/.exec(s)
  if (fn) return [clamp255(Number(fn[1])), clamp255(Number(fn[2])), clamp255(Number(fn[3]))]
  return null
}

/** Let the canvas normalise any other CSS colour (names, hsl(), …); null if it rejects it. */
function viaContext(ctx: CanvasRenderingContext2D, color: string): [number, number, number] | null {
  const prev = ctx.fillStyle
  const probe = '#010203'
  ctx.fillStyle = probe
  ctx.fillStyle = color
  const out = ctx.fillStyle
  ctx.fillStyle = prev
  if (typeof out !== 'string' || out === probe) return null
  return parseColor(out)
}
