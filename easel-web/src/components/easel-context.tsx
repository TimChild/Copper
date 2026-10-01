/**
 * What every shape component needs from the page: the doc to write to, the
 * host (for picture URLs) and who is looking. Replaces the wiki app's imports
 * of module-level `canvasDoc` functions and `useViewer()`.
 */
import { createContext, useContext } from 'react'
import type { EaselDoc } from '../doc/easel-doc'
import type { Host, Viewer } from '../host/types'

export interface EaselContextValue {
  doc: EaselDoc
  host: Host
  easelId: string
  viewer: Viewer
}

export const EaselContext = createContext<EaselContextValue | null>(null)

export function useEasel(): EaselContextValue {
  const value = useContext(EaselContext)
  if (!value) throw new Error('useEasel outside <EaselContext.Provider>')
  return value
}
