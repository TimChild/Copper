import { describe, expect, it } from 'vitest'
import {
  MAX_ZOOM,
  MIN_ZOOM,
  boxFromPoints,
  boxSegment,
  boxesOverlap,
  containsBox,
  distanceToSegment,
  exitPoint,
  fitBoxes,
  nearestSide,
  screenToWorld,
  segmentIntersectsBox,
  sidePoint,
  unionBox,
  visibleWorld,
  worldToScreen,
  zoomAt,
  zoomTo,
} from '../geometry'

describe('boxSegment', () => {
  it('runs from the right edge of one box to the left edge of the next', () => {
    expect(boxSegment({ x: 0, y: 0, w: 240, h: 112 }, { x: 400, y: 0, w: 240, h: 112 })).toEqual({
      x1: 240,
      y1: 56,
      x2: 400,
      y2: 56,
    })
  })

  it('clips to the borders of boxes of any size', () => {
    const sticky = { x: 0, y: 0, w: 200, h: 140 }
    const frame = { x: 400, y: -90, w: 480, h: 320 }
    expect(boxSegment(sticky, frame)).toEqual({ x1: 200, y1: 70, x2: 400, y2: 70 })
  })

  it('clips diagonally on the nearer side', () => {
    const seg = boxSegment({ x: 0, y: 0, w: 100, h: 100 }, { x: 300, y: 300, w: 100, h: 100 })!
    expect(seg).toEqual({ x1: 100, y1: 100, x2: 300, y2: 300 })
  })

  it('drops overlapping boxes of different sizes', () => {
    expect(boxSegment({ x: 0, y: 0, w: 480, h: 320 }, { x: 100, y: 100, w: 200, h: 140 })).toBeNull()
  })
})

describe('sides and points', () => {
  const box = { x: 10, y: 20, w: 100, h: 60 }

  it('puts side midpoints on each edge', () => {
    expect(sidePoint(box, 'top')).toEqual({ x: 60, y: 20 })
    expect(sidePoint(box, 'right')).toEqual({ x: 110, y: 50 })
    expect(sidePoint(box, 'bottom')).toEqual({ x: 60, y: 80 })
    expect(sidePoint(box, 'left')).toEqual({ x: 10, y: 50 })
  })

  it('finds the side nearest a point', () => {
    expect(nearestSide(box, { x: 112, y: 52 }).side).toBe('right')
    expect(nearestSide(box, { x: 60, y: 0 }).side).toBe('top')
    expect(nearestSide(box, { x: 60, y: 0 }).distance).toBe(20)
  })

  it('exits a box toward a point, and stays at the centre for the centre', () => {
    expect(exitPoint(box, { x: 500, y: 50 })).toEqual({ x: 110, y: 50 })
    expect(exitPoint(box, { x: 60, y: 50 })).toEqual({ x: 60, y: 50 })
  })

  it('measures distance to a segment', () => {
    const seg = { x1: 0, y1: 0, x2: 100, y2: 0 }
    expect(distanceToSegment({ x: 50, y: 30 }, seg)).toBe(30)
    expect(distanceToSegment({ x: -30, y: 40 }, seg)).toBe(50)
  })

  it('tells when a segment crosses a box', () => {
    const b = { x: 0, y: 0, w: 10, h: 10 }
    expect(segmentIntersectsBox({ x1: -5, y1: 5, x2: 15, y2: 5 }, b)).toBe(true)
    expect(segmentIntersectsBox({ x1: -5, y1: 20, x2: 15, y2: 20 }, b)).toBe(false)
    expect(segmentIntersectsBox({ x1: 2, y1: 2, x2: 3, y2: 3 }, b)).toBe(true)
  })
})

describe('boxes', () => {
  it('overlaps with a gap, contains, unions and normalises', () => {
    const a = { x: 0, y: 0, w: 10, h: 10 }
    expect(boxesOverlap(a, { x: 15, y: 0, w: 10, h: 10 })).toBe(false)
    expect(boxesOverlap(a, { x: 15, y: 0, w: 10, h: 10 }, 6)).toBe(true)
    expect(containsBox({ x: -1, y: -1, w: 20, h: 20 }, a)).toBe(true)
    expect(containsBox(a, { x: 5, y: 5, w: 10, h: 10 })).toBe(false)
    expect(unionBox([a, { x: 20, y: -5, w: 5, h: 5 }])).toEqual({ x: 0, y: -5, w: 25, h: 15 })
    expect(unionBox([])).toBeNull()
    expect(boxFromPoints({ x: 10, y: 0 }, { x: 0, y: 10 })).toEqual({ x: 0, y: 0, w: 10, h: 10 })
  })
})

describe('view math', () => {
  it('zooms around the cursor', () => {
    const view = { x: 30, y: -20, z: 1 }
    const cursor = { x: 200, y: 150 }
    const before = screenToWorld(view, cursor)
    const after = screenToWorld(zoomAt(view, 1.5, cursor), cursor)
    expect(after.x).toBeCloseTo(before.x)
    expect(after.y).toBeCloseTo(before.y)
  })

  it('clamps zoom and sets an absolute zoom', () => {
    expect(zoomAt({ x: 0, y: 0, z: 1 }, 1000, { x: 0, y: 0 }).z).toBe(MAX_ZOOM)
    expect(zoomAt({ x: 0, y: 0, z: 1 }, 0.0001, { x: 0, y: 0 }).z).toBe(MIN_ZOOM)
    expect(zoomTo({ x: 10, y: 10, z: 2 }, 1, { x: 0, y: 0 }).z).toBe(1)
  })

  it('round-trips screen and world points', () => {
    const view = { x: 12, y: -40, z: 0.75 }
    const p = { x: 300, y: 200 }
    const w = screenToWorld(view, p)
    expect(worldToScreen(view, w).x).toBeCloseTo(p.x)
    expect(worldToScreen(view, w).y).toBeCloseTo(p.y)
  })

  it('fits every box into the viewport, never past 100%', () => {
    const view = fitBoxes(
      [
        { x: -1000, y: 0, w: 240, h: 112 },
        { x: 1000, y: 400, w: 240, h: 112 },
      ],
      800,
      600
    )
    expect(-1000 * view.z + view.x).toBeGreaterThanOrEqual(0)
    expect((1000 + 240) * view.z + view.x).toBeLessThanOrEqual(800)
    expect(fitBoxes([{ x: 0, y: 0, w: 10, h: 10 }], 800, 600).z).toBe(1)
  })

  it('centres the origin for an empty board', () => {
    expect(fitBoxes([], 800, 600)).toEqual({ x: 400, y: 300, z: 1 })
  })

  it('knows the visible world rectangle', () => {
    expect(visibleWorld({ x: -100, y: -50, z: 2 }, 800, 600)).toEqual({ x: 50, y: 25, w: 400, h: 300 })
  })
})
