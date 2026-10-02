/**
 * Page → host messages. In Copper the page runs in a WKWebView and posts JSON
 * strings to `window.webkit.messageHandlers.canvas`. Anywhere else (a normal
 * browser, tests) messages go to `window.__copperHost`, a test double that
 * records them and can forward them to a callback.
 */
export interface HostPresencePerson {
  id: string
  name: string
  color: string
  kind: 'human' | 'agent'
}

export type PageMessage =
  | { type: 'ready'; version: string }
  | { type: 'update'; b64: string }
  | { type: 'selection'; ids: string[] }
  | { type: 'share' }
  | { type: 'presence'; people: readonly HostPresencePerson[] }
  | { type: 'ws'; b64: string }
  | { type: 'wsOpen'; url: string }
  | { type: 'wsClose' }
  | { type: 'openUrl'; url: string }
  | { type: 'log'; level: 'debug' | 'info' | 'warn' | 'error'; msg: string }

export interface HostDouble {
  /** Every message posted, oldest first (capped). */
  messages: PageMessage[]
  /** Called for each message with the object and its JSON framing. */
  onMessage?: (msg: PageMessage, json: string) => void
}

interface WebkitHandler {
  postMessage(body: string): void
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { canvas?: WebkitHandler } }
    __copperHost?: HostDouble
  }
}

const MAX_RECORDED = 2000

/** The native handler, when the page runs inside Copper. */
export function nativeHandler(): WebkitHandler | null {
  if (typeof window === 'undefined') return null
  return window.webkit?.messageHandlers?.canvas ?? null
}

export const hasNativeHost = () => nativeHandler() !== null

/** The recording double used outside Copper; created on first use. */
export function hostDouble(): HostDouble {
  if (typeof window === 'undefined') return { messages: [] }
  if (!window.__copperHost) window.__copperHost = { messages: [] }
  if (!Array.isArray(window.__copperHost.messages)) window.__copperHost.messages = []
  return window.__copperHost
}

/** The exact framing the host receives: one JSON string per message. */
export const frame = (msg: PageMessage) => JSON.stringify(msg)

/** Post one message to the host. Never throws: a broken bridge only logs. */
export function postToHost(msg: PageMessage): void {
  const json = frame(msg)
  try {
    const handler = nativeHandler()
    if (handler) {
      handler.postMessage(json)
      return
    }
    const double = hostDouble()
    double.messages.push(msg)
    if (double.messages.length > MAX_RECORDED) double.messages.splice(0, double.messages.length - MAX_RECORDED)
    double.onMessage?.(msg, json)
  } catch (error) {
    console.error('canvas bridge: post failed', error)
  }
}

/** A log line for the host's console (and the browser's, outside Copper). */
export function hostLog(level: 'debug' | 'info' | 'warn' | 'error', msg: string) {
  if (!hasNativeHost()) {
    const fn = level === 'error' ? console.error : level === 'warn' ? console.warn : console.debug
    fn(`[canvas] ${msg}`)
  }
  postToHost({ type: 'log', level, msg: msg.slice(0, 4000) })
}
