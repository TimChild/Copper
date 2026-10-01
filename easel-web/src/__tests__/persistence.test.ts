import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { createEaselDoc, LOAD_ORIGIN } from '../doc/easel-doc'
import { createSaver, wireFlush, SAVE_DEBOUNCE_MS } from '../doc/persistence'
import { base64ToBytes } from '../host/base64'

type Listener = (e?: unknown) => void

/** A tiny document/window double with the two events the saver listens to. */
function fakeTargets() {
  const listeners = new Map<string, Set<Listener>>()
  const on = (type: string, fn: EventListenerOrEventListenerObject) => {
    const set = listeners.get(type) ?? new Set()
    set.add(fn as Listener)
    listeners.set(type, set)
  }
  const off = (type: string, fn: EventListenerOrEventListenerObject) =>
    listeners.get(type)?.delete(fn as Listener)
  const target = {
    visibilityState: 'visible' as DocumentVisibilityState,
    addEventListener: on,
    removeEventListener: off,
  }
  const win = { addEventListener: on, removeEventListener: off }
  const fire = (type: string) => listeners.get(type)?.forEach(fn => fn())
  return { target, win, fire, count: (t: string) => listeners.get(t)?.size ?? 0 }
}

describe('saver', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('debounces local changes into one save ≤ 500 ms later, with the title', () => {
    const easel = createEaselDoc()
    const save = vi.fn()
    const saver = createSaver({ doc: easel.doc, save, title: easel.title })
    easel.setTitle('Plan')
    easel.createShape({ type: 'sticky', text: 'a' })
    easel.createShape({ type: 'sticky', text: 'b' })
    expect(save).not.toHaveBeenCalled()
    expect(saver.pending()).toBe(true)
    vi.advanceTimersByTime(SAVE_DEBOUNCE_MS - 1)
    expect(save).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(save).toHaveBeenCalledTimes(1)
    expect(saver.pending()).toBe(false)

    const [state, title] = save.mock.calls[0]!
    expect(title).toBe('Plan')
    // The state is the whole doc: a fresh doc loads to the same shapes.
    const copy = new Y.Doc()
    Y.applyUpdate(copy, base64ToBytes(state))
    expect(copy.getMap('shapes').size).toBe(2)
    expect(copy.getMap('meta').get('title')).toBe('Plan')
    saver.dispose()
  })

  it('restarts the timer on every change', () => {
    const easel = createEaselDoc()
    const save = vi.fn()
    const saver = createSaver({ doc: easel.doc, save, title: easel.title })
    easel.createShape({ type: 'sticky' })
    vi.advanceTimersByTime(400)
    easel.createShape({ type: 'sticky' })
    vi.advanceTimersByTime(400)
    expect(save).not.toHaveBeenCalled()
    vi.advanceTimersByTime(100)
    expect(save).toHaveBeenCalledTimes(1)
    saver.dispose()
  })

  it('flush saves at once when something is pending and not otherwise', () => {
    const easel = createEaselDoc()
    const save = vi.fn()
    const saver = createSaver({ doc: easel.doc, save, title: easel.title })
    saver.flush()
    expect(save).not.toHaveBeenCalled()
    easel.createShape({ type: 'sticky' })
    saver.flush()
    expect(save).toHaveBeenCalledTimes(1)
    // The timer was cancelled: nothing doubles up later.
    vi.advanceTimersByTime(1000)
    expect(save).toHaveBeenCalledTimes(1)
    // A forced flush saves even with nothing pending (native's `flush`).
    saver.flush(true)
    expect(save).toHaveBeenCalledTimes(2)
    saver.dispose()
  })

  it('ignores the initial load but saves everything after', () => {
    const source = createEaselDoc()
    source.createShape({ type: 'sticky', text: 'saved' })
    const update = Y.encodeStateAsUpdate(source.doc)

    const easel = createEaselDoc()
    const save = vi.fn()
    const saver = createSaver({
      doc: easel.doc,
      save,
      title: easel.title,
      ignoreOrigins: [LOAD_ORIGIN],
    })
    Y.applyUpdate(easel.doc, update, LOAD_ORIGIN)
    vi.advanceTimersByTime(1000)
    expect(save).not.toHaveBeenCalled()
    easel.setTitle('Now dirty')
    vi.advanceTimersByTime(500)
    expect(save).toHaveBeenCalledTimes(1)
    saver.dispose()
  })

  it('stops after dispose', () => {
    const easel = createEaselDoc()
    const save = vi.fn()
    const saver = createSaver({ doc: easel.doc, save, title: easel.title })
    easel.createShape({ type: 'sticky' })
    saver.dispose()
    vi.advanceTimersByTime(1000)
    easel.createShape({ type: 'sticky' })
    vi.advanceTimersByTime(1000)
    expect(save).not.toHaveBeenCalled()
  })
})

describe('wireFlush', () => {
  it('flushes on hidden, pagehide and a native flush; unwires cleanly', () => {
    const flush = vi.fn()
    const { target, win, fire, count } = fakeTargets()
    let hostFlush: (() => void) | null = null
    const offHost = vi.fn()
    const unwire = wireFlush(
      { flush },
      fn => {
        hostFlush = fn
        return offHost
      },
      target,
      win
    )

    fire('visibilitychange')
    expect(flush).not.toHaveBeenCalled() // still visible
    target.visibilityState = 'hidden'
    fire('visibilitychange')
    expect(flush).toHaveBeenCalledTimes(1)
    expect(flush).toHaveBeenLastCalledWith()

    fire('pagehide')
    expect(flush).toHaveBeenCalledTimes(2)

    hostFlush!()
    expect(flush).toHaveBeenCalledTimes(3)
    // Native's flush is forced: it saves even with nothing pending.
    expect(flush).toHaveBeenLastCalledWith(true)

    unwire()
    expect(offHost).toHaveBeenCalledTimes(1)
    expect(count('visibilitychange')).toBe(0)
    expect(count('pagehide')).toBe(0)
  })
})
