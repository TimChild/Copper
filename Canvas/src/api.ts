/**
 * `window.copperCanvas`: what the host calls (via evaluateJavaScript). Every
 * entry point takes either a JSON string or a plain value, never throws into
 * the host, and `apply`/`read` answer with a JSON string.
 */
import { BridgeSocket } from './bridge-socket'
import { VERSION, controller, type Controller } from './controller'
import { hostLog } from './host-bridge'
import { setTheme } from './theme'

export interface CopperCanvasApi {
  readonly version: string
  init(cfg: unknown): void
  applyUpdate(b64: string): void
  wsMessage(b64: string): void
  wsState(state: 'open' | 'closed' | string): void
  apply(opsJson: unknown): string
  read(optsJson?: unknown): string
  select(ids: unknown): void
  zoomTo(ids: unknown): void
  setAgent(agent: unknown): void
  theme(mode: 'light' | 'dark' | string): void
  exportState(): string
}

declare global {
  interface Window {
    copperCanvas?: CopperCanvasApi
  }
}

function idList(raw: unknown): string[] {
  let v = raw
  if (typeof v === 'string') {
    const t = v.trim()
    if (t.startsWith('[')) {
      try {
        v = JSON.parse(t)
      } catch {
        v = []
      }
    } else v = t ? [t] : []
  }
  if (!Array.isArray(v)) return []
  return v.filter((x): x is string => typeof x === 'string' && x.length > 0)
}

const guard =
  <A extends unknown[], R>(name: string, fn: (...args: A) => R, fallback: R) =>
  (...args: A): R => {
    try {
      return fn(...args)
    } catch (error) {
      hostLog('error', `${name}: ${error instanceof Error ? error.message : String(error)}`)
      return fallback
    }
  }

export function createApi(c: Controller = controller): CopperCanvasApi {
  return {
    version: VERSION,
    init: guard('init', (cfg: unknown) => void c.init(cfg), undefined),
    applyUpdate: guard('applyUpdate', (b64: string) => c.applyUpdate(b64), undefined),
    wsMessage: guard(
      'wsMessage',
      (b64: string) => {
        if (!BridgeSocket.deliver(b64)) hostLog('debug', 'wsMessage with no open socket: dropped')
      },
      undefined
    ),
    wsState: guard(
      'wsState',
      (state: string) => {
        if (!BridgeSocket.setState(state)) hostLog('debug', `wsState(${state}) with no socket: ignored`)
      },
      undefined
    ),
    apply: (opsJson: unknown) => {
      try {
        return JSON.stringify(c.apply(opsJson))
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error)
        hostLog('error', `apply: ${msg}`)
        return JSON.stringify({ applied: 0, ids: [], errors: [{ index: -1, op: '', error: msg }] })
      }
    },
    read: (optsJson?: unknown) => {
      try {
        return JSON.stringify(c.read(optsJson ?? {}))
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error)
        return JSON.stringify({ error: msg })
      }
    },
    select: guard('select', (ids: unknown) => c.setSelection(idList(ids), true), undefined),
    zoomTo: guard('zoomTo', (ids: unknown) => void c.zoomTo(idList(ids)), undefined),
    setAgent: guard('setAgent', (agent: unknown) => c.setAgent(agent), undefined),
    theme: guard('theme', (mode: string) => void setTheme(mode), undefined),
    exportState: guard('exportState', () => c.exportState(), ''),
  }
}

export function installApi(): CopperCanvasApi {
  const api = createApi()
  Object.defineProperty(window, 'copperCanvas', { value: api, configurable: true, writable: false, enumerable: true })
  return api
}
