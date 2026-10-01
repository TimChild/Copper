/**
 * The page's one controller: owns the current canvas session (Y.Doc, store,
 * awareness, sync provider), the selection, and what the board reports about
 * its viewport. The window API and the React board both talk to it.
 */
import * as Y from 'yjs'
import { Awareness } from 'y-protocols/awareness'
import { WebsocketProvider } from 'y-websocket'
import { BridgeSocket } from './bridge-socket'
import { fromBase64, toBase64 } from './canvas/base64'
import { CanvasStore, HOST, INIT, PRESENCE, bareId } from './canvas/doc'
import { writeAgent, isStatus, type AgentPatch } from './canvas/agents'
import { colorFor } from './canvas/colors'
import { visibleWorld, type Box, type Point, type View } from './canvas/geometry'
import { parseHostStatus, sameHostStatus, type HostStatus, type SyncStatus } from './canvas/status'
import type { Me } from './canvas/types'
import { hostLog, postToHost } from './host-bridge'
import { applyOps, readCanvas, type ApplyResult, type CanvasRead } from './ops'

export const VERSION = '1.0.0'

/** What the host passes to `copperCanvas.init`. */
export interface InitConfig {
  docId: string
  name: string
  kind: string
  me: Me
  state: string | null
  online: boolean
  readOnly: boolean
}

export type { HostStatus, SyncStatus }

/** How long an agent shows "writing" after its last op. */
export const WRITING_MS = 1500

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)

export function parseInit(raw: unknown): InitConfig {
  let v = raw
  if (typeof v === 'string') v = JSON.parse(v)
  if (!isObject(v)) throw new Error('init: expected {docId, name, kind, me, state, online, readOnly}')
  const docId = typeof v.docId === 'string' && v.docId ? v.docId : 'personal'
  const meRaw = isObject(v.me) ? v.me : {}
  const meId = typeof meRaw.id === 'string' && meRaw.id ? meRaw.id : 'me'
  const me: Me = {
    id: meId,
    name: typeof meRaw.name === 'string' && meRaw.name.trim() ? meRaw.name.trim() : 'You',
    color: typeof meRaw.color === 'string' && meRaw.color ? meRaw.color : colorFor(meId),
  }
  return {
    docId,
    name: typeof v.name === 'string' && v.name.trim() ? v.name.trim() : 'Canvas',
    kind: typeof v.kind === 'string' && v.kind ? v.kind : 'personal',
    me,
    state: typeof v.state === 'string' && v.state ? v.state : null,
    online: v.online === true,
    readOnly: v.readOnly === true,
  }
}

/** One open canvas. */
export class Session {
  private static opened = 0
  /** Distinct per init, so the board remounts for every new session. */
  readonly serial = ++Session.opened
  readonly cfg: InitConfig
  readonly doc: Y.Doc
  readonly store: CanvasStore
  readonly awareness: Awareness
  readonly provider: WebsocketProvider | null
  status: SyncStatus
  private onUpdate: (update: Uint8Array, origin: unknown) => void

  constructor(cfg: InitConfig, onStatus: () => void) {
    this.cfg = cfg
    this.doc = new Y.Doc()
    if (cfg.state) {
      try {
        Y.applyUpdate(this.doc, fromBase64(cfg.state), HOST)
      } catch (error) {
        hostLog('error', `init: the stored state did not apply (${String(error)}); starting empty`)
      }
    }
    this.store = new CanvasStore(this.doc)
    this.awareness = new Awareness(this.doc)
    this.awareness.setLocalState({
      user: { id: cfg.me.id, name: cfg.me.name, color: cfg.me.color },
      name: cfg.me.name,
      color: cfg.me.color,
      cursor: null,
      selection: [],
    })
    // Every local change goes to the host, which stores it (offline) and the
    // provider relays it (online). What the host or the server sent is theirs.
    this.onUpdate = (update, origin) => {
      if (origin === HOST || (this.provider && origin === this.provider)) return
      postToHost({ type: 'update', b64: toBase64(update) })
    }
    this.doc.on('update', this.onUpdate)
    this.status = cfg.online ? 'connecting' : 'local'
    this.provider = null
    if (cfg.online) {
      const provider = new WebsocketProvider('ws://bridge', cfg.docId, this.doc, {
        WebSocketPolyfill: BridgeSocket as unknown as typeof WebSocket,
        connect: false,
        awareness: this.awareness,
        disableBc: true,
        maxBackoffTime: 5000,
      })
      this.provider = provider
      provider.on('status', ({ status }: { status: string }) => {
        this.status = status === 'connected' ? (provider.synced ? 'online' : 'connecting') : status === 'connecting' ? 'connecting' : 'offline'
        onStatus()
      })
      provider.on('sync', (synced: boolean) => {
        if (synced) {
          this.status = 'online'
          this.ensureMeta()
        }
        onStatus()
      })
      provider.connect()
    } else this.ensureMeta()
  }

  /** A canvas made here gets its name and maker recorded once. */
  private ensureMeta() {
    if (this.cfg.readOnly || this.store.meta.get('name')) return
    this.doc.transact(() => {
      this.store.meta.set('name', this.cfg.name)
      if (!this.store.meta.get('createdBy')) this.store.meta.set('createdBy', this.cfg.me.name)
    }, INIT)
  }

  destroy() {
    try {
      this.awareness.setLocalState(null)
    } catch {
      // already gone
    }
    this.provider?.destroy()
    this.doc.off('update', this.onUpdate)
    this.awareness.destroy()
    this.store.destroy()
    this.doc.destroy()
  }
}

export interface ViewInfo {
  view: View
  width: number
  height: number
}

type Listener = () => void

/** What the board does for the controller (flights need its animation). */
export interface BoardHandle {
  zoomTo(ids: string[]): boolean
}

export class Controller {
  session: Session | null = null
  private listeners = new Set<Listener>()
  private selection: readonly string[] = []
  private selectionListeners = new Set<Listener>()
  private lastPostedSelection = '[]'
  viewInfo: ViewInfo = { view: { x: 640, y: 400, z: 1 }, width: 1280, height: 800 }
  board: BoardHandle | null = null
  private pendingZoom: string[] | null = null
  private agentTimers = new Map<string, ReturnType<typeof setTimeout>>()
  private version = 0
  /** What the host last said about the board's connection; outlives `init`. */
  private hostStatus: HostStatus | null = null

  subscribe = (fn: Listener) => {
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
    }
  }
  /** Bumps on init and on sync status changes. */
  getVersion = () => this.version
  private emit() {
    this.version++
    for (const fn of this.listeners) fn()
  }

  // ---- lifecycle ---------------------------------------------------------------

  init(raw: unknown): { ok: true; docId: string } {
    const cfg = parseInit(raw)
    for (const t of this.agentTimers.values()) clearTimeout(t)
    this.agentTimers.clear()
    this.session?.destroy()
    this.selection = []
    this.lastPostedSelection = '[]'
    this.session = new Session(cfg, () => this.emit())
    hostLog('info', `init ${cfg.docId} (${cfg.kind}${cfg.online ? ', online' : ''}${cfg.readOnly ? ', read-only' : ''})`)
    this.emit()
    for (const fn of this.selectionListeners) fn()
    return { ok: true, docId: cfg.docId }
  }

  private need(): Session {
    if (!this.session) throw new Error('copperCanvas.init has not been called')
    return this.session
  }

  applyUpdate(b64: string) {
    const s = this.need()
    Y.applyUpdate(s.doc, fromBase64(b64), HOST)
  }

  exportState(): string {
    const s = this.need()
    return toBase64(Y.encodeStateAsUpdate(s.doc))
  }

  // ---- host status --------------------------------------------------------------

  getHostStatus = () => this.hostStatus

  /**
   * `copperCanvas.setStatus`: idempotent; `null` clears it. Kept across
   * `init`, so it may come before or after one.
   */
  setHostStatus(raw: unknown): HostStatus | null {
    const next = parseHostStatus(raw)
    if (sameHostStatus(next, this.hostStatus)) return this.hostStatus
    this.hostStatus = next
    this.emit()
    return next
  }

  // ---- viewport ----------------------------------------------------------------

  setViewInfo(info: ViewInfo) {
    this.viewInfo = info
  }

  viewportCenter = (): Point => {
    const { view, width, height } = this.viewInfo
    return { x: (width / 2 - view.x) / view.z, y: (height / 2 - view.y) / view.z }
  }

  visibleBox(): (Box & { zoom: number }) | null {
    const { view, width, height } = this.viewInfo
    if (width <= 0 || height <= 0) return null
    return { ...visibleWorld(view, width, height), zoom: view.z }
  }

  attachBoard(board: BoardHandle | null) {
    this.board = board
    if (board && this.pendingZoom) {
      const ids = this.pendingZoom
      this.pendingZoom = null
      board.zoomTo(ids)
    }
  }

  zoomTo(ids: string[]): boolean {
    const list = ids.map(bareId)
    if (!this.board) {
      this.pendingZoom = list
      return false
    }
    return this.board.zoomTo(list)
  }

  // ---- selection ---------------------------------------------------------------

  getSelection = () => this.selection
  subscribeSelection = (fn: Listener) => {
    this.selectionListeners.add(fn)
    return () => {
      this.selectionListeners.delete(fn)
    }
  }

  /** Set the selection; `fromHost` skips telling the host what it just said. */
  setSelection(ids: readonly string[], fromHost = false) {
    const shapes = this.session?.store.getShapes()
    const next = [...new Set(ids.map(bareId))].filter(id => !shapes || shapes.has(id))
    const same = next.length === this.selection.length && next.every((id, i) => id === this.selection[i])
    if (!same) {
      this.selection = next
      for (const fn of this.selectionListeners) fn()
      this.session?.awareness.setLocalStateField('selection', next)
    }
    const json = JSON.stringify(next)
    if (fromHost) this.lastPostedSelection = json
    else if (json !== this.lastPostedSelection) {
      this.lastPostedSelection = json
      postToHost({ type: 'selection', ids: next })
    }
  }

  // ---- agents ------------------------------------------------------------------

  setAgent(raw: unknown) {
    const s = this.need()
    let v = raw
    if (typeof v === 'string') v = JSON.parse(v)
    if (!isObject(v) || typeof v.id !== 'string' || !v.id) throw new Error('setAgent: expected {id, name, color, cursor, status}')
    const id = v.id
    if (v.remove === true) {
      s.doc.transact(() => s.store.agents.delete(id), PRESENCE)
      return
    }
    const patch: AgentPatch = {}
    if (typeof v.name === 'string') patch.name = v.name
    if (typeof v.color === 'string') patch.color = v.color
    if (v.cursor === null) patch.cursor = null
    else if (isObject(v.cursor)) patch.cursor = v.cursor as unknown as Point
    if (isStatus(v.status)) patch.status = v.status
    s.doc.transact(() => writeAgent(s.store.agents, id, patch), PRESENCE)
  }

  private agentWrote(actor: { id: string; name: string; color?: string }, at: Point | null) {
    const s = this.session
    if (!s) return
    s.doc.transact(
      () =>
        writeAgent(s.store.agents, actor.id, {
          name: actor.name,
          color: actor.color || colorFor(actor.id),
          status: 'writing',
          ...(at ? { cursor: at } : {}),
        }),
      PRESENCE
    )
    clearTimeout(this.agentTimers.get(actor.id))
    const session = s
    this.agentTimers.set(
      actor.id,
      setTimeout(() => {
        this.agentTimers.delete(actor.id)
        if (this.session !== session) return
        const current = session.store.agents.get(actor.id) as { status?: string } | undefined
        if (current?.status !== 'writing') return
        session.doc.transact(() => writeAgent(session.store.agents, actor.id, { status: 'idle' }), PRESENCE)
      }, WRITING_MS)
    )
  }

  // ---- ops ---------------------------------------------------------------------

  apply(raw: unknown): ApplyResult {
    const s = this.session
    if (!s) return { applied: 0, ids: [], errors: [{ index: -1, op: '', error: 'copperCanvas.init has not been called' }] }
    s.store.undo.stopCapturing()
    const out = applyOps({ store: s.store, viewportCenter: this.viewportCenter, readOnly: s.cfg.readOnly }, raw)
    s.store.undo.stopCapturing()
    if (out.applied > 0 || out.actor) {
      const actor = out.actor ?? { id: 'agent', name: 'Agent' }
      if (out.applied > 0) this.agentWrote(actor, out.anchor)
    }
    // Drop anything that vanished from the selection.
    if (this.selection.length) this.setSelection(this.selection)
    return { applied: out.applied, ids: out.ids, errors: out.errors }
  }

  read(raw: unknown): CanvasRead {
    const s = this.need()
    const name = (s.store.meta.get('name') as string | undefined) || s.cfg.name
    return readCanvas(
      {
        store: s.store,
        canvas: { id: s.cfg.docId, name: s.cfg.name || name, kind: s.cfg.kind },
        viewport: this.visibleBox(),
        selection: this.selection,
      },
      raw
    )
  }
}

export const controller = new Controller()
