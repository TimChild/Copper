/**
 * `canvas_read` for big boards: the narrowing options (`frame`, `region`,
 * `query`, and the cursor's own copy of `ids`/`types`/`inView`), the
 * `overview`, and the paged answer — a page of at most `limit` shapes and
 * about 48 KB, with a `next` cursor while more remain (docs/canvas.md,
 * "Reading a big canvas"). `readCanvas` (ops.ts) summarises the shapes; this
 * decides which of them a call gets and how the answer is shaped. Everything
 * here reads the document, never the DOM, so a shape the board has not drawn
 * (off screen, culled) reads the same as one it has.
 *
 * Paging rules: a deterministic reading order — frames first, then everything
 * else, each by y, then x, then id — and a cursor that names the last key
 * read plus the filters it was read under (not an index), so shapes added or
 * deleted between pages never make an unchanged shape repeat or go missing.
 * Comment threads ride with the page that holds their anchor; a thread whose
 * shape is gone goes on the first page. A board that fits in one page answers
 * exactly as it always did, plus `total` and `returned`.
 */
import { fromBase64, toBase64 } from './canvas/base64'
import { VIEW_CHECKLIST } from './canvas/checklist-text'
import { boxesOverlap, containsBox, unionBox, type Box } from './canvas/geometry'
import { VIEW_TIMELINE } from './canvas/timeline-text'
import type { Shape } from './canvas/types'
import type { CanvasRead, CommentSummary, ReadContext, ReadOptions, ShapeSummary } from './ops'

/** Shapes per page unless `limit` says otherwise, and the most it may say. */
export const PAGE_LIMIT = 200
export const MAX_PAGE_LIMIT = 500
/** Serialized size a page stops short of (the whole answer, UTF-8). */
export const PAGE_BYTES = 48 * 1024
/** Frames listed in an overview (or a first page) before the list is cut. */
export const FRAME_LIST_MAX = 300
const FRAME_TITLE_MAX = 120
const CURSOR_PREFIX = 'cr1.'

/** The kinds a read reports and `types` takes: a checklist/timeline card and a live link count as their own. */
export const READ_KINDS = ['sticky', 'text', 'frame', 'arrow', 'image', 'link', 'web', 'checklist', 'timeline'] as const

/** What narrows a read: the set a cursor carries from page to page. */
export interface ReadFilters {
  ids?: string[]
  types?: string[]
  inView?: true
  frame?: string
  region?: Box
  query?: string
}

/** One entry of the frame list (overview, and the first page of an un-narrowed paged read). */
export interface FrameListing {
  id: string
  title: string
  x: number
  y: number
  w: number
  h: number
  /** Shapes lying wholly inside it (that match the read's filters). */
  shapes: number
}

export interface CanvasOverview {
  canvas: CanvasRead['canvas']
  viewport?: CanvasRead['viewport']
  overview: true
  /** Shapes matching the filters (all of them, with none). */
  total: number
  /** By kind: a checklist or timeline card counts as `checklist` / `timeline`, a live link as `web`. */
  counts: Record<string, number>
  bounds: Box | null
  frames: FrameListing[]
  /** Set when the frame list was cut at FRAME_LIST_MAX: how many more there are. */
  moreFrames?: number
  comments: { threads: number; open: number }
  agents: CanvasRead['agents']
  selection: string[]
  count: number
  note: string
}

/** A read narrowed or paged: what `readCanvas` builds its loop and its answer from. */
export interface ReadScope {
  /** The options the summaries are made under: the call's, with the cursor's filters in force. */
  opts: ReadOptions
  /** Any of ids/types/inView/frame/region/query in force. */
  narrowed: boolean
  /** frame, region or query in force: comments then follow the shapes returned, as with ids/types/inView. */
  located: boolean
  /** The shape (and its box: an arrow's is its path's) passes frame/region/query. Counts it toward its frames. */
  accepts(shape: Shape, box: Box): boolean
  /** The read as the call should get it: as it is, a page of it, or the overview. */
  finish(read: CanvasRead): CanvasRead | CanvasOverview
}

class ReadError extends Error {}
const fail = (message: string): never => {
  throw new ReadError(message)
}
const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)
const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** UTF-8 length of a string, without encoding it. */
export function utf8Bytes(s: string): number {
  let n = 0
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c < 0xdc00 && i + 1 < s.length) {
      n += 4
      i++
    } else n += 3
  }
  return n
}
const bytesOf = (v: unknown) => utf8Bytes(JSON.stringify(v))

/** The kind a read reports for a shape (see READ_KINDS). */
export function kindOf(s: Pick<ShapeSummary, 'type' | 'view' | 'live'>): string {
  if (s.view === VIEW_CHECKLIST || s.view === VIEW_TIMELINE) return s.view
  if (s.type === 'link' && s.live) return 'web'
  return s.type
}

/** `types` matches the stored type (a checklist card is still a sticky) or the kind. */
export function typeMatches(types: ReadonlySet<string>, s: Pick<Shape, 'type' | 'view' | 'live'>): boolean {
  return types.has(s.type) || types.has(kindOf(s))
}

function raw(rawOpts: unknown): Record<string, unknown> {
  let v = rawOpts
  if (typeof v === 'string') {
    if (!v.trim()) return {}
    try {
      v = JSON.parse(v)
    } catch {
      return {}
    }
  }
  return isObject(v) ? v : {}
}

function parseRegion(v: unknown): Box {
  if (!isObject(v)) return fail('region must be {x, y, w, h} in board units')
  const { x, y, w, h } = v
  if (!finite(x) || !finite(y) || !finite(w) || !finite(h)) return fail('region needs numbers x, y, w and h')
  if (w <= 0 || h <= 0) return fail('region needs a positive w and h')
  return { x, y, w, h }
}

function parseLimit(v: unknown): number {
  if (v === undefined || v === null) return PAGE_LIMIT
  const n = typeof v === 'string' && v.trim() ? Number(v) : v
  if (!finite(n) || n < 1) return fail(`limit must be a number from 1 to ${MAX_PAGE_LIMIT}`)
  return Math.min(MAX_PAGE_LIMIT, Math.floor(n))
}

/** The filters a call names: ids/types/inView as ops.ts parsed them, frame/region/query here. */
function filtersOf(o: Record<string, unknown>, parsed: ReadOptions): ReadFilters {
  const f: ReadFilters = {}
  if (parsed.ids) f.ids = [...new Set(parsed.ids)].sort()
  if (parsed.types) {
    const unknown = parsed.types.filter(t => !(READ_KINDS as readonly string[]).includes(t))
    if (unknown.length) fail(`unknown type ${unknown.map(t => JSON.stringify(t)).join(', ')} — types are ${READ_KINDS.join(', ')}`)
    f.types = [...new Set(parsed.types)].sort()
  }
  if (parsed.inView) f.inView = true
  if (o.frame !== undefined && o.frame !== null && o.frame !== '') {
    if (typeof o.frame !== 'string') fail('frame must be a frame shape id')
    f.frame = (o.frame as string).replace(/^shape:/, '')
  }
  if (o.region !== undefined && o.region !== null) f.region = parseRegion(o.region)
  if (o.query !== undefined && o.query !== null) {
    if (typeof o.query !== 'string') fail('query must be a string')
    const q = (o.query as string).trim()
    if (q) f.query = q
  }
  return f
}

const isEmpty = (f: ReadFilters) => Object.keys(f).length === 0
const sameFilters = (a: ReadFilters, b: ReadFilters) => JSON.stringify(sortKeys(a)) === JSON.stringify(sortKeys(b))
function sortKeys(f: ReadFilters): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const k of Object.keys(f).sort()) out[k] = k === 'query' ? f.query!.toLowerCase() : f[k as keyof ReadFilters]
  return out
}

// ---- the cursor ---------------------------------------------------------------

/** A page's place in the reading order: frames (0) before the rest (1), then y, x, id. */
type SortKey = [rank: number, y: number, x: number, id: string]

interface Cursor {
  /** Canvas it was read from. */
  c: string
  /** Filters in force. */
  f: ReadFilters
  /** The last key read. */
  k: SortKey
  /** Shapes shown before the next page (for "Showing 201–400"). */
  n: number
  /** The page size it was read at, unless that was the default. */
  l?: number
}

const keyOf = (s: ShapeSummary): SortKey => [s.type === 'frame' ? 0 : 1, s.y, s.x, s.id]
function compareKeys(a: SortKey, b: SortKey): number {
  return a[0] - b[0] || a[1] - b[1] || a[2] - b[2] || (a[3] < b[3] ? -1 : a[3] > b[3] ? 1 : 0)
}

function encodeCursor(c: Cursor): string {
  const b64 = toBase64(new TextEncoder().encode(JSON.stringify(c)))
  return CURSOR_PREFIX + b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function decodeCursor(text: unknown, canvasId: string): Cursor {
  const bad = 'cursor is not one canvas_read gave out — start again without it'
  if (typeof text !== 'string' || !text.startsWith(CURSOR_PREFIX)) return fail(bad)
  let c: unknown
  try {
    c = JSON.parse(new TextDecoder().decode(fromBase64(text.slice(CURSOR_PREFIX.length))))
  } catch {
    return fail(bad)
  }
  if (!isObject(c) || !isObject(c.f) || !Array.isArray(c.k) || c.k.length !== 4 || !finite(c.n) || typeof c.c !== 'string') return fail(bad)
  const [rank, y, x, id] = c.k as unknown[]
  if (!finite(rank) || !finite(y) || !finite(x) || typeof id !== 'string') return fail(bad)
  if (c.c !== canvasId) fail('that cursor is from another canvas — start again without it')
  const l = finite(c.l) && c.l >= 1 ? Math.min(MAX_PAGE_LIMIT, Math.floor(c.l)) : undefined
  return { c: c.c, f: c.f as ReadFilters, k: [rank, y, x, id], n: c.n as number, ...(l ? { l } : {}) }
}

// ---- the scope ----------------------------------------------------------------

/**
 * Parse what narrows and pages this read, and check it against the board: an
 * unknown frame, a bad region or a foreign cursor is an error the agent can act on.
 */
export function readScope(ctx: ReadContext, rawOpts: unknown, parsed: ReadOptions, allowOverview = true): ReadScope {
  const o = raw(rawOpts)
  const overview = allowOverview && o.overview === true
  let limit = parseLimit(o.limit)
  const given = filtersOf(o, parsed)
  let filters = given
  let cursor: Cursor | null = null
  if (!overview && o.cursor !== undefined && o.cursor !== null && o.cursor !== '') {
    cursor = decodeCursor(o.cursor, ctx.canvas.id)
    if (!isEmpty(given) && !sameFilters(given, cursor.f))
      fail('that cursor was made for other filters — pass it with the same frame/region/types/query/ids (or alone), or start again without it')
    filters = cursor.f
    // The cursor keeps the page size it was made at, unless this call names one.
    if ((o.limit === undefined || o.limit === null) && cursor.l) limit = cursor.l
  }

  const shapes = ctx.store.getShapes()
  let frameBox: Box | null = null
  if (filters.frame) {
    const f = shapes.get(filters.frame)
    if (!f) fail(`no shape ${filters.frame} on this canvas — overview lists the frames`)
    else if (f.type !== 'frame') fail(`${filters.frame} is a ${f.type}, not a frame — overview lists the frames`)
    else frameBox = { x: f.x, y: f.y, w: f.w, h: f.h }
  }
  const query = filters.query?.toLowerCase()
  const frames = [...shapes.values()].filter(s => s.type === 'frame')
  const inside = new Map<string, number>()

  const opts: ReadOptions = { ...(parsed.full ? { full: true } : {}) }
  if (filters.ids) opts.ids = filters.ids
  if (filters.types) opts.types = filters.types
  if (filters.inView) opts.inView = true
  const narrowed = !isEmpty(filters)

  const sized = (box: Box) => box.w > 0 || box.h > 0
  const accepts = (s: Shape, box: Box): boolean => {
    if (frameBox && s.id !== filters.frame && !(sized(box) && containsBox(frameBox, box))) return false
    if (filters.region && !(sized(box) && boxesOverlap(filters.region, box))) return false
    if (query && !matches(s, query)) return false
    for (const f of frames) if (f.id !== s.id && sized(box) && containsBox(f, box)) inside.set(f.id, (inside.get(f.id) ?? 0) + 1)
    return true
  }

  // Every frame in the area read (all of them, unless frame/region narrow it), each with how many of
  // the shapes this read matched lie inside it — so an overview of `types:['web']` says which slides hold them.
  const frameList = () => {
    const listed = frames
      .filter(f => (!frameBox || f.id === filters.frame || containsBox(frameBox, f)) && (!filters.region || boxesOverlap(filters.region, f)))
      .map(f => ({ f, k: [0, Math.round(f.y), Math.round(f.x), f.id] as SortKey }))
      .sort((a, b) => compareKeys(a.k, b.k))
      .map(
        ({ f }): FrameListing => ({
          id: f.id,
          title: f.title.length > FRAME_TITLE_MAX ? `${f.title.slice(0, FRAME_TITLE_MAX)}…` : f.title,
          x: Math.round(f.x),
          y: Math.round(f.y),
          w: Math.round(f.w),
          h: Math.round(f.h),
          shapes: inside.get(f.id) ?? 0,
        })
      )
    return { frames: listed.slice(0, FRAME_LIST_MAX), more: Math.max(0, listed.length - FRAME_LIST_MAX) }
  }

  const finish = (read: CanvasRead): CanvasRead | CanvasOverview => {
    const total = read.shapes.length
    if (overview) {
      const counts: Record<string, number> = {}
      for (const s of read.shapes) {
        const k = kindOf(s)
        counts[k] = (counts[k] ?? 0) + 1
      }
      const bounds = unionBox(read.shapes.filter(s => s.w > 0 || s.h > 0))
      const { frames: list, more } = frameList()
      const out: CanvasOverview = {
        canvas: read.canvas,
        ...(read.viewport ? { viewport: read.viewport } : {}),
        overview: true,
        total,
        counts,
        bounds: bounds && { x: Math.round(bounds.x), y: Math.round(bounds.y), w: Math.round(bounds.w), h: Math.round(bounds.h) },
        frames: list,
        comments: { threads: read.comments.length, open: read.comments.filter(c => !c.resolved).length },
        agents: read.agents,
        selection: read.selection,
        count: read.count,
        note: `Overview only: ${total} shape${total === 1 ? '' : 's'}${narrowed ? ' match' : ''}. Read a slide with frame:<id>, an area with region, or everything a page at a time (limit, then next as cursor).`,
      }
      if (more) out.moreFrames = more
      return out
    }

    // Small enough: exactly what a read always said, plus the counts.
    if (!cursor && total <= limit) {
      const whole: CanvasRead = { ...read, total, returned: total }
      if (bytesOf(whole) <= PAGE_BYTES) return whole
    }

    // A page.
    const order = [...read.shapes].sort((a, b) => compareKeys(keyOf(a), keyOf(b)))
    let start = 0
    if (cursor) {
      const after = cursor.k
      start = order.findIndex(s => compareKeys(keyOf(s), after) > 0)
      if (start < 0) start = order.length
    }
    const shown = cursor?.n ?? 0
    const on = new Set(order.map(s => s.id))
    const threads = new Map<string, CommentSummary[]>()
    const orphans: CommentSummary[] = []
    for (const t of read.comments) {
      if (on.has(t.anchor)) {
        const list = threads.get(t.anchor)
        if (list) list.push(t)
        else threads.set(t.anchor, [t])
      } else orphans.push(t)
    }
    const first = !cursor
    const page: CanvasRead = {
      ...read,
      shapes: [],
      comments: first ? orphans : [],
      total,
      returned: 0,
    }
    if (first && !narrowed) {
      const { frames: list, more } = frameList()
      page.frames = list
      if (more) page.moreFrames = more
    }
    // The envelope with room for the cursor and the note that will join it.
    const room = 600
    let used = bytesOf(page) + room
    const comments: CommentSummary[] = [...page.comments]
    let i = start
    for (; i < order.length; i++) {
      if (page.shapes.length >= limit) break
      const s = order[i]!
      const riding = threads.get(s.id) ?? []
      const cost = bytesOf(s) + 1 + riding.reduce((n, t) => n + bytesOf(t) + 1, 0)
      if (page.shapes.length > 0 && used + cost > PAGE_BYTES) break
      used += cost
      page.shapes.push(s)
      comments.push(...riding)
    }
    page.comments = comments
    page.returned = page.shapes.length
    const last = page.shapes[page.shapes.length - 1]
    if (i < order.length && last)
      page.next = encodeCursor({ c: ctx.canvas.id, f: filters, k: keyOf(last), n: shown + page.returned, ...(limit !== PAGE_LIMIT ? { l: limit } : {}) })
    if (!page.returned) page.note = `No shapes after this cursor (${total} in all).`
    else {
      const range = `Showing ${shown + 1}–${shown + page.returned} of ${total} shape${total === 1 ? '' : 's'}.`
      page.note = page.next
        ? `${range} Pass cursor to continue${narrowed ? '' : ', or overview / frame / region / types / query to narrow'}.`
        : `${range} That is the last page.`
    }
    return page
  }

  return { opts, narrowed, located: !!(filters.frame || filters.region || filters.query), accepts, finish }
}

/** Case-insensitive substring over what a shape says: text, title, label, url, a checklist's rows. */
function matches(s: Shape, q: string): boolean {
  const hit = (v: string | undefined) => !!v && v.toLowerCase().includes(q)
  if (hit(s.text) || hit(s.title) || hit(s.label) || hit(s.url)) return true
  if (s.src && !s.src.startsWith('data:') && hit(s.src)) return true
  return !!s.rows?.some(r => hit(r.label))
}

export const isReadError = (e: unknown): e is Error => e instanceof ReadError
