/** Root: one board per initialised session; a quiet backdrop until the host calls init. */
import { useSyncExternalStore } from 'react'
import { controller } from '../../controller'
import { Board } from './Board'

export function CanvasApp() {
  useSyncExternalStore(controller.subscribe, controller.getVersion)
  const session = controller.session
  if (!session) return <div className="h-full w-full" style={{ background: 'var(--bg)' }} aria-busy="true" />
  return <Board key={session.serial} session={session} />
}
