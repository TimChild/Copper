import { useEffect, useState, useSyncExternalStore } from 'react'
import { createRoot } from 'react-dom/client'
import { detectHost } from './host'
import type { Host } from './host/types'
import { openEaselSession, type EaselSession } from './session'
import { EaselContext } from './components/easel-context'
import { EaselPage } from './components/easel-page'
import { debug } from './debug'
import './app.css'

function App({ host }: { host: Host }) {
  const [session, setSession] = useState<EaselSession | null>(null)
  useEffect(() => {
    let live = true
    let opened: EaselSession | null = null
    openEaselSession(host)
      .then(s => {
        if (!live) return s.close()
        opened = s
        setSession(s)
      })
      .catch(error => {
        host.log(
          'error',
          `could not open: ${error instanceof Error ? error.message : String(error)}`
        )
      })
    return () => {
      live = false
      opened?.close()
    }
  }, [host])
  if (!session) return <div className="easel-viewport" aria-busy="true" />
  return <Session session={session} />
}

function Session({ session }: { session: EaselSession }) {
  const { doc, host, config } = session
  const meta = useSyncExternalStore(doc.subscribeMeta, doc.getMeta)
  useEffect(() => {
    debug.attach(session)
    return () => debug.attach(null)
  }, [session])
  // The tab's title is document.title; keep it equal to the easel's.
  useEffect(() => {
    document.title = meta.title
  }, [meta.title])
  return (
    <EaselContext.Provider
      value={{ doc, host, easelId: config.easel.id, viewer: config.viewer }}
    >
      <EaselPage session={session} title={meta.title} />
    </EaselContext.Provider>
  )
}

const host = detectHost()
window.addEventListener('error', e => host.log('error', String(e.message)))
window.addEventListener('unhandledrejection', e =>
  host.log('error', `unhandled: ${String(e.reason)}`)
)

createRoot(document.getElementById('root')!).render(<App host={host} />)
