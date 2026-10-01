// Ported from the wiki app's __tests__/canvas-geometry.test.ts minus the wiki
// page-card cases; fitBoxes, rectFrom and intersection are new.
import { describe, expect, it } from 'vitest'
import {
  MAX_ZOOM,
  MIN_ZOOM,
  boxSegment,
  boxesIntersect,
  canvasToScreen,
  fitBoxes,
  pointInBox,
  rectFrom,
  screenToCanvas,
  zoomAt,
  zoomTo,
} from '../lib/canvas-geometry'

describe('boxSegment', () => {
  it('clips to the borders of boxes of any size', () => {
    const sticky = { x: 0, y: 0, w: 200, h: 140 }
    const frame = { x: 400, y: -90, w: 480, h: 320 }
    expect(boxSegment(sticky, frame)).toEqual({
      x1: 200,
      y1: 70,
      x2: 400,
      y2: 70,
    })
  })

  it('clips diagonally on the nearer side', () => {
    const seg = boxSegment(
      { x: 0, y: 0, w: 100, h: 100 },
      { x: 300, y: 300, w: 100, h: 100 }
    )!
    expect(seg).toEqual({ x1: 100, y1: 100, x2: 300, y2: 300 })
  })

  it('drops overlapping boxes of different sizes', () => {
    expect(
      boxSegment(
        { x: 0, y: 0, w: 480, h: 320 },
        { x: 100, y: 100, w: 200, h: 140 }
      )
    ).toBeNull()
  })
})

describe('view math', () => {
  it('round-trips screen and canvas coordinates', () => {
    const view = { x: 30, y: -20, z: 1.5 }
    const p = { x: 200, y: 150 }
    expect(canvasToScreen(view, screenToCanvas(view, p))).toEqual(p)
  })

  it('zooms around the cursor', () => {
    const view = { x: 30, y: -20, z: 1 }
    const cursor = { x: 200, y: 150 }
    const before = screenToCanvas(view, cursor)
    const after = screenToCanvas(zoomAt(view, 1.5, cursor), cursor)
    expect(after.x).toBeCloseTo(before.x)
    expect(after.y).toBeCloseTo(before.y)
  })

  it('clamps zoom to the allowed range', () => {
    const view = { x: 0, y: 0, z: 1 }
    expect(zoomAt(view, 100, { x: 0, y: 0 }).z).toBe(MAX_ZOOM)
    expect(zoomAt(view, 0.0001, { x: 0, y: 0 }).z).toBe(MIN_ZOOM)
    expect(zoomTo(view, 5, { x: 0, y: 0 }).z).toBe(MAX_ZOOM)
  })

  it('zoomTo lands on the exact level and keeps the point fixed', () => {
    const view = { x: 120, y: 40, z: 0.6 }
    const p = { x: 300, y: 200 }
    const next = zoomTo(view, 1, p)
    expect(next.z).toBe(1)
    const a = screenToCanvas(view, p)
    const b = screenToCanvas(next, p)
    expect(b.x).toBeCloseTo(a.x)
    expect(b.y).toBeCloseTo(a.y)
  })
})

describe('fitBoxes', () => {
  it('centres the origin when there is nothing to show', () => {
    expect(fitBoxes([], 800, 600)).toEqual({ x: 400, y: 300, z: 1 })
  })

  it('fits every box inside the viewport', () => {
    const boxes = [
      { x: -1000, y: 0, w: 200, h: 140 },
      { x: 1000, y: 400, w: 480, h: 320 },
    ]
    const view = fitBoxes(boxes, 800, 600)
    const left = -1000 * view.z + view.x
    const right = (1000 + 480) * view.z + view.x
    const top = 0 * view.z + view.y
    const bottom = (400 + 320) * view.z + view.y
    expect(left).toBeGreaterThanOrEqual(0)
    expect(right).toBeLessThanOrEqual(800)
    expect(top).toBeGreaterThanOrEqual(0)
    expect(bottom).toBeLessThanOrEqual(600)
  })

  it('never zooms past 100% for a small board', () => {
    const view = fitBoxes([{ x: 0, y: 0, w: 200, h: 140 }], 1600, 1200)
    expect(view.z).toBe(1)
    // and the one box is centred
    expect(view.x + 100).toBeCloseTo(800)
    expect(view.y + 70).toBeCloseTo(600)
  })
})

describe('rects', () => {
  it('spans two corners in any drag direction', () => {
    expect(rectFrom({ x: 10, y: 10 }, { x: 0, y: 30 })).toEqual({
      x: 0,
      y: 10,
      w: 10,
      h: 20,
    })
  })

  it('tests intersection and containment', () => {
    const a = { x: 0, y: 0, w: 100, h: 100 }
    expect(boxesIntersect(a, { x: 50, y: 50, w: 100, h: 100 })).toBe(true)
    expect(boxesIntersect(a, { x: 100, y: 0, w: 10, h: 10 })).toBe(false)
    expect(pointInBox({ x: 100, y: 100 }, a)).toBe(true)
    expect(pointInBox({ x: 101, y: 100 }, a)).toBe(false)
  })
})
