/**
 * A WebSocket stand-in for y-websocket's `WebsocketProvider` (its
 * `WebSocketPolyfill` option). The page never opens a socket: the host does,
 * pinned and authenticated, and relays frames over the bridge.
 *
 * - `new BridgeSocket(url)` asks the host to connect: `{type:'wsOpen', url}`.
 * - `send(data)` posts `{type:'ws', b64}`.
 * - `close()` posts `{type:'wsClose'}` and closes at once.
 * - Host → page: `copperCanvas.wsState('open'|'closed')` fires onopen/onclose,
 *   `copperCanvas.wsMessage(b64)` fires onmessage with an ArrayBuffer.
 *
 * Only the newest socket is live; frames for an older one are dropped.
 */
import { fromBase64, toBase64 } from './canvas/base64'
import { postToHost, type PageMessage } from './host-bridge'

type Handler<E> = ((event: E) => void) | null

export interface BridgeMessageEvent {
  data: ArrayBuffer | string
  type: 'message'
}
export interface BridgeCloseEvent {
  code: number
  reason: string
  wasClean: boolean
  type: 'close'
}

let poster: (msg: PageMessage) => void = postToHost

/** Tests: route the socket's messages somewhere else. */
export function setBridgePoster(fn: ((msg: PageMessage) => void) | null) {
  poster = fn ?? postToHost
}

export class BridgeSocket {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSING = 2
  static readonly CLOSED = 3
  readonly CONNECTING = 0
  readonly OPEN = 1
  readonly CLOSING = 2
  readonly CLOSED = 3

  /** The socket the host's frames belong to. */
  static current: BridgeSocket | null = null

  readonly url: string
  readonly protocol = ''
  readonly extensions = ''
  readonly bufferedAmount = 0
  binaryType: 'arraybuffer' | 'blob' = 'arraybuffer'
  readyState: number = BridgeSocket.CONNECTING

  onopen: Handler<{ type: 'open' }> = null
  onmessage: Handler<BridgeMessageEvent> = null
  onclose: Handler<BridgeCloseEvent> = null
  onerror: Handler<{ type: 'error'; message?: string }> = null

  private listeners = new Map<string, Set<(event: never) => void>>()

  constructor(url: string | URL, _protocols?: string | string[]) {
    void _protocols
    this.url = String(url)
    const previous = BridgeSocket.current
    BridgeSocket.current = this
    if (previous && previous.readyState < BridgeSocket.CLOSING) previous.dropSilently()
    poster({ type: 'wsOpen', url: this.url })
  }

  send(data: ArrayBuffer | ArrayBufferView | string): void {
    if (this.readyState === BridgeSocket.CONNECTING) throw new Error('InvalidStateError: socket is still connecting')
    if (this.readyState !== BridgeSocket.OPEN) return
    let bytes: Uint8Array
    if (typeof data === 'string') bytes = new TextEncoder().encode(data)
    else if (data instanceof ArrayBuffer) bytes = new Uint8Array(data)
    else bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
    poster({ type: 'ws', b64: toBase64(bytes) })
  }

  close(code = 1000, reason = ''): void {
    if (this.readyState >= BridgeSocket.CLOSING) return
    this.readyState = BridgeSocket.CLOSING
    if (BridgeSocket.current === this) {
      BridgeSocket.current = null
      poster({ type: 'wsClose' })
    }
    this.readyState = BridgeSocket.CLOSED
    this.dispatch('close', { type: 'close', code, reason, wasClean: true })
  }

  /** Host: the real socket is open. */
  hostOpened(): void {
    if (this.readyState !== BridgeSocket.CONNECTING) return
    this.readyState = BridgeSocket.OPEN
    this.dispatch('open', { type: 'open' })
  }

  /** Host: the real socket closed (or never opened). */
  hostClosed(code = 1006, reason = ''): void {
    if (this.readyState === BridgeSocket.CLOSED) return
    this.readyState = BridgeSocket.CLOSED
    if (BridgeSocket.current === this) BridgeSocket.current = null
    this.dispatch('close', { type: 'close', code, reason, wasClean: false })
  }

  /** Host: one binary frame from the server. */
  hostMessage(bytes: Uint8Array): void {
    // A frame before 'open' means the host forgot to say so: it is open.
    if (this.readyState === BridgeSocket.CONNECTING) this.hostOpened()
    if (this.readyState !== BridgeSocket.OPEN) return
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
    this.dispatch('message', { type: 'message', data: buffer })
  }

  /** A newer socket replaced this one: close without telling the host. */
  private dropSilently(): void {
    this.readyState = BridgeSocket.CLOSED
    this.dispatch('close', { type: 'close', code: 1000, reason: 'replaced', wasClean: true })
  }

  addEventListener(type: string, fn: (event: never) => void): void {
    let set = this.listeners.get(type)
    if (!set) this.listeners.set(type, (set = new Set()))
    set.add(fn)
  }

  removeEventListener(type: string, fn: (event: never) => void): void {
    this.listeners.get(type)?.delete(fn)
  }

  private dispatch(type: 'open' | 'message' | 'close' | 'error', event: unknown): void {
    const prop = (this as unknown as Record<string, unknown>)[`on${type}`]
    try {
      if (typeof prop === 'function') (prop as (e: unknown) => void).call(this, event)
      for (const fn of this.listeners.get(type) ?? []) (fn as (e: unknown) => void)(event)
    } catch (error) {
      console.error(`canvas bridge socket: ${type} handler failed`, error)
    }
  }

  // ---- host entry points (window.copperCanvas.wsMessage / wsState) ----------

  static deliver(b64: string): boolean {
    const socket = BridgeSocket.current
    if (!socket) return false
    socket.hostMessage(fromBase64(b64))
    return true
  }

  static setState(state: string): boolean {
    const socket = BridgeSocket.current
    if (!socket) return false
    if (state === 'open') socket.hostOpened()
    else socket.hostClosed()
    return true
  }
}
