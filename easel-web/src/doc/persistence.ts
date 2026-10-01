/**
 * Saving: the whole doc as one base64 update, ≤ 500 ms after the last change,
 * and at once when the page hides, unloads, or native asks (`flush`). The
 * contract's `save` is idempotent, so saving a little too often is harmless
 * and saving too late is the only failure that matters.
 */
import * as Y from 'yjs'
import { bytesToBase64 } from '../host/base64'

export const SAVE_DEBOUNCE_MS = 500

export interface SaverOptions {
  doc: Y.Doc
  save: (stateB64: string, title: string) => void
  title: () => string
  debounceMs?: number
  /** Transaction origins that must not trigger a save (the initial load). */
  ignoreOrigins?: unknown[]
}

export interface Saver {
  /** Called on every doc update; a save follows after the debounce. */
  schedule(): void
  /** Save now if anything is pending (or `force`), cancelling the timer. */
  flush(force?: boolean): void
  /** Whether a save is waiting on the timer. */
  pending(): boolean
  dispose(): void
}

export function createSaver({
  doc,
  save,
  title,
  debounceMs = SAVE_DEBOUNCE_MS,
  ignoreOrigins = [],
}: SaverOptions): Saver {
  let timer: ReturnType<typeof setTimeout> | null = null
  let dirty = false

  const write = () => {
    dirty = false
    save(bytesToBase64(Y.encodeStateAsUpdate(doc)), title())
  }

  const schedule = () => {
    dirty = true
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => {
      timer = null
      write()
    }, debounceMs)
  }

  const flush = (force = false) => {
    if (timer) {
      clearTimeout(timer)
      timer = null
    }
    if (dirty || force) write()
  }

  const onUpdate = (_update: Uint8Array, origin: unknown) => {
    if (ignoreOrigins.includes(origin)) return
    schedule()
  }
  doc.on('update', onUpdate)

  return {
    schedule,
    flush,
    pending: () => dirty,
    dispose() {
      doc.off('update', onUpdate)
      if (timer) clearTimeout(timer)
      timer = null
    },
  }
}

/**
 * Flush on the page lifecycle: hidden tab, unload, and a native `flush`.
 * Returns the teardown.
 */
export function wireFlush(
  saver: Pick<Saver, 'flush'>,
  onHostFlush: (fn: () => void) => () => void,
  target: Pick<Document, 'addEventListener' | 'removeEventListener'> & {
    visibilityState?: DocumentVisibilityState
  } = document,
  win: Pick<Window, 'addEventListener' | 'removeEventListener'> = window
): () => void {
  const onVisibility = () => {
    if (target.visibilityState === 'hidden') saver.flush()
  }
  const onHide = () => saver.flush()
  // Native wants a save whether or not anything changed: it is about to
  // close the tab or quit, and the index's updatedAt should be honest.
  const offHost = onHostFlush(() => saver.flush(true))
  target.addEventListener('visibilitychange', onVisibility)
  win.addEventListener('pagehide', onHide)
  return () => {
    offHost()
    target.removeEventListener('visibilitychange', onVisibility)
    win.removeEventListener('pagehide', onHide)
  }
}
