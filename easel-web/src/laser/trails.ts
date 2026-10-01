/**
 * LaserTrails: the laser's state, with no DOM. One local stroke (driven by the pointer) plus one
 * stroke per remote awareness client, and the strokes that were replaced but are still fading.
 *
 * Timing, per point (all ms, `now` on the local clock):
 *  - drawing: a point is solid until it is `tailMs` old, then fades out over `fadeMs`, so a long
 *    drag does not pile up;
 *  - released at E: the tail fade freezes at E, the whole stroke holds until E + holdMs, then
 *    fades over `fadeMs`. The tail starts first and the head's fade lags by FADE_STAGGER, so the
 *    stroke drains toward its head; everything is gone at E + holdMs + fadeMs and pruned then.
 *
 * Remote clocks differ from ours, so a remote wire is re-anchored when it arrives: its newest
 * moment (last point, or `end` if later) is "now" here and everything else keeps its offset from
 * that. The offset is fixed per wire id (only ever lowered, if a later copy arrives faster), so a
 * re-sent unchanged wire never slides forward in time and never keeps a stroke alive.
 */
import {
  DEFAULT_LASER_COLOR,
  DEFAULT_TIMING,
  MAX_LOCAL_POINTS,
  MIN_STEP_PX,
  type LaserOptions,
  type LaserStroke,
  type LaserTiming,
  type LaserWire,
} from './types'
import { decodeWireInto, encodeWire, isLaserWire, wireNewest } from './wire'

/** How far (as a share of fadeMs) the head's final fade lags the tail's. */
export const FADE_STAGGER = 0.4

/** Retired strokes kept fading at once; older ones are dropped beyond this. */
const MAX_FADING = 32

type LocalStroke = LaserStroke & { base: number }

type Remote = {
  wireId: string
  /** local = remote + offset */
  offset: number
  /** null once faded and pruned; the id is remembered so a re-sent copy is not resurrected. */
  stroke: LaserStroke | null
  /** the client's laser went null (or the client left); drop the entry once its stroke is gone */
  departed: boolean
}

let seq = 0
const newId = (): string =>
  (++seq).toString(36) + Math.random().toString(36).slice(2, 8)

const ms = (v: number | undefined, fallback: number): number =>
  typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : fallback

/** When a stroke is fully faded (Infinity while it is still being drawn). */
export function goneAt(s: LaserStroke, t: LaserTiming): number {
  return s.endedAt === null ? Infinity : s.endedAt + t.holdMs + t.fadeMs
}

/**
 * Fill `out[i]` with the life (1 = solid, 0 = gone) of each point of `s` at `now` and return the
 * index of the first point with life > 0 (`points.length` if none). Life never decreases from
 * tail to head, so the visible part of a stroke is always one suffix.
 */
export function fillLife(
  s: LaserStroke,
  now: number,
  t: LaserTiming,
  out: { [i: number]: number }
): number {
  const pts = s.points
  const n = pts.length
  if (n === 0) return 0
  const ended = s.endedAt
  const clock = ended === null ? now : Math.min(now, ended)
  const tail = t.tailMs
  const fade = t.fadeMs
  const t0 = pts[0]!.t
  const span = pts[n - 1]!.t - t0
  const since = ended === null ? 0 : now - ended - t.holdMs
  const lag = FADE_STAGGER * fade
  const dur = fade - lag
  let first = n
  for (let i = n - 1; i >= 0; i--) {
    const p = pts[i]!
    const age = clock - p.t
    let life = age <= tail ? 1 : fade > 0 ? 1 - (age - tail) / fade : 0
    if (since > 0 && life > 0) {
      const u = span > 0 ? (p.t - t0) / span : 1
      const f = dur > 0 ? (since - u * lag) / dur : since >= u * lag ? 1 : 0
      if (f > 0) life *= f >= 1 ? 0 : 1 - f
    }
    if (life <= 0) life = 0
    else first = i
    out[i] = life
  }
  return first
}

/** Life of one point; see `fillLife`. */
export function pointLife(s: LaserStroke, i: number, now: number, t: LaserTiming): number {
  const out: number[] = []
  fillLife(s, now, t, out)
  return out[i] ?? 0
}

export class LaserTrails {
  readonly holdMs: number
  readonly fadeMs: number
  readonly tailMs: number

  private local: LocalStroke | null = null
  private remotes = new Map<string, Remote>()
  private fading: LaserStroke[] = []
  private listeners = new Set<() => void>()
  private minStep = MIN_STEP_PX
  private list: LaserStroke[] = []
  private listDirty = true
  private version = 0
  private wire: LaserWire | null = null
  private wireVersion = -1

  constructor(opts?: LaserOptions) {
    this.holdMs = ms(opts?.holdMs, DEFAULT_TIMING.holdMs)
    this.fadeMs = ms(opts?.fadeMs, DEFAULT_TIMING.fadeMs)
    this.tailMs = ms(opts?.tailMs, DEFAULT_TIMING.tailMs)
  }

  /** Start the local stroke at `p` (canvas coords). A previous local stroke keeps fading. */
  begin(p: { x: number; y: number }, color: string, now = Date.now()): string {
    if (this.local) this.retire(this.local, now)
    const id = newId()
    this.local = {
      id,
      color: color || DEFAULT_LASER_COLOR,
      points: [{ x: p.x, y: p.y, t: now }],
      endedAt: null,
      base: 0,
    }
    this.localChanged(true)
    return id
  }

  /** Extend the local stroke. Moves closer than ~1.5 screen px to the last sample are ignored. */
  move(p: { x: number; y: number }, now = Date.now()): void {
    const s = this.local
    if (!s || s.endedAt !== null) return
    const pts = s.points
    const last = pts[pts.length - 1]!
    const dx = p.x - last.x
    const dy = p.y - last.y
    if (dx * dx + dy * dy < this.minStep * this.minStep) return
    pts.push({ x: p.x, y: p.y, t: Math.max(now, last.t) })
    if (pts.length > MAX_LOCAL_POINTS) {
      const drop = pts.length - MAX_LOCAL_POINTS
      pts.splice(0, drop)
      s.base += drop
    }
    this.localChanged(false)
  }

  /** Release the local stroke: it holds, then fades. */
  end(now = Date.now()): void {
    const s = this.local
    if (!s || s.endedAt !== null) return
    s.endedAt = Math.max(now, s.points[s.points.length - 1]!.t)
    this.localChanged(false)
  }

  /** Drop the local stroke at once (peers still let their copy fade). */
  cancel(): void {
    if (!this.local) return
    this.local = null
    this.localChanged(true)
  }

  /**
   * The local stroke for awareness, or null when there is none (or it has fully faded by `now`).
   * The same object is returned until the stroke changes, so callers can compare by identity.
   */
  localWire(now = Date.now()): LaserWire | null {
    const s = this.local
    if (!s || now >= goneAt(s, this)) return null
    if (this.wireVersion !== this.version) {
      this.wire = encodeWire(s, s.base)
      this.wireVersion = this.version
    }
    return this.wire
  }

  /**
   * Set (or clear) a remote client's stroke from its awareness state. A new wire id replaces the
   * client's stroke (the old one keeps fading on its own schedule); the same id updates it; null
   * lets the current one finish (an unfinished stroke is treated as released now).
   */
  setRemote(clientId: string | number, wire: LaserWire | null, now = Date.now()): void {
    const key = String(clientId)
    const e = this.remotes.get(key)
    if (wire == null) {
      if (!e || e.departed) return
      e.departed = true
      const s = e.stroke
      if (s && s.endedAt === null) {
        const last = s.points[s.points.length - 1]
        s.endedAt = Math.max(now, last ? last.t : now)
      }
      if (!s) {
        this.remotes.delete(key)
        this.listDirty = true
      }
      this.notify()
      return
    }
    if (!isLaserWire(wire)) return
    const sample = now - wireNewest(wire)
    if (e && e.wireId === wire.id) {
      e.departed = false
      if (!e.stroke) return // already faded here: never bring it back
      if (sample < e.offset) e.offset = sample
      decodeWireInto(e.stroke, wire, e.offset)
      this.notify()
      return
    }
    if (e?.stroke) this.retire(e.stroke, now)
    const stroke: LaserStroke = { id: wire.id, color: DEFAULT_LASER_COLOR, points: [], endedAt: null }
    decodeWireInto(stroke, wire, sample)
    if (stroke.points.length === 0) {
      if (e) this.remotes.delete(key)
    } else {
      this.remotes.set(key, { wireId: wire.id, offset: sample, stroke, departed: false })
    }
    this.listDirty = true
    this.notify()
  }

  /** Drop what has fully faded by `now` (and dead tail points of strokes still being drawn). */
  prune(now = Date.now()): void {
    let changed = false
    const local = this.local
    if (local) {
      if (now >= goneAt(local, this)) {
        this.local = null
        this.listDirty = true
        this.version++
        changed = true
      } else if (local.endedAt === null) {
        const drop = this.deadTail(local, now)
        if (drop > 0) {
          local.points.splice(0, drop)
          local.base += drop
          this.version++
          changed = true
        }
      }
    }
    for (const [key, e] of this.remotes) {
      const s = e.stroke
      if (s && now >= goneAt(s, this)) {
        e.stroke = null
        changed = true
        this.listDirty = true
      } else if (s && s.endedAt === null) {
        const drop = this.deadTail(s, now)
        if (drop > 0) {
          s.points.splice(0, drop)
          changed = true
        }
      }
      if (!e.stroke && e.departed) {
        this.remotes.delete(key)
        this.listDirty = true
      }
    }
    let w = 0
    for (let i = 0; i < this.fading.length; i++) {
      const s = this.fading[i]!
      if (now < goneAt(s, this)) this.fading[w++] = s
    }
    if (w !== this.fading.length) {
      this.fading.length = w
      this.listDirty = true
      changed = true
    }
    if (changed) this.notify()
  }

  /** Whether anything is (or may still become) visible at `now`. */
  hasVisible(now = Date.now()): boolean {
    if (this.local && now < goneAt(this.local, this)) return true
    for (const e of this.remotes.values()) if (e.stroke && now < goneAt(e.stroke, this)) return true
    for (const s of this.fading) if (now < goneAt(s, this)) return true
    return false
  }

  /** Fires on any change (local input, remote wires, pruning). Returns the unsubscribe. */
  subscribe(fn: () => void): () => void {
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
    }
  }

  /**
   * Current zoom of the board, so the move threshold is ~1.5 screen px at any zoom.
   * `LaserCanvas` calls this from its `view`; call it yourself if you draw without it.
   */
  setZoom(z: number): void {
    const zz = Number.isFinite(z) && z > 0 ? Math.min(Math.max(z, 0.02), 50) : 1
    this.minStep = MIN_STEP_PX / zz
  }

  /**
   * Every stroke, in paint order (fading, then remote, then local). Live objects: read only.
   * The array is reused until a stroke is added or removed.
   */
  strokes(): readonly LaserStroke[] {
    if (this.listDirty) {
      const list = this.list
      list.length = 0
      for (const s of this.fading) list.push(s)
      for (const e of this.remotes.values()) if (e.stroke) list.push(e.stroke)
      if (this.local) list.push(this.local)
      this.listDirty = false
    }
    return this.list
  }

  private retire(s: LaserStroke, now: number): void {
    if (s.endedAt === null) {
      const last = s.points[s.points.length - 1]
      s.endedAt = Math.max(now, last ? last.t : now)
    }
    if (now < goneAt(s, this)) {
      this.fading.push(s)
      if (this.fading.length > MAX_FADING) this.fading.splice(0, this.fading.length - MAX_FADING)
    }
    this.listDirty = true
  }

  /** Points at the front of a stroke still being drawn that are fully faded (keeps the head). */
  private deadTail(s: LaserStroke, now: number): number {
    const limit = now - this.tailMs - this.fadeMs
    const pts = s.points
    let i = 0
    while (i < pts.length - 1 && pts[i]!.t <= limit) i++
    return i
  }

  private localChanged(structural: boolean): void {
    this.version++
    if (structural) this.listDirty = true
    this.notify()
  }

  private notify(): void {
    for (const fn of this.listeners) fn()
  }
}
