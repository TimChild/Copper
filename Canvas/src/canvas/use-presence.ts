/** React views of who else is here: people (awareness) and agents (the `agents` map). */
import { useEffect, useMemo, useState, useSyncExternalStore } from 'react'
import type { Awareness } from 'y-protocols/awareness'
import type * as Y from 'yjs'
import { liveAgents, readAgents } from './agents'
import { colorFor } from './colors'
import type { CanvasAgent } from './types'
import type { PeerView } from './components/Overlays'

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** Peers' awareness states (never our own), read tolerantly. */
export function readPeers(awareness: Awareness): PeerView[] {
  const out: PeerView[] = []
  awareness.getStates().forEach((state, clientId) => {
    if (clientId === awareness.clientID || !state) return
    const s = state as Record<string, unknown>
    const user = (s.user && typeof s.user === 'object' ? s.user : s) as Record<string, unknown>
    const name = typeof user.name === 'string' && user.name ? user.name : 'Someone'
    const id = typeof user.id === 'string' && user.id ? user.id : `client:${clientId}`
    const color = typeof user.color === 'string' && user.color ? user.color : colorFor(id)
    const c = s.cursor as Record<string, unknown> | null | undefined
    const cursor = c && finite(c.x) && finite(c.y) ? { x: c.x, y: c.y } : null
    const selection = Array.isArray(s.selection) ? s.selection.filter((x): x is string => typeof x === 'string') : []
    out.push({ clientId, id, name, color, cursor, selection })
  })
  return out.sort((a, b) => a.name.localeCompare(b.name) || a.clientId - b.clientId)
}

export function usePeers(awareness: Awareness): PeerView[] {
  const [peers, setPeers] = useState<PeerView[]>(() => readPeers(awareness))
  useEffect(() => {
    let frame = 0
    const onChange = () => {
      if (frame) return
      frame = requestAnimationFrame(() => {
        frame = 0
        setPeers(readPeers(awareness))
      })
    }
    awareness.on('change', onChange)
    onChange()
    return () => {
      awareness.off('change', onChange)
      cancelAnimationFrame(frame)
    }
  }, [awareness])
  return peers
}

/** How often presence is re-checked for expiry when the doc is quiet. */
const EXPIRY_TICK_MS = 10_000

/** External store over the `agents` map, for useSyncExternalStore. */
class AgentsStore {
  private snapshot: CanvasAgent[]
  private listeners = new Set<() => void>()
  private readonly map: Y.Map<unknown>
  constructor(map: Y.Map<unknown>) {
    this.map = map
    this.snapshot = readAgents(map)
  }
  private onChange = () => {
    this.snapshot = readAgents(this.map)
    for (const fn of this.listeners) fn()
  }
  subscribe = (fn: () => void) => {
    if (this.listeners.size === 0) this.map.observeDeep(this.onChange)
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
      if (this.listeners.size === 0) this.map.unobserveDeep(this.onChange)
    }
  }
  get = () => this.snapshot
}

export function useLiveAgents(map: Y.Map<unknown>): CanvasAgent[] {
  const store = useMemo(() => new AgentsStore(map), [map])
  const all = useSyncExternalStore(store.subscribe, store.get)
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), EXPIRY_TICK_MS)
    return () => clearInterval(timer)
  }, [])
  // A fresh write is always live: its updatedAt is ahead of the (stale) clock.
  return useMemo(() => liveAgents(all, now), [all, now])
}
