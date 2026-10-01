/**
 * Presence. Local mode still runs a `y-protocols/awareness` instance so P4
 * only adds a provider. Local state (the contract):
 *
 *   { user: { id, name, color }, cursor: { x, y } | null, laser: LaserWire | null }
 *
 * `usePeers` reads the other clients' cursors (empty with no provider);
 * `useRemoteLasers` feeds their laser wires into the trails.
 */
import { useEffect, useState } from 'react'
import type * as Y from 'yjs'
import { Awareness } from 'y-protocols/awareness'
import type { Point } from './canvas-geometry'
import type { LaserTrails, LaserWire } from '../laser'
import type { Viewer } from '../host/types'

export interface PresenceState {
  user: Viewer
  cursor: Point | null
  laser: LaserWire | null
}

export function createAwareness(doc: Y.Doc, user: Viewer): Awareness {
  const awareness = new Awareness(doc)
  const initial: PresenceState = { user, cursor: null, laser: null }
  awareness.setLocalState(initial)
  return awareness
}

export interface Peer {
  id: number
  name: string
  color: string
  cursor: Point
}

const isPoint = (v: unknown): v is Point =>
  !!v &&
  typeof v === 'object' &&
  Number.isFinite((v as Point).x) &&
  Number.isFinite((v as Point).y)

/** Other people's cursors, from awareness; never the local client. */
export function readPeers(awareness: Awareness): Peer[] {
  const out: Peer[] = []
  for (const [id, raw] of awareness.getStates()) {
    if (id === awareness.clientID) continue
    const state = raw as Partial<PresenceState> | null
    if (!state || !isPoint(state.cursor)) continue
    out.push({
      id,
      name: state.user?.name ?? 'Someone',
      color: state.user?.color ?? '#8a8580',
      cursor: state.cursor,
    })
  }
  return out
}

export interface AwarenessChanges {
  added: number[]
  updated: number[]
  removed: number[]
}

/**
 * Whether a `change` event involves anyone but `self`. y-protocols fires
 * `change` for the local client too, so every local cursor move (30 Hz) and
 * laser publish would otherwise re-render whoever listens.
 */
export function involvesOthers(changes: AwarenessChanges, self: number): boolean {
  for (const ids of [changes.added, changes.updated, changes.removed])
    for (const id of ids) if (id !== self) return true
  return false
}

/** Same peers in the same order at the same spots. */
export function samePeers(a: readonly Peer[], b: readonly Peer[]): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) {
    const p = a[i]!
    const q = b[i]!
    if (
      p.id !== q.id ||
      p.name !== q.name ||
      p.color !== q.color ||
      p.cursor.x !== q.cursor.x ||
      p.cursor.y !== q.cursor.y
    )
      return false
  }
  return true
}

/**
 * Other people's cursors. Ignores changes that only involve the local
 * client, and keeps the previous array when nothing visible changed, so
 * neither causes a render.
 */
export function usePeers(awareness: Awareness): Peer[] {
  const [peers, setPeers] = useState<Peer[]>(() => readPeers(awareness))
  useEffect(() => {
    const update = (changes?: AwarenessChanges) => {
      if (changes && !involvesOthers(changes, awareness.clientID)) return
      setPeers(prev => {
        const next = readPeers(awareness)
        return samePeers(prev, next) ? prev : next
      })
    }
    awareness.on('change', update)
    update()
    return () => {
      awareness.off('change', update)
    }
  }, [awareness])
  return peers
}

/** Mirror every remote client's `laser` into the trails; null clears it. */
export function useRemoteLasers(awareness: Awareness, trails: LaserTrails) {
  useEffect(() => {
    const onChange = ({
      added,
      updated,
      removed,
    }: {
      added: number[]
      updated: number[]
      removed: number[]
    }) => {
      const states = awareness.getStates()
      for (const id of [...added, ...updated]) {
        if (id === awareness.clientID) continue
        const state = states.get(id) as Partial<PresenceState> | undefined
        trails.setRemote(id, state?.laser ?? null)
      }
      for (const id of removed) trails.setRemote(id, null)
    }
    awareness.on('change', onChange)
    return () => {
      awareness.off('change', onChange)
    }
  }, [awareness, trails])
}
