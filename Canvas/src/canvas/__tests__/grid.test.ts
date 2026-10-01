import { describe, expect, it } from 'vitest'
import { GRID, MAJOR_EVERY, MINOR_MIN_PX, fadeIn, gridBackground, gridLayers } from '../grid'

describe('fadeIn', () => {
  it('ramps from 0 at the cutoff to 1 over the last 30% of scale', () => {
    expect(fadeIn(8, 8)).toBe(0)
    expect(fadeIn(7, 8)).toBe(0)
    expect(fadeIn(8 / 0.7, 8)).toBe(1)
    expect(fadeIn(24, 8)).toBe(1)
    const steps = [8.5, 9, 10, 11].map(px => fadeIn(px, 8))
    for (let i = 1; i < steps.length; i++) expect(steps[i]!).toBeGreaterThan(steps[i - 1]!)
    expect(steps.every(a => a > 0 && a < 1)).toBe(true)
  })
})

describe('gridLayers', () => {
  it('is the plain minor grid at ordinary zoom', () => {
    expect(gridLayers(1)).toEqual([{ size: GRID, alpha: 1 }])
    expect(gridLayers(0.5)).toEqual([{ size: GRID / 2, alpha: 1 }])
  })

  it('fades the minor dots just above the old cutoff and lets the major ones take over', () => {
    const z = (MINOR_MIN_PX / GRID) * 1.15
    const [minor, major] = gridLayers(z)
    expect(minor!.alpha).toBeGreaterThan(0)
    expect(minor!.alpha).toBeLessThan(1)
    expect(major!.size).toBeCloseTo(minor!.size * MAJOR_EVERY)
    expect(major!.alpha).toBeCloseTo(1 - minor!.alpha)
  })

  it('shows only the sparse dots at the 34% overview, and nothing far out', () => {
    const layers = gridLayers(0.34)
    expect(layers).toHaveLength(1)
    expect(layers[0]!.size).toBeCloseTo(GRID * MAJOR_EVERY * 0.34)
    expect(gridLayers(0.1)).toEqual([])
    expect(gridBackground({ x: 0, y: 0, z: 0.1 })).toEqual({})
  })

  it('lines the major dots up with minor ones', () => {
    const bg = gridBackground({ x: 10, y: 20, z: 0.4 })
    const [minorAt, majorAt] = bg.backgroundPosition!.split(', ')
    const parse = (s: string) => s.split(' ').map(v => parseFloat(v))
    const [mx, my] = parse(minorAt!)
    const [Mx, My] = parse(majorAt!)
    const minor = GRID * 0.4
    // Centre of the first major tile lands on a minor dot centre.
    expect(((Mx! + (minor * MAJOR_EVERY) / 2 - (mx! + minor / 2)) / minor) % 1).toBeCloseTo(0)
    expect(((My! + (minor * MAJOR_EVERY) / 2 - (my! + minor / 2)) / minor) % 1).toBeCloseTo(0)
    expect(bg.backgroundImage).toMatch(/color-mix/)
  })
})
