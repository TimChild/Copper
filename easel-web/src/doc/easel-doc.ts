/**
 * One easel's Y.Doc, as a factory rather than the wiki app's module singleton
 * (lifted from apps/web/src/modules/wiki/lib/canvas-doc.ts). The schema is a
 * superset of `wiki:canvas` so renderers can be shared later:
 *
 * - `meta` Y.Map: `title`, `createdAt` (Unix seconds, like native's index).
 * - `shapes` Y.Map<id, Y.Map>: `type`, `x`, `y`, `w`, `h`, `color`, `text`
 *   (Y.Text), `by`, plus `from`/`to` (arrows, `shape:<id>`) and `image`
 *   (frames, `file:<fileId>`). Unknown types are dropped by `readShape`, so
 *   P2's `embed` and older clients never break each other.
 */
import * as Y from 'yjs'
import { textSplice } from '../lib/text-diff'

export const DEFAULT_TITLE = 'Untitled Easel'

export const SHAPE_TYPES = ['sticky', 'frame', 'arrow'] as const
export type ShapeType = (typeof SHAPE_TYPES)[number]
export const SHAPE_COLORS = [
  'yellow',
  'pink',
  'blue',
  'green',
  'purple',
  'gray',
  'white',
] as const
export type ShapeColor = (typeof SHAPE_COLORS)[number]

/** Default size per shape type; arrows have none. */
export const SHAPE_SIZE: Record<ShapeType, { w: number; h: number }> = {
  sticky: { w: 200, h: 140 },
  frame: { w: 480, h: 320 },
  arrow: { w: 0, h: 0 },
}

/**
 * Plain read of one entry of `shapes`. In the doc each shape is a Y.Map with
 * these keys (per-property last-writer-wins); `text` is a Y.Text there.
 * `from`/`to` (arrows) are refs: `shape:<shapeId>`. `image` (frames) is
 * `file:<fileId>`; an empty string means the image was removed.
 */
export interface Shape {
  id: string
  type: ShapeType
  x: number
  y: number
  w: number
  h: number
  color: ShapeColor
  text: string
  from?: string
  to?: string
  image?: string
  by?: string
}

export type ShapeInput = { type: ShapeType } & Partial<
  Omit<Shape, 'id' | 'type'>
>
export type ShapePatch = Partial<Omit<Shape, 'id' | 'type' | 'text'>>

const num = (v: unknown, fallback: number) =>
  typeof v === 'number' && Number.isFinite(v) ? v : fallback
const str = (v: unknown) => (typeof v === 'string' ? v : undefined)

/** Tolerant read: agents and older clients may write partial shapes. */
export function readShape(id: string, m: Y.Map<unknown>): Shape | null {
  if (!(m instanceof Y.Map)) return null
  const type = m.get('type') as ShapeType
  if (!SHAPE_TYPES.includes(type)) return null
  const color = m.get('color') as ShapeColor
  const text = m.get('text')
  return {
    id,
    type,
    x: num(m.get('x'), 0),
    y: num(m.get('y'), 0),
    w: num(m.get('w'), SHAPE_SIZE[type].w),
    h: num(m.get('h'), SHAPE_SIZE[type].h),
    color: SHAPE_COLORS.includes(color) ? color : 'yellow',
    text: text instanceof Y.Text ? text.toString() : (str(text) ?? ''),
    from: str(m.get('from')),
    to: str(m.get('to')),
    image: str(m.get('image')) || undefined,
    by: str(m.get('by')),
  }
}

const roundIfNumber = (k: string, v: unknown) =>
  typeof v === 'number' && 'xywh'.includes(k) ? Math.round(v) : v

export interface EaselMeta {
  title: string
  createdAt: number | null
}

export interface EaselDoc {
  doc: Y.Doc
  shapes: Y.Map<Y.Map<unknown>>
  meta: Y.Map<unknown>
  /** Cmd+Z / Shift+Cmd+Z over this person's own shape edits. */
  undo: Y.UndoManager

  getShapesSnapshot(): Map<string, Shape>
  subscribeShapes(onChange: () => void): () => void
  getMeta(): EaselMeta
  subscribeMeta(onChange: () => void): () => void

  /** The title to show and to send with `save`; never empty. */
  title(): string
  setTitle(title: string): void
  /** Fill `createdAt` (and a title) from native's config when missing. */
  ensureMeta(info: { title?: string; createdAt?: number }): void

  createShape(input: ShapeInput): string
  updateShape(id: string, patch: ShapePatch): void
  /** Set positions for many shapes in one transaction. */
  moveShapes(moves: Iterable<[string, { x: number; y: number }]>): void
  setShapeText(id: string, next: string): void
  deleteShape(id: string): void
  deleteShapes(ids: Iterable<string>): void

  destroy(): void
}

/** The sentinel origin for the first `applyUpdate` of saved state. */
export const LOAD_ORIGIN = 'easel:load'

export function createEaselDoc(doc = new Y.Doc()): EaselDoc {
  const shapes = doc.getMap<Y.Map<unknown>>('shapes')
  const meta = doc.getMap<unknown>('meta')

  let shapesSnapshot = new Map<string, Shape>()
  const readShapes = () => {
    shapesSnapshot = new Map()
    shapes.forEach((m, id) => {
      const shape = readShape(id, m)
      if (shape) shapesSnapshot.set(id, shape)
    })
  }
  readShapes()
  // Rebuilds every shape per change; diff by event keys if boards get big.
  shapes.observeDeep(readShapes)

  let metaSnapshot: EaselMeta = readMeta()
  function readMeta(): EaselMeta {
    const title = str(meta.get('title'))?.trim()
    const createdAt = meta.get('createdAt')
    return {
      title: title || DEFAULT_TITLE,
      createdAt: typeof createdAt === 'number' ? createdAt : null,
    }
  }
  meta.observe(() => {
    metaSnapshot = readMeta()
  })

  const undo = new Y.UndoManager([shapes], { captureTimeout: 500 })

  return {
    doc,
    shapes,
    meta,
    undo,

    getShapesSnapshot: () => shapesSnapshot,
    subscribeShapes(onChange) {
      shapes.observeDeep(onChange)
      return () => shapes.unobserveDeep(onChange)
    },
    getMeta: () => metaSnapshot,
    subscribeMeta(onChange) {
      meta.observe(onChange)
      return () => meta.unobserve(onChange)
    },

    title: () => metaSnapshot.title,
    setTitle(title) {
      const next = title.trim()
      if (next === (str(meta.get('title')) ?? '')) return
      meta.set('title', next)
    },
    ensureMeta(info) {
      doc.transact(() => {
        if (!str(meta.get('title')) && info.title?.trim())
          meta.set('title', info.title.trim())
        if (typeof meta.get('createdAt') !== 'number')
          meta.set('createdAt', info.createdAt ?? Date.now() / 1000)
      })
    },

    /** Add a shape; returns its id. Unset size/colour get the type's defaults. */
    createShape(input) {
      const id = crypto.randomUUID()
      const { text = '', ...props } = input
      const m = new Y.Map<unknown>()
      const full: Record<string, unknown> = {
        ...(input.type === 'arrow'
          ? {}
          : { ...SHAPE_SIZE[input.type], color: 'yellow' }),
        ...props,
      }
      for (const [k, v] of Object.entries(full))
        if (v !== undefined) m.set(k, roundIfNumber(k, v))
      m.set('text', new Y.Text(text))
      shapes.set(id, m)
      return id
    },

    /** Set only the given keys, so concurrent edits to other props survive. */
    updateShape(id, patch) {
      const m = shapes.get(id)
      if (!m) return
      doc.transact(() => {
        for (const [k, v] of Object.entries(patch))
          if (v !== undefined) m.set(k, roundIfNumber(k, v))
      })
    },

    moveShapes(moves) {
      doc.transact(() => {
        for (const [id, p] of moves) {
          const m = shapes.get(id)
          if (!m) continue
          m.set('x', Math.round(p.x))
          m.set('y', Math.round(p.y))
        }
      })
    },

    /** Replace a shape's text with the minimal splice, merging with peers. */
    setShapeText(id, next) {
      const m = shapes.get(id)
      if (!m) return
      doc.transact(() => {
        let text = m.get('text')
        if (!(text instanceof Y.Text)) {
          text = new Y.Text()
          m.set('text', text)
        }
        const t = text as Y.Text
        const { index, remove, insert } = textSplice(t.toString(), next)
        if (remove) t.delete(index, remove)
        if (insert) t.insert(index, insert)
      })
    },

    /** Delete a shape and every arrow that ends on it. */
    deleteShape(id) {
      this.deleteShapes([id])
    },

    deleteShapes(ids) {
      const gone = new Set(ids)
      const refs = new Set([...gone].map(id => `shape:${id}`))
      doc.transact(() => {
        for (const id of gone) shapes.delete(id)
        shapes.forEach((m, other) => {
          const from = m.get('from')
          const to = m.get('to')
          if (
            (typeof from === 'string' && refs.has(from)) ||
            (typeof to === 'string' && refs.has(to))
          )
            shapes.delete(other)
        })
      })
    },

    destroy() {
      undo.destroy()
      doc.destroy()
    },
  }
}
