import { describe, expect, it, vi } from 'vitest'
import { createLiveBoxes } from '../lib/live-boxes'
import { createStore } from '../lib/store'

describe('live boxes', () => {
  it('notifies only the ids whose box changed, and flips active', () => {
    const live = createLiveBoxes()
    const a = vi.fn()
    const b = vi.fn()
    const active = vi.fn()
    live.subscribe('a', a)
    live.subscribe('b', b)
    live.subscribeActive(active)
    expect(live.active()).toBe(false)

    live.set([['a', { x: 1, y: 1, w: 10, h: 10, lifted: true }]])
    expect(a).toHaveBeenCalledTimes(1)
    expect(b).not.toHaveBeenCalled()
    expect(active).toHaveBeenCalledTimes(1)
    expect(live.active()).toBe(true)

    // Same box again: nobody hears it.
    live.set([['a', { x: 1, y: 1, w: 10, h: 10, lifted: true }]])
    expect(a).toHaveBeenCalledTimes(1)

    live.set([['a', { x: 2, y: 1, w: 10, h: 10, lifted: true }]])
    expect(a).toHaveBeenCalledTimes(2)
    expect(active).toHaveBeenCalledTimes(1)

    live.clear()
    expect(live.get('a')).toBeUndefined()
    expect(a).toHaveBeenCalledTimes(3)
    expect(active).toHaveBeenCalledTimes(2)
    expect(live.active()).toBe(false)
  })
})

describe('store', () => {
  it('skips identical values', () => {
    const s = createStore<string | null>(null)
    const fn = vi.fn()
    s.subscribe(fn)
    s.set(null)
    s.set('x')
    s.set('x')
    expect(fn).toHaveBeenCalledTimes(1)
    expect(s.get()).toBe('x')
  })
})
