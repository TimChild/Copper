/**
 * STUB — the laser work package (branch feat/easels-laser) replaces this
 * file. Same exports as the contract (docs/plans/2026-10-01-easels-p1-local.md,
 * "Laser pointer"); everything here is a no-op so the page can be wired
 * against the real API before it lands.
 */
import { createElement, type JSX } from 'react'

export type LaserPoint = { x: number; y: number; t: number }
export type LaserStroke = {
  id: string
  color: string
  points: LaserPoint[]
  endedAt: number | null
}
/** Flat `[x, y, dt, …]`, dt = ms since `start`, ≤ 400 points. */
export type LaserWire = {
  id: string
  color: string
  start: number
  end: number | null
  pts: number[]
}
export type LaserOptions = { holdMs?: number; fadeMs?: number; tailMs?: number }

export class LaserTrails {
  constructor(_opts?: LaserOptions) {}
  begin(_p: { x: number; y: number }, _color: string, _now?: number): string {
    return ''
  }
  move(_p: { x: number; y: number }, _now?: number): void {}
  end(_now?: number): void {}
  cancel(): void {}
  localWire(): LaserWire | null {
    return null
  }
  setRemote(_clientId: string | number, _wire: LaserWire | null): void {}
  prune(_now?: number): void {}
  hasVisible(_now?: number): boolean {
    return false
  }
  subscribe(_fn: () => void): () => void {
    return () => {}
  }
}

export function drawLaser(
  _ctx: CanvasRenderingContext2D,
  _trails: LaserTrails,
  _view: { x: number; y: number; z: number },
  _dpr: number,
  _now: number
): boolean {
  return false
}

export function LaserCanvas(_props: {
  trails: LaserTrails
  view: { x: number; y: number; z: number }
}): JSX.Element {
  return createElement('canvas', {
    className: 'easel-laser',
    'aria-hidden': 'true',
  })
}
