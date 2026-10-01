/**
 * The board's dot grid as CSS background layers. Pure.
 *
 * Minor dots sit every 24 board px. Instead of switching off abruptly when
 * they get dense, they fade out over the last 30% of zoom above the cutoff,
 * and every fourth dot (a major one) takes over, so the overview keeps a
 * quiet sense of space; the major dots fade out the same way further out.
 */

export const GRID = 24
export const MAJOR_EVERY = 4
/** Minor dots are gone below this spacing on screen. */
export const MINOR_MIN_PX = 8
/** Major dots are gone below this spacing on screen (sparser: the overview is quieter). */
export const MAJOR_MIN_PX = 18
/** The fade spans this fraction of the zoom above a cutoff. */
export const FADE = 0.3

export interface GridLayer {
  /** Spacing on screen, px. */
  size: number
  /** 0..1, multiplies the theme's dot colour. */
  alpha: number
}

const smooth = (t: number) => t * t * (3 - 2 * t)

/** 0 at the cutoff spacing, 1 once the spacing is `1 / (1 - FADE)` times it. */
export function fadeIn(spacingPx: number, minPx: number): number {
  const full = minPx / (1 - FADE)
  if (spacingPx >= full) return 1
  if (spacingPx <= minPx) return 0
  return smooth((spacingPx - minPx) / (full - minPx))
}

/** The visible layers at zoom `z`, densest first. */
export function gridLayers(z: number): GridLayer[] {
  const minor = GRID * z
  const major = minor * MAJOR_EVERY
  const a = fadeIn(minor, MINOR_MIN_PX)
  // A major dot sits on a minor one: it only fills in what the minor fade took away.
  const b = (1 - a) * fadeIn(major, MAJOR_MIN_PX)
  const out: GridLayer[] = []
  if (a > 0.01) out.push({ size: minor, alpha: a })
  if (b > 0.01) out.push({ size: major, alpha: b })
  return out
}

const pct = (a: number) => `${Math.round(a * 1000) / 10}%`

/** `background-*` for the viewport at `view`. */
export function gridBackground(view: { x: number; y: number; z: number }): {
  backgroundImage?: string
  backgroundSize?: string
  backgroundPosition?: string
} {
  const layers = gridLayers(view.z)
  if (layers.length === 0) return {}
  const dot = (alpha: number) => {
    const c = alpha >= 0.999 ? 'var(--dot)' : `color-mix(in srgb, var(--dot) ${pct(alpha)}, transparent)`
    return `radial-gradient(${c} 1px, transparent 1.2px)`
  }
  // Each dot is centred in its tile; shift the sparser tiles so their dots
  // land on minor dots (board origin + half a minor cell).
  const half = (GRID * view.z) / 2
  const at = (size: number) => `${view.x + half - size / 2}px ${view.y + half - size / 2}px`
  return {
    backgroundImage: layers.map(l => dot(l.alpha)).join(', '),
    backgroundSize: layers.map(l => `${l.size}px ${l.size}px`).join(', '),
    backgroundPosition: layers.map(l => at(l.size)).join(', '),
  }
}
