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

describe('findFreeSpot with a search hint', () => {
  it('lands each shape of a run exactly where a search from the middle would', () => {
    const crowd: { x: number; y: number; w: number; h: number }[] = []
    for (let i = -12; i <= 12; i++) for (let j = -12; j <= 12; j++) if ((i * 7 + j * 3) % 5) crowd.push({ x: i * 230 - 100, y: j * 230 - 100, w: 200, h: 200 })
    const plain = [...crowd]
    const hinted = [...crowd]
    const hint = { ring: 0 }
    for (let n = 0; n < 60; n++) {
      const a = findFreeSpot(plain, size, { x: 0, y: 0 }, { gap: 24, step: 32 })
      const b = findFreeSpot(hinted, size, { x: 0, y: 0 }, { gap: 24, step: 32 }, hint)
      expect(b).toEqual(a)
      plain.push({ ...a, ...size })
      hinted.push({ ...b, ...size })
    }
    expect(hint.ring).toBeGreaterThan(1)
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
