import { describe, expect, it } from 'vitest'
import { STICKY_MAX_H, STICKY_PAD_Y, growFor, overflows } from '../overflow'

describe('overflows', () => {
  it('is true only when the content is taller than the body', () => {
    // A 200 px note has 200 - 27 = 173 px of body.
    expect(overflows(173, 200)).toBe(false)
    expect(overflows(174, 200)).toBe(false) // a pixel of rounding slack
    expect(overflows(175, 200)).toBe(true)
    expect(overflows(0, 200)).toBe(false)
    expect(overflows(80, 96, 0)).toBe(false)
  })
})

describe('growFor', () => {
  it('grows to fit the content plus padding', () => {
    expect(growFor(200, 300)).toEqual({ h: 300 + STICKY_PAD_Y, fits: true })
    expect(growFor(200, 300.2).h).toBe(Math.ceil(300.2 + STICKY_PAD_Y))
  })

  it('never shrinks a note', () => {
    expect(growFor(400, 100)).toEqual({ h: null, fits: true })
    expect(growFor(200, 173)).toEqual({ h: null, fits: true })
  })

  it('stops at the limit and says the rest needs the editor', () => {
    expect(growFor(200, 5000)).toEqual({ h: STICKY_MAX_H, fits: false })
    expect(growFor(200, 5000, { max: 600 })).toEqual({ h: 600, fits: false })
  })

  it('leaves a note already past the limit as it is', () => {
    expect(growFor(STICKY_MAX_H + 200, 5000)).toEqual({ h: null, fits: false })
    expect(growFor(STICKY_MAX_H + 200, STICKY_MAX_H)).toEqual({ h: null, fits: true })
  })
})
