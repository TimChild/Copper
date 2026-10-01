/**
 * An in-memory y-websocket-style server for development and tests: it plays
 * the part of the host's relayed socket plus the sync server behind it. It
 * answers `wsOpen` with `wsState('open')`, speaks the Yjs sync protocol over
 * `ws` frames, keeps one server doc, and echoes awareness (as the reference
 * server does, so a lone client never times out).
 */
import * as Y from 'yjs'
import * as decoding from 'lib0/decoding'
import * as encoding from 'lib0/encoding'
import * as syncProtocol from 'y-protocols/sync'
import { fromBase64, toBase64 } from './canvas/base64'
import type { PageMessage } from './host-bridge'

const MESSAGE_SYNC = 0
const MESSAGE_AWARENESS = 1

export interface RelayClient {
  /** Feed a page → host message (only ws traffic is looked at). */
  receive(msg: PageMessage): void
}

export interface RelayPage {
  wsMessage(b64: string): void
  wsState(state: 'open' | 'closed'): void
}

export class DevRelay {
  readonly doc = new Y.Doc()
  private clients = new Set<{ page: RelayPage; open: boolean }>()
  latency: number

  constructor(latency = 0) {
    this.latency = latency
    this.doc.on('update', (update: Uint8Array, origin: unknown) => {
      const encoder = encoding.createEncoder()
      encoding.writeVarUint(encoder, MESSAGE_SYNC)
      syncProtocol.writeUpdate(encoder, update)
      const frame = toBase64(encoding.toUint8Array(encoder))
      for (const c of this.clients) if (c.open && c !== origin) this.send(c, frame)
    })
  }

  private later(fn: () => void) {
    if (this.latency > 0) setTimeout(fn, this.latency)
    else queueMicrotask(fn)
  }

  private send(c: { page: RelayPage; open: boolean }, b64: string) {
    this.later(() => {
      if (c.open) c.page.wsMessage(b64)
    })
  }

  /** A page joins; returns the handler for its outgoing messages. */
  connect(page: RelayPage): RelayClient {
    const client = { page, open: false }
    this.clients.add(client)
    return {
      receive: (msg: PageMessage) => {
        if (msg.type === 'wsOpen') {
          this.later(() => {
            client.open = true
            page.wsState('open')
            const encoder = encoding.createEncoder()
            encoding.writeVarUint(encoder, MESSAGE_SYNC)
            syncProtocol.writeSyncStep1(encoder, this.doc)
            this.send(client, toBase64(encoding.toUint8Array(encoder)))
          })
        } else if (msg.type === 'wsClose') {
          client.open = false
        } else if (msg.type === 'ws') {
          const bytes = fromBase64(msg.b64)
          const decoder = decoding.createDecoder(bytes)
          const type = decoding.readVarUint(decoder)
          if (type === MESSAGE_SYNC) {
            const encoder = encoding.createEncoder()
            encoding.writeVarUint(encoder, MESSAGE_SYNC)
            syncProtocol.readSyncMessage(decoder, encoder, this.doc, client)
            if (encoding.length(encoder) > 1) this.send(client, toBase64(encoding.toUint8Array(encoder)))
          } else if (type === MESSAGE_AWARENESS) {
            for (const c of this.clients) if (c.open) this.send(c, msg.b64)
          }
        }
      },
    }
  }

  /** Drop every connection, as a network loss would. */
  dropAll() {
    for (const c of this.clients) {
      if (!c.open) continue
      c.open = false
      c.page.wsState('closed')
    }
  }
}
