/**
 * Laser pointer types and defaults. The contract lives in
 * docs/plans/2026-10-01-easels-p1-local.md, "Laser pointer".
 */

/** A sample in canvas (world) coordinates; `t` is ms since the Unix epoch on this machine. */
export type LaserPoint = { x: number; y: number; t: number }

/** `endedAt` is null while the pointer is still down. */
export type LaserStroke = {
  id: string
  color: string
  points: LaserPoint[]
  endedAt: number | null
}

/**
 * What goes in awareness. `pts` is flat `[x, y, dt, …]`: x/y rounded to 0.1 canvas px, `dt` integer
 * ms since `start`, at most 400 points. `start`/`end` are the sender's clock and only meaningful
 * relative to each other; receivers re-anchor them to their own clock.
 */
export type LaserWire = {
  id: string
  color: string
  start: number
  end: number | null
  pts: number[]
}

export type LaserOptions = { holdMs?: number; fadeMs?: number; tailMs?: number }

/** The board camera, the wiki app's model: `screen = world * z + (x, y)` in CSS px. */
export type LaserView = { x: number; y: number; z: number }

export type LaserTiming = { holdMs: number; fadeMs: number; tailMs: number }

export const DEFAULT_TIMING: LaserTiming = { holdMs: 2000, fadeMs: 1000, tailMs: 4000 }

/** Copper red-orange. */
export const DEFAULT_LASER_COLOR = '#ff5a36'

/** Local samples kept per stroke (older ones drop first). */
export const MAX_LOCAL_POINTS = 2000

/** Points per wire; older points are downsampled first so the head stays dense. */
export const MAX_WIRE_POINTS = 400

/** Most points accepted from one remote wire (a misbehaving peer cannot make us draw more). */
export const MAX_DECODED_POINTS = 1000

/** Moves closer than this to the last kept sample are ignored, in screen px (1.5 world px at 100%). */
export const MIN_STEP_PX = 1.5
