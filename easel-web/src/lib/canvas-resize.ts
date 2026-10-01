/**
 * Pure resize math for stickies and frames. No React, no Yjs.
 * Lifted as-is from the wiki app's apps/web/src/modules/wiki/lib/canvas-resize.ts.
 */
import type { Box, Point } from './canvas-geometry'

/** Compass handle: corners move two edges, sides move one. */
export type Handle = 'nw' | 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w'

export const CORNER_HANDLES = ['nw', 'ne', 'se', 'sw'] as const
export const EDGE_HANDLES = ['n', 'e', 's', 'w'] as const

export const HANDLE_CURSOR: Record<Handle, string> = {
  nw: 'nwse-resize',
  se: 'nwse-resize',
  ne: 'nesw-resize',
  sw: 'nesw-resize',
  n: 'ns-resize',
  s: 'ns-resize',
  e: 'ew-resize',
  w: 'ew-resize',
}

export interface Size {
  w: number
  h: number
}

/** Smallest a resizable shape may get. */
export const MIN_SIZE = {
  sticky: { w: 96, h: 64 },
  frame: { w: 160, h: 120 },
} as const satisfies Record<string, Size>

export type ResizableType = keyof typeof MIN_SIZE
export const isResizable = (type: string): type is ResizableType =>
  type in MIN_SIZE

/**
 * The box after dragging `handle` by `delta` (canvas px) from `start`. The
 * opposite edge/corner stays put; sizes clamp at `min`, and a dragged edge
 * stops rather than crossing over. Moving edges land on whole pixels so the
 * anchored edge never drifts when the result is rounded for storage.
 */
export function resizeBox(
  start: Box,
  handle: Handle,
  delta: Point,
  min: Size
): Box {
  let { x, y, w, h } = start
  const right = start.x + start.w
  const bottom = start.y + start.h
  if (handle.includes('w')) {
    x = Math.min(Math.round(start.x + delta.x), right - min.w)
    w = right - x
  } else if (handle.includes('e')) {
    w = Math.max(min.w, Math.round(start.w + delta.x))
  }
  if (handle.includes('n')) {
    y = Math.min(Math.round(start.y + delta.y), bottom - min.h)
    h = bottom - y
  } else if (handle.includes('s')) {
    h = Math.max(min.h, Math.round(start.h + delta.y))
  }
  return { x, y, w, h }
}
