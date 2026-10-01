/**
 * Where shapes are while a gesture moves them (drag, resize, drawing a new
 * box), keyed by shape id. Only the moved shapes, the arrows on them and
 * their handles subscribe to their own ids, so a drag re-renders those and
 * nothing else; the document is written once, on release (one undo step).
 */
import { useCallback, useSyncExternalStore } from 'react'
import type { Box } from './canvas-geometry'

export interface LiveBox extends Box {
  /** Picked up by a drag: drawn above the rest with a lifted shadow. */
  lifted?: boolean
}

export interface LiveBoxes {
  get(id: string | undefined): LiveBox | undefined
  /** Put these shapes at these boxes; notifies only ids whose box changed. */
  set(entries: Iterable<[string, LiveBox]>): void
  /** Drop every live box (the gesture ended). */
  clear(): void
  /** Whether a gesture is moving anything. */
  active(): boolean
  subscribe(id: string, fn: () => void): () => void
  /** Fires when `active()` flips. */
  subscribeActive(fn: () => void): () => void
}

const same = (a: LiveBox | undefined, b: LiveBox | undefined) =>
  a === b ||
  (!!a &&
    !!b &&
    a.x === b.x &&
    a.y === b.y &&
    a.w === b.w &&
    a.h === b.h &&
    !!a.lifted === !!b.lifted)

export function createLiveBoxes(): LiveBoxes {
  const boxes = new Map<string, LiveBox>()
  const subs = new Map<string, Set<() => void>>()
  const activeSubs = new Set<() => void>()
  const notify = (ids: Iterable<string>) => {
    for (const id of ids) for (const fn of [...(subs.get(id) ?? [])]) fn()
  }
  const flipped = (was: boolean) => {
    if (was !== boxes.size > 0) for (const fn of [...activeSubs]) fn()
  }
  return {
    get: id => (id === undefined ? undefined : boxes.get(id)),
    set(entries) {
      const was = boxes.size > 0
      const changed: string[] = []
      for (const [id, box] of entries) {
        if (same(boxes.get(id), box)) continue
        boxes.set(id, box)
        changed.push(id)
      }
      notify(changed)
      flipped(was)
    },
    clear() {
      if (!boxes.size) return
      const ids = [...boxes.keys()]
      boxes.clear()
      notify(ids)
      flipped(true)
    },
    active: () => boxes.size > 0,
    subscribe(id, fn) {
      let set = subs.get(id)
      if (!set) subs.set(id, (set = new Set()))
      set.add(fn)
      return () => {
        set.delete(fn)
        if (!set.size) subs.delete(id)
      }
    },
    subscribeActive(fn) {
      activeSubs.add(fn)
      return () => {
        activeSubs.delete(fn)
      }
    },
  }
}

/** This shape's live box while a gesture moves it, else undefined. */
export function useLiveBox(live: LiveBoxes, id: string | undefined): LiveBox | undefined {
  const subscribe = useCallback(
    (fn: () => void) => (id === undefined ? () => {} : live.subscribe(id, fn)),
    [live, id]
  )
  const get = useCallback(() => live.get(id), [live, id])
  return useSyncExternalStore(subscribe, get, get)
}

export function useLiveActive(live: LiveBoxes): boolean {
  return useSyncExternalStore(live.subscribeActive, live.active, live.active)
}
