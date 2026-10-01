/** Pure board math: boxes, segments, anchors, pan and zoom. No React, no Yjs. */

export interface Point {
  x: number
  y: number
}

/** Pan offset in screen px plus zoom factor: screen = world * z + (x, y). */
export interface View {
  x: number
  y: number
  z: number
}

/** An axis-aligned box in world coordinates (top-left + size). */
export interface Box extends Point {
  w: number
  h: number
}

export interface Segment {
  x1: number
  y1: number
  x2: number
  y2: number
}

export type Side = 'top' | 'right' | 'bottom' | 'left'
export const SIDES: readonly Side[] = ['top', 'right', 'bottom', 'left']

export const MIN_ZOOM = 0.1
export const MAX_ZOOM = 4

export const clampZoom = (z: number) => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z))

export const center = (b: Box): Point => ({ x: b.x + b.w / 2, y: b.y + b.h / 2 })

/** Where the ray from the box's centre toward `toward` leaves the box. */
export function exitPoint(box: Box, toward: Point): Point {
  const cx = box.x + box.w / 2
  const cy = box.y + box.h / 2
  const dx = toward.x - cx
  const dy = toward.y - cy
  if (dx === 0 && dy === 0) return { x: cx, y: cy }
  const t = Math.min(
    dx === 0 ? Infinity : box.w / 2 / Math.abs(dx),
    dy === 0 ? Infinity : box.h / 2 / Math.abs(dy)
  )
  return { x: cx + dx * t, y: cy + dy * t }
}

/** The middle of one side of a box: where a side-anchored arrow attaches. */
export function sidePoint(box: Box, side: Side): Point {
  switch (side) {
    case 'top':
      return { x: box.x + box.w / 2, y: box.y }
    case 'right':
      return { x: box.x + box.w, y: box.y + box.h / 2 }
    case 'bottom':
      return { x: box.x + box.w / 2, y: box.y + box.h }
    case 'left':
      return { x: box.x, y: box.y + box.h / 2 }
  }
}

/** Outward unit normal of a side. */
export const sideNormal = (side: Side): Point =>
  side === 'top'
    ? { x: 0, y: -1 }
    : side === 'right'
      ? { x: 1, y: 0 }
      : side === 'bottom'
        ? { x: 0, y: 1 }
        : { x: -1, y: 0 }

/** The side of `box` whose midpoint is nearest to `p`, with that distance. */
export function nearestSide(box: Box, p: Point): { side: Side; distance: number } {
  let best: { side: Side; distance: number } = { side: 'right', distance: Infinity }
  for (const side of SIDES) {
    const q = sidePoint(box, side)
    const d = Math.hypot(q.x - p.x, q.y - p.y)
    if (d < best.distance) best = { side, distance: d }
  }
  return best
}

export const containsPoint = (b: Box, p: Point) =>
  p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h

/** `inner` lies entirely inside `outer`. */
export const containsBox = (outer: Box, inner: Box) =>
  inner.x >= outer.x &&
  inner.y >= outer.y &&
  inner.x + inner.w <= outer.x + outer.w &&
  inner.y + inner.h <= outer.y + outer.h

/** Two boxes closer than `gap` on both axes. */
export function boxesOverlap(a: Box, b: Box, gap = 0): boolean {
  return (
    a.x < b.x + b.w + gap &&
    b.x < a.x + a.w + gap &&
    a.y < b.y + b.h + gap &&
    b.y < a.y + a.h + gap
  )
}

/** The smallest box around every box given; null for none. */
export function unionBox(boxes: Iterable<Box>): Box | null {
  let minX = Infinity
  let minY = Infinity
  let maxX = -Infinity
  let maxY = -Infinity
  for (const b of boxes) {
    minX = Math.min(minX, b.x)
    minY = Math.min(minY, b.y)
    maxX = Math.max(maxX, b.x + b.w)
    maxY = Math.max(maxY, b.y + b.h)
  }
  if (!Number.isFinite(minX)) return null
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
}

/** Normalised box between two corner points (a marquee). */
export const boxFromPoints = (a: Point, b: Point): Box => ({
  x: Math.min(a.x, b.x),
  y: Math.min(a.y, b.y),
  w: Math.abs(a.x - b.x),
  h: Math.abs(a.y - b.y),
})

export const segmentBox = (s: Segment): Box => boxFromPoints({ x: s.x1, y: s.y1 }, { x: s.x2, y: s.y2 })

/**
 * Line between the centres of two boxes, clipped to both borders so the
 * arrowhead sits on the target's edge. Null when the boxes overlap.
 */
export function boxSegment(a: Box, b: Box): Segment | null {
  const ca = center(a)
  const cb = center(b)
  if (Math.abs(ca.x - cb.x) < (a.w + b.w) / 2 && Math.abs(ca.y - cb.y) < (a.h + b.h) / 2) return null
  const p = exitPoint(a, cb)
  const q = exitPoint(b, ca)
  return { x1: p.x, y1: p.y, x2: q.x, y2: q.y }
}

/** Distance from `p` to the segment. */
export function distanceToSegment(p: Point, s: Segment): number {
  const dx = s.x2 - s.x1
  const dy = s.y2 - s.y1
  const len2 = dx * dx + dy * dy
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((p.x - s.x1) * dx + (p.y - s.y1) * dy) / len2))
  return Math.hypot(p.x - (s.x1 + t * dx), p.y - (s.y1 + t * dy))
}

/** Does the segment cross (or touch) the box? */
export function segmentIntersectsBox(s: Segment, b: Box): boolean {
  if (containsPoint(b, { x: s.x1, y: s.y1 }) || containsPoint(b, { x: s.x2, y: s.y2 })) return true
  const corners: Point[] = [
    { x: b.x, y: b.y },
    { x: b.x + b.w, y: b.y },
    { x: b.x + b.w, y: b.y + b.h },
    { x: b.x, y: b.y + b.h },
  ]
  for (let i = 0; i < 4; i++) {
    const c = corners[i]!
    const d = corners[(i + 1) % 4]!
    if (segmentsCross({ x1: s.x1, y1: s.y1, x2: s.x2, y2: s.y2 }, { x1: c.x, y1: c.y, x2: d.x, y2: d.y })) return true
  }
  return false
}

function segmentsCross(a: Segment, b: Segment): boolean {
  const o = (px: number, py: number, qx: number, qy: number, rx: number, ry: number) =>
    Math.sign((qx - px) * (ry - py) - (qy - py) * (rx - px))
  const o1 = o(a.x1, a.y1, a.x2, a.y2, b.x1, b.y1)
  const o2 = o(a.x1, a.y1, a.x2, a.y2, b.x2, b.y2)
  const o3 = o(b.x1, b.y1, b.x2, b.y2, a.x1, a.y1)
  const o4 = o(b.x1, b.y1, b.x2, b.y2, a.x2, a.y2)
  return o1 !== o2 && o3 !== o4
}

export const screenToWorld = (view: View, p: Point): Point => ({
  x: (p.x - view.x) / view.z,
  y: (p.y - view.y) / view.z,
})

export const worldToScreen = (view: View, p: Point): Point => ({
  x: p.x * view.z + view.x,
  y: p.y * view.z + view.y,
})

/** Zoom by `factor`, keeping the world point under screen `p` fixed. */
export function zoomAt(view: View, factor: number, p: Point): View {
  const z = clampZoom(view.z * factor)
  const k = z / view.z
  return { x: p.x - (p.x - view.x) * k, y: p.y - (p.y - view.y) * k, z }
}

/** Set an absolute zoom, keeping the world point under screen `p` fixed. */
export const zoomTo = (view: View, z: number, p: Point): View => zoomAt(view, z / view.z, p)

/**
 * A view that shows every box inside a `width` x `height` viewport, never
 * zoomed in past `maxZoom`. An empty board centres the origin at 100%.
 */
export function fitBoxes(boxes: Iterable<Box>, width: number, height: number, padding = 64, maxZoom = 1): View {
  const u = unionBox(boxes)
  if (!u || width <= 0 || height <= 0) return { x: width / 2, y: height / 2, z: 1 }
  const z = clampZoom(
    Math.min(
      maxZoom,
      Math.max(width - padding * 2, 1) / Math.max(u.w, 1),
      Math.max(height - padding * 2, 1) / Math.max(u.h, 1)
    )
  )
  return {
    x: width / 2 - (u.x + u.w / 2) * z,
    y: height / 2 - (u.y + u.h / 2) * z,
    z,
  }
}

/** The world rectangle a view shows in a `width` x `height` viewport. */
export const visibleWorld = (view: View, width: number, height: number): Box => ({
  x: -view.x / view.z,
  y: -view.y / view.z,
  w: width / view.z,
  h: height / view.z,
})
