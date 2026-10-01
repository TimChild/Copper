/**
 * The board camera, outside React. Wheel and trackpad deliver up to 120
 * events a second; holding the view in `EaselPage` state re-rendered the
 * whole board for each one. Here input only moves a target, and once per
 * animation frame the camera
 *
 *   1. hands the view to its DOM writers (layer transform, grid offset), then
 *   2. tells subscribers, which are the few components that draw in screen
 *      space (laser, cursors, selection bar, zoom %, handles, marquee).
 *
 * A pure pan or zoom therefore commits nothing in `EaselPage`.
 */
import { useSyncExternalStore } from 'react'
import type { View } from './canvas-geometry'

export interface FrameScheduler {
  request(cb: () => void): number
  cancel(id: number): void
}

const rafScheduler: FrameScheduler = {
  request: cb => requestAnimationFrame(() => cb()),
  cancel: id => cancelAnimationFrame(id),
}

export interface Camera {
  /** The newest view, input not painted yet included: map pointer events with this. */
  get(): View
  /** The view on screen, stable between frames (what React reads). */
  applied(): View
  /** Move the camera; lands on the next frame however many calls come in. */
  set(next: View | ((current: View) => View)): void
  /** Apply at once, e.g. the first fit before the board paints. */
  setNow(next: View): void
  /** Apply a pending `set` now, if any. */
  flush(): void
  /** DOM writer, called with each applied view before subscribers hear of it. */
  onApply(fn: (view: View, previous: View) => void): () => void
  subscribe(fn: () => void): () => void
  destroy(): void
}

const sameView = (a: View, b: View) => a.x === b.x && a.y === b.y && a.z === b.z

export function createCamera(
  initial: View = { x: 0, y: 0, z: 1 },
  frames: FrameScheduler = rafScheduler
): Camera {
  let target = initial
  let shown = initial
  let frame: number | null = null
  const writers = new Set<(view: View, previous: View) => void>()
  const subs = new Set<() => void>()

  const apply = () => {
    if (frame !== null) frames.cancel(frame)
    frame = null
    if (sameView(target, shown)) return
    const previous = shown
    shown = target
    for (const fn of [...writers]) fn(shown, previous)
    for (const fn of [...subs]) fn()
  }

  return {
    get: () => target,
    applied: () => shown,
    set(next) {
      const view = typeof next === 'function' ? next(target) : next
      if (sameView(view, target)) return
      target = view
      frame ??= frames.request(() => {
        frame = null
        apply()
      })
    },
    setNow(next) {
      target = next
      apply()
    },
    flush: apply,
    onApply(fn) {
      writers.add(fn)
      return () => {
        writers.delete(fn)
      }
    },
    subscribe(fn) {
      subs.add(fn)
      return () => {
        subs.delete(fn)
      }
    },
    destroy() {
      if (frame !== null) frames.cancel(frame)
      frame = null
      writers.clear()
      subs.clear()
    },
  }
}

/** The whole on-screen view; re-renders every camera frame. */
export function useCameraView(camera: Camera): View {
  return useSyncExternalStore(camera.subscribe, camera.applied, camera.applied)
}

/** Only the zoom; a pan does not re-render. */
export function useCameraZoom(camera: Camera): number {
  const get = () => camera.applied().z
  return useSyncExternalStore(camera.subscribe, get, get)
}
