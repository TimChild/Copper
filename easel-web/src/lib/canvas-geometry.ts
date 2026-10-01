/**
 * Pure canvas math: arrow endpoints, pan/zoom, fitting. No React, no Yjs.
 * Lifted from the wiki app's apps/web/src/modules/wiki/lib/canvas-geometry.ts
 * minus the wiki page-card helpers; `fitBoxes` is new.
 */

export interface Point {
  x: number
  y: number
}

/** Pan offset in screen px plus zoom factor: screen = canvas * z + (x, y). */
export interface View {
  x: number
  y: number
  z: number
}

export const MIN_ZOOM = 0.2
export const MAX_ZOOM = 2.5

/** An axis-aligned box in canvas coords (top-left + size). */
export interface Box extends Point {
  w: number
  h: number
}

/** Where the ray from the box's centre toward `toward` leaves the box. */
function exitPoint(box: Box, toward: Point): Point {
  const cx = box.x + box.w / 2
  const cy = box.y + box.h / 2
  const dx = toward.x - cx
  const dy = toward.y - cy
  const t = Math.min(
    dx === 0 ? Infinity : box.w / 2 / Math.abs(dx),
    dy === 0 ? Infinity : box.h / 2 / Math.abs(dy)
  )
  return { x: cx + dx * t, y: cy + dy * t }
}

export interface Segment {
  x1: number
  y1: number
  x2: number
  y2: number
}

/**
 * Line between the centres of two boxes, clipped to both borders so the
 * arrowhead sits on the target's edge. Null when the boxes overlap.
 */
export function boxSegment(a: Box, b: Box): Segment | null {
  const ca = { x: a.x + a.w / 2, y: a.y + a.h / 2 }
  const cb = { x: b.x + b.w / 2, y: b.y + b.h / 2 }
  if (
    Math.abs(ca.x - cb.x) < (a.w + b.w) / 2 &&
    Math.abs(ca.y - cb.y) < (a.h + b.h) / 2
  )
    return null
  const p = exitPoint(a, cb)
  const q = exitPoint(b, ca)
  return { x1: p.x, y1: p.y, x2: q.x, y2: q.y }
}

export const screenToCanvas = (view: View, p: Point): Point => ({
  x: (p.x - view.x) / view.z,
  y: (p.y - view.y) / view.z,
})

export const canvasToScreen = (view: View, p: Point): Point => ({
  x: p.x * view.z + view.x,
  y: p.y * view.z + view.y,
})

export const clampZoom = (z: number) =>
  Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z))

/** Zoom by `factor`, keeping the canvas point under screen `p` fixed. */
export function zoomAt(view: View, factor: number, p: Point): View {
  const z = clampZoom(view.z * factor)
  const k = z / view.z
  return { x: p.x - (p.x - view.x) * k, y: p.y - (p.y - view.y) * k, z }
}

/** Set zoom to exactly `z`, keeping the canvas point under screen `p` fixed. */
export const zoomTo = (view: View, z: number, p: Point): View =>
  zoomAt(view, clampZoom(z) / view.z, p)

/**
 * A view that shows every box inside a `width` x `height` viewport, never
 * zoomed past 100%. With nothing to show, the origin sits at the centre.
 */
export function fitBoxes(
  boxes: Iterable<Box>,
  width: number,
  height: number,
  padding = 64
): View {
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
  if (!Number.isFinite(minX) || width <= 0 || height <= 0)
    return { x: width / 2, y: height / 2, z: 1 }
  const z = clampZoom(
    Math.min(
      1,
      Math.max(width - padding * 2, 1) / Math.max(maxX - minX, 1),
      Math.max(height - padding * 2, 1) / Math.max(maxY - minY, 1)
    )
  )
  return {
    x: width / 2 - ((minX + maxX) / 2) * z,
    y: height / 2 - ((minY + maxY) / 2) * z,
    z,
  }
}

/** The box spanned by two corners, in any drag direction. */
export function rectFrom(a: Point, b: Point): Box {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    w: Math.abs(a.x - b.x),
    h: Math.abs(a.y - b.y),
  }
}

export const boxesIntersect = (a: Box, b: Box) =>
  a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y

export const pointInBox = (p: Point, b: Box) =>
  p.x >= b.x && p.x <= b.x + b.w && p.y >= b.y && p.y <= b.y + b.h
