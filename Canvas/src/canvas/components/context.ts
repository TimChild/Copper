import { createContext, useCallback, useContext } from 'react'
import type { CanvasStore } from '../doc'
import type { Me } from '../types'

/** Field of a shape being edited in place. */
export type EditField = 'text' | 'title' | 'label' | `part:${string}`

export interface BoardActions {
  store: CanvasStore
  me: Me
  readOnly: boolean
  openUrl: (url: string) => void
  /** Leave in-place editing; the shape stays selected. */
  endEdit: (id: string) => void
  /** Cmd+Enter in a sticky: a fresh sticky beside (or below) this one. */
  sibling: (id: string, dir: 'right' | 'down') => void
  /** A text shape measured its content: keep its stored height in step. */
  autoHeight: (id: string, h: number) => void
  /**
   * A sticky's body needs `contentPx`: grow it to fit (never shrinking, up to
   * a limit). `open` (a click on "Show all"): one undo step, and a note too
   * long to show whole opens in its editor, which scrolls. True if it all shows.
   */
  growSticky: (id: string, contentPx: number, opts?: { open?: boolean }) => boolean
  /** A checklist's editor moves to another of its parts (`cl-title`, `cl-row:<id>`, `cl-col:<i>`); null closes it. */
  editPart: (id: string, part: string | null) => void
  /** Live frames' handles, by shape id: what the board asks a frame before it takes its page away. */
  frameHandles: Map<string, FrameHandle>
  /** When the view last moved; read, never rendered on. */
  motion: ViewMotion
  /** The exact zoom, for the few elements that must keep their size on screen every frame of a zoom. */
  zoomVars: ZoomVars
}

/**
 * The board's layer carries `--z` as the zoom it last settled at: changing an
 * inherited custom property on the layer restyles every shape under it, which
 * cost a zoom gesture 30–40 ms a frame on a big board. The few elements that
 * must stay the same size on screen through every frame of a zoom (frame
 * titles, a live frame's ring) register here instead and get the exact zoom
 * as their own `--zx`.
 */
export class ZoomVars {
  z = 1
  private els = new Set<HTMLElement>()
  /** A ref callback: keep `el`'s `--z` exact while it is mounted. */
  attach = (el: HTMLElement | null) => {
    if (!el) return
    el.style.setProperty('--zx', String(this.z))
    this.els.add(el)
    return () => {
      this.els.delete(el)
      el.style.removeProperty('--zx')
    }
  }
  set(z: number) {
    if (z === this.z) return
    this.z = z
    const v = String(z)
    for (const el of this.els) el.style.setProperty('--zx', v)
  }
}

/** When the board's view last moved (`performance.now()`). */
export class ViewMotion {
  lastMove = 0
  moved() {
    this.lastMove = performance.now()
  }
}

export interface FrameHandle {
  /**
   * The board is about to take this frame's page: a promise that settles once
   * its picture is taken (or given up on), or null to drop it at once.
   */
  beforeUnload: () => Promise<unknown> | null
}

export const BoardContext = createContext<BoardActions | null>(null)

export function useBoard(): BoardActions {
  const ctx = useContext(BoardContext)
  if (!ctx) throw new Error('useBoard outside the board')
  return ctx
}

/** A ref callback that keeps an element's own `--zx` at the board's exact zoom (`ZoomVars`). */
export function useExactZoomRef() {
  const { zoomVars } = useContext(BoardContext)!
  return useCallback((el: HTMLElement | null) => zoomVars.attach(el), [zoomVars])
}
