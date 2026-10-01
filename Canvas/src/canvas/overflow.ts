/**
 * Sticky notes that hold more than they show. Pure: the view measures, these
 * decide. Text is never shrunk to fit; a note that overflows says so (a fade
 * and "Show all"), and grows to fit — on that click, or as you type into it —
 * up to a height past which it is better read in its editor, which scrolls.
 */

/** A sticky body's vertical padding (14 px top + 13 px bottom). */
export const STICKY_PAD_Y = 27
/** Tallest a sticky grows on its own, board px. Taller notes scroll in the editor. */
export const STICKY_MAX_H = 960

/** The body's content is taller than the room it has (with a pixel of slack for rounding). */
export function overflows(contentPx: number, boxH: number, pad = STICKY_PAD_Y): boolean {
  return contentPx > boxH - pad + 1
}

export interface Growth {
  /** The new height, or null when the note already fits (or cannot grow). */
  h: number | null
  /** Everything shows once grown. */
  fits: boolean
}

/**
 * How tall a note of height `boxH` grows for `contentPx` of body to show:
 * never shorter than it is, never past `max` (a note already taller than
 * `max` is left alone).
 */
export function growFor(boxH: number, contentPx: number, { pad = STICKY_PAD_Y, max = STICKY_MAX_H } = {}): Growth {
  const want = Math.ceil(contentPx + pad)
  const cap = Math.max(boxH, max)
  const next = Math.min(want, cap)
  return { h: next > boxH + 1 ? next : null, fits: want <= cap + 1 }
}
