/**
 * Laser pointer: a glowing trail drawn while the Laser tool is down, held for 2 s after release
 * and faded over 1 s; never written to the document. Peers' lasers arrive as `LaserWire`s in Yjs
 * awareness (the `laser` field), so everyone on the board sees the same trail. Brought over from
 * Easels with its tests.
 */
export type { LaserPoint, LaserStroke, LaserWire, LaserOptions } from './types'
export { LaserTrails } from './trails'
export { drawLaser } from './draw'
export { LaserCanvas } from './LaserCanvas'
