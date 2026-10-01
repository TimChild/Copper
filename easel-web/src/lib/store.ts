/**
 * The smallest external store: a value, `set`, and subscribers. The board
 * keeps fast-changing state (marquee rect, which sticky is being edited)
 * here instead of in `EaselPage` state, so a change re-renders only the
 * components that read it.
 */
import { useCallback, useSyncExternalStore } from 'react'

export interface Store<T> {
  get(): T
  set(next: T): void
  subscribe(fn: () => void): () => void
}

export function createStore<T>(initial: T): Store<T> {
  let value = initial
  const subs = new Set<() => void>()
  return {
    get: () => value,
    set(next) {
      if (Object.is(next, value)) return
      value = next
      for (const fn of [...subs]) fn()
    },
    subscribe(fn) {
      subs.add(fn)
      return () => {
        subs.delete(fn)
      }
    },
  }
}

export function useStore<T>(store: Store<T>): T {
  return useSyncExternalStore(store.subscribe, store.get, store.get)
}

/**
 * Read a slice. `select` must return a primitive (or something stable),
 * because a change is detected with `Object.is` on what it returns.
 */
export function useStoreSelect<T, S>(store: Store<T>, select: (value: T) => S): S {
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const get = useCallback(() => select(store.get()), [store, select])
  return useSyncExternalStore(store.subscribe, get, get)
}
