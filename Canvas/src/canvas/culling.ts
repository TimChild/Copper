/**
 * Viewport culling: which shapes the board mounts. Pure math over the doc's
 * shapes, never the DOM, so search, marquee, snapping, frames' children,
 * zoom-to-fit and the tools see every shape whether it is drawn or not.
 *
 * The board mounts what meets its *cull rect*: the visible world plus half a
 * viewport on each side. The rect is not recomputed every frame — only when
 * the view has moved far enough that less than a quarter viewport of margin
 * is left on some side (a zoom out grows the view, so it re-culls at once), or
 * once the view has settled and the rect is much bigger than it needs to be
 * (after a zoom in). A pan therefore mounts and unmounts shapes in batches,
 * ahead of the screen edge, instead of a few every frame.
 */
import { boxesOverlap, type Box } from './geometry'

/** Margin around the visible world, as a fraction of the viewport, on each side. */
export const CULL_MARGIN = 0.5
/** Re-cull when less margin than this (fraction of the viewport) is left on any side. */
export const CULL_TRIGGER = 0.25
/** Once settled, re-cull when some side has more margin than this (fraction of the viewport). */
export const CULL_SLACK = 1.25

/** The visible world grown by `margin` viewports on each side. */
export function cullRect(visible: Box, margin = CULL_MARGIN): Box {
  const mx = visible.w * margin
  const my = visible.h * margin
  return { x: visible.x - mx, y: visible.y - my, w: visible.w + mx * 2, h: visible.h + my * 2 }
}

/** How much of `cull` lies beyond `visible` on each side, in viewports (negative: `visible` pokes out). */
export function cullMargins(cull: Box, visible: Box) {
  const w = visible.w || 1
  const h = visible.h || 1
  return {
    left: (visible.x - cull.x) / w,
    right: (cull.x + cull.w - (visible.x + visible.w)) / w,
    top: (visible.y - cull.y) / h,
    bottom: (cull.y + cull.h - (visible.y + visible.h)) / h,
  }
}

/** Should the board recompute its cull rect for what it shows now? */
export function needsRecull(cull: Box | null, visible: Box, settled: boolean): boolean {
  if (!cull) return true
  const m = cullMargins(cull, visible)
  const least = Math.min(m.left, m.right, m.top, m.bottom)
  if (!(least >= CULL_TRIGGER)) return true
  if (!settled) return false
  return Math.max(m.left, m.right, m.top, m.bottom) > CULL_SLACK
}

/** The cull rect to use for this view: the current one while it still covers it, else a fresh one. */
export function nextCull(cull: Box | null, visible: Box, settled: boolean): Box {
  return needsRecull(cull, visible, settled) ? cullRect(visible) : cull!
}

interface Cullable extends Box {
  id: string
  type: string
}

/**
 * The shapes to mount: those meeting `cull`, plus every `pinned` id (selected,
 * being edited, in use, a live frame keeping its page, an open comment).
 * Arrows are not boxes: see `arrowsToDraw`. Order is kept.
 */
export function shapesToMount<S extends Cullable>(list: readonly S[], cull: Box, pinned: ReadonlySet<string>): S[] {
  const out: S[] = []
  for (const s of list) {
    if (s.type === 'arrow') continue
    if (pinned.has(s.id) || boxesOverlap(cull, s)) out.push(s)
  }
  return out
}

/**
 * The arrows to draw: an arrow's path is computed from the doc's boxes (so an
 * arrow to a culled shape still lands on it); it is drawn when its bounds meet
 * `cull`, when either end is a mounted shape, or when it is pinned.
 */
export function arrowsToDraw<A extends { shape: { id: string; from?: unknown; to?: unknown } }>(
  arrows: readonly A[],
  cull: Box,
  bounds: (a: A) => Box,
  mounted: ReadonlySet<string>,
  pinned: ReadonlySet<string>
): A[] {
  const out: A[] = []
  const refOf = (e: unknown) => (e && typeof e === 'object' && 'ref' in e && typeof (e as { ref: unknown }).ref === 'string' ? (e as { ref: string }).ref : null)
  for (const a of arrows) {
    const from = refOf(a.shape.from)
    const to = refOf(a.shape.to)
    if (pinned.has(a.shape.id) || (from && mounted.has(from)) || (to && mounted.has(to)) || boxesOverlap(cull, bounds(a))) out.push(a)
  }
  return out
}

/** Most shapes a re-cull mounts in one frame while the view moves. */
export const MOUNT_CHUNK = 60

/**
 * What of `target` (from `shapesToMount`) to mount now: all of it when
 * nothing is `held` back (the view has settled) or few shapes are new; else
 * what was showing, what is pinned, and the `chunk` new ones nearest the cull
 * rect's middle (where the view is). The board admits the rest a frame later.
 */
export function admit<S extends Box & { id: string }>(
  target: S[],
  held: ReadonlySet<string> | null,
  pinned: ReadonlySet<string>,
  cull: Box,
  chunk = MOUNT_CHUNK
): S[] {
  if (!held) return target
  const fresh = target.filter(s => !held.has(s.id) && !pinned.has(s.id))
  if (fresh.length <= chunk) return target
  const cx = cull.x + cull.w / 2
  const cy = cull.y + cull.h / 2
  const chosen = new Set(
    fresh
      .map(s => [Math.hypot(s.x + s.w / 2 - cx, s.y + s.h / 2 - cy), s.id] as const)
      .sort((a, b) => a[0] - b[0])
      .slice(0, chunk)
      .map(([, id]) => id)
  )
  return target.filter(s => held.has(s.id) || pinned.has(s.id) || chosen.has(s.id))
}
