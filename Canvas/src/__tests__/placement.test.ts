import { describe, expect, it } from 'vitest'
import { boxesOverlap } from '../canvas/geometry'
import { findFreeSpot, gridSlots } from '../placement'

const size = { w: 200, h: 200 }

describe('findFreeSpot', () => {
  it('takes the centre when it is free', () => {
    expect(findFreeSpot([], size, { x: 0, y: 0 })).toEqual({ x: -100, y: -100 })
  })

  it('moves to the nearest clear spot, with the gap kept', () => {
    const taken = [{ x: -100, y: -100, w: 200, h: 200 }]
    const p = findFreeSpot(taken, size, { x: 0, y: 0 }, { gap: 24 })
    const box = { ...p, ...size }
    expect(boxesOverlap(box, taken[0]!, 23)).toBe(false)
    // Nearest first, and ties go right.
    expect(p.y).toBe(-100)
    expect(p.x).toBeGreaterThan(100)
  })

  it('never overlaps anything, however crowded the middle is', () => {
    const taken = []
    for (let i = -3; i <= 3; i++) for (let j = -3; j <= 3; j++) taken.push({ x: i * 220 - 100, y: j * 220 - 100, w: 200, h: 200 })
    const p = findFreeSpot(taken, size, { x: 0, y: 0 }, { gap: 16 })
    for (const t of taken) expect(boxesOverlap({ ...p, ...size }, t, 15)).toBe(false)
  })

  it('places a run of shapes without overlap when each sees the last', () => {
    const taken: { x: number; y: number; w: number; h: number }[] = []
    for (let i = 0; i < 12; i++) taken.push({ ...findFreeSpot(taken, size, { x: 0, y: 0 }), ...size })
    for (let i = 0; i < taken.length; i++)
      for (let j = i + 1; j < taken.length; j++) expect(boxesOverlap(taken[i]!, taken[j]!)).toBe(false)
  })
})

describe('gridSlots', () => {
  it('lays boxes in rows', () => {
    expect(gridSlots({ x: 0, y: 0 }, { w: 10, h: 10 }, 3, 2, 5)).toEqual([
      { x: 0, y: 0 },
      { x: 15, y: 0 },
      { x: 0, y: 15 },
    ])
  })
})
