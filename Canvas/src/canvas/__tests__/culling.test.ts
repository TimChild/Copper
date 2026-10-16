import { describe, expect, it } from 'vitest'
import { CULL_MARGIN, CULL_TRIGGER, admit, arrowsToDraw, cullMargins, cullRect, needsRecull, nextCull, shapesToMount } from '../culling'
import type { Box } from '../geometry'

const visible: Box = { x: 0, y: 0, w: 1000, h: 800 }
const shift = (b: Box, dx: number, dy = 0): Box => ({ ...b, x: b.x + dx, y: b.y + dy })

describe('the cull rect', () => {
  it('is the visible world plus half a viewport on each side', () => {
    expect(cullRect(visible)).toEqual({ x: -500, y: -400, w: 2000, h: 1600 })
    const m = cullMargins(cullRect(visible), visible)
    expect(m).toEqual({ left: CULL_MARGIN, right: CULL_MARGIN, top: CULL_MARGIN, bottom: CULL_MARGIN })
  })

  it('stays put while a pan keeps a quarter viewport of margin, and moves on past it', () => {
    const c = cullRect(visible)
    // A fifth of a viewport right: still 0.3 viewports of margin.
    expect(needsRecull(c, shift(visible, 200), false)).toBe(false)
    expect(nextCull(c, shift(visible, 200), false)).toBe(c)
    // Past the trigger: a fresh rect around the new view.
    const far = shift(visible, (CULL_MARGIN - CULL_TRIGGER) * 1000 + 10)
    expect(needsRecull(c, far, false)).toBe(true)
    expect(nextCull(c, far, false)).toEqual(cullRect(far))
  })

  it('re-culls at once on a zoom out (the view grows past it)', () => {
    const c = cullRect(visible)
    const out = { x: -800, y: -640, w: 2600, h: 2080 }
    expect(needsRecull(c, out, false)).toBe(true)
  })

  it('keeps a too-big rect during a zoom in, and shrinks it once settled', () => {
    const c = cullRect(visible)
    const zoomedIn = { x: 400, y: 300, w: 200, h: 160 }
    expect(needsRecull(c, zoomedIn, false)).toBe(false)
    expect(needsRecull(c, zoomedIn, true)).toBe(true)
    // A small settle after a pan doesn't churn.
    expect(needsRecull(c, shift(visible, 100), true)).toBe(false)
  })

  it('a fresh rect never asks for another (no render loop)', () => {
    for (const v of [visible, { x: -5, y: 3, w: 1, h: 1 }, { x: 1e6, y: -1e6, w: 18400, h: 12400 }]) {
      expect(needsRecull(cullRect(v), v, true)).toBe(false)
      expect(needsRecull(cullRect(v), v, false)).toBe(false)
    }
    expect(needsRecull(null, visible, false)).toBe(true)
  })
})

describe('what is mounted', () => {
  const shapes = [
    { id: 'in', type: 'sticky', x: 100, y: 100, w: 200, h: 200 },
    { id: 'margin', type: 'sticky', x: 1300, y: 100, w: 200, h: 200 },
    { id: 'far', type: 'sticky', x: 9000, y: 9000, w: 200, h: 200 },
    { id: 'sel', type: 'image', x: -9000, y: 0, w: 200, h: 200 },
    { id: 'a1', type: 'arrow', x: 0, y: 0, w: 0, h: 0 },
  ]

  it('mounts what meets the cull rect plus what is pinned, in order, never arrows', () => {
    const c = cullRect(visible)
    expect(shapesToMount(shapes, c, new Set()).map(s => s.id)).toEqual(['in', 'margin'])
    expect(shapesToMount(shapes, c, new Set(['sel', 'a1'])).map(s => s.id)).toEqual(['in', 'margin', 'sel'])
  })

  it('draws arrows that cross the rect, that end on a mounted shape, or are pinned', () => {
    const arrow = (id: string, from: unknown, to: unknown, box: Box) => ({ shape: { id, from, to }, box })
    const list = [
      arrow('crosses', { x: -9000, y: 0 }, { x: 9000, y: 0 }, { x: -9000, y: 0, w: 18000, h: 1 }),
      arrow('fromMounted', { ref: 'sel' }, { x: -9500, y: 0 }, { x: -9500, y: 0, w: 500, h: 1 }),
      arrow('away', { x: 20000, y: 0 }, { x: 21000, y: 0 }, { x: 20000, y: 0, w: 1000, h: 1 }),
      arrow('pinned', { x: 20000, y: 0 }, { x: 21000, y: 0 }, { x: 20000, y: 0, w: 1000, h: 1 }),
    ]
    const got = arrowsToDraw(list, cullRect(visible), a => a.box, new Set(['sel']), new Set(['pinned']))
    expect(got.map(a => a.shape.id)).toEqual(['crosses', 'fromMounted', 'pinned'])
  })
})

describe('mounting in batches while the view moves', () => {
  const grid = Array.from({ length: 10 }, (_, i) => ({ id: `s${i}`, type: 'sticky', x: i * 100, y: 0, w: 50, h: 50 }))
  const cull = { x: 0, y: -500, w: 1000, h: 1000 }

  it('mounts everything once settled, or when few are new', () => {
    expect(admit(grid, null, new Set(), cull, 3)).toBe(grid)
    expect(admit(grid, new Set(grid.slice(0, 8).map(s => s.id)), new Set(), cull, 3)).toBe(grid)
  })

  it('otherwise keeps what showed, what is pinned, and the new ones nearest the middle', () => {
    const got = admit(grid, new Set(['s0']), new Set(['s9']), cull, 3).map(s => s.id)
    // Middle is x = 500: s4 (425) and s5 (525) are nearest, then s3 / s6.
    expect(got).toEqual(['s0', 's4', 's5', 's6', 's9'].filter(id => got.includes(id)))
    expect(got).toContain('s0')
    expect(got).toContain('s9')
    expect(got.filter(id => id !== 's0' && id !== 's9')).toHaveLength(3)
    expect(got).toEqual(expect.arrayContaining(['s4', 's5']))
  })
})
