import type { Awareness } from 'y-protocols/awareness'
import { colorFor } from './colors'
import { liveAgents, readAgents } from './agents'
import type { CanvasAgent } from './types'
import type { Point } from './geometry'

export type PresenceKind = 'human' | 'agent'

/** The page's read-only view of someone else in the room. */
export interface PresencePerson {
  id: string
  name: string
  color: string
  kind: PresenceKind
  cursor: Point | null
  selection: string[]
  /** Yjs awareness client id; absent for document-backed agents. */
  clientId?: number
}

export interface HostPresencePerson {
  id: string
  name: string
  color: string
  kind: PresenceKind
}

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** Read human presence from awareness, excluding this page's own client. */
export function readHumanPresence(awareness: Awareness): PresencePerson[] {
  const out: PresencePerson[] = []
  awareness.getStates().forEach((state, clientId) => {
    if (clientId === awareness.clientID || !state) return
    const s = state as Record<string, unknown>
    const user = (s.user && typeof s.user === 'object' ? s.user : s) as Record<string, unknown>
    const id = typeof user.id === 'string' && user.id ? user.id : `client:${clientId}`
    const name = typeof user.name === 'string' && user.name.trim() ? user.name.trim() : 'Someone'
    const color = typeof user.color === 'string' && user.color ? user.color : colorFor(id)
    const rawCursor = s.cursor as Record<string, unknown> | null | undefined
    const cursor = rawCursor && finite(rawCursor.x) && finite(rawCursor.y) ? { x: rawCursor.x, y: rawCursor.y } : null
    const selection = Array.isArray(s.selection) ? s.selection.filter((x): x is string => typeof x === 'string') : []
    out.push({ id, name, color, kind: 'human', cursor, selection, clientId })
  })
  const unique = new Map<string, PresencePerson>()
  for (const person of out) {
    const previous = unique.get(person.id)
    if (!previous || (person.cursor && !previous.cursor)) unique.set(person.id, person)
  }
  return [...unique.values()].sort((a, b) => a.name.localeCompare(b.name) || (a.clientId ?? 0) - (b.clientId ?? 0))
}

/** Merge awareness humans with live document-backed agents in a stable order. */
export function mergePresence(humans: readonly PresencePerson[], agents: readonly CanvasAgent[]): PresencePerson[] {
  const people = humans.map(person => ({ ...person, selection: [...person.selection] }))
  for (const agent of agents) {
    people.push({
      id: agent.id,
      name: agent.name,
      color: agent.color || colorFor(agent.id),
      kind: 'agent',
      cursor: agent.cursor,
      selection: [],
    })
  }
  return people
}

/** Current room presence for the host/evaluate API. */
export function readPresence(awareness: Awareness, agentsMap: Parameters<typeof readAgents>[0], now = Date.now()): PresencePerson[] {
  return mergePresence(readHumanPresence(awareness), liveAgents(readAgents(agentsMap), now))
}

/** Strip cursors and selections for the page → host presence message. */
export function hostPresence(people: readonly PresencePerson[]): HostPresencePerson[] {
  return people.map(({ id, name, color, kind }) => ({ id, name, color, kind }))
}

export function presenceSignature(people: readonly HostPresencePerson[]): string {
  return people.map(person => `${person.kind}\u0000${person.id}\u0000${person.name}\u0000${person.color}`).join('\u0001')
}

/**
 * Debounced, diffed host presence reporter. Cursor-only changes do not emit;
 * a stable empty list is still sent once so the host can clear stale faces.
 */
export function createPresenceReporter(post: (people: HostPresencePerson[]) => void, delay = 400) {
  let lastKey: string | null = null
  let pendingKey: string | null = null
  let pending: HostPresencePerson[] | null = null
  let timer: ReturnType<typeof setTimeout> | null = null

  const clearTimer = () => {
    if (timer !== null) clearTimeout(timer)
    timer = null
  }

  const update = (people: readonly HostPresencePerson[]) => {
    const next = people.map(person => ({ ...person }))
    const key = presenceSignature(next)
    if (key === lastKey) {
      pending = null
      pendingKey = null
      clearTimer()
      return
    }
    if (key === pendingKey) return
    pending = next
    pendingKey = key
    clearTimer()
    timer = setTimeout(() => {
      timer = null
      if (!pending || pendingKey === null) return
      lastKey = pendingKey
      const sent = pending
      pending = null
      pendingKey = null
      post(sent)
    }, Math.max(0, delay))
  }

  const flush = () => {
    if (!pending || pendingKey === null) return
    clearTimer()
    lastKey = pendingKey
    const sent = pending
    pending = null
    pendingKey = null
    post(sent)
  }

  const dispose = () => {
    clearTimer()
    pending = null
    pendingKey = null
  }

  return { update, flush, dispose }
}

/** Facepile ordering and overflow are shared by the chrome and its tests. */
export function facepilePeople(people: readonly PresencePerson[], limit = 4): { shown: PresencePerson[]; overflow: number } {
  const shown = people.slice(0, Math.max(0, limit)).map(person => ({ ...person, selection: [...person.selection] }))
  return { shown, overflow: Math.max(0, people.length - shown.length) }
}
