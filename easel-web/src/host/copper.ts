/**
 * The real host: `webkit.messageHandlers.easel.postMessage(msg)` out,
 * `window.__easelHost.receive(msg)` in. `receive` accepts the object itself
 * or its JSON text, whichever native finds easier to evaluate.
 */
import type {
  EaselConfig,
  Host,
  HostMessage,
  LogLevel,
  PageMessage,
  UploadedFile,
} from './types'
import { MAX_FILE_BYTES } from './types'
import { blobToBase64 } from './base64'

interface EaselMessageHandler {
  postMessage(message: PageMessage): void
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: { easel?: EaselMessageHandler }
    }
    __easelHost?: { receive(message: HostMessage | string): void }
  }
}

/** The bridge, when this page is inside Copper. */
export function easelHandler(): EaselMessageHandler | null {
  if (typeof window === 'undefined') return null
  return window.webkit?.messageHandlers?.easel ?? null
}

export const hasCopperBridge = () => easelHandler() !== null

type Pending = { resolve: (f: UploadedFile) => void; reject: (e: Error) => void }

export function createCopperHost(
  handler: EaselMessageHandler = easelHandler()!
): Host {
  let configResolve: ((c: EaselConfig) => void) | null = null
  let config: EaselConfig | null = null
  let readyPromise: Promise<EaselConfig> | null = null
  const uploads = new Map<string, Pending>()
  const flushers = new Set<() => void>()

  const post = (message: PageMessage) => handler.postMessage(message)

  const receive = (raw: HostMessage | string) => {
    const message: HostMessage =
      typeof raw === 'string' ? (JSON.parse(raw) as HostMessage) : raw
    switch (message.type) {
      case 'config': {
        const { v: _v, type: _t, ...rest } = message
        config = rest
        configResolve?.(config)
        configResolve = null
        return
      }
      case 'file:done': {
        const pending = uploads.get(message.reqId)
        uploads.delete(message.reqId)
        pending?.resolve({ fileId: message.fileId, url: message.url })
        return
      }
      case 'file:error': {
        const pending = uploads.get(message.reqId)
        uploads.delete(message.reqId)
        pending?.reject(new Error(message.message))
        return
      }
      case 'flush':
        for (const fn of flushers) fn()
        return
    }
  }

  // Defined before `ready` is sent, as the contract requires.
  window.__easelHost = { receive }

  return {
    mode: 'copper',
    ready() {
      if (config) return Promise.resolve(config)
      // One `ready` on the wire however many times this is asked.
      readyPromise ??= new Promise<EaselConfig>(resolve => {
        configResolve = resolve
        post({ v: 1, type: 'ready' })
      })
      return readyPromise
    },
    save(state, title) {
      post({ v: 1, type: 'save', state, title })
    },
    async uploadFile(file) {
      if (file.size > MAX_FILE_BYTES)
        throw new Error('That picture is over 15 MB.')
      const data = await blobToBase64(file)
      const reqId = crypto.randomUUID()
      return new Promise<UploadedFile>((resolve, reject) => {
        uploads.set(reqId, { resolve, reject })
        post({
          v: 1,
          type: 'file',
          reqId,
          name: file.name || 'image',
          mime: file.type,
          data,
        })
      })
    },
    open(url, background) {
      if (!/^https?:/i.test(url)) return
      post(
        background === undefined
          ? { v: 1, type: 'open', url }
          : { v: 1, type: 'open', url, background }
      )
    },
    log(level: LogLevel, message: string) {
      post({ v: 1, type: 'log', level, message })
    },
    onFlush(fn) {
      flushers.add(fn)
      return () => flushers.delete(fn)
    },
    fileUrl(easelId, fileId) {
      return `copper-easel://easel/files/${encodeURIComponent(easelId)}/${encodeURIComponent(fileId)}`
    },
  }
}
