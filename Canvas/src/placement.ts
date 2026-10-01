/**
 * Free-space placement: where a new shape goes when nobody said where. The
 * search starts at the viewport centre and walks outward ring by ring on a
 * grid, taking the nearest spot whose box (plus a gap) touches nothing.
 * Pure: no React, no Yjs.
 */
import { boxesOverlap, type Box, type Point } from './canvas/geometry'

export interface PlacementOptions {
  /** Clear space kept around the new box. */
  gap?: number
  /** Grid step of the search, world px. */
  step?: number
  /** Give up past this distance from the centre and use the centre. */
  maxRadius?: number
}

/**
 * Top-left of a `size` box near `around` that overlaps none of `taken`.
 * Ties go right, then down, then left, then up, so a run of placements
 * reads like a row.
 */
export function findFreeSpot(
  taken: readonly Box[],
  size: { w: number; h: number },
  around: Point,
  { gap = 24, step = 24, maxRadius = 6000 }: PlacementOptions = {}
): Point {
  const w = Math.max(1, size.w)
  const h = Math.max(1, size.h)
  const origin = { x: Math.round(around.x - w / 2), y: Math.round(around.y - h / 2) }
  const free = (p: Point) => {
    const box = { x: p.x, y: p.y, w, h }
    for (const t of taken) if (boxesOverlap(box, t, gap)) return false
    return true
  }
  if (free(origin)) return origin
  // Only boxes near the search area matter; prune the rest once.
  const reach = maxRadius + Math.max(w, h)
  const near = taken.filter(
    t =>
      t.x < origin.x + w + reach && t.x + t.w > origin.x - reach && t.y < origin.y + h + reach && t.y + t.h > origin.y - reach
  )
  const freeNear = (p: Point) => {
    const box = { x: p.x, y: p.y, w, h }
    for (const t of near) if (boxesOverlap(box, t, gap)) return false
    return true
  }
  const rings = Math.ceil(maxRadius / step)
  for (let k = 1; k <= rings; k++) {
    const cells: { p: Point; d: number; a: number }[] = []
    for (let i = -k; i <= k; i++)
      for (let j = -k; j <= k; j++) {
        if (Math.max(Math.abs(i), Math.abs(j)) !== k) continue
        const dx = i * step
        const dy = j * step
        // Angle from "right", clockwise in screen space, for tie-breaking.
        let a = Math.atan2(dy, dx)
        if (a < 0) a += Math.PI * 2
        cells.push({ p: { x: origin.x + dx, y: origin.y + dy }, d: Math.hypot(dx, dy), a })
      }
    cells.sort((m, n) => m.d - n.d || m.a - n.a)
    for (const c of cells) if (freeNear(c.p)) return c.p
  }
  return origin
}

/** A row of `count` boxes of `size`, left to right, wrapping after `perRow`. */
export function gridSlots(start: Point, size: { w: number; h: number }, count: number, perRow = 4, gap = 24): Point[] {
  const out: Point[] = []
  for (let i = 0; i < count; i++)
    out.push({
      x: start.x + (i % perRow) * (size.w + gap),
      y: start.y + Math.floor(i / perRow) * (size.h + gap),
    })
  return out
}

/** Room a frame's title takes above its box. */
export const FRAME_LABEL_ROOM = 36

/** What a shape occupies for placement: its box, plus a frame's title above it. */
export function occupied(s: { type: string } & Box): Box {
  return s.type === 'frame' ? { x: s.x, y: s.y - FRAME_LABEL_ROOM, w: s.w, h: s.h + FRAME_LABEL_ROOM } : { x: s.x, y: s.y, w: s.w, h: s.h }
}
