/**
 * Agents on the board. Whoever drives an agent (the host, a tool call, a
 * collaborator's agent through the sync server) writes one entry per agent
 * into the `agents` map and moves its cursor while it works. The writer
 * removes its lease; readers also hide expired leases after a disconnect.
 */
import * as Y from 'yjs'
import type { Point } from './geometry'
import { AGENT_STATUSES, type AgentPresence, type AgentStatus, type CanvasAgent } from './types'

/** How long an entry counts as present after its last write. */
export const AGENT_TTL_MS = 2000

const plain = (v: unknown): Record<string, unknown> | null => {
  if (v instanceof Y.Map) return v.toJSON() as Record<string, unknown>
  return v && typeof v === 'object' ? (v as Record<string, unknown>) : null
}

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** Epoch ms from a number (ms or seconds) or an ISO string. */
export function toEpochMs(v: unknown): number {
  if (finite(v)) return v < 1e12 ? v * 1000 : v
  if (typeof v === 'string') {
    const parsed = Date.parse(v)
    return Number.isFinite(parsed) ? parsed : 0
  }
  return 0
}

export const isStatus = (v: unknown): v is AgentStatus =>
  typeof v === 'string' && (AGENT_STATUSES as readonly string[]).includes(v)

/** Tolerant read of one `agents` entry; null when it isn't an agent at all. */
export function readAgent(id: string, value: unknown): CanvasAgent | null {
  const v = plain(value)
  if (!v) return null
  const c = plain(v.cursor)
  return {
    id,
    name: typeof v.name === 'string' && v.name.trim() ? v.name.trim() : 'Agent',
    color: typeof v.color === 'string' && v.color ? v.color : '',
    cursor: c && finite(c.x) && finite(c.y) ? { x: c.x, y: c.y } : null,
    status: isStatus(v.status) ? v.status : 'idle',
    updatedAt: toEpochMs(v.updatedAt),
  }
}

/** Every readable entry of the map. */
export function readAgents(map: Y.Map<unknown>): CanvasAgent[] {
  const out: CanvasAgent[] = []
  map.forEach((value, id) => {
    const agent = readAgent(id, value)
    if (agent) out.push(agent)
  })
  return out
}

/** Agents written to within `ttl` of `now`, busiest first, then by name. */
export function liveAgents(agents: Iterable<CanvasAgent>, now: number, ttl = AGENT_TTL_MS): CanvasAgent[] {
  const rank = (a: CanvasAgent) => (a.status === 'idle' ? 1 : 0)
  return [...agents]
    .filter(a => a.updatedAt > 0 && now - a.updatedAt <= ttl)
    .sort((a, b) => rank(a) - rank(b) || a.name.localeCompare(b.name) || (a.id < b.id ? -1 : 1))
}

export const isBusy = (status: AgentStatus) => status !== 'idle'

export interface AgentPatch {
  name?: string
  color?: string
  cursor?: Point | null
  status?: AgentStatus
}

/**
 * Merge a patch into an agent's entry (the value is replaced whole, as the
 * map's contract says). Returns what was written.
 */
export function writeAgent(map: Y.Map<unknown>, id: string, patch: AgentPatch, now = Date.now()): AgentPresence {
  const prev = readAgent(id, map.get(id))
  const cursor =
    patch.cursor === undefined
      ? (prev?.cursor ?? null)
      : patch.cursor && finite(patch.cursor.x) && finite(patch.cursor.y)
        ? { x: Math.round(patch.cursor.x), y: Math.round(patch.cursor.y) }
        : null
  const next: AgentPresence = {
    name: (patch.name?.trim() || prev?.name || 'Agent').slice(0, 60),
    color: (patch.color || prev?.color || '').slice(0, 32),
    cursor,
    status: patch.status && isStatus(patch.status) ? patch.status : (prev?.status ?? 'idle'),
    updatedAt: now,
  }
  map.set(id, next)
  return next
}
