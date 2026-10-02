/** React views of who else is here: people (awareness) and agents (the `agents` map). */
import { useEffect, useMemo, useState, useSyncExternalStore } from 'react'
import type { Awareness } from 'y-protocols/awareness'
import type * as Y from 'yjs'
import { liveAgents, readAgents } from './agents'
import type { LaserTrails, LaserWire } from './laser'
import { readHumanPresence } from './presence'
import type { CanvasAgent } from './types'
import type { PeerView } from './components/Overlays'

/** Peers' awareness states (never our own), read tolerantly. */
export function readPeers(awareness: Awareness): PeerView[] {
  return readHumanPresence(awareness).map(({ clientId, id, name, color, cursor, selection }) => ({
    clientId: clientId!,
    id,
    name,
    color,
    cursor,
    selection,
  }))
}

export interface AwarenessChanges {
  added: number[]
  updated: number[]
  removed: number[]
}

/**
 * Whether a `change` involves anyone but `self`. y-protocols reports the
 * local client too, so our own cursor (30 Hz) and laser would otherwise
 * re-render the board while nobody else is here.
 */
export function involvesOthers(changes: AwarenessChanges | undefined, self: number): boolean {
  if (!changes) return true
  for (const ids of [changes.added, changes.updated, changes.removed]) for (const id of ids ?? []) if (id !== self) return true
  return false
}

/** Same people, same order, same cursors and selections: nothing to redraw. */
export function samePeers(a: readonly PeerView[], b: readonly PeerView[]): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) {
    const p = a[i]!
    const q = b[i]!
    if (p.clientId !== q.clientId || p.id !== q.id || p.name !== q.name || p.color !== q.color) return false
    if ((p.cursor?.x ?? null) !== (q.cursor?.x ?? null) || (p.cursor?.y ?? null) !== (q.cursor?.y ?? null)) return false
    if (p.selection.length !== q.selection.length || p.selection.some((id, j) => id !== q.selection[j])) return false
  }
  return true
}

export function usePeers(awareness: Awareness): PeerView[] {
  const [peers, setPeers] = useState<PeerView[]>(() => readPeers(awareness))
  useEffect(() => {
    let frame = 0
    let shown: PeerView[] = []
    const onChange = (changes?: AwarenessChanges) => {
      if (frame || !involvesOthers(changes, awareness.clientID)) return
      frame = requestAnimationFrame(() => {
        frame = 0
        const next = readPeers(awareness)
        // A peer's laser or a renewal changes awareness without moving anything we draw.
        if (samePeers(shown, next)) return
        shown = next
        setPeers(next)
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

/**
 * Mirror every other client's `laser` (a `LaserWire` in awareness) into the
 * trails, which draw them; null, or the client leaving, lets the stroke fade.
 */
export function syncRemoteLasers(awareness: Awareness, trails: LaserTrails, changes: AwarenessChanges) {
  const states = awareness.getStates()
  for (const id of [...changes.added, ...changes.updated]) {
    if (id === awareness.clientID) continue
    const state = states.get(id) as { laser?: LaserWire | null } | undefined
    trails.setRemote(id, state?.laser ?? null)
  }
  for (const id of changes.removed) if (id !== awareness.clientID) trails.setRemote(id, null)
}

export function useRemoteLasers(awareness: Awareness, trails: LaserTrails) {
  useEffect(() => {
    const onChange = (changes: AwarenessChanges) => syncRemoteLasers(awareness, trails, changes)
    // Someone may be pointing already.
    syncRemoteLasers(awareness, trails, { added: [...awareness.getStates().keys()], updated: [], removed: [] })
    awareness.on('change', onChange)
    return () => {
      awareness.off('change', onChange)
    }
  }, [awareness, trails])
}
