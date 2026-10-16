/**
 * Level of detail: what the board draws more cheaply when it is zoomed out.
 * Pure decisions only (the views live in `components/Lod.tsx`,
 * `components/Shapes.tsx`):
 *
 * - Text shapes (notes, text, checklists, timelines) whose text would be
 *   under `LOD_TEXT_PX` on screen draw a colour block and a heading line.
 * - Images drawn much smaller than their natural size draw a cached,
 *   downscaled copy (`thumbs.ts`) of the width bucket they need.
 *
 * The zoom these decisions use (`lodZoom`) follows the view in steps, not
 * every frame, so a pinch that wobbles around a threshold doesn't swap
 * hundreds of shapes back and forth; it snaps to the exact zoom on settle.
 */

/** Text smaller than this on screen (CSS px) is not legible: draw the simplified card. */
export const LOD_TEXT_PX = 4
/** The LOD zoom moves down when the view's zoom has changed by more than this (log scale, ≈ 8%). */
export const LOD_STEP = 0.08
/** …and up, mid-gesture, only once the zoom has doubled (log scale): a zoom in shows text by 2× the threshold at most. */
export const LOD_STEP_UP = Math.LN2

/** Body text sizes of the text-heavy shapes, in world px, for the threshold. */
export const CHECKLIST_TEXT_PX = 13
export const TIMELINE_TEXT_PX = 12

export const isLowText = (fontPx: number, zoom: number) => fontPx * zoom < LOD_TEXT_PX
/**
 * Text smaller than this on screen is a smudge: a simplified shape draws its
 * lines as soft bars of the same length instead of glyphs (glyphs were most
 * of what a pan or zoom across a far-out board spent painting).
 */
export const LOD_BAR_PX = 2.5
export const isBarText = (fontPx: number, zoom: number) => fontPx * zoom < LOD_BAR_PX

/** A bar standing for `text` at `fontPx`: about half an em per character, at most `maxW`. */
export const barWidth = (text: string, fontPx: number, maxW: number) => Math.max(0, Math.min(maxW, text.length * fontPx * 0.5))

/**
 * The zoom the LOD decisions use next. While the view moves it goes down
 * (less detail) in small steps, and up only in big ones (the zoom has
 * doubled); the rest waits for the view to settle. So a pinch that wobbles
 * around a threshold swaps nothing, and a zoom in from far out doesn't build
 * hundreds of full notes every few frames.
 */
export function nextLodZoom(prev: number, zoom: number, settled: boolean): number {
  if (!(prev > 0) || settled) return zoom
  const step = Math.log(zoom / prev)
  return step < -LOD_STEP || step > LOD_STEP_UP ? zoom : prev
}

// ---- images ---------------------------------------------------------------------

/** Widths (device px) a downscaled copy is made at. */
export const THUMB_BUCKETS = [96, 192, 384, 768] as const
/** A copy is only worth it when it is at most this fraction of the natural width. */
const THUMB_GAIN = 2 / 3

/**
 * The width of the downscaled copy to draw an image at, or null for its own
 * source. `drawnW` is how wide the image's pixels are laid out in world px
 * (its box, or more under `object-fit: cover`).
 */
export function imageBucket(drawnW: number, naturalW: number, zoom: number, dpr = 1): number | null {
  if (!(naturalW > 0) || !(drawnW > 0) || !(zoom > 0)) return null
  const need = drawnW * zoom * Math.max(1, dpr)
  // Drawn at more than half its size: the source it is.
  if (need * 2 > naturalW) return null
  for (const b of THUMB_BUCKETS) if (b >= need) return b <= naturalW * THUMB_GAIN ? b : null
  return null
}

/** How wide an image's pixels are laid out in a `w`×`h` box: `cover` fills it (cropping), `contain` fits it. */
export function drawnWidth(w: number, h: number, naturalW: number, naturalH: number, fit: 'cover' | 'contain'): number {
  if (!(naturalW > 0) || !(naturalH > 0)) return w
  const k = fit === 'cover' ? Math.max(w / naturalW, h / naturalH) : Math.min(w / naturalW, h / naturalH)
  return naturalW * k
}

// ---- text -----------------------------------------------------------------------

const LEAD = /^\s*(?:#{1,6}\s+|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+|>\s*)/

/**
 * The line a simplified note shows: its first line with text, markdown marks
 * taken off (`# `, list bullets, task boxes, emphasis, link syntax).
 * `heading` says whether that line was a markdown heading.
 */
export function headingLine(text: string, max = 140): { text: string; heading: boolean } {
  for (const raw of text.split('\n')) {
    if (!raw.trim()) continue
    const heading = /^\s*#{1,6}\s+/.test(raw)
    const line = raw
      .replace(LEAD, '')
      .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/(\*\*|__|\*|_|~~|`)/g, '')
      .trim()
    if (line) return { text: line.slice(0, max), heading }
  }
  return { text: '', heading: false }
}
