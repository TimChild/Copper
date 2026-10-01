import { describe, expect, it } from 'vitest'
import { CORNER_HANDLES, EDGE_HANDLES, HANDLE_CURSOR, MIN_SIZE, isResizable, resizeBox, resizeBoxKeepAspect } from '../resize'

const start = { x: 100, y: 200, w: 200, h: 140 }
const min = MIN_SIZE.sticky

describe('resizeBox', () => {
  it('grows from the bottom-right corner without moving the origin', () => {
    expect(resizeBox(start, 'se', { x: 40, y: 20 }, min)).toEqual({ x: 100, y: 200, w: 240, h: 160 })
  })

  it('keeps the bottom-right corner anchored when dragging top-left', () => {
    const box = resizeBox(start, 'nw', { x: -30, y: 50 }, min)
    expect(box).toEqual({ x: 70, y: 250, w: 230, h: 90 })
    expect(box.x + box.w).toBe(start.x + start.w)
    expect(box.y + box.h).toBe(start.y + start.h)
  })

  it('anchors the opposite corner for ne and sw', () => {
    expect(resizeBox(start, 'ne', { x: 10, y: -10 }, min)).toEqual({ x: 100, y: 190, w: 210, h: 150 })
    expect(resizeBox(start, 'sw', { x: 10, y: -10 }, min)).toEqual({ x: 110, y: 200, w: 190, h: 130 })
  })

  it('edge handles move one axis only', () => {
    const d = { x: 25, y: 25 }
    expect(resizeBox(start, 'e', d, min)).toEqual({ ...start, w: 225 })
    expect(resizeBox(start, 's', d, min)).toEqual({ ...start, h: 165 })
    expect(resizeBox(start, 'w', d, min)).toEqual({ ...start, x: 125, w: 175 })
    expect(resizeBox(start, 'n', d, min)).toEqual({ ...start, y: 225, h: 115 })
  })

  it('clamps to the minimum size from the far side', () => {
    expect(resizeBox(start, 'se', { x: -1000, y: -1000 }, min)).toEqual({ x: 100, y: 200, w: 96, h: 64 })
  })

  it('clamps a top-left drag without letting the anchor move or edges cross', () => {
    expect(resizeBox(start, 'nw', { x: 1000, y: 1000 }, min)).toEqual({ x: 300 - 96, y: 340 - 64, w: 96, h: 64 })
  })

  it('uses the frame minimum for frames', () => {
    expect(resizeBox({ x: 0, y: 0, w: 480, h: 320 }, 'sw', { x: 900, y: -900 }, MIN_SIZE.frame)).toEqual({
      x: 320,
      y: 0,
      w: 160,
      h: 120,
    })
  })

  it('snaps moving edges to whole pixels and leaves the anchor exact', () => {
    expect(resizeBox(start, 'nw', { x: -10.4, y: 3.6 }, min)).toEqual({ x: 90, y: 204, w: 210, h: 136 })
  })

  it('is the identity for a zero delta', () => {
    for (const handle of [...CORNER_HANDLES, ...EDGE_HANDLES]) expect(resizeBox(start, handle, { x: 0, y: 0 }, min)).toEqual(start)
  })
})

describe('resizeBoxKeepAspect', () => {
  const img = { x: 0, y: 0, w: 400, h: 200 }
  it('holds the ratio from a corner, anchored opposite', () => {
    const box = resizeBoxKeepAspect(img, 'se', { x: 200, y: 0 }, MIN_SIZE.image)
    expect(box).toEqual({ x: 0, y: 0, w: 600, h: 300 })
    const nw = resizeBoxKeepAspect(img, 'nw', { x: 200, y: 0 }, MIN_SIZE.image)
    expect(nw.x + nw.w).toBe(400)
    expect(nw.y + nw.h).toBe(200)
    expect(nw.w / nw.h).toBeCloseTo(2)
  })

  it('scales the other axis around the middle from an edge', () => {
    const box = resizeBoxKeepAspect(img, 'e', { x: 400, y: 0 }, MIN_SIZE.image)
    expect(box).toEqual({ x: 0, y: -100, w: 800, h: 400 })
  })
})

describe('handles', () => {
  it('has a resize cursor for every handle', () => {
    for (const handle of [...CORNER_HANDLES, ...EDGE_HANDLES]) expect(HANDLE_CURSOR[handle]).toMatch(/-resize$/)
    expect(HANDLE_CURSOR.nw).toBe('nwse-resize')
    expect(HANDLE_CURSOR.ne).toBe('nesw-resize')
  })

  it('resizes boxes but not arrows', () => {
    for (const t of ['sticky', 'text', 'frame', 'image', 'link']) expect(isResizable(t)).toBe(true)
    expect(isResizable('arrow')).toBe(false)
  })
})
