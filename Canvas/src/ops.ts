/**
 * Canvas ops and reads: the agent-facing contract, shared by the window API
 * (`copperCanvas.apply` / `copperCanvas.read`), and mirrored by the sync
 * server's own ops endpoint.
 *
 * apply: `{ops:[...], as?:{id,name,color}}` (or a bare array). Ops run in
 * order inside one transaction; a bad op is skipped and reported, the rest
 * still apply. Returns `{applied, ids, errors}` where `ids[i]` is the id op
 * `i` created or touched (null when it failed, or for `clear`).
 *
 *   {op:"add", shape:{type, id?, x?, y?, w?, h?, color?, …}}  // no x/y → free space near the viewport centre
 *   {op:"update", id, patch:{…}}                              // merges props
 *
 * A checklist (`checklist.ts`) takes `title`, `columns` (1–4, default Yes/No),
 * `rows` (labels or {label, id?}, ≤ 60) and `picks` ({rowIdOrLabel: column |
 * true | null}) on add and update; `rows` and `columns` replace the lists.
 *   {op:"move", id, dx, dy}                                    // a frame carries what sits inside it
 *   {op:"resize", id, w, h}
 *   {op:"delete", id}                                          // arrows ending on it go too
 *   {op:"connect", from:id, to:id, label?, color?, fromSide?, toSide?}
 *   {op:"clear"}
 */
import { arrowBox, arrowPath } from './canvas/arrows'
import { AGENT, bareId, readEndpoint, type CanvasStore, type ShapeInput, type ShapeProps } from './canvas/doc'
import {
  DEFAULT_COLUMNS,
  checklistHeight,
  checklistWidth,
  cleanColumns,
  cleanPicks,
  cleanRows,
  summarizeChecklist,
  writeColumns,
  writePick,
  writeRows,
  type Picker,
} from './canvas/checklist'
import { liveAgents, readAgents } from './canvas/agents'
import { center, containsBox, boxesOverlap, SIDES, type Box, type Point, type Side } from './canvas/geometry'
import { MIN_SIZE, isResizable, minSizeOf } from './canvas/resize'
import { LIVE_SIZE, frameUrl } from './canvas/frames'
import { frameSizeFor, imageSizeFor, MAX_DATA_URL } from './canvas/images'
import { findFreeSpot, occupied } from './placement'
import {
  SHAPE_SIZE,
  isRefEndpoint,
  isShapeColor,
  isShapeType,
  type CanvasAgent,
  type ChecklistRow,
  type Endpoint,
  type Shape,
  type ShapeType,
} from './canvas/types'

export const MAX_OPS = 500
const ID = /^[A-Za-z0-9_:.-]{1,64}$/
const MAX_TEXT = 20_000
const MAX_TITLE = 500

export interface Actor {
  id: string
  name: string
  color?: string
}

export interface OpError {
  index: number
  op: string
  error: string
}

export interface ApplyResult {
  applied: number
  ids: (string | null)[]
  errors: OpError[]
}

export interface OpsContext {
  store: CanvasStore
  /** Where unplaced shapes go: the middle of what the user is looking at. */
  viewportCenter: () => Point
  readOnly?: boolean
}

export interface ParsedInput {
  ops: unknown[]
  as: Actor | null
}

class OpFailure extends Error {}
const fail = (message: string): never => {
  throw new OpFailure(message)
}

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)
const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)

/** `{ops, as?}`, a bare array, or either as a JSON string. */
export function parseApplyInput(raw: unknown): ParsedInput {
  let value = raw
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value)
    } catch {
      fail('ops are not valid JSON')
    }
  }
  if (Array.isArray(value)) return { ops: value, as: null }
  if (!isObject(value)) fail('expected {ops:[...], as?:{id,name,color}} or an array of ops')
  const obj = value as Record<string, unknown>
  if (!Array.isArray(obj.ops)) fail('`ops` must be an array')
  let as: Actor | null = null
  if (obj.as !== undefined && obj.as !== null) {
    if (typeof obj.as === 'string') as = { id: `agent:${obj.as}`, name: obj.as }
    else if (isObject(obj.as)) {
      const name = typeof obj.as.name === 'string' && obj.as.name.trim() ? obj.as.name.trim().slice(0, 60) : 'Agent'
      const id =
        typeof obj.as.id === 'string' && obj.as.id.trim() ? obj.as.id.trim().slice(0, 64) : `agent:${name.toLowerCase()}`
      as = { id, name }
      if (typeof obj.as.color === 'string' && obj.as.color) as.color = obj.as.color.slice(0, 32)
    } else fail('`as` must be {id,name,color}')
  }
  return { ops: obj.ops as unknown[], as }
}

// ---- prop validation ---------------------------------------------------------

const COMMON = ['x', 'y', 'w', 'h', 'color', 'z'] as const
const BY_TYPE: Record<ShapeType, readonly string[]> = {
  sticky: [...COMMON, 'text', 'fontSize'],
  text: [...COMMON, 'text', 'fontSize', 'align'],
  frame: [...COMMON, 'title', 'image'],
  arrow: ['color', 'z', 'from', 'to', 'label'],
  image: [...COMMON, 'src', 'naturalW', 'naturalH'],
  link: [...COMMON, 'url', 'title', 'favicon', 'live'],
  checklist: [...COMMON, 'title', 'columns', 'rows', 'picks'],
}
/** Friendly spellings: `text` on a frame or link is its title, on an arrow its label. */
const ALIAS: Partial<Record<ShapeType, Record<string, string>>> = {
  frame: { text: 'title', label: 'title' },
  link: { text: 'title', label: 'title', embed: 'live' },
  arrow: { text: 'label', title: 'label' },
  sticky: { title: 'text' },
  text: { title: 'text' },
  checklist: { text: 'title', label: 'title' },
}
/** Accepted and dropped silently: the page owns these. */
const IGNORED = new Set(['id', 'type', 'by', 'createdAt', 'updatedAt'])

export function validImageSrc(src: unknown): string {
  if (typeof src !== 'string' || !src) return fail('`src` must be a data: or https: URL')
  if (src.startsWith('data:')) {
    if (!/^data:image\/[a-z0-9.+-]+[;,]/i.test(src)) fail('`src` data URL must be an image')
    if (src.length > MAX_DATA_URL) fail(`image data URL is over ${Math.round(MAX_DATA_URL / 1024 / 1024)} MB`)
    return src
  }
  if (/^https:\/\/\S+$/i.test(src)) return src
  return fail('`src` must be a data: or https: URL')
}

function validUrl(url: unknown): string {
  if (typeof url !== 'string' || !url.trim()) return fail('`url` must be a non-empty string')
  const trimmed = url.trim()
  let parsed: URL
  try {
    parsed = new URL(/^[a-z][a-z0-9+.-]*:/i.test(trimmed) ? trimmed : `https://${trimmed}`)
  } catch {
    return fail(`\`url\` is not a URL: ${trimmed.slice(0, 80)}`)
  }
  if (!['http:', 'https:', 'mailto:', 'copper:'].includes(parsed.protocol)) fail(`unsupported link scheme ${parsed.protocol}`)
  return parsed.toString()
}

/** Where a URL points, for a default link title. */
export function hostOf(url: string): string {
  try {
    const u = new URL(url)
    return u.hostname.replace(/^www\./, '') || url
  } catch {
    return url
  }
}

/**
 * The checked, normalised props a caller gave for a shape of `type`. Throws
 * an OpFailure naming the first bad prop.
 */
function cleanProps(type: ShapeType, raw: Record<string, unknown>, store: CanvasStore, selfId?: string): ShapeProps {
  const allowed = BY_TYPE[type]
  const out: Record<string, unknown> = {}
  for (const [rawKey, value] of Object.entries(raw)) {
    if (value === undefined) continue
    const key = ALIAS[type]?.[rawKey] ?? rawKey
    if (IGNORED.has(key)) continue
    if (!allowed.includes(key)) {
      if (type === 'arrow' && ['x', 'y', 'w', 'h'].includes(key))
        fail('arrows have no box of their own: set `from`/`to` (or move the shapes they join)')
      fail(`unknown prop \`${rawKey}\` for ${type} (allowed: ${allowed.join(', ')})`)
    }
    switch (key) {
      case 'x':
      case 'y':
      case 'z':
        if (!finite(value)) fail(`\`${key}\` must be a finite number`)
        out[key] = value
        break
      case 'w':
      case 'h':
        if (!finite(value) || value <= 0) fail(`\`${key}\` must be a positive number`)
        out[key] = value
        break
      case 'naturalW':
      case 'naturalH':
        if (!finite(value) || value < 0) fail(`\`${key}\` must be a non-negative number`)
        out[key] = value
        break
      case 'color':
        if (!isShapeColor(value))
          fail('`color` must be yellow, pink, blue, green, purple, gray, white or a #hex colour')
        out.color = value
        break
      case 'text':
        if (typeof value !== 'string') fail('`text` must be a string')
        if ((value as string).length > MAX_TEXT) fail(`\`text\` is over ${MAX_TEXT} characters`)
        out.text = value
        break
      case 'title':
      case 'label':
        if (typeof value !== 'string') fail(`\`${key}\` must be a string`)
        out[key] = (value as string).slice(0, MAX_TITLE)
        break
      case 'fontSize':
        if (!finite(value) || value < 6 || value > 240) fail('`fontSize` must be between 6 and 240')
        out.fontSize = value
        break
      case 'align':
        if (value !== 'left' && value !== 'center' && value !== 'right') fail('`align` must be left, center or right')
        out.align = value
        break
      case 'image': {
        if (value === null || value === '') {
          out.image = null
          break
        }
        if (typeof value === 'string') {
          out.image = { src: validImageSrc(value), naturalW: 0, naturalH: 0 }
          break
        }
        if (!isObject(value)) fail('`image` must be {src, naturalW, naturalH} or null')
        const img = value as Record<string, unknown>
        out.image = {
          src: validImageSrc(img.src),
          naturalW: finite(img.naturalW) ? img.naturalW : 0,
          naturalH: finite(img.naturalH) ? img.naturalH : 0,
        }
        break
      }
      case 'src':
        out.src = validImageSrc(value)
        break
      case 'url':
        out.url = validUrl(value)
        break
      case 'live':
        if (typeof value !== 'boolean') fail('`live` must be true or false')
        out.live = value
        break
      case 'favicon':
        if (typeof value !== 'string') fail('`favicon` must be a data: or https: URL')
        if (value) {
          if (!/^(data:image\/|https:\/\/)/i.test(value as string)) fail('`favicon` must be a data: or https: URL')
          if ((value as string).length > 256 * 1024) fail('`favicon` is over 256 KB')
        }
        out.favicon = value
        break
      case 'columns':
        out.columns = cleanColumns(value)
        break
      case 'rows':
        out.rows = cleanRows(value, (selfId && store.live(selfId)?.rows) || [])
        break
      case 'picks':
        // Resolved against the final rows and columns by the op (`checklistPicks`).
        break
      case 'from':
      case 'to': {
        const end = readEndpoint(value)
        if (!end) fail(`\`${key}\` must be a shape id, {ref, side?} or {x, y}`)
        checkEnd(end as Endpoint, store, key, selfId)
        out[key] = end
        break
      }
    }
  }
  return out as ShapeProps
}

/** The `picks` an add or update gave (by any alias), if any. */
function rawPicks(raw: Record<string, unknown>): unknown {
  return raw.picks
}

/**
 * Write a checklist's new rows and columns (dropping picks they orphan) and
 * the op's `picks`, all in the op's transaction. Fresh lists also size the
 * card, unless the op sized it.
 */
function writeChecklist(ctx: OpsContext, id: string, props: ShapeProps, picks: unknown, as: Actor | null, sized: { w: boolean; h: boolean }) {
  const m = ctx.store.shapes.get(id)
  if (!m) return
  const live = ctx.store.live(id)
  const rows: ChecklistRow[] = props.rows ?? live?.rows ?? []
  const columns: string[] = props.columns ?? live?.columns ?? [...DEFAULT_COLUMNS]
  const resolved = picks === undefined ? [] : cleanPicks(picks, rows, columns)
  if (props.columns) writeColumns(m, columns)
  if (props.rows) writeRows(m, rows)
  const by: Picker = { name: as?.name ?? 'Agent', id: as?.id ?? 'agent' }
  const now = Date.now()
  for (const [rowId, col] of resolved) writePick(m, rowId, col, by, now)
  if (props.columns && !sized.w) m.set('w', Math.max(live?.w ?? 0, checklistWidth(columns.length)))
  if ((props.rows || props.columns) && !sized.h) m.set('h', checklistHeight(columns.length, rows.length))
}

function checkEnd(end: Endpoint, store: CanvasStore, key: string, selfId?: string) {
  if (!isRefEndpoint(end)) return
  if (end.ref === selfId) fail(`\`${key}\` cannot be the arrow itself`)
  const target = store.live(end.ref)
  if (!target) fail(`\`${key}\`: no shape ${end.ref}`)
  if (target!.type === 'arrow') fail(`\`${key}\`: ${end.ref} is an arrow; arrows join boxes`)
}

const boxesOf = (store: CanvasStore, except?: string): Box[] =>
  store
    .liveAll()
    .filter(s => s.type !== 'arrow' && s.id !== except)
    .map(occupied)

/** Shapes lying wholly inside a frame (not the frame, not arrows). */
export function frameChildren(shapes: readonly Shape[], frame: Box & { id: string }): Shape[] {
  return shapes.filter(s => s.id !== frame.id && s.type !== 'arrow' && containsBox(frame, s))
}

// ---- the ops ----------------------------------------------------------------

function opAdd(op: Record<string, unknown>, ctx: OpsContext, as: Actor | null): { id: string; anchor: Point } {
  let raw = isObject(op.shape) ? op.shape : fail('`add` needs `shape:{type, …}`')
  // `web` (or `iframe`): a live web frame, which is a link with `live` — one shape type, so older clients still show it.
  if (raw.type === 'web' || raw.type === 'iframe') raw = { ...raw, type: 'link', live: raw.live ?? raw.embed ?? true, embed: undefined }
  const type = raw.type
  if (!isShapeType(type)) return fail('`shape.type` must be sticky, text, frame, arrow, image, link, checklist or web')
  let id: string | undefined
  if (raw.id !== undefined) {
    if (typeof raw.id !== 'string' || !ID.test(raw.id)) fail('`shape.id` must be 1–64 of A–Z a–z 0–9 _ - : .')
    if (ctx.store.shapes.has(raw.id as string)) fail(`a shape with id ${raw.id as string} already exists`)
    id = raw.id as string
  }
  const props = cleanProps(type, raw, ctx.store, id)
  const input: ShapeInput = { type, ...props }
  if (id) input.id = id
  input.by = as?.name ?? 'Agent'

  if (type === 'arrow') {
    if (!props.from || !props.to) fail('an arrow needs `from` and `to`')
    const newId = ctx.store.create(input, AGENT)
    const shape = ctx.store.live(newId)
    const path = shape ? arrowPath(shape, ref => ctx.store.live(ref)) : null
    return { id: newId, anchor: path ? path.mid : { x: 0, y: 0 } }
  }
  if (type === 'image') {
    if (!props.src) fail('an image needs `src`')
    const nw = props.naturalW || 0
    const nh = props.naturalH || 0
    if (props.w === undefined || props.h === undefined) {
      const size = imageSizeFor(nw || SHAPE_SIZE.image.w, nh || SHAPE_SIZE.image.h)
      if (props.w === undefined && props.h !== undefined) input.w = Math.round((props.h * size.w) / size.h)
      else if (props.h === undefined && props.w !== undefined) input.h = Math.round((props.w * size.h) / size.w)
      else {
        input.w = size.w
        input.h = size.h
      }
    }
    if (!nw || !nh) {
      input.naturalW = nw || input.w
      input.naturalH = nh || input.h
    }
  }
  if (type === 'frame' && props.image && props.w === undefined && props.h === undefined) {
    const size = frameSizeFor(props.image.naturalW || 640, props.image.naturalH || 480)
    input.w = size.w
    input.h = size.h
  }
  if (type === 'link') {
    if (!props.url) fail('a link needs `url`')
    if (!props.title) input.title = hostOf(props.url!)
    if (props.live && !frameUrl(props.url)) fail('a live frame needs an http(s) `url`')
  }
  if (type === 'checklist') {
    input.columns = props.columns ?? [...DEFAULT_COLUMNS]
    input.rows = props.rows ?? []
    input.title = props.title ?? ''
    // Checked before anything is written: a bad pick fails the whole add.
    if (rawPicks(raw) !== undefined) cleanPicks(rawPicks(raw), input.rows, input.columns)
    input.w ??= checklistWidth(input.columns.length)
    input.h ??= checklistHeight(input.columns.length, input.rows.length)
  }
  const base = type === 'link' && props.live ? LIVE_SIZE : SHAPE_SIZE[type]
  const size = { w: input.w ?? base.w, h: input.h ?? base.h }
  if (isResizable(type)) {
    const min = minSizeOf({ type, live: props.live })
    size.w = Math.max(size.w, min.w)
    size.h = Math.max(size.h, min.h)
  }
  input.w = size.w
  input.h = size.h
  if (props.x === undefined || props.y === undefined) {
    const spot = findFreeSpot(boxesOf(ctx.store), size, ctx.viewportCenter(), { gap: 24, step: 32 })
    if (props.x === undefined) input.x = spot.x
    if (props.y === undefined) input.y = spot.y
  }
  const newId = ctx.store.create(input, AGENT)
  if (type === 'checklist' && rawPicks(raw) !== undefined) writeChecklist(ctx, newId, {}, rawPicks(raw), as, { w: true, h: true })
  return { id: newId, anchor: center({ x: input.x!, y: input.y!, w: size.w, h: size.h }) }
}

function needShape(ctx: OpsContext, id: unknown): Shape {
  if (typeof id !== 'string' || !id) return fail('`id` must be a shape id')
  const shape = ctx.store.live(bareId(id))
  if (!shape) return fail(`no shape ${id}`)
  return shape
}

function anchorOf(ctx: OpsContext, id: string): Point {
  const shape = ctx.store.live(id)
  if (!shape) return ctx.viewportCenter()
  if (shape.type === 'arrow') {
    const path = arrowPath(shape, ref => ctx.store.live(ref))
    return path ? path.mid : ctx.viewportCenter()
  }
  return center(shape)
}

function opUpdate(op: Record<string, unknown>, ctx: OpsContext, as: Actor | null = null): string {
  const shape = needShape(ctx, op.id)
  const raw = isObject(op.patch) ? op.patch : isObject(op.props) ? op.props : fail('`update` needs `patch:{…}`')
  const props = cleanProps(shape.type, raw, ctx.store, shape.id)
  if (shape.type === 'checklist') {
    const { columns, rows, ...rest } = props
    const picks = rawPicks(raw)
    if (picks !== undefined) cleanPicks(picks, rows ?? shape.rows ?? [], columns ?? shape.columns ?? [...DEFAULT_COLUMNS])
    if (rest.w !== undefined) rest.w = Math.max(rest.w, MIN_SIZE.checklist.w)
    if (rest.h !== undefined) rest.h = Math.max(rest.h, MIN_SIZE.checklist.h)
    ctx.store.update(shape.id, rest, AGENT)
    writeChecklist(ctx, shape.id, { columns, rows }, picks, as, { w: rest.w !== undefined, h: rest.h !== undefined })
    return shape.id
  }
  if (shape.type === 'link' && props.live && !frameUrl(props.url ?? shape.url)) fail('a live frame needs an http(s) `url`')
  // A new address without a new name: the old page's name and icon would be wrong. The host
  // stands in, and a live frame puts the page's own name back once it has loaded.
  if (shape.type === 'link' && props.url && props.url !== shape.url) {
    if (props.title === undefined) props.title = hostOf(props.url)
    if (props.favicon === undefined && shape.favicon && hostOf(props.url) !== hostOf(shape.url ?? '')) props.favicon = ''
  }
  if (isResizable(shape.type)) {
    const live = props.live ?? shape.live
    const min = minSizeOf({ type: shape.type, live })
    // Turning a small card live makes it a frame worth looking at.
    if (shape.type === 'link' && props.live && !shape.live) {
      props.w ??= Math.max(shape.w, LIVE_SIZE.w)
      props.h ??= Math.max(shape.h, LIVE_SIZE.h)
    }
    if (props.w !== undefined) props.w = Math.max(props.w, min.w)
    if (props.h !== undefined) props.h = Math.max(props.h, min.h)
  }
  if (shape.type === 'arrow') {
    const from = props.from ?? shape.from
    const to = props.to ?? shape.to
    if (from && to && isRefEndpoint(from) && isRefEndpoint(to) && from.ref === to.ref)
      fail('an arrow cannot start and end on the same shape')
  }
  ctx.store.update(shape.id, props, AGENT)
  return shape.id
}

function opMove(op: Record<string, unknown>, ctx: OpsContext): string {
  const shape = needShape(ctx, op.id)
  const dx = op.dx ?? 0
  const dy = op.dy ?? 0
  if (!finite(dx) || !finite(dy)) fail('`dx` and `dy` must be finite numbers')
  const moves: [string, Record<string, unknown>][] = []
  if (shape.type === 'arrow') {
    const shift = (e: Endpoint | undefined) => (e && !isRefEndpoint(e) ? { x: e.x + (dx as number), y: e.y + (dy as number) } : e)
    moves.push([shape.id, { from: shift(shape.from), to: shift(shape.to) }])
  } else {
    moves.push([shape.id, { x: shape.x + (dx as number), y: shape.y + (dy as number) }])
    if (shape.type === 'frame')
      for (const child of frameChildren(ctx.store.liveAll(), shape))
        moves.push([child.id, { x: child.x + (dx as number), y: child.y + (dy as number) }])
  }
  ctx.store.moveMany(moves, AGENT)
  return shape.id
}

function opResize(op: Record<string, unknown>, ctx: OpsContext): string {
  const shape = needShape(ctx, op.id)
  if (!isResizable(shape.type)) fail(`${shape.type} shapes have no size`)
  const w = op.w ?? shape.w
  const h = op.h ?? shape.h
  if (!finite(w) || !finite(h) || w <= 0 || h <= 0) fail('`w` and `h` must be positive numbers')
  const min = minSizeOf(shape as Shape & { type: keyof typeof MIN_SIZE })
  ctx.store.update(shape.id, { w: Math.max(w as number, min.w), h: Math.max(h as number, min.h) }, AGENT)
  return shape.id
}

function opDelete(op: Record<string, unknown>, ctx: OpsContext): string {
  const shape = needShape(ctx, op.id)
  ctx.store.remove([shape.id], AGENT)
  return shape.id
}

const isSide = (v: unknown): v is Side => typeof v === 'string' && (SIDES as readonly string[]).includes(v)

function opConnect(op: Record<string, unknown>, ctx: OpsContext, as: Actor | null): { id: string; anchor: Point } {
  const end = (v: unknown, side: unknown, key: string): Endpoint => {
    const e = readEndpoint(v)
    if (!e) return fail(`\`${key}\` must be a shape id`)
    if (isRefEndpoint(e) && side !== undefined) {
      if (!isSide(side)) fail(`\`${key}Side\` must be top, right, bottom or left`)
      e.side = side as Side
    }
    return e
  }
  const from = end(op.from, op.fromSide, 'from')
  const to = end(op.to, op.toSide, 'to')
  if (isRefEndpoint(from) && isRefEndpoint(to) && from.ref === to.ref) fail('`from` and `to` are the same shape')
  const raw: Record<string, unknown> = { from, to }
  if (op.label !== undefined) raw.label = op.label
  if (op.color !== undefined) raw.color = op.color
  let id: string | undefined
  if (op.id !== undefined) {
    if (typeof op.id !== 'string' || !ID.test(op.id)) fail('`id` must be 1–64 of A–Z a–z 0–9 _ - : .')
    if (ctx.store.shapes.has(op.id as string)) fail(`a shape with id ${op.id as string} already exists`)
    id = op.id as string
  }
  const props = cleanProps('arrow', raw, ctx.store, id)
  const input: ShapeInput = { type: 'arrow', ...props, by: as?.name ?? 'Agent' }
  if (id) input.id = id
  const newId = ctx.store.create(input, AGENT)
  return { id: newId, anchor: anchorOf(ctx, newId) }
}

export interface ApplyOutcome extends ApplyResult {
  /** Where the agent's cursor should rest: the last thing it touched. */
  anchor: Point | null
  actor: Actor | null
}

/** Apply ops (see the file header). Never throws. */
export function applyOps(ctx: OpsContext, raw: unknown): ApplyOutcome {
  let parsed: ParsedInput
  try {
    parsed = parseApplyInput(raw)
  } catch (e) {
    return { applied: 0, ids: [], errors: [{ index: -1, op: '', error: messageOf(e) }], anchor: null, actor: null }
  }
  const { ops, as } = parsed
  const result: ApplyOutcome = { applied: 0, ids: [], errors: [], anchor: null, actor: as }
  if (ctx.readOnly) {
    result.ids = ops.map(() => null)
    result.errors = ops.map((op, index) => ({ index, op: opName(op), error: 'this canvas is read-only' }))
    return result
  }
  if (ops.length > MAX_OPS) {
    result.errors.push({ index: -1, op: '', error: `at most ${MAX_OPS} ops per call (got ${ops.length})` })
    return result
  }
  ctx.store.transact(() => {
    ops.forEach((op, index) => {
      const name = opName(op)
      try {
        if (!isObject(op)) fail('an op must be an object like {op:"add", …}')
        const o = op as Record<string, unknown>
        let id: string | null = null
        switch (o.op) {
          case 'add': {
            const r = opAdd(o, ctx, as)
            id = r.id
            result.anchor = r.anchor
            break
          }
          case 'update':
            id = opUpdate(o, ctx, as)
            result.anchor = anchorOf(ctx, id)
            break
          case 'move':
            id = opMove(o, ctx)
            result.anchor = anchorOf(ctx, id)
            break
          case 'resize':
            id = opResize(o, ctx)
            result.anchor = anchorOf(ctx, id)
            break
          case 'delete': {
            const at = anchorOf(ctx, bareId(String(o.id ?? '')))
            id = opDelete(o, ctx)
            result.anchor = at
            break
          }
          case 'connect': {
            const r = opConnect(o, ctx, as)
            id = r.id
            result.anchor = r.anchor
            break
          }
          case 'clear':
            ctx.store.clear(AGENT)
            break
          default:
            fail(`unknown op ${JSON.stringify(o.op ?? null)} (add, update, move, resize, delete, connect, clear)`)
        }
        result.ids.push(id)
        result.applied++
      } catch (e) {
        result.ids.push(null)
        result.errors.push({ index, op: name, error: messageOf(e) })
      }
    })
  }, AGENT)
  return result
}

const opName = (op: unknown) => (isObject(op) && typeof op.op === 'string' ? op.op : '')
const messageOf = (e: unknown) => (e instanceof Error ? e.message : String(e))

// ---- read -------------------------------------------------------------------

export interface ReadOptions {
  /** Whole text instead of the first 500 characters. */
  full?: boolean
  /** Only these shapes. */
  ids?: string[]
  /** Only shapes touching the visible area. */
  inView?: boolean
  /** Only these types. */
  types?: string[]
}

export interface ReadContext {
  store: CanvasStore
  canvas: { id: string; name: string; kind: string }
  /** The visible world rectangle and zoom; null when unknown. */
  viewport: (Box & { zoom: number }) | null
  selection: readonly string[]
  now?: number
}

export interface ShapeSummary {
  id: string
  type: ShapeType
  x: number
  y: number
  w: number
  h: number
  color: string
  z: number
  by?: string
  text?: string
  title?: string
  label?: string
  url?: string
  /** link: shown live (the site in a frame) rather than as a card. */
  live?: boolean
  fontSize?: number
  align?: string
  from?: Endpoint
  to?: Endpoint
  src?: string
  naturalW?: number
  naturalH?: number
  image?: { src: string; naturalW: number; naturalH: number }
  /** checklist: its columns, rows with each one's pick (and who made it, when), and the count per column. */
  columns?: string[]
  rows?: { id: string; label: string; pick: string | null; by?: string; at?: number }[]
  tally?: Record<string, number>
  /** The innermost frame this shape sits in. */
  frame?: string
}

export interface CanvasRead {
  canvas: { id: string; name: string; kind: string }
  viewport?: { x: number; y: number; w: number; h: number; zoom: number }
  shapes: ShapeSummary[]
  agents: (Omit<CanvasAgent, 'cursor'> & { cursor: Point | null })[]
  selection: string[]
  count: number
}

export const READ_TEXT_LIMIT = 500

export function parseReadOptions(raw: unknown): ReadOptions {
  let v = raw
  if (typeof v === 'string') {
    if (!v.trim()) return {}
    try {
      v = JSON.parse(v)
    } catch {
      return {}
    }
  }
  if (!isObject(v)) return {}
  const out: ReadOptions = {}
  if (v.full === true) out.full = true
  if (v.inView === true || v.viewport === true) out.inView = true
  if (Array.isArray(v.ids)) out.ids = v.ids.filter((x): x is string => typeof x === 'string').map(bareId)
  if (Array.isArray(v.types)) out.types = v.types.filter((x): x is string => typeof x === 'string')
  return out
}

const clip = (s: string, full: boolean) => (full || s.length <= READ_TEXT_LIMIT ? s : `${s.slice(0, READ_TEXT_LIMIT)}…`)

/** A data URL is never echoed whole: its kind and size are enough to reason about. */
export function describeSrc(src: string, full = false): string {
  if (!src.startsWith('data:')) return src
  if (full && src.length <= 4096) return src
  const kind = /^data:([^;,]+)/.exec(src)?.[1] ?? 'data'
  const bytes = Math.round(((src.length - src.indexOf(',') - 1) * 3) / 4)
  return `data:${kind} (${bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`})`
}

const r = (n: number) => Math.round(n)

/** The board as an agent should see it (see the spec's read format). */
export function readCanvas(ctx: ReadContext, rawOpts: unknown = {}): CanvasRead {
  const opts = parseReadOptions(rawOpts)
  const full = !!opts.full
  const all = [...ctx.store.getShapes().values()]
  const byId = new Map(all.map(s => [s.id, s] as const))
  const boxOf = (id: string) => {
    const s = byId.get(id)
    return s && s.type !== 'arrow' ? s : null
  }
  const frames = all.filter(s => s.type === 'frame')
  const parentFrame = (s: Shape) => {
    let best: Shape | null = null
    for (const f of frames) {
      if (f.id === s.id || !containsBox(f, s)) continue
      if (!best || f.w * f.h < best.w * best.h) best = f
    }
    return best?.id
  }
  const ids = opts.ids ? new Set(opts.ids) : null
  const types = opts.types ? new Set(opts.types) : null
  const out: ShapeSummary[] = []
  for (const s of all) {
    if (ids && !ids.has(s.id)) continue
    if (types && !types.has(s.type)) continue
    let box: Box = { x: s.x, y: s.y, w: s.w, h: s.h }
    if (s.type === 'arrow') {
      const path = arrowPath(s, boxOf)
      box = path ? arrowBox(path) : { x: 0, y: 0, w: 0, h: 0 }
    }
    if (opts.inView && ctx.viewport && !boxesOverlap(ctx.viewport, box)) continue
    const sum: ShapeSummary = {
      id: s.id,
      type: s.type,
      x: r(box.x),
      y: r(box.y),
      w: r(box.w),
      h: r(box.h),
      color: s.color,
      z: s.z,
    }
    if (s.by) sum.by = s.by
    switch (s.type) {
      case 'sticky':
      case 'text':
        sum.text = clip(s.text, full)
        if (s.fontSize) sum.fontSize = s.fontSize
        if (s.align) sum.align = s.align
        break
      case 'frame':
        sum.title = clip(s.title, full)
        if (s.image) sum.image = { ...s.image, src: describeSrc(s.image.src, full) }
        break
      case 'arrow':
        sum.label = clip(s.label ?? '', full)
        if (s.from) sum.from = s.from
        if (s.to) sum.to = s.to
        break
      case 'image':
        sum.src = describeSrc(s.src ?? '', full)
        sum.naturalW = s.naturalW
        sum.naturalH = s.naturalH
        break
      case 'link':
        sum.url = s.url
        sum.title = clip(s.title, full)
        if (s.live) sum.live = true
        break
      case 'checklist':
        sum.title = clip(s.title, full)
        Object.assign(sum, summarizeChecklist(s.columns ?? [], s.rows ?? [], s.picks ?? {}))
        break
    }
    if (s.type !== 'arrow') {
      const parent = parentFrame(s)
      if (parent) sum.frame = parent
    }
    out.push(sum)
  }
  out.sort((a, b) => a.y - b.y || a.x - b.x || (a.id < b.id ? -1 : 1))
  const now = ctx.now ?? Date.now()
  const read: CanvasRead = {
    canvas: ctx.canvas,
    shapes: out,
    agents: liveAgents(readAgents(ctx.store.agents), now),
    selection: [...ctx.selection],
    count: all.length,
  }
  if (ctx.viewport)
    read.viewport = {
      x: r(ctx.viewport.x),
      y: r(ctx.viewport.y),
      w: r(ctx.viewport.w),
      h: r(ctx.viewport.h),
      zoom: Math.round(ctx.viewport.zoom * 1000) / 1000,
    }
  return read
}
