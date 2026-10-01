/**
 * Where an arrow is drawn. Arrows store endpoints, not geometry: a free
 * point, a shape (the line runs centre to centre, clipped to both borders),
 * or a shape's side (the end sits on that side's midpoint and the line
 * leaves it square, as a gentle curve). Moving a shape reroutes its arrows.
 */
import {
  boxSegment,
  exitPoint,
  sideNormal,
  sidePoint,
  type Box,
  type Point,
  type Segment,
  type Side,
} from './geometry'
import { isRefEndpoint, type Endpoint, type Shape } from './types'

export interface ArrowPath {
  /** Straight chord from tail to head. */
  seg: Segment
  /** SVG path data (a line, or a cubic when an end is pinned to a side). */
  d: string
  /** Where the label sits: the path's midpoint. */
  mid: Point
  /** Bezier control points, when curved. */
  c1?: Point
  c2?: Point
}

type BoxOf = (id: string) => Box | null

interface Resolved {
  /** The fixed point, when the end is a point or a pinned side. */
  point?: Point
  box?: Box
  side?: Side
}

function resolve(end: Endpoint | undefined, boxOf: BoxOf): Resolved | null {
  if (!end) return null
  if (isRefEndpoint(end)) {
    const box = boxOf(end.ref)
    if (!box) return null
    return end.side ? { box, side: end.side, point: sidePoint(box, end.side) } : { box }
  }
  return { point: { x: end.x, y: end.y } }
}

const cubicAt = (p0: Point, c1: Point, c2: Point, p3: Point, t: number): Point => {
  const u = 1 - t
  return {
    x: u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x,
    y: u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y,
  }
}

const fmt = (n: number) => Math.round(n * 10) / 10

/**
 * The drawn path of an arrow given where shapes are now; null when an end's
 * shape is gone or two unpinned boxes overlap (there is no line to draw).
 */
export function arrowPath(shape: Pick<Shape, 'from' | 'to'>, boxOf: BoxOf): ArrowPath | null {
  const a = resolve(shape.from, boxOf)
  const b = resolve(shape.to, boxOf)
  if (!a || !b) return null
  let p: Point
  let q: Point
  if (a.point && b.point) {
    p = a.point
    q = b.point
  } else if (a.point && b.box) {
    p = a.point
    q = exitPoint(b.box, p)
  } else if (b.point && a.box) {
    q = b.point
    p = exitPoint(a.box, q)
  } else if (a.box && b.box) {
    const seg = boxSegment(a.box, b.box)
    if (!seg) return null
    p = { x: seg.x1, y: seg.y1 }
    q = { x: seg.x2, y: seg.y2 }
  } else return null
  const seg = { x1: p.x, y1: p.y, x2: q.x, y2: q.y }
  const len = Math.hypot(q.x - p.x, q.y - p.y)
  if (len < 1) return null
  if (!a.side && !b.side) {
    return {
      seg,
      d: `M${fmt(p.x)},${fmt(p.y)} L${fmt(q.x)},${fmt(q.y)}`,
      mid: { x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 },
    }
  }
  const reach = Math.max(24, Math.min(160, len / 2.2))
  const towards = (from: Point, to: Point) => {
    const d = Math.hypot(to.x - from.x, to.y - from.y) || 1
    return { x: (to.x - from.x) / d, y: (to.y - from.y) / d }
  }
  const na = a.side ? sideNormal(a.side) : towards(p, q)
  const nb = b.side ? sideNormal(b.side) : towards(q, p)
  const c1 = { x: p.x + na.x * reach, y: p.y + na.y * reach }
  const c2 = { x: q.x + nb.x * reach, y: q.y + nb.y * reach }
  return {
    seg,
    d: `M${fmt(p.x)},${fmt(p.y)} C${fmt(c1.x)},${fmt(c1.y)} ${fmt(c2.x)},${fmt(c2.y)} ${fmt(q.x)},${fmt(q.y)}`,
    mid: cubicAt(p, c1, c2, q, 0.5),
    c1,
    c2,
  }
}

/** Bounding box of an arrow's path (control points included for curves). */
export function arrowBox(path: ArrowPath): Box {
  const xs = [path.seg.x1, path.seg.x2]
  const ys = [path.seg.y1, path.seg.y2]
  if (path.c1 && path.c2) {
    // Sample the curve: control points overshoot the visible bounds.
    for (let i = 1; i < 8; i++) {
      const pt = cubicAt({ x: path.seg.x1, y: path.seg.y1 }, path.c1, path.c2, { x: path.seg.x2, y: path.seg.y2 }, i / 8)
      xs.push(pt.x)
      ys.push(pt.y)
    }
  }
  const x = Math.min(...xs)
  const y = Math.min(...ys)
  return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y }
}

/** Points along the path, for hit tests against a curve. */
export function arrowPoints(path: ArrowPath, steps = 16): Point[] {
  const p0 = { x: path.seg.x1, y: path.seg.y1 }
  const p3 = { x: path.seg.x2, y: path.seg.y2 }
  if (!path.c1 || !path.c2) return [p0, p3]
  const out: Point[] = []
  for (let i = 0; i <= steps; i++) out.push(cubicAt(p0, path.c1, path.c2, p3, i / steps))
  return out
}
