/**
 * Reading an Easels board (the whiteboard Canvas replaced) and turning it into
 * canvas shapes, for `copperCanvas.importLegacy`. Pure: no DOM, no React; the
 * controller resolves the pictures and writes the result in one transaction.
 *
 * The legacy document (easel-web's `doc/easel-doc.ts`):
 * - `shapes: Y.Map<id, Y.Map>` with `type` sticky | frame | arrow, `x y w h`,
 *   `color` (yellow, pink, blue, green, purple, gray, white), `text` (a Y.Text,
 *   or a plain string from other writers), `by`;
 * - arrows: `from` / `to` are `shape:<id>` refs, and `text` is the label;
 * - frames: `text` is the title, `image` is `file:<fileId>` ('' once removed);
 * - `meta: Y.Map` with `title`, `createdAt`.
 *
 * Easels saved the whole document as one update (`Y.encodeStateAsUpdate`,
 * `doc.yjs`); a stream of updates (an array, or one buffer of
 * length-prefixed records) is read too.
 */
import * as Y from 'yjs'
import * as decoding from 'lib0/decoding'
import { fromBase64 } from './base64'
import type { ShapeInput } from './doc'
import { boxesOverlap, unionBox, type Box } from './geometry'
import { MIN_SIZE } from './resize'
import { SHAPE_COLORS, isNamedColor, type NamedColor, type ShapeColor } from './types'

export const LEGACY_TYPES = ['sticky', 'frame', 'arrow'] as const
export type LegacyType = (typeof LEGACY_TYPES)[number]

/** Easels' default sizes (its stickies were shorter than ours). */
export const LEGACY_SIZE: Record<LegacyType, { w: number; h: number }> = {
  sticky: { w: 200, h: 140 },
  frame: { w: 480, h: 320 },
  arrow: { w: 0, h: 0 },
}

/** Easels drew sticky text at 14 px; imported notes keep that so they read the same. */
export const LEGACY_STICKY_FONT = 14
/** Gap between a frame's edge and the picture placed inside it. */
export const FRAME_PICTURE_INSET = 8
/** Names a canvas has before anybody named it; an import may replace them. */
export const DEFAULT_NAMES = ['canvas', 'untitled', 'untitled canvas', 'untitled easel', 'new canvas']

/** What the host passes to `importLegacy`. */
export interface LegacyPayload {
  /** The legacy document: base64 of one update (or of length-prefixed updates), or a list of base64 updates. */
  doc: string | string[]
  /** `fileId` → `data:` URL (an `https:` URL or bare base64 is accepted too). */
  files: Record<string, string>
  title?: string
}

export interface LegacyShape {
  id: string
  type: LegacyType
  x: number
  y: number
  w: number
  h: number
  /** As stored; mapped by `legacyColor`. */
  color: unknown
  text: string
  /** Arrows: the bare ids of the shapes they join. */
  from?: string
  to?: string
  /** Frames: the picture's file id. */
  fileId?: string
}

export interface LegacyRead {
  shapes: LegacyShape[]
  /** Entries that are not a shape Easels drew (unknown types, broken entries). */
  skipped: number
  /** `meta.title`, when it is not Easels' placeholder. */
  title?: string
}

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)
const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** `{doc, files, title?}`, or that as a JSON string. Throws a readable error. */
export function parseLegacyPayload(raw: unknown): LegacyPayload {
  let v = raw
  if (typeof v === 'string') {
    try {
      v = JSON.parse(v)
    } catch {
      throw new Error('importLegacy: the payload is not valid JSON')
    }
  }
  if (!isObject(v)) throw new Error('importLegacy: expected {doc, files, title?}')
  let doc: string | string[]
  if (typeof v.doc === 'string' && v.doc.trim()) doc = v.doc
  else if (Array.isArray(v.doc) && v.doc.length > 0 && v.doc.every(d => typeof d === 'string')) doc = v.doc as string[]
  else throw new Error('importLegacy: `doc` must be the base64 of the legacy document')
  const files: Record<string, string> = {}
  if (isObject(v.files)) for (const [k, f] of Object.entries(v.files)) if (typeof f === 'string' && f) files[k] = f
  const out: LegacyPayload = { doc, files }
  if (typeof v.title === 'string' && v.title.trim()) out.title = v.title.trim().slice(0, 200)
  return out
}

// ---- decoding ----------------------------------------------------------------

/** Whether applying left nothing waiting on missing updates. */
function complete(doc: Y.Doc): boolean {
  const store = doc.store as unknown as { pendingStructs: unknown; pendingDs: unknown }
  return !store.pendingStructs && !store.pendingDs
}

const hasContent = (doc: Y.Doc) => doc.getMap('shapes').size > 0 || doc.getMap('meta').size > 0

/** A fresh doc with `updates` applied, or null when one does not apply cleanly. */
function tryApply(updates: Uint8Array[], v2 = false): Y.Doc | null {
  const doc = new Y.Doc()
  try {
    for (const u of updates) {
      if (v2) Y.applyUpdateV2(doc, u)
      else Y.applyUpdate(doc, u)
    }
  } catch {
    doc.destroy()
    return null
  }
  if (!complete(doc)) {
    doc.destroy()
    return null
  }
  return doc
}

/** Records of `4-byte big-endian length + bytes`, covering the buffer exactly (Copper's update logs). */
export function splitLengthPrefixed(bytes: Uint8Array): Uint8Array[] | null {
  const out: Uint8Array[] = []
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  let at = 0
  while (at < bytes.length) {
    if (at + 4 > bytes.length) return null
    const n = view.getUint32(at)
    at += 4
    if (n === 0 || at + n > bytes.length) return null
    out.push(bytes.subarray(at, at + n))
    at += n
  }
  return out.length ? out : null
}

/** Records of `varuint length + bytes` (lib0's `writeVarUint8Array`), covering the buffer exactly. */
export function splitVarPrefixed(bytes: Uint8Array): Uint8Array[] | null {
  const out: Uint8Array[] = []
  const d = decoding.createDecoder(bytes)
  try {
    while (decoding.hasContent(d)) {
      const chunk = decoding.readVarUint8Array(d)
      if (chunk.length === 0) return null
      out.push(chunk)
    }
  } catch {
    return null
  }
  return out.length > 1 ? out : null
}

/**
 * The legacy Y.Doc from what the host read off disk. Tries one whole-document
 * update first (what Easels wrote), then an update stream. Throws when
 * nothing reads.
 */
export function decodeLegacyDoc(doc: string | string[] | Uint8Array): Y.Doc {
  if (Array.isArray(doc)) {
    const updates = doc.map(fromBase64)
    const out = tryApply(updates) ?? tryApply(updates, true)
    if (!out) throw new Error('the legacy updates do not apply')
    return out
  }
  const bytes = typeof doc === 'string' ? fromBase64(doc) : doc
  if (bytes.length === 0) throw new Error('the legacy document is empty')
  let fallback: Y.Doc | null = null
  const attempts: (() => Y.Doc | null)[] = [
    () => tryApply([bytes]),
    () => {
      const parts = splitLengthPrefixed(bytes)
      return parts ? tryApply(parts) : null
    },
    () => {
      const parts = splitVarPrefixed(bytes)
      return parts ? tryApply(parts) : null
    },
    () => tryApply([bytes], true),
  ]
  for (const attempt of attempts) {
    const out = attempt()
    if (!out) continue
    if (hasContent(out)) {
      fallback?.destroy()
      return out
    }
    // Applies, but holds nothing we know: keep looking, remember it.
    if (fallback) out.destroy()
    else fallback = out
  }
  if (fallback) return fallback
  throw new Error('the legacy document is not a Yjs update')
}

const refId = (v: unknown): string | undefined => {
  if (typeof v !== 'string') return undefined
  const t = v.trim()
  if (!t) return undefined
  return t.startsWith('shape:') ? t.slice(6) || undefined : t
}

const fileRef = (v: unknown): string | undefined => {
  if (typeof v !== 'string') return undefined
  const t = v.trim()
  if (!t) return undefined
  return t.startsWith('file:') ? t.slice(5) || undefined : t
}

const textOf = (v: unknown): string => (v instanceof Y.Text ? v.toString() : typeof v === 'string' ? v : '')

/** Every shape Easels would have drawn, in the document's order. */
export function readLegacyShapes(doc: Y.Doc): LegacyRead {
  const shapes: LegacyShape[] = []
  let skipped = 0
  doc.getMap<unknown>('shapes').forEach((m, id) => {
    if (!(m instanceof Y.Map) || !id) {
      skipped++
      return
    }
    const type: unknown = m.get('type')
    if (type !== 'sticky' && type !== 'frame' && type !== 'arrow') {
      skipped++
      return
    }
    const size = LEGACY_SIZE[type]
    const num = (k: string, fallback: number) => {
      const v = m.get(k)
      return finite(v) ? v : fallback
    }
    const shape: LegacyShape = {
      id,
      type,
      x: num('x', 0),
      y: num('y', 0),
      w: Math.max(0, num('w', size.w)),
      h: Math.max(0, num('h', size.h)),
      color: m.get('color'),
      text: textOf(m.get('text')),
    }
    if (type === 'arrow') {
      const from = refId(m.get('from'))
      const to = refId(m.get('to'))
      if (from) shape.from = from
      if (to) shape.to = to
    }
    if (type === 'frame') {
      const fileId = fileRef(m.get('image'))
      if (fileId) shape.fileId = fileId
    }
    shapes.push(shape)
  })
  const out: LegacyRead = { shapes, skipped }
  const title = doc.getMap<unknown>('meta').get('title')
  if (typeof title === 'string' && title.trim() && title.trim().toLowerCase() !== 'untitled easel') out.title = title.trim()
  return out
}

// ---- colours -----------------------------------------------------------------

/** Representative tones of the named colours, for finding the nearest one. */
const NAMED_RGB: Record<NamedColor, [number, number, number]> = {
  yellow: [255, 212, 59],
  pink: [247, 131, 172],
  blue: [116, 180, 252],
  green: [127, 216, 143],
  purple: [177, 151, 252],
  gray: [201, 204, 209],
  white: [255, 255, 255],
}

const CSS_NAMES: Record<string, NamedColor> = {
  grey: 'gray',
  silver: 'gray',
  black: 'gray',
  red: 'pink',
  rose: 'pink',
  magenta: 'pink',
  orange: 'yellow',
  amber: 'yellow',
  gold: 'yellow',
  lime: 'green',
  teal: 'green',
  mint: 'green',
  cyan: 'blue',
  sky: 'blue',
  navy: 'blue',
  indigo: 'purple',
  violet: 'purple',
  lavender: 'purple',
}

const HEX = /^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i

/** The named colour closest to an RGB triple. */
export function nearestNamed(rgb: [number, number, number]): NamedColor {
  let best: NamedColor = 'gray'
  let bestD = Infinity
  for (const name of SHAPE_COLORS) {
    const [r, g, b] = NAMED_RGB[name]
    const d = (r - rgb[0]) ** 2 * 0.3 + (g - rgb[1]) ** 2 * 0.59 + (b - rgb[2]) ** 2 * 0.11
    if (d < bestD) {
      bestD = d
      best = name
    }
  }
  return best
}

/**
 * A legacy colour on the canvas: palette names as they are, `#hex` passed
 * through, `rgb()` and common colour words mapped to the nearest named
 * colour. Undefined (the type's default) for anything else, and for arrows,
 * which Easels always drew in one colour.
 */
export function legacyColor(raw: unknown, type: LegacyType): ShapeColor | undefined {
  if (type === 'arrow' || typeof raw !== 'string') return undefined
  const v = raw.trim().toLowerCase()
  if (!v) return undefined
  if (isNamedColor(v)) return v
  if (HEX.test(v)) return v as ShapeColor
  if (CSS_NAMES[v]) return CSS_NAMES[v]
  const rgb = /^rgba?\(\s*(\d{1,3})[\s,]+(\d{1,3})[\s,]+(\d{1,3})/.exec(v)
  if (rgb) return nearestNamed([Number(rgb[1]), Number(rgb[2]), Number(rgb[3])])
  return undefined
}

// ---- pictures ----------------------------------------------------------------

const MAGIC: [string, number[]][] = [
  ['image/png', [0x89, 0x50, 0x4e, 0x47]],
  ['image/jpeg', [0xff, 0xd8, 0xff]],
  ['image/gif', [0x47, 0x49, 0x46, 0x38]],
  ['image/webp', [0x52, 0x49, 0x46, 0x46]],
]

/** A `data:` URL for a file the host handed over: as is, or bare base64 typed by its magic bytes. */
export function pictureSrc(value: string): string | null {
  const v = value.trim()
  if (/^data:image\/[a-z0-9.+-]+[;,]/i.test(v)) return v
  if (/^https:\/\/\S+$/i.test(v)) return v
  if (/^[A-Za-z0-9+/=\s_-]+$/.test(v) && v.length >= 16) {
    let head: Uint8Array
    try {
      head = fromBase64(v.slice(0, 32).replace(/=+$/, ''))
    } catch {
      return null
    }
    for (const [mime, sig] of MAGIC) if (sig.every((b, i) => head[i] === b)) return `data:${mime};base64,${v.replace(/\s/g, '')}`
  }
  return null
}

/** The first `n` bytes of a base64 `data:` URL's payload. */
function dataBytes(src: string, n: number): Uint8Array | null {
  const comma = src.indexOf(',')
  if (comma < 0 || !/;base64$/i.test(src.slice(0, comma))) return null
  const take = Math.ceil(n / 3) * 4
  try {
    return fromBase64(src.slice(comma + 1, comma + 1 + take).replace(/[^A-Za-z0-9+/]/g, '').slice(0, take))
  } catch {
    return null
  }
}

const be16 = (b: Uint8Array, i: number) => ((b[i] ?? 0) << 8) | (b[i + 1] ?? 0)
const le16 = (b: Uint8Array, i: number) => (b[i] ?? 0) | ((b[i + 1] ?? 0) << 8)
const le24 = (b: Uint8Array, i: number) => (b[i] ?? 0) | ((b[i + 1] ?? 0) << 8) | ((b[i + 2] ?? 0) << 16)
const be32 = (b: Uint8Array, i: number) => (((b[i] ?? 0) << 24) | ((b[i + 1] ?? 0) << 16) | ((b[i + 2] ?? 0) << 8) | (b[i + 3] ?? 0)) >>> 0

/**
 * An image's pixel size read from its header (PNG, GIF, JPEG, WebP, SVG),
 * without decoding it; null when the header says nothing.
 */
export function sniffImageSize(src: string): { w: number; h: number } | null {
  if (/^data:image\/svg\+xml/i.test(src)) return svgSize(src)
  const b = dataBytes(src, 256 * 1024)
  if (!b || b.length < 24) return null
  const ok = (w: number, h: number) => (w > 0 && h > 0 ? { w, h } : null)
  // PNG: IHDR right after the signature.
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return ok(be32(b, 16), be32(b, 20))
  // GIF: logical screen size.
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return ok(le16(b, 6), le16(b, 8))
  // WebP: VP8 / VP8L / VP8X.
  if (b[0] === 0x52 && b[1] === 0x49 && b[8] === 0x57 && b[9] === 0x45) {
    const kind = String.fromCharCode(b[12] ?? 0, b[13] ?? 0, b[14] ?? 0, b[15] ?? 0)
    if (kind === 'VP8 ') return ok(le16(b, 26) & 0x3fff, le16(b, 28) & 0x3fff)
    if (kind === 'VP8L') {
      const bits = (b[21] ?? 0) | ((b[22] ?? 0) << 8) | ((b[23] ?? 0) << 16) | ((b[24] ?? 0) << 24)
      return ok((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1)
    }
    if (kind === 'VP8X') return ok(le24(b, 24) + 1, le24(b, 27) + 1)
    return null
  }
  // JPEG: the first start-of-frame marker.
  if (b[0] === 0xff && b[1] === 0xd8) {
    let i = 2
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) {
        i++
        continue
      }
      const marker = b[i + 1] ?? 0
      if (marker === 0xff) {
        i++
        continue
      }
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
        i += 2
        continue
      }
      const len = be16(b, i + 2)
      if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc)
        return ok(be16(b, i + 7), be16(b, i + 5))
      if (len < 2) return null
      i += 2 + len
    }
  }
  return null
}

function svgSize(src: string): { w: number; h: number } | null {
  const comma = src.indexOf(',')
  if (comma < 0) return null
  let text: string
  try {
    const body = src.slice(comma + 1, comma + 1 + 8192)
    text = /;base64$/i.test(src.slice(0, comma)) ? new TextDecoder().decode(fromBase64(body.replace(/[^A-Za-z0-9+/]/g, '').slice(0, 4096))) : decodeURIComponent(body)
  } catch {
    return null
  }
  const tag = /<svg\b[^>]*>/i.exec(text)?.[0]
  if (!tag) return null
  const attr = (name: string) => new RegExp(`\\s${name}\\s*=\\s*["']\\s*([0-9.]+)(px)?\\s*["']`, 'i').exec(tag)?.[1]
  const w = Number(attr('width'))
  const h = Number(attr('height'))
  if (w > 0 && h > 0) return { w: Math.round(w), h: Math.round(h) }
  const vb = /\sviewBox\s*=\s*["']\s*[-0-9.]+[\s,]+[-0-9.]+[\s,]+([0-9.]+)[\s,]+([0-9.]+)/i.exec(tag)
  if (vb && Number(vb[1]) > 0 && Number(vb[2]) > 0) return { w: Math.round(Number(vb[1])), h: Math.round(Number(vb[2])) }
  return null
}

/** `natural` scaled to fit inside `box` less an inset, centred (CSS `object-fit: contain`). */
export function containIn(box: Box, natural: { w: number; h: number }, inset = FRAME_PICTURE_INSET): Box {
  const pad = Math.min(inset, Math.max(0, (Math.min(box.w, box.h) - MIN_SIZE.image.w) / 2))
  const aw = Math.max(1, box.w - pad * 2)
  const ah = Math.max(1, box.h - pad * 2)
  const nw = natural.w > 0 ? natural.w : aw
  const nh = natural.h > 0 ? natural.h : ah
  const k = Math.min(aw / nw, ah / nh)
  const w = Math.max(1, Math.floor(nw * k))
  const h = Math.max(1, Math.floor(nh * k))
  return { x: Math.round(box.x + (box.w - w) / 2), y: Math.round(box.y + (box.h - h) / 2), w, h }
}

// ---- the plan ------------------------------------------------------------------

/** A picture ready for the board: its source and natural size (0 when unknown). */
export interface Picture {
  src: string
  naturalW: number
  naturalH: number
}

export interface PlanContext {
  /** Whether the canvas already has a shape with this id. */
  taken: (id: string) => boolean
  /** Boxes already on the canvas: an import that would land on them moves aside. */
  existing: Box[]
  /** First stacking order to use; everything imported sits above what is there. */
  zBase: number
  /** Resolved pictures by file id; a missing entry means the picture is not available. */
  pictures: ReadonlyMap<string, Picture>
  /** New ids for collisions. */
  newId: () => string
}

export interface ImportPlan {
  /** In write order: frames, their pictures, notes, then arrows. */
  inputs: (ShapeInput & { id: string })[]
  /** Legacy entries (and pictures) that do not come over. */
  skipped: number
  /** File ids of frames whose picture was not available. */
  missingPictures: string[]
  /** Where the imported shapes were moved by, to clear what is there. */
  offset: { x: number; y: number }
}

/** Gap kept between what was on the board and an import moved beside it. */
const BESIDE_GAP = 160

/**
 * Translate legacy shapes into canvas inputs. Ids are kept (arrows resolve
 * through them) unless the canvas already uses one; then the shape gets a
 * fresh id and the arrows that point at it follow. Arrows whose ends do not
 * resolve to a sticky or frame are skipped (Easels did not draw them either).
 */
export function planLegacyImport(shapes: readonly LegacyShape[], ctx: PlanContext): ImportPlan {
  const ids = new Map<string, string>()
  const used = new Set<string>()
  for (const s of shapes) {
    let id = s.id
    if (ctx.taken(id) || used.has(id)) id = ctx.newId()
    ids.set(s.id, id)
    used.add(id)
  }
  const boxes = new Map(shapes.filter(s => s.type !== 'arrow').map(s => [s.id, s] as const))
  const bounds = unionBox([...boxes.values()].map(s => ({ x: s.x, y: s.y, w: Math.max(s.w, 1), h: Math.max(s.h, 1) })))
  const there = unionBox(ctx.existing)
  let offset = { x: 0, y: 0 }
  if (bounds && there && ctx.existing.some(b => boxesOverlap(b, bounds, 24)))
    offset = { x: Math.round(there.x + there.w + BESIDE_GAP - bounds.x), y: Math.round(there.y - bounds.y) }

  const frames: (ShapeInput & { id: string })[] = []
  const pictures: (ShapeInput & { id: string })[] = []
  const notes: (ShapeInput & { id: string })[] = []
  const arrows: (ShapeInput & { id: string })[] = []
  const missingPictures: string[] = []
  let skipped = 0

  for (const s of shapes) {
    const id = ids.get(s.id)!
    if (s.type === 'arrow') {
      const from = s.from ? boxes.get(s.from) : undefined
      const to = s.to ? boxes.get(s.to) : undefined
      if (!from || !to || from.id === to.id) {
        skipped++
        continue
      }
      const label = s.text.replace(/\s+/g, ' ').trim()
      arrows.push({
        id,
        type: 'arrow',
        from: { ref: ids.get(from.id)! },
        to: { ref: ids.get(to.id)! },
        ...(label ? { label } : {}),
      })
      continue
    }
    const min = MIN_SIZE[s.type]
    const box = {
      x: Math.round(s.x + offset.x),
      y: Math.round(s.y + offset.y),
      w: Math.max(min.w, Math.round(s.w || LEGACY_SIZE[s.type].w)),
      h: Math.max(min.h, Math.round(s.h || LEGACY_SIZE[s.type].h)),
    }
    const color = legacyColor(s.color, s.type)
    if (s.type === 'sticky') {
      notes.push({ id, type: 'sticky', ...box, ...(color ? { color } : {}), text: s.text, fontSize: LEGACY_STICKY_FONT })
      continue
    }
    frames.push({ id, type: 'frame', ...box, ...(color ? { color } : {}), title: s.text.replace(/\s+/g, ' ').trim() })
    if (!s.fileId) continue
    const pic = ctx.pictures.get(s.fileId)
    if (!pic) {
      missingPictures.push(s.fileId)
      skipped++
      continue
    }
    const at = containIn(box, { w: pic.naturalW, h: pic.naturalH })
    let pid = `${id}-picture`
    while (ctx.taken(pid) || used.has(pid)) pid = ctx.newId()
    used.add(pid)
    pictures.push({
      id: pid,
      type: 'image',
      ...at,
      src: pic.src,
      naturalW: pic.naturalW || at.w,
      naturalH: pic.naturalH || at.h,
    })
  }
  const inputs = [...frames, ...pictures, ...notes, ...arrows].map((input, i) => ({ ...input, z: ctx.zBase + i }))
  return { inputs, skipped, missingPictures, offset }
}

/** A short, stable fingerprint of a legacy document's bytes (FNV-1a, two lanes). */
export function fingerprint(doc: string | string[]): string {
  const text = Array.isArray(doc) ? doc.join('\n') : doc.replace(/\s/g, '')
  let a = 0x811c9dc5
  let b = 0x01000193 ^ text.length
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i)
    a = Math.imul(a ^ c, 0x01000193)
    b = Math.imul(b ^ c, 0x5bd1e995)
  }
  return `${(a >>> 0).toString(16).padStart(8, '0')}${(b >>> 0).toString(16).padStart(8, '0')}`
}
