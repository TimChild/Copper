/**
 * Opening an easel: ask the host for `config`, build the doc, apply the
 * saved state, start awareness and the saver, and wire the flush hooks.
 */
import * as Y from 'yjs'
import type { Awareness } from 'y-protocols/awareness'
import type { EaselConfig, Host } from './host/types'
import { base64ToBytes } from './host/base64'
import { createEaselDoc, LOAD_ORIGIN, type EaselDoc } from './doc/easel-doc'
import { createSaver, wireFlush, type Saver } from './doc/persistence'
import { createAwareness } from './lib/awareness'
import { mark } from './debug'

export interface EaselSession {
  host: Host
  config: EaselConfig
  doc: EaselDoc
  awareness: Awareness
  saver: Saver
  /** Flush and release everything. */
  close(): void
}

export async function openEaselSession(host: Host): Promise<EaselSession> {
  const config = await host.ready()
  mark('config')
  const doc = createEaselDoc()
  if (config.state) {
    try {
      Y.applyUpdate(doc.doc, base64ToBytes(config.state), LOAD_ORIGIN)
    } catch (error) {
      host.log(
        'error',
        `saved state did not apply: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  }
  const saver = createSaver({
    doc: doc.doc,
    save: (state, title) => host.save(state, title),
    title: () => doc.title(),
    ignoreOrigins: [LOAD_ORIGIN],
  })
  // A brand-new easel gets its title and createdAt from native (one save).
  doc.ensureMeta({
    title: config.easel.title,
    createdAt: config.easel.createdAt,
  })
  // Renamed from its sidebar row while the board was closed.
  if (config.easel.renamed) doc.setTitle(config.easel.title)
  const awareness = createAwareness(doc.doc, config.viewer)
  const unwire = wireFlush(saver, fn => host.onFlush(fn))
  // Sidebar rename: the title lands in `meta` (so document.title follows)
  // and the saver picks the change up like any edit.
  const offRename = host.onRename(title => doc.setTitle(title))
  return {
    host,
    config,
    doc,
    awareness,
    saver,
    close() {
      saver.flush()
      unwire()
      offRename()
      saver.dispose()
      awareness.destroy()
      doc.destroy()
    },
  }
}
