/**
 * The board's fast-changing state, outside React state: the camera, live
 * boxes for shapes a gesture is moving, which sticky is being edited and
 * the marquee. `EaselPage` makes one per board; the default lets a shape
 * render on its own (tests).
 */
import { createContext, useContext } from 'react'
import { createCamera, type Camera } from '../lib/camera'
import type { Box } from '../lib/canvas-geometry'
import { createLiveBoxes, type LiveBoxes } from '../lib/live-boxes'
import { createStore, type Store } from '../lib/store'

export interface Board {
  camera: Camera
  live: LiveBoxes
  /** Id of the sticky whose TipTap editor is mounted, if any. */
  editing: Store<string | null>
  /** The rubber band in canvas coords while one is being dragged. */
  marquee: Store<Box | null>
}

export function createBoard(): Board {
  return {
    camera: createCamera(),
    live: createLiveBoxes(),
    editing: createStore<string | null>(null),
    marquee: createStore<Box | null>(null),
  }
}

export const BoardContext = createContext<Board>(createBoard())

export const useBoard = () => useContext(BoardContext)
