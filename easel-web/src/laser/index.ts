/**
 * Laser pointer for Easels: a glowing trail drawn while the Laser tool is down, held for 2 s after
 * release and faded over 1 s; never written to the document. Peers' lasers arrive as `LaserWire`s
 * in Yjs awareness. Contract: docs/plans/2026-10-01-easels-p1-local.md, "Laser pointer".
 */
export type { LaserPoint, LaserStroke, LaserWire, LaserOptions } from './types'
export { LaserTrails } from './trails'
export { drawLaser } from './draw'
export { LaserCanvas } from './LaserCanvas'
