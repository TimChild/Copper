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
 * Where a search left off, for a run of placements of the same size around the
 * same centre while the boxes only grow (an applyOps batch): every ring before
 * the one the last spot was found in was full then and is full now, so the next
 * search starts there. Same answers as starting from the middle, without
 * walking a filled-in centre again for every shape.
 */
export interface SearchHint {
  ring: number
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
  { gap = 24, step = 24, maxRadius = 6000 }: PlacementOptions = {},
  hint?: SearchHint
): Point {
  const w = Math.max(1, size.w)
  const h = Math.max(1, size.h)
  const origin = { x: Math.round(around.x - w / 2), y: Math.round(around.y - h / 2) }
  const free = (p: Point) => {
    const box = { x: p.x, y: p.y, w, h }
    for (const t of taken) if (boxesOverlap(box, t, gap)) return false
    return true
  }
  const rings = Math.ceil(maxRadius / step)
  if (hint && hint.ring > rings) return origin
  if (!hint?.ring && free(origin)) return origin
  // Only boxes near the search area matter; prune the rest once.
  const reach = maxRadius + Math.max(w, h)
  const near = taken.filter(
    t =>
      t.x < origin.x + w + reach && t.x + t.w > origin.x - reach && t.y < origin.y + h + reach && t.y + t.h > origin.y - reach
  )
  // On a crowded board the search goes many rings out: each candidate is checked against the boxes in
  // its own grid cells, not against every box near the centre (same answers, far fewer comparisons).
  const index = new BoxGrid(near, Math.max(64, step * 8))
  const freeNear = (p: Point) => !index.hits({ x: p.x, y: p.y, w, h }, gap)
  for (let k = Math.max(1, hint?.ring ?? 1); k <= rings; k++) {
    const cells = ringOrder(k)
    for (let c = 0; c < cells.length; c += 2) {
      const p = { x: origin.x + cells[c]! * step, y: origin.y + cells[c + 1]! * step }
      if (freeNear(p)) {
        if (hint) hint.ring = k
        return p
      }
    }
  }
  if (hint) hint.ring = rings + 1
  return origin
}

/**
 * Ring `k` of the search grid (the cells k steps out, as [i, j] pairs), nearest
 * first, ties by angle from "right", clockwise in screen space. The order does
 * not depend on the step, so it is worked out once per ring, not per search.
 */
const rings: Int32Array[] = []
function ringOrder(k: number): Int32Array {
  const known = rings[k]
  if (known) return known
  const cells: { i: number; j: number; d: number; a: number }[] = []
  const add = (i: number, j: number) => {
    let a = Math.atan2(j, i)
    if (a < 0) a += Math.PI * 2
    cells.push({ i, j, d: Math.hypot(i, j), a })
  }
  for (let i = -k; i <= k; i++) {
    if (Math.abs(i) === k) for (let j = -k; j <= k; j++) add(i, j)
    else {
      add(i, -k)
      add(i, k)
    }
  }
  cells.sort((m, n) => m.d - n.d || m.a - n.a)
  const out = new Int32Array(cells.length * 2)
  cells.forEach((c, n) => {
    out[n * 2] = c.i
    out[n * 2 + 1] = c.j
  })
  rings[k] = out
  return out
}

/** Boxes bucketed on a square grid, for "does this box come within `gap` of any of them". */
class BoxGrid {
  private cells = new Map<number, number[]>()
  /** Boxes too big to bucket (they would fill thousands of cells): always checked. */
  private large: number[] = []
  private seen: Uint32Array
  private stamp = 0
  constructor(
    private boxes: readonly Box[],
    private size: number
  ) {
    this.seen = new Uint32Array(boxes.length)
    boxes.forEach((b, i) => {
      const [x0, x1, y0, y1] = this.span(b, 0)
      if ((x1 - x0 + 1) * (y1 - y0 + 1) > 4096) {
        this.large.push(i)
        return
      }
      for (let cx = x0; cx <= x1; cx++)
        for (let cy = y0; cy <= y1; cy++) {
          const key = BoxGrid.key(cx, cy)
          const list = this.cells.get(key)
          if (list) list.push(i)
          else this.cells.set(key, [i])
        }
    })
  }
  private static key = (cx: number, cy: number) => (cx + 0x8000) * 0x10000 + (cy + 0x8000)
  private span(b: Box, gap: number): [number, number, number, number] {
    const c = (v: number) => Math.max(-0x7fff, Math.min(0x7fff, Math.floor(v / this.size)))
    return [c(b.x - gap), c(b.x + b.w + gap), c(b.y - gap), c(b.y + b.h + gap)]
  }
  hits(box: Box, gap: number): boolean {
    for (const i of this.large) if (boxesOverlap(box, this.boxes[i]!, gap)) return true
    if (++this.stamp === 0xffffffff) {
      this.seen.fill(0)
      this.stamp = 1
    }
    const [x0, x1, y0, y1] = this.span(box, gap)
    for (let cx = x0; cx <= x1; cx++)
      for (let cy = y0; cy <= y1; cy++) {
        const list = this.cells.get(BoxGrid.key(cx, cy))
        if (!list) continue
        for (const i of list) {
          if (this.seen[i] === this.stamp) continue
          this.seen[i] = this.stamp
          if (boxesOverlap(box, this.boxes[i]!, gap)) return true
        }
      }
    return false
  }
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
