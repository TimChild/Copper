// @vitest-environment jsdom
import { describe, expect, it, vi } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { createCamera, useCameraView, useCameraZoom, type FrameScheduler } from '../lib/camera'

/** A frame clock the test advances by hand. */
function fakeFrames() {
  let next = 1
  const queue = new Map<number, () => void>()
  const scheduler: FrameScheduler = {
    request: cb => {
      const id = next++
      queue.set(id, cb)
      return id
    },
    cancel: id => {
      queue.delete(id)
    },
  }
  const tick = () => {
    const due = [...queue.values()]
    queue.clear()
    for (const cb of due) cb()
  }
  return { scheduler, tick, pending: () => queue.size }
}

describe('camera store', () => {
  it('coalesces any number of sets into one apply per frame', () => {
    const frames = fakeFrames()
    const camera = createCamera({ x: 0, y: 0, z: 1 }, frames.scheduler)
    const write = vi.fn()
    const sub = vi.fn()
    camera.onApply(write)
    camera.subscribe(sub)
    for (let i = 0; i < 12; i++) camera.set(v => ({ ...v, x: v.x + 10 }))
    // Input composes on the newest target, which pointer mapping reads...
    expect(camera.get()).toEqual({ x: 120, y: 0, z: 1 })
    // ...but nothing is applied before the frame.
    expect(camera.applied()).toEqual({ x: 0, y: 0, z: 1 })
    expect(frames.pending()).toBe(1)
    expect(write).not.toHaveBeenCalled()
    frames.tick()
    expect(write).toHaveBeenCalledTimes(1)
    expect(write).toHaveBeenCalledWith({ x: 120, y: 0, z: 1 }, { x: 0, y: 0, z: 1 })
    expect(sub).toHaveBeenCalledTimes(1)
    expect(camera.applied()).toEqual({ x: 120, y: 0, z: 1 })
  })

  it('writes the DOM before subscribers hear of the frame', () => {
    const frames = fakeFrames()
    const camera = createCamera(undefined, frames.scheduler)
    const order: string[] = []
    camera.subscribe(() => order.push('sub'))
    camera.onApply(() => order.push('dom'))
    camera.set({ x: 1, y: 2, z: 1 })
    frames.tick()
    expect(order).toEqual(['dom', 'sub'])
  })

  it('ignores a set to the current view and does not schedule a frame', () => {
    const frames = fakeFrames()
    const camera = createCamera({ x: 5, y: 5, z: 2 }, frames.scheduler)
    camera.set({ x: 5, y: 5, z: 2 })
    expect(frames.pending()).toBe(0)
    // Moving away and back within a frame applies nothing either.
    const sub = vi.fn()
    camera.subscribe(sub)
    camera.set({ x: 6, y: 5, z: 2 })
    camera.set({ x: 5, y: 5, z: 2 })
    frames.tick()
    expect(sub).not.toHaveBeenCalled()
  })

  it('setNow and flush apply at once and cancel the pending frame', () => {
    const frames = fakeFrames()
    const camera = createCamera(undefined, frames.scheduler)
    const sub = vi.fn()
    camera.subscribe(sub)
    camera.set({ x: 9, y: 0, z: 1 })
    camera.flush()
    expect(camera.applied()).toEqual({ x: 9, y: 0, z: 1 })
    expect(frames.pending()).toBe(0)
    camera.setNow({ x: 0, y: 0, z: 0.5 })
    expect(camera.applied().z).toBe(0.5)
    expect(sub).toHaveBeenCalledTimes(2)
  })

  it('destroy drops listeners and the pending frame', () => {
    const frames = fakeFrames()
    const camera = createCamera(undefined, frames.scheduler)
    const sub = vi.fn()
    camera.subscribe(sub)
    camera.set({ x: 3, y: 0, z: 1 })
    camera.destroy()
    expect(frames.pending()).toBe(0)
    camera.flush()
    expect(sub).not.toHaveBeenCalled()
  })

  it('useCameraZoom re-renders on zoom only; useCameraView on every frame', () => {
    const frames = fakeFrames()
    const camera = createCamera({ x: 0, y: 0, z: 1 }, frames.scheduler)
    let zoomRenders = 0
    let viewRenders = 0
    const zoom = renderHook(() => {
      zoomRenders++
      return useCameraZoom(camera)
    })
    const view = renderHook(() => {
      viewRenders++
      return useCameraView(camera)
    })
    const baseZoom = zoomRenders
    const baseView = viewRenders
    act(() => {
      camera.set({ x: 40, y: 10, z: 1 })
      frames.tick()
    })
    expect(zoomRenders).toBe(baseZoom)
    expect(viewRenders).toBe(baseView + 1)
    expect(view.result.current).toEqual({ x: 40, y: 10, z: 1 })
    act(() => {
      camera.set({ x: 40, y: 10, z: 2 })
      frames.tick()
    })
    expect(zoom.result.current).toBe(2)
    expect(zoomRenders).toBe(baseZoom + 1)
  })
})
