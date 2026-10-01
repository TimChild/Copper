import { createContext, useContext } from 'react'
import type { CanvasStore } from '../doc'
import type { Me } from '../types'

/** Field of a shape being edited in place. */
export type EditField = 'text' | 'title' | 'label'

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
}

export const BoardContext = createContext<BoardActions | null>(null)

export function useBoard(): BoardActions {
  const ctx = useContext(BoardContext)
  if (!ctx) throw new Error('useBoard outside the board')
  return ctx
}
