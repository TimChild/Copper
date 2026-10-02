/**
 * LaserWire encoding: the compact form of a stroke that rides in Yjs awareness.
 *
 * Encoding rounds x/y to 0.1 px and times to whole ms, and keeps at most `max` points. When a
 * stroke is longer, the newest half stays at full density and the older part is thinned to every
 * s-th sample (s a power of two, aligned to the sample's absolute index), so successive wires of
 * the same stroke keep choosing the same old points and the far side does not shimmer.
 *
 * Decoding re-anchors the sender's clock onto ours: see `wireNewest` and `decodeWireInto`.
 */
import {
  DEFAULT_LASER_COLOR,
  MAX_DECODED_POINTS,
  MAX_WIRE_POINTS,
  type LaserPoint,
  type LaserStroke,
  type LaserWire,
} from './types'

const round1 = (v: number): number => Math.round(v * 10) / 10

/**
 * Encode `s` for awareness. `base` is the absolute index of `s.points[0]` (how many samples were
 * dropped from the front so far), which keeps the downsampling stable while a stroke grows.
 */
export function encodeWire(s: LaserStroke, base = 0, max = MAX_WIRE_POINTS): LaserWire | null {
  const pts = s.points
  const n = pts.length
  const first = pts[0]
  if (!first) return null
  const start = Math.round(first.t)
  const out: number[] = []
  const push = (p: LaserPoint): void => {
    out.push(round1(p.x), round1(p.y), Math.max(0, Math.round(p.t - start)))
  }
  const cap = Math.max(2, Math.floor(max))
  if (n <= cap) {
    for (let i = 0; i < n; i++) push(pts[i]!)
  } else {
    const head = Math.floor(cap / 2)
    const headStart = n - head
    const budget = cap - head - 1 // older samples, not counting the first one
    // Smallest power-of-two stride whose aligned samples in (0, headStart) fit the budget.
    let stride = 1
    const lo = base // absolute index of sample 0 (always kept)
    const hi = base + headStart - 1 // absolute index of the last older sample
    while (Math.floor(hi / stride) - Math.floor(lo / stride) > budget) stride *= 2
    push(first)
    for (let i = 1; i < headStart; i++) if ((base + i) % stride === 0) push(pts[i]!)
    for (let i = headStart; i < n; i++) push(pts[i]!)
  }
  return {
    id: s.id,
    color: s.color,
    start,
    end: s.endedAt === null ? null : Math.max(start, Math.round(s.endedAt)),
    pts: out,
  }
}

/** Basic shape check for a wire that came off the network. */
export function isLaserWire(w: unknown): w is LaserWire {
  if (!w || typeof w !== 'object') return false
  const o = w as Record<string, unknown>
  return (
    typeof o.id === 'string' &&
    o.id.length > 0 &&
    o.id.length <= 64 &&
    typeof o.start === 'number' &&
    Number.isFinite(o.start) &&
    (o.end === null || (typeof o.end === 'number' && Number.isFinite(o.end))) &&
    Array.isArray(o.pts) &&
    o.pts.length >= 3
  )
}

/**
 * The newest moment a wire describes, on the sender's clock: its last point, or its `end` if
 * that is later. A receiver treats this moment as "now" (see `decodeWireInto`).
 */
export function wireNewest(w: LaserWire): number {
  const n = Math.floor(w.pts.length / 3)
  const lastDt = n > 0 ? Number(w.pts[n * 3 - 1]) || 0 : 0
  const newest = w.start + lastDt
  return w.end !== null && w.end > newest ? w.end : newest
}

/**
 * Decode `w` into `into`, reusing its point objects, with every sender timestamp shifted by
 * `offset` (local = remote + offset). Non-finite samples are skipped, times are made monotonic,
 * and only the newest MAX_DECODED_POINTS samples are kept.
 */
export function decodeWireInto(into: LaserStroke, w: LaserWire, offset: number): void {
  const pts = w.pts
  const total = Math.floor(pts.length / 3)
  const from = Math.max(0, total - MAX_DECODED_POINTS)
  const out = into.points
  const base = w.start + offset
  let n = 0
  let lastT = -Infinity
  for (let i = from; i < total; i++) {
    const x = pts[i * 3]
    const y = pts[i * 3 + 1]
    const dt = pts[i * 3 + 2]
    if (
      typeof x !== 'number' ||
      typeof y !== 'number' ||
      typeof dt !== 'number' ||
      !Number.isFinite(x) ||
      !Number.isFinite(y) ||
      !Number.isFinite(dt)
    )
      continue
    let t = base + dt
    if (t < lastT) t = lastT
    lastT = t
    const p = out[n]
    if (p) {
      p.x = x
      p.y = y
      p.t = t
    } else {
      out[n] = { x, y, t }
    }
    n++
  }
  out.length = n
  into.id = w.id
  into.color = typeof w.color === 'string' && w.color.length <= 64 ? w.color : DEFAULT_LASER_COLOR
  into.endedAt = w.end === null ? null : Math.max(w.end + offset, n > 0 ? lastT : -Infinity)
}

/**
 * Decode a wire into a fresh stroke. With the default `offset` of 0 the times stay on the sender's
 * clock (a plain round trip); pass `now - wireNewest(w)` to re-anchor onto the local clock.
 */
export function decodeWire(w: LaserWire, offset = 0): LaserStroke {
  const s: LaserStroke = { id: w.id, color: w.color, points: [], endedAt: null }
  decodeWireInto(s, w, offset)
  return s
}
