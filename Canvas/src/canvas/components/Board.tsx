/**
 * The board: pan/zoom, the pointer state machine (select, marquee, move,
 * resize, draw frames and arrows, reattach arrow ends), keyboard shortcuts,
 * clipboard, drag-and-drop, and the layer stack that draws it all.
 */
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type DragEvent as ReactDragEvent,
  type PointerEvent as ReactPointerEvent,
} from 'react'
import { controller, type Session } from '../../controller'
import { hasNativeHost, postToHost } from '../../host-bridge'
import { findFreeSpot, occupied } from '../../placement'
import { frameChildren, hostOf } from '../../ops'
import { arrowBox, arrowPath, type ArrowPath } from '../arrows'
import { readAgents } from '../agents'
import { LOCAL, newId, type ShapeInput } from '../doc'
import {
  boxFromPoints,
  boxesOverlap,
  containsBox,
  containsPoint,
  fitBoxes,
  nearestSide,
  screenToWorld,
  unionBox,
  visibleWorld,
  zoomAt,
  zoomTo,
  type Box,
  type Point,
  type Side,
  type View,
} from '../geometry'
import { imageFile, imageFromFile, imageFromUrl, imageSizeFor, isUrlText, looksLikeImageUrl, urlFrom } from '../images'
import { MIN_SIZE, isResizable, resizeBox, resizeBoxKeepAspect, type Handle } from '../resize'
import { arrowLabelBox, revealView, type SearchResult } from '../search'
import { SHAPE_SIZE, isRefEndpoint, type Endpoint, type NamedColor, type Shape, type ShapeColor } from '../types'
import { useLiveAgents, usePeers } from '../use-presence'
import { useBoardSearch } from '../use-search'
import { useViewFlight } from '../use-view-flight'
import {
  AuthorChip,
  CompactBar,
  EmptyHint,
  LinkPrompt,
  SelectionBar,
  ShortcutsSheet,
  TOOL_KEYS,
  TitleBar,
  Toasts,
  Toolbar,
  TopRight,
  ZoomBar,
  type Tool,
  type Toast,
} from './Chrome'
import { BoardContext, type BoardActions, type EditField } from './context'
import {
  AgentCursors,
  AnchorDots,
  ArrowDraft,
  ArrowEndHandles,
  Marquee,
  PeerCursors,
  ResizeHandles,
  SearchRings,
  SelectionOutlines,
  type RingPlace,
} from './Overlays'
import { SearchBox } from './SearchBox'
import { ArrowLabel, ArrowLayer, FrameView, ImageView, LinkView, StickyView, TextView, type DrawnArrow } from './Shapes'
import { cn } from './ui'

type Gesture =
  | { kind: 'pan'; start: Point; view: View }
  | {
      kind: 'move'
      start: Point
      startScreen: Point
      origins: Map<string, Shape>
      moved: boolean
      hit: string
      last: number
      next?: Map<string, Partial<Shape>>
    }
  | { kind: 'resize'; id: string; handle: Handle; start: Point; box: Box; type: Shape['type']; at?: Box; last: number }
  | { kind: 'marquee'; start: Point; startScreen: Point; base: string[]; additive: boolean; frameClick?: string; moved: boolean }
  | { kind: 'frame'; start: Point; startScreen: Point; box?: Box }
  | { kind: 'arrow'; from: Endpoint; startScreen: Point; moved: boolean }
  | { kind: 'arrow-end'; id: string; end: 'from' | 'to'; other: Endpoint | undefined }

interface Draft {
  from: Endpoint
  to: Endpoint
  hover: { id: string; side?: Side } | null
}

interface ClipShape extends ShapeInput {
  id: string
}

const CLIP_TYPE = 'application/x-copper-canvas'
const SEND_MS = 50
const DOUBLE_MS = 350

const isTextField = (el: EventTarget | null) =>
  el instanceof HTMLElement && (el.isContentEditable || el.closest('input, textarea, select') !== null)

const sortZ = (a: Shape, b: Shape) => a.z - b.z || a.createdAt - b.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)

export function Board({ session }: { session: Session }) {
  const { store, awareness, cfg } = session
  const readOnly = cfg.readOnly
  const me = cfg.me
  const shapes = useSyncExternalStore(store.subscribe, store.getShapes)
  const selectionList = useSyncExternalStore(controller.subscribeSelection, controller.getSelection)
  const selection = useMemo(() => new Set(selectionList), [selectionList])
  const status = useSyncExternalStore(controller.subscribe, () => session.status)
  const peers = usePeers(awareness)
  const agents = useLiveAgents(store.agents)

  const viewport = useRef<HTMLDivElement>(null)
  const [size, setSize] = useState({ w: 0, h: 0 })
  const [view, setView] = useState<View>({ x: 0, y: 0, z: 1 })
  const flight = useViewFlight(view, setView, viewport)
  const [tool, setToolState] = useState<Tool>('select')
  const [noteColor, setNoteColor] = useState<NamedColor>('yellow')
  const [editing, setEditing] = useState<{ id: string; field: EditField } | null>(null)
  const [drag, setDrag] = useState<Map<string, Partial<Shape>> | null>(null)
  const [marquee, setMarquee] = useState<Box | null>(null)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [pendingFrom, setPendingFrom] = useState<Endpoint | null>(null)
  const [frameDraft, setFrameDraft] = useState<Box | null>(null)
  /** The arrow whose end is being dragged: its draft stands in for it. */
  const [reEnding, setReEnding] = useState<string | null>(null)
  const [hover, setHover] = useState<string | null>(null)
  const [arrowHover, setArrowHover] = useState<{ id: string; side?: Side } | null>(null)
  const [space, setSpace] = useState(false)
  const [panning, setPanning] = useState(false)
  const [linkAt, setLinkAt] = useState<Point | null>(null)
  const [help, setHelp] = useState(false)
  const [toasts, setToasts] = useState<Toast[]>([])
  const [history, setHistory] = useState({ undo: false, redo: false })
  const gesture = useRef<Gesture | null>(null)
  const pointer = useRef<Point | null>(null)
  const fileInput = useRef<HTMLInputElement>(null)
  const imageAt = useRef<{ frame: string | null; at: Point; free?: boolean } | null>(null)
  const lastDown = useRef({ id: '', at: 0, p: { x: 0, y: 0 } })
  const lastCursor = useRef(0)
  /** Set when a pointerdown opened an editor: its mousedown must not refocus the board. */
  const keepFocus = useRef(false)
  const clip = useRef<{ text: string; shapes: ClipShape[] } | null>(null)
  const pasteCount = useRef(0)
  const viewRef = useRef(view)
  const sizeRef = useRef(size)
  useEffect(() => {
    viewRef.current = view
    sizeRef.current = size
    controller.setViewInfo({ view, width: size.w, height: size.h })
  }, [view, size])

  const select = useCallback((ids: Iterable<string>) => controller.setSelection([...ids]), [])
  const setTool = useCallback((next: Tool) => {
    setToolState(next)
    setPendingFrom(null)
    setDraft(null)
  }, [])

  const toast = useCallback((text: string, tone: Toast['tone'] = 'info', ms = 2600) => {
    const id = Date.now() + Math.random()
    setToasts(t => [...t.slice(-2), { id, text, tone }])
    setTimeout(() => setToasts(t => t.filter(x => x.id !== id)), ms)
  }, [])

  // ---- geometry of what is on the board --------------------------------------

  /** A shape with the local drag/resize applied, so it moves at frame rate. */
  const placed = useCallback(
    (shape: Shape): Shape => {
      const o = drag?.get(shape.id)
      return o ? { ...shape, ...o } : shape
    },
    [drag]
  )

  const live = useMemo(() => {
    const list = [...shapes.values()].map(placed).sort(sortZ)
    const byId = new Map(list.map(s => [s.id, s] as const))
    const boxOf = (id: string): Box | null => {
      const s = byId.get(id)
      return s && s.type !== 'arrow' ? s : null
    }
    const arrows: DrawnArrow[] = []
    for (const s of list) {
      if (s.type !== 'arrow') continue
      const path = arrowPath(s, boxOf)
      if (path) arrows.push({ shape: s, path })
    }
    return { list, byId, boxOf, arrows, arrowById: new Map(arrows.map(a => [a.shape.id, a.path] as const)) }
  }, [shapes, placed])

  /** The box a shape occupies: its own, or its path's bounds for an arrow. */
  const boundsOf = useCallback(
    (id: string): Box | null => {
      const s = live.byId.get(id)
      if (!s) return null
      if (s.type !== 'arrow') return s
      const path = live.arrowById.get(id)
      return path ? arrowBox(path) : null
    },
    [live]
  )

  const center0 = (): Point => {
    const v = viewRef.current
    const { w, h } = sizeRef.current
    return screenToWorld(v, { x: w / 2, y: h / 2 })
  }

  // ---- size, first fit, controller handle -----------------------------------

  const fitted = useRef(false)
  useLayoutEffect(() => {
    const el = viewport.current
    if (!el) return
    const measure = () => {
      const w = el.clientWidth
      const h = el.clientHeight
      setSize(prev => (prev.w === w && prev.h === h ? prev : { w, h }))
      if (!fitted.current && w > 0 && h > 0) {
        fitted.current = true
        const boxes = [...store.getShapes().values()].filter(s => s.type !== 'arrow')
        setView(boxes.length ? fitBoxes(boxes, w, h, 96, 1) : { x: w / 2, y: h / 2, z: 1 })
      }
    }
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    el.focus({ preventScroll: true })
    return () => ro.disconnect()
  }, [store])

  const fitAll = useCallback(() => {
    const boxes = [...live.list.filter(s => s.type !== 'arrow'), ...live.arrows.map(a => arrowBox(a.path))]
    const { w, h } = sizeRef.current
    flight.fly(boxes.length ? fitBoxes(boxes, w, h, 96, 1) : { x: w / 2, y: h / 2, z: 1 })
  }, [live, flight])

  const zoomToIds = useCallback(
    (ids: readonly string[]) => {
      const boxes = ids.map(boundsOf).filter((b): b is Box => !!b)
      const u = unionBox(boxes)
      if (!u) return false
      const { w, h } = sizeRef.current
      const target = ids.length === 1 ? revealView(u, viewRef.current, w, h, { padding: 96 }) : fitBoxes([u], w, h, 96, 1.5)
      flight.fly(target)
      return true
    },
    [boundsOf, flight]
  )

  const zoomRef = useRef(zoomToIds)
  useEffect(() => {
    zoomRef.current = zoomToIds
  })
  useEffect(() => {
    controller.attachBoard({ zoomTo: ids => zoomRef.current(ids) })
    return () => controller.attachBoard(null)
  }, [])

  // ---- undo state -------------------------------------------------------------

  useEffect(() => {
    const u = store.undo
    const sync = () => setHistory({ undo: u.canUndo(), redo: u.canRedo() })
    u.on('stack-item-added', sync)
    u.on('stack-item-popped', sync)
    u.on('stack-cleared', sync)
    sync()
    return () => {
      u.off('stack-item-added', sync)
      u.off('stack-item-popped', sync)
      u.off('stack-cleared', sync)
    }
  }, [store])

  const undo = useCallback(() => {
    setEditing(null)
    store.undo.undo()
    controller.setSelection(controller.getSelection())
  }, [store])
  const redo = useCallback(() => {
    setEditing(null)
    store.undo.redo()
    controller.setSelection(controller.getSelection())
  }, [store])

  // ---- creating things --------------------------------------------------------

  const takenBoxes = useCallback(
    (except?: string) => [...store.getShapes().values()].filter(s => s.type !== 'arrow' && s.id !== except).map(occupied),
    [store]
  )

  const createAt = useCallback(
    (input: ShapeInput, at: Point, { centered = true, free = false } = {}): string => {
      const w = input.w ?? SHAPE_SIZE[input.type].w
      const h = input.h ?? SHAPE_SIZE[input.type].h
      let pos = centered ? { x: at.x - w / 2, y: at.y - h / 2 } : at
      if (free) pos = findFreeSpot(takenBoxes(), { w, h }, { x: pos.x + w / 2, y: pos.y + h / 2 }, { gap: 20, step: 24 })
      store.undo.stopCapturing()
      const id = store.create({ by: me.name, ...input, x: pos.x, y: pos.y, w, h }, LOCAL)
      store.undo.stopCapturing()
      return id
    },
    [store, me.name, takenBoxes]
  )

  const startEdit = useCallback(
    (id: string) => {
      if (readOnly) return
      const s = store.get(id)
      if (!s) return
      const field: EditField = s.type === 'frame' ? 'title' : s.type === 'arrow' ? 'label' : 'text'
      if (s.type === 'image' || s.type === 'link') return
      select([id])
      setEditing({ id, field })
    },
    [store, readOnly, select]
  )

  const openUrl = useCallback((url: string) => {
    postToHost({ type: 'openUrl', url })
    if (!hasNativeHost()) window.open(url, '_blank', 'noopener,noreferrer')
  }, [])

  const placeImage = useCallback(
    async (file: Blob, into: string | null, at: Point, free = false) => {
      const slow = setTimeout(() => toast('Adding the image…'), 400)
      try {
        const img = await imageFromFile(file)
        store.undo.stopCapturing()
        if (into && store.get(into)?.type === 'frame') {
          store.update(into, { image: img }, LOCAL)
          select([into])
        } else {
          const { w, h } = imageSizeFor(img.naturalW, img.naturalH)
          const id = createAt({ type: 'image', src: img.src, naturalW: img.naturalW, naturalH: img.naturalH, w, h }, at, { free })
          select([id])
        }
      } catch (error) {
        toast(error instanceof Error ? error.message : 'The image could not be added.', 'error', 4000)
      } finally {
        clearTimeout(slow)
      }
    },
    [store, createAt, select, toast]
  )

  const addLink = useCallback(
    (url: string, at: Point, title?: string) => {
      const id = createAt(
        { type: 'link', url, title: title?.trim() || hostOf(url), color: 'white', w: SHAPE_SIZE.link.w, h: SHAPE_SIZE.link.h },
        at,
        { free: true }
      )
      select([id])
      return id
    },
    [createAt, select]
  )

  const addImageUrl = useCallback(
    async (url: string, at: Point) => {
      try {
        const img = await imageFromUrl(url)
        const { w, h } = imageSizeFor(img.naturalW, img.naturalH)
        select([createAt({ type: 'image', src: url, naturalW: img.naturalW, naturalH: img.naturalH, w, h }, at)])
      } catch {
        addLink(url, at)
      }
    },
    [createAt, select, addLink]
  )

  const addText = useCallback(
    (text: string, at: Point) => {
      const trimmed = text.trim()
      if (!trimmed) return
      if (isUrlText(trimmed)) {
        if (looksLikeImageUrl(trimmed)) void addImageUrl(trimmed, at)
        else addLink(trimmed, at)
        return
      }
      const long = trimmed.length > 160
      const id = createAt({ type: 'sticky', text: trimmed, color: noteColor, ...(long ? { w: 280, h: 280 } : {}) }, at, { free: true })
      select([id])
    },
    [createAt, select, noteColor, addLink, addImageUrl]
  )

  /** ⌘Enter in a sticky: a fresh one beside it (or below), same colour, editing. */
  const sibling = useCallback(
    (id: string, dir: 'right' | 'down') => {
      const s = store.get(id)
      if (!s) return
      const gap = 24
      const want = dir === 'right' ? { x: s.x + s.w + gap, y: s.y } : { x: s.x, y: s.y + s.h + gap }
      const spot = findFreeSpot(takenBoxes(), { w: s.w, h: s.h }, { x: want.x + s.w / 2, y: want.y + s.h / 2 }, { gap: 16, step: 16 })
      const next = createAt({ type: s.type === 'text' ? 'text' : 'sticky', color: s.color, w: s.w, h: s.h, fontSize: s.fontSize }, spot, {
        centered: false,
      })
      select([next])
      setEditing({ id: next, field: 'text' })
      const { w, h } = sizeRef.current
      const box = { x: spot.x, y: spot.y, w: s.w, h: s.h }
      const v = viewRef.current
      const vis = visibleWorld(v, w, h)
      if (!containsBox(vis, box)) flight.fly(revealView(box, v, w, h, { padding: 120 }))
    },
    [store, takenBoxes, createAt, select, flight]
  )

  const endEdit = useCallback(
    (id: string) => {
      setEditing(e => (e?.id === id ? null : e))
      // An empty text shape left behind is noise: drop it.
      const s = store.get(id)
      if (s?.type === 'text' && !s.text.trim()) {
        store.remove([id], LOCAL)
        controller.setSelection([])
      }
      viewport.current?.focus({ preventScroll: true })
    },
    [store]
  )

  const autoHeight = useCallback(
    (id: string, h: number) => {
      const s = store.get(id)
      if (!s || s.type !== 'text') return
      const next = Math.max(MIN_SIZE.text.h, Math.ceil(h))
      if (Math.abs(next - s.h) > 1) store.update(id, { h: next }, LOCAL, false)
    },
    [store]
  )

  const actions = useMemo<BoardActions>(
    () => ({ store, me, readOnly, openUrl, endEdit, sibling, autoHeight }),
    [store, me, readOnly, openUrl, endEdit, sibling, autoHeight]
  )

  // ---- acting on the selection ------------------------------------------------

  const selected = useMemo(() => selectionList.map(id => live.byId.get(id)).filter((s): s is Shape => !!s), [selectionList, live])

  const removeSelected = useCallback(() => {
    if (readOnly || selectionList.length === 0) return
    store.undo.stopCapturing()
    store.remove(selectionList, LOCAL)
    store.undo.stopCapturing()
    setEditing(null)
    select([])
  }, [store, selectionList, select, readOnly])

  const recolor = useCallback(
    (color: ShapeColor) => {
      store.undo.stopCapturing()
      store.transact(() => {
        for (const s of selected) if (s.type !== 'image') store.update(s.id, { color })
      })
      if (selected.some(s => s.type === 'sticky') && typeof color === 'string' && !color.startsWith('#'))
        setNoteColor(color as NamedColor)
    },
    [store, selected]
  )

  const restack = useCallback(
    (front: boolean) => {
      const ordered = [...selected].sort(sortZ)
      store.transact(() => {
        const base = front ? store.maxZ() + 1 : store.minZ() - ordered.length
        ordered.forEach((s, i) => store.update(s.id, { z: base + i }, LOCAL, false))
      })
    },
    [store, selected]
  )

  /** Everything that travels with the selection: frames carry what sits inside them. */
  const moving = useCallback(
    (ids: Iterable<string>): Map<string, Shape> => {
      const out = new Map<string, Shape>()
      const all = live.list
      for (const id of ids) {
        const s = live.byId.get(id)
        if (!s) continue
        out.set(id, s)
        if (s.type === 'frame') for (const c of frameChildren(all, s)) out.set(c.id, c)
      }
      return out
    },
    [live]
  )

  const shifted = (s: Shape, dx: number, dy: number): Partial<Shape> => {
    if (s.type !== 'arrow') return { x: Math.round(s.x + dx), y: Math.round(s.y + dy) }
    const move = (e: Endpoint | undefined) => (e && !isRefEndpoint(e) ? { x: Math.round(e.x + dx), y: Math.round(e.y + dy) } : e)
    return { from: move(s.from), to: move(s.to) }
  }

  const nudge = useCallback(
    (dx: number, dy: number) => {
      const set = moving(selectionList)
      store.moveMany([...set.values()].map(s => [s.id, shifted(s, dx, dy)] as [string, Point]), LOCAL)
    },
    [moving, selectionList, store]
  )

  const clipFor = useCallback(
    (ids: readonly string[]): ClipShape[] => {
      const set = new Set(moving(ids).keys())
      for (const id of store.arrowsTouching(set)) {
        const a = store.get(id)
        if (a && isRefEndpoint(a.from) && isRefEndpoint(a.to) && set.has(a.from.ref) && set.has(a.to.ref)) set.add(id)
      }
      return [...set].map(id => store.toJSON(id)).filter((s): s is ClipShape => !!s)
    },
    [moving, store]
  )

  /** Paste shapes with fresh ids, arrows rewired to the copies, centred on `at` (or offset). */
  const pasteShapes = useCallback(
    (items: ClipShape[], at: Point | null) => {
      if (readOnly || items.length === 0) return
      const boxes = items.filter(s => s.type !== 'arrow' && typeof s.x === 'number')
      const u = unionBox(boxes.map(s => ({ x: s.x ?? 0, y: s.y ?? 0, w: s.w ?? 0, h: s.h ?? 0 })))
      pasteCount.current++
      const off = at && u ? { x: at.x - (u.x + u.w / 2), y: at.y - (u.y + u.h / 2) } : { x: 24 * pasteCount.current, y: 24 * pasteCount.current }
      const ids = new Map(items.map(s => [s.id, newId()] as const))
      const remap = (e: unknown): Endpoint | undefined => {
        if (!e || typeof e !== 'object') return undefined
        const end = e as Endpoint
        if (isRefEndpoint(end)) {
          const to = ids.get(end.ref)
          if (to) return { ...end, ref: to }
          return store.get(end.ref) ? end : undefined
        }
        return { x: end.x + off.x, y: end.y + off.y }
      }
      const z = store.maxZ() + 1
      store.undo.stopCapturing()
      store.transact(() => {
        items.forEach((s, i) => {
          const { id: oldId, createdAt: _c, updatedAt: _u, ...rest } = s as ClipShape & { createdAt?: number; updatedAt?: number }
          void _c
          void _u
          const input: ShapeInput = { ...rest, id: ids.get(oldId), z: z + i, by: me.name }
          if (s.type === 'arrow') {
            const from = remap(s.from)
            const to = remap(s.to)
            if (!from || !to) return
            input.from = from
            input.to = to
          } else {
            input.x = (s.x ?? 0) + off.x
            input.y = (s.y ?? 0) + off.y
          }
          store.create(input, LOCAL)
        })
      })
      store.undo.stopCapturing()
      select([...ids.values()].filter(id => store.shapes.has(id)))
    },
    [readOnly, store, me.name, select]
  )

  const duplicate = useCallback(() => {
    pasteCount.current = 0
    pasteShapes(clipFor(selectionList), null)
  }, [clipFor, pasteShapes, selectionList])

  // ---- hit testing --------------------------------------------------------------

  /** The topmost box under a world point (not arrows); frames only when nothing else is there. */
  const shapeAt = useCallback(
    (p: Point, except?: string): Shape | null => {
      const pad = 6 / viewRef.current.z
      const hit = (s: Shape) => containsPoint({ x: s.x - pad, y: s.y - pad, w: s.w + pad * 2, h: s.h + pad * 2 }, p)
      for (let i = live.list.length - 1; i >= 0; i--) {
        const s = live.list[i]!
        if (s.type === 'arrow' || s.type === 'frame' || s.id === except) continue
        if (hit(s)) return s
      }
      let best: Shape | null = null
      for (const s of live.list)
        if (s.type === 'frame' && s.id !== except && hit(s) && (!best || s.w * s.h < best.w * best.h)) best = s
      return best
    },
    [live]
  )

  /** Where an arrow end lands at `p`: a shape's side (near its midpoint), the shape, or the point. */
  const endAt = useCallback(
    (p: Point, except?: string): { end: Endpoint; hover: Draft['hover'] } => {
      const s = shapeAt(p, except)
      if (!s) return { end: { x: Math.round(p.x), y: Math.round(p.y) }, hover: null }
      const near = nearestSide(s, p)
      const snap = near.distance < Math.max(18, 22 / viewRef.current.z)
      return snap ? { end: { ref: s.id, side: near.side }, hover: { id: s.id, side: near.side } } : { end: { ref: s.id }, hover: { id: s.id } }
    },
    [shapeAt]
  )

  const draftPath = useCallback(
    (d: Draft): ArrowPath | null => arrowPath({ from: d.from, to: d.to }, live.boxOf),
    [live]
  )

  const localPoint = (e: { clientX: number; clientY: number }): Point => {
    const rect = viewport.current!.getBoundingClientRect()
    return { x: e.clientX - rect.left, y: e.clientY - rect.top }
  }

  // ---- pointer --------------------------------------------------------------------

  const doubleClick = (hitId: string | null, part: string | null, c: Point) => {
    keepFocus.current = true
    if (!hitId) {
      if (readOnly || tool !== 'select') return
      const id = createAt({ type: 'sticky', color: noteColor }, c)
      select([id])
      setEditing({ id, field: 'text' })
      return
    }
    const s = live.byId.get(hitId)
    if (!s) return
    if (s.type === 'link') {
      if (s.url) openUrl(s.url)
      return
    }
    if (s.type === 'frame' && part !== 'frame-title' && s.image) return
    startEdit(hitId)
  }

  const createArrow = (from: Endpoint, to: Endpoint) => {
    if (isRefEndpoint(from) && isRefEndpoint(to) && from.ref === to.ref) return
    const id = createAt({ type: 'arrow', from, to, color: 'gray' }, { x: 0, y: 0 }, { centered: false })
    select([id])
    setTool('select')
  }

  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.button === 2) return
    const target = e.target as Element
    if (!isTextField(target)) viewport.current?.focus({ preventScroll: true })
    const p = localPoint(e)
    const c = screenToWorld(view, p)
    flight.cancel()
    setLinkAt(null)
    if (e.button === 1 || tool === 'hand' || space) {
      e.preventDefault()
      e.currentTarget.setPointerCapture(e.pointerId)
      gesture.current = { kind: 'pan', start: p, view }
      setPanning(true)
      return
    }
    if (e.button !== 0) return
    const hitId = target.closest('[data-id]')?.getAttribute('data-id') ?? null
    const part = target.closest('[data-part]')?.getAttribute('data-part') ?? null
    if (editing && hitId === editing.id) return

    // Our own double-click: pointer capture would hide the target from dblclick.
    const now = performance.now()
    const prev = lastDown.current
    const twice = now - prev.at < DOUBLE_MS && prev.id === (hitId ?? '') && Math.hypot(prev.p.x - p.x, prev.p.y - p.y) < 8
    lastDown.current = twice ? { id: '', at: 0, p } : { id: hitId ?? '', at: now, p }
    if (twice && tool === 'select') {
      gesture.current = null
      doubleClick(hitId, part, c)
      return
    }

    e.currentTarget.setPointerCapture(e.pointerId)
    gesture.current = null

    if (!readOnly && pendingFrom) {
      const { end } = endAt(c, isRefEndpoint(pendingFrom) ? pendingFrom.ref : undefined)
      createArrow(pendingFrom, end)
      setPendingFrom(null)
      setDraft(null)
      return
    }

    if (!readOnly && (tool === 'sticky' || tool === 'text')) {
      keepFocus.current = true
      const id =
        tool === 'sticky'
          ? createAt({ type: 'sticky', color: noteColor }, c)
          : createAt({ type: 'text', color: 'gray' }, { x: c.x, y: c.y - 16 }, { centered: false })
      setTool('select')
      select([id])
      setEditing({ id, field: 'text' })
      return
    }
    if (!readOnly && tool === 'frame') {
      gesture.current = { kind: 'frame', start: c, startScreen: p }
      return
    }
    if (!readOnly && tool === 'arrow') {
      const { end, hover } = endAt(c)
      gesture.current = { kind: 'arrow', from: end, startScreen: p, moved: false }
      setDraft({ from: end, to: { x: c.x, y: c.y }, hover })
      return
    }
    if (!readOnly && tool === 'link') {
      setLinkAt(c)
      setTool('select')
      return
    }
    if (!readOnly && tool === 'image') {
      imageAt.current = { frame: hitId && live.byId.get(hitId)?.type === 'frame' ? hitId : null, at: c }
      fileInput.current?.click()
      setTool('select')
      return
    }

    // Select tool.
    if (hitId && live.byId.has(hitId)) {
      const s = live.byId.get(hitId)!
      if (s.type === 'frame' && part === 'frame-body' && !s.image && !selection.has(hitId)) {
        if (!e.shiftKey) select([])
        gesture.current = { kind: 'marquee', start: c, startScreen: p, base: e.shiftKey ? selectionList.slice() : [], additive: e.shiftKey, frameClick: hitId, moved: false }
        return
      }
      let ids = selectionList.slice()
      if (e.shiftKey) {
        if (selection.has(hitId)) {
          select(ids.filter(id => id !== hitId))
          return
        }
        ids = [...ids, hitId]
      } else if (!selection.has(hitId)) ids = [hitId]
      select(ids)
      if (readOnly) return
      store.undo.stopCapturing()
      gesture.current = { kind: 'move', start: c, startScreen: p, origins: moving(ids), moved: false, hit: hitId, last: 0 }
      return
    }
    if (!e.shiftKey) select([])
    gesture.current = { kind: 'marquee', start: c, startScreen: p, base: e.shiftKey ? selectionList.slice() : [], additive: e.shiftKey, moved: false }
  }

  const startResize = (s: Shape, handle: Handle, e: ReactPointerEvent<HTMLElement>) => {
    if (e.button !== 0 || readOnly || !isResizable(s.type)) return
    e.stopPropagation()
    viewport.current?.setPointerCapture(e.pointerId)
    store.undo.stopCapturing()
    gesture.current = {
      kind: 'resize',
      id: s.id,
      handle,
      type: s.type,
      start: screenToWorld(view, localPoint(e)),
      box: { x: s.x, y: s.y, w: s.w, h: s.h },
      last: 0,
    }
  }

  const startEndDrag = (s: Shape, end: 'from' | 'to', e: ReactPointerEvent<HTMLElement>) => {
    if (e.button !== 0 || readOnly) return
    e.stopPropagation()
    viewport.current?.setPointerCapture(e.pointerId)
    store.undo.stopCapturing()
    gesture.current = { kind: 'arrow-end', id: s.id, end, other: end === 'from' ? s.to : s.from }
    setReEnding(s.id)
    const p = screenToWorld(view, localPoint(e))
    setDraft({ from: (end === 'from' ? s.to : s.from) ?? p, to: p, hover: null })
  }

  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const p = localPoint(e)
    pointer.current = p
    const c = screenToWorld(view, p)
    const now = performance.now()
    if (now - lastCursor.current > 33) {
      lastCursor.current = now
      awareness.setLocalStateField('cursor', { x: Math.round(c.x), y: Math.round(c.y) })
    }
    const g = gesture.current
    if (!g) {
      if (pendingFrom) {
        const { end, hover: h } = endAt(c, isRefEndpoint(pendingFrom) ? pendingFrom.ref : undefined)
        setDraft({ from: pendingFrom, to: end, hover: h })
      } else if (tool === 'arrow' && !readOnly) {
        const s = shapeAt(c)
        if (s) {
          const near = nearestSide(s, c)
          const side = near.distance < Math.max(18, 22 / view.z) ? near.side : undefined
          setArrowHover(prev => (prev?.id === s.id && prev.side === side ? prev : { id: s.id, side }))
        } else setArrowHover(null)
      }
      const id = (e.target as Element).closest?.('[data-id]')?.getAttribute('data-id') ?? null
      setHover(prev => (prev === id ? prev : id))
      return
    }
    switch (g.kind) {
      case 'pan':
        setView({ ...g.view, x: g.view.x + p.x - g.start.x, y: g.view.y + p.y - g.start.y })
        return
      case 'move': {
        if (!g.moved && Math.hypot(p.x - g.startScreen.x, p.y - g.startScreen.y) < 3) return
        g.moved = true
        const dx = c.x - g.start.x
        const dy = c.y - g.start.y
        const next = new Map<string, Partial<Shape>>()
        for (const s of g.origins.values()) next.set(s.id, shifted(s, dx, dy))
        g.next = next
        setDrag(next)
        if (now - g.last > SEND_MS) {
          g.last = now
          store.moveMany([...next.entries()] as [string, Record<string, unknown>][], LOCAL)
        }
        return
      }
      case 'resize': {
        const min = MIN_SIZE[g.type as keyof typeof MIN_SIZE]
        const delta = { x: c.x - g.start.x, y: c.y - g.start.y }
        const keep = g.type === 'image' ? !e.shiftKey : e.shiftKey
        const box = keep ? resizeBoxKeepAspect(g.box, g.handle, delta, min) : resizeBox(g.box, g.handle, delta, min)
        g.at = box
        setDrag(new Map([[g.id, box]]))
        if (now - g.last > SEND_MS) {
          g.last = now
          store.update(g.id, box, LOCAL)
        }
        return
      }
      case 'marquee': {
        if (!g.moved && Math.hypot(p.x - g.startScreen.x, p.y - g.startScreen.y) < 3) return
        g.moved = true
        const box = boxFromPoints(g.start, c)
        setMarquee(box)
        const hits: string[] = []
        for (const s of live.list) {
          if (s.type === 'arrow') {
            const path = live.arrowById.get(s.id)
            if (path && containsBox(box, arrowBox(path))) hits.push(s.id)
          } else if (s.type === 'frame' ? containsBox(box, s) : boxesOverlap(box, s)) hits.push(s.id)
        }
        select(g.additive ? [...new Set([...g.base, ...hits])] : hits)
        return
      }
      case 'frame': {
        g.box = boxFromPoints(g.start, c)
        setFrameDraft(g.box)
        return
      }
      case 'arrow': {
        if (!g.moved && Math.hypot(p.x - g.startScreen.x, p.y - g.startScreen.y) < 4) return
        g.moved = true
        const { end, hover: h } = endAt(c, isRefEndpoint(g.from) ? g.from.ref : undefined)
        setDraft({ from: g.from, to: end, hover: h })
        return
      }
      case 'arrow-end': {
        const except = isRefEndpoint(g.other) ? g.other.ref : undefined
        const { end, hover: h } = endAt(c, except)
        setDraft({ from: g.other ?? end, to: end, hover: h })
        return
      }
    }
  }

  const onPointerUp = (e: ReactPointerEvent<HTMLDivElement>) => {
    const g = gesture.current
    gesture.current = null
    if (!g) return
    const c = screenToWorld(view, localPoint(e))
    switch (g.kind) {
      case 'pan':
        setPanning(false)
        return
      case 'move':
        if (g.moved && g.next) store.moveMany([...g.next.entries()] as [string, Record<string, unknown>][], LOCAL)
        else if (!g.moved && !e.shiftKey && selectionList.length > 1 && selection.has(g.hit)) select([g.hit])
        store.undo.stopCapturing()
        setDrag(null)
        return
      case 'resize':
        if (g.at) store.update(g.id, g.at, LOCAL)
        store.undo.stopCapturing()
        setDrag(null)
        return
      case 'marquee':
        setMarquee(null)
        if (!g.moved && g.frameClick) select([g.frameClick])
        return
      case 'frame': {
        setFrameDraft(null)
        const small = !g.box || g.box.w * view.z < 12 || g.box.h * view.z < 12
        const box = small ? { ...SHAPE_SIZE.frame, x: g.start.x - SHAPE_SIZE.frame.w / 2, y: g.start.y - SHAPE_SIZE.frame.h / 2 } : g.box!
        const id = createAt(
          { type: 'frame', color: 'gray', w: Math.max(box.w, MIN_SIZE.frame.w), h: Math.max(box.h, MIN_SIZE.frame.h) },
          { x: box.x, y: box.y },
          { centered: false }
        )
        setTool('select')
        select([id])
        setEditing({ id, field: 'title' })
        return
      }
      case 'arrow': {
        if (!g.moved) {
          // A click on a shape: the line follows the pointer until the next click.
          if (isRefEndpoint(g.from)) {
            setPendingFrom(g.from)
            return
          }
          setDraft(null)
          return
        }
        const { end } = endAt(c, isRefEndpoint(g.from) ? g.from.ref : undefined)
        setDraft(null)
        createArrow(g.from, end)
        return
      }
      case 'arrow-end': {
        const except = isRefEndpoint(g.other) ? g.other.ref : undefined
        const { end } = endAt(c, except)
        setDraft(null)
        setReEnding(null)
        store.update(g.id, { [g.end]: end } as Partial<Shape>, LOCAL)
        store.undo.stopCapturing()
        return
      }
    }
  }

  const onPointerLeave = () => {
    pointer.current = null
    setHover(null)
    awareness.setLocalStateField('cursor', null)
  }

  // ---- zoom ---------------------------------------------------------------------

  const zoomBy = useCallback(
    (factor: number) => {
      const { w, h } = sizeRef.current
      flight.cancel()
      setView(v => zoomAt(v, factor, { x: w / 2, y: h / 2 }))
    },
    [flight]
  )
  const zoomReset = useCallback(() => {
    const { w, h } = sizeRef.current
    flight.fly(zoomTo(viewRef.current, 1, { x: w / 2, y: h / 2 }))
  }, [flight])

  // Wheel and pinch must be non-passive to keep the page from scrolling or zooming.
  useEffect(() => {
    const el = viewport.current
    if (!el) return
    const onWheel = (e: WheelEvent) => {
      const t = e.target as HTMLElement | null
      if (t?.closest('textarea') && t.scrollHeight > t.clientHeight) return
      e.preventDefault()
      flight.cancel()
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1
      const dx = e.deltaX * unit
      const dy = e.deltaY * unit
      const rect = el.getBoundingClientRect()
      const p = { x: e.clientX - rect.left, y: e.clientY - rect.top }
      if (e.ctrlKey || e.metaKey) {
        const step = Math.max(-60, Math.min(60, dy))
        setView(v => zoomAt(v, Math.exp(-step * 0.009), p))
      } else setView(v => ({ ...v, x: v.x - dx, y: v.y - dy }))
    }
    let gestureZoom = 1
    const onGestureStart = (e: Event) => {
      e.preventDefault()
      gestureZoom = viewRef.current.z
    }
    const onGestureChange = (e: Event) => {
      e.preventDefault()
      const g = e as Event & { scale: number; clientX: number; clientY: number }
      const rect = el.getBoundingClientRect()
      const p = { x: g.clientX - rect.left, y: g.clientY - rect.top }
      setView(v => zoomTo(v, gestureZoom * g.scale, p))
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    el.addEventListener('gesturestart', onGestureStart)
    el.addEventListener('gesturechange', onGestureChange)
    el.addEventListener('gestureend', onGestureStart)
    return () => {
      el.removeEventListener('wheel', onWheel)
      el.removeEventListener('gesturestart', onGestureStart)
      el.removeEventListener('gesturechange', onGestureChange)
      el.removeEventListener('gestureend', onGestureStart)
    }
  }, [flight])

  const openImagePicker = (at: Point | null) => {
    const frame = selected.length === 1 && selected[0]!.type === 'frame' ? selected[0]!.id : null
    imageAt.current = { frame, at: at ?? center0(), free: !at }
    fileInput.current?.click()
  }

  // ---- keyboard -------------------------------------------------------------------

  const keyHandler = useRef<(e: KeyboardEvent) => void>(() => {})
  useEffect(() => {
    keyHandler.current = (e: KeyboardEvent) => {
      if (e.defaultPrevented || isTextField(e.target) || help) return
      if ((e.target as Element | null)?.closest?.('[role="dialog"]')) return
      const key = e.key.toLowerCase()
      const mod = e.metaKey || e.ctrlKey
      if (mod && !e.altKey && (key === 'z' || key === 'y')) {
        e.preventDefault()
        if (readOnly) return
        if (key === 'y' || e.shiftKey) redo()
        else undo()
        return
      }
      if (mod && key === 'a') {
        e.preventDefault()
        select(live.list.map(s => s.id))
        return
      }
      if (mod && key === 'd') {
        e.preventDefault()
        if (!readOnly) duplicate()
        return
      }
      if (mod && (key === ']' || key === '[')) {
        e.preventDefault()
        if (!readOnly) restack(key === ']')
        return
      }
      if (mod && (key === '=' || key === '+' || key === '-')) {
        e.preventDefault()
        zoomBy(key === '-' ? 1 / 1.25 : 1.25)
        return
      }
      if (mod && key === '0') {
        e.preventDefault()
        zoomReset()
        return
      }
      if (mod || e.altKey) return
      if (e.key === ' ') {
        e.preventDefault()
        setSpace(true)
        return
      }
      if (e.key === 'Escape') {
        if (pendingFrom || draft) {
          setPendingFrom(null)
          setDraft(null)
        } else if (linkAt) setLinkAt(null)
        else if (tool !== 'select') setTool('select')
        else select([])
        return
      }
      if (e.key === 'Delete' || e.key === 'Backspace') {
        e.preventDefault()
        removeSelected()
        return
      }
      if (e.key === 'Enter') {
        const only = selected.length === 1 ? selected[0]! : null
        if (!only) return
        e.preventDefault()
        if (only.type === 'link') {
          if (only.url) openUrl(only.url)
        } else startEdit(only.id)
        return
      }
      if (e.key.startsWith('Arrow') && selectionList.length && !readOnly) {
        e.preventDefault()
        const d = e.shiftKey ? 10 : 1
        nudge(e.key === 'ArrowLeft' ? -d : e.key === 'ArrowRight' ? d : 0, e.key === 'ArrowUp' ? -d : e.key === 'ArrowDown' ? d : 0)
        return
      }
      if (e.shiftKey && (e.code === 'Digit1' || e.key === '!')) {
        e.preventDefault()
        fitAll()
        return
      }
      if (e.shiftKey && (e.code === 'Digit2' || e.key === '@')) {
        e.preventDefault()
        if (selectionList.length) zoomToIds(selectionList)
        return
      }
      if (e.shiftKey && (e.code === 'Digit0' || e.key === ')')) {
        e.preventDefault()
        zoomReset()
        return
      }
      if (e.key === '?') {
        e.preventDefault()
        setHelp(true)
        return
      }
      if (e.key === '+' || e.key === '=') {
        zoomBy(1.25)
        return
      }
      if (e.key === '-' || e.key === '_') {
        zoomBy(1 / 1.25)
        return
      }
      const next = TOOL_KEYS[key]
      if (next && !e.shiftKey) {
        if (readOnly && next !== 'select' && next !== 'hand') return
        e.preventDefault()
        if (next === 'image') openImagePicker(null)
        else if (next === 'link') setLinkAt(center0())
        else setTool(next)
      }
    }
  })
  useEffect(() => {
    const down = (e: KeyboardEvent) => keyHandler.current(e)
    const up = (e: KeyboardEvent) => {
      if (e.key === ' ') setSpace(false)
    }
    const blur = () => setSpace(false)
    window.addEventListener('keydown', down)
    window.addEventListener('keyup', up)
    window.addEventListener('blur', blur)
    return () => {
      window.removeEventListener('keydown', down)
      window.removeEventListener('keyup', up)
      window.removeEventListener('blur', blur)
    }
  }, [])

  // ---- clipboard and drops ---------------------------------------------------------

  const clipHandler = useRef<{ copy: (e: ClipboardEvent, cut: boolean) => void; paste: (e: ClipboardEvent) => void }>({
    copy: () => {},
    paste: () => {},
  })
  useEffect(() => {
    const where = (): Point => (pointer.current ? screenToWorld(viewRef.current, pointer.current) : center0())
    clipHandler.current = {
      copy: (e, cut) => {
        if (isTextField(e.target) || isTextField(document.activeElement) || selectionList.length === 0) return
        const items = clipFor(selectionList)
        if (items.length === 0) return
        const text = items
          .map(s => (s.type === 'link' ? s.url : s.type === 'frame' ? s.title : s.type === 'arrow' ? s.label : s.text))
          .filter((t): t is string => typeof t === 'string' && !!t)
          .join('\n\n')
        clip.current = { text, shapes: items }
        pasteCount.current = 0
        e.preventDefault()
        try {
          e.clipboardData?.setData('text/plain', text || ' ')
          e.clipboardData?.setData(CLIP_TYPE, JSON.stringify({ shapes: items }))
        } catch {
          // custom types refused: the in-page copy still works
        }
        if (cut && !readOnly) removeSelected()
      },
      paste: e => {
        if (readOnly) return
        const data = e.clipboardData
        const titledFrame = (() => {
          const el = e.target instanceof Element ? e.target.closest('[data-kind="frame"]') : null
          return el?.getAttribute('data-id') ?? null
        })()
        if (isTextField(e.target) && !(titledFrame && imageFile(data))) return
        const at = where()
        const file = imageFile(data)
        if (file) {
          e.preventDefault()
          const frame = titledFrame ?? (selected.length === 1 && selected[0]!.type === 'frame' ? selected[0]!.id : null)
          void placeImage(file, frame, at)
          return
        }
        const raw = (() => {
          try {
            return data?.getData(CLIP_TYPE) ?? ''
          } catch {
            return ''
          }
        })()
        const text = data?.getData('text/plain') ?? ''
        if (raw) {
          try {
            const parsed = JSON.parse(raw) as { shapes?: ClipShape[] }
            if (Array.isArray(parsed.shapes)) {
              e.preventDefault()
              pasteShapes(parsed.shapes, pointer.current ? at : null)
              return
            }
          } catch {
            // not ours after all
          }
        }
        if (clip.current && (text === clip.current.text || (!text && clip.current.text === ' '))) {
          e.preventDefault()
          pasteShapes(clip.current.shapes, pointer.current ? at : null)
          return
        }
        const link = urlFrom(data)
        if (link) {
          e.preventDefault()
          if (looksLikeImageUrl(link.url)) void addImageUrl(link.url, at)
          else addLink(link.url, at, link.title)
          return
        }
        if (text.trim()) {
          e.preventDefault()
          addText(text, at)
        }
      },
    }
  })
  useEffect(() => {
    const copy = (e: ClipboardEvent) => clipHandler.current.copy(e, false)
    const cut = (e: ClipboardEvent) => clipHandler.current.copy(e, true)
    const paste = (e: ClipboardEvent) => clipHandler.current.paste(e)
    // Never let a drop navigate the page away from the board.
    const block = (e: DragEvent) => e.preventDefault()
    document.addEventListener('copy', copy)
    document.addEventListener('cut', cut)
    document.addEventListener('paste', paste)
    window.addEventListener('dragover', block)
    window.addEventListener('drop', block)
    return () => {
      document.removeEventListener('copy', copy)
      document.removeEventListener('cut', cut)
      document.removeEventListener('paste', paste)
      window.removeEventListener('dragover', block)
      window.removeEventListener('drop', block)
    }
  }, [])

  const [dropping, setDropping] = useState(false)
  const onDragOver = (e: ReactDragEvent<HTMLDivElement>) => {
    if (readOnly || isTextField(e.target)) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
    if (!dropping) setDropping(true)
  }
  const onDrop = (e: ReactDragEvent<HTMLDivElement>) => {
    setDropping(false)
    if (readOnly || isTextField(e.target)) return
    e.preventDefault()
    const at = screenToWorld(view, localPoint(e))
    const file = imageFile(e.dataTransfer)
    if (file) {
      const frame = [...live.list].reverse().find(s => s.type === 'frame' && containsPoint(s, at))
      void placeImage(file, frame?.id ?? null, at)
      return
    }
    const link = urlFrom(e.dataTransfer)
    if (link) {
      if (looksLikeImageUrl(link.url)) void addImageUrl(link.url, at)
      else addLink(link.url, at, link.title)
      return
    }
    const text = e.dataTransfer.getData('text/plain')
    if (text.trim()) addText(text, at)
  }

  // ---- search ---------------------------------------------------------------------

  const search = useBoardSearch({ shapes, viewport })
  const locate = useCallback(
    (ref: string): { box: Box; seg?: RingPlace['seg'] } | null => {
      const path = live.arrowById.get(ref)
      if (path) return { box: arrowLabelBox(path.seg), seg: path.seg }
      const s = live.byId.get(ref)
      return s && s.type !== 'arrow' ? { box: s } : null
    },
    [live]
  )
  const revealHit = (hit: SearchResult) => {
    const at = locate(hit.ref)
    if (!at) return
    const { w, h } = sizeRef.current
    flight.fly(revealView(at.box, view, w, h, { top: search.coveredTop() }), () => select([hit.ref]))
  }

  // ---- what to draw -----------------------------------------------------------------

  const vis = useMemo(() => {
    const b = visibleWorld(view, size.w || 1, size.h || 1)
    const m = 300 / view.z
    return { x: b.x - m, y: b.y - m, w: b.w + m * 2, h: b.h + m * 2 }
  }, [view, size])
  const onScreen = (s: Shape) => boxesOverlap(vis, s) || selection.has(s.id) || editing?.id === s.id
  const frames = live.list.filter(s => s.type === 'frame' && onScreen(s))
  const boxes = live.list.filter(s => s.type !== 'frame' && s.type !== 'arrow' && onScreen(s))
  const arrows = live.arrows.filter(
    a => a.shape.id !== reEnding && (boxesOverlap(vis, arrowBox(a.path)) || selection.has(a.shape.id))
  )
  const editId = editing?.id ?? null

  const single = selected.length === 1 ? selected[0]! : null
  const busy = !!(drag || draft || frameDraft || panning)
  const resizable = tool === 'select' && single && !readOnly && isResizable(single.type) && editId !== single.id ? single : null
  const selectedBoxes = selected.filter(s => s.type !== 'arrow')
  const group = selected.length > 1 ? unionBox(selected.map(s => boundsOf(s.id)).filter((b): b is Box => !!b)) : null

  const toScreen = (p: Point) => ({ x: view.x + p.x * view.z, y: view.y + p.y * view.z })
  const barAt = (() => {
    if (selected.length === 0 || drag || marquee || draft || readOnly || size.w === 0) return null
    if (editId && single?.type === 'sticky') return null
    const u = unionBox(selected.map(s => boundsOf(s.id)).filter((b): b is Box => !!b))
    if (!u) return null
    const top = toScreen({ x: u.x + u.w / 2, y: u.y })
    const bottom = toScreen({ x: u.x, y: u.y + u.h })
    if (bottom.y < 0 || top.y > size.h || top.x < -200 || top.x > size.w + 200) return null
    const frameLabel = single?.type === 'frame' ? labelPx(view.z) * 2 : 0
    const below = top.y - frameLabel < 112
    const x = Math.min(Math.max(top.x, 220), Math.max(220, size.w - 220))
    return { x, y: below ? bottom.y + 14 : top.y - 14 - frameLabel, below }
  })()

  const hovered = hover && !busy ? live.byId.get(hover) : undefined
  const chip =
    hovered && hovered.by && hovered.by !== me.name && hovered.type !== 'arrow' && editId !== hovered.id
      ? {
          at: toScreen({ x: hovered.x, y: hovered.y + hovered.h }),
          name: hovered.by,
          agent: readAgents(store.agents).some(a => a.name === hovered.by),
        }
      : null

  const peerSelections = peers
    .filter(p => p.selection.length > 0)
    .map(p => ({ peer: p, boxes: p.selection.map(id => boundsOf(id)).filter((b): b is Box => !!b) }))

  const rings: RingPlace[] = search.open
    ? search.results.flatMap((hit, i) => {
        const at = locate(hit.ref)
        return at ? [{ ref: hit.ref, on: i === search.active, ...at }] : []
      })
    : []

  const draftD = draft ? draftPath(draft)?.d : null
  const anchorTarget = draft?.hover ?? (tool === 'arrow' ? arrowHover : null)
  const anchorBox = anchorTarget ? live.boxOf(anchorTarget.id) : null
  const selectedArrowPath = single?.type === 'arrow' && !draft ? live.arrowById.get(single.id) : undefined

  const cursor =
    panning ? 'grabbing' : tool === 'hand' || space ? 'grab' : tool === 'select' ? 'default' : 'crosshair'
  const grid = 24 * view.z
  const showGrid = grid >= 8

  return (
    <BoardContext.Provider value={actions}>
      <div
        ref={viewport}
        role="application"
        aria-label={`${cfg.name} canvas`}
        tabIndex={0}
        className={cn('relative h-full w-full touch-none overflow-hidden outline-none', dropping && 'ring-4 ring-inset ring-accent/40')}
        style={{
          cursor,
          backgroundColor: 'var(--bg)',
          backgroundImage: showGrid ? 'radial-gradient(var(--dot) 1px, transparent 1.2px)' : undefined,
          backgroundSize: showGrid ? `${grid}px ${grid}px` : undefined,
          backgroundPosition: `${view.x}px ${view.y}px`,
        }}
        onPointerDown={onPointerDown}
        onMouseDown={e => {
          if (keepFocus.current) {
            keepFocus.current = false
            e.preventDefault()
          }
        }}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        onPointerLeave={onPointerLeave}
        onContextMenu={e => e.preventDefault()}
        onDragOver={onDragOver}
        onDragLeave={() => setDropping(false)}
        onDrop={onDrop}
      >
        <div
          className="absolute left-0 top-0 origin-top-left"
          style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.z})` }}
        >
          {frames.map(s => (
            <FrameView key={s.id} shape={s} editing={editId === s.id} selected={selection.has(s.id)} zoom={view.z} />
          ))}
          {boxes.map(s =>
            s.type === 'sticky' ? (
              <StickyView key={s.id} shape={s} editing={editId === s.id} />
            ) : s.type === 'text' ? (
              <TextView key={s.id} shape={s} editing={editId === s.id} />
            ) : s.type === 'image' ? (
              <ImageView key={s.id} shape={s} />
            ) : (
              <LinkView key={s.id} shape={s} selected={selection.has(s.id)} />
            )
          )}
          <ArrowLayer arrows={arrows} selected={selection} zoom={view.z} />
          {arrows.map(({ shape, path }) => (
            <ArrowLabel key={shape.id} shape={shape} path={path} editing={editId === shape.id} selected={selection.has(shape.id)} />
          ))}

          {peerSelections.map(({ peer, boxes: b }) => (
            <SelectionOutlines key={peer.clientId} boxes={b} group={null} zoom={view.z} color={peer.color} dashed />
          ))}
          <SelectionOutlines boxes={selectedBoxes} group={group} zoom={view.z} />
          {rings.length > 0 && <SearchRings places={rings} zoom={view.z} />}
          {resizable && (
            <ResizeHandles
              box={resizable}
              zoom={view.z}
              edges={resizable.type !== 'image'}
              onStart={(handle, e) => startResize(resizable, handle, e)}
            />
          )}
          {selectedArrowPath && single && !readOnly && (
            <ArrowEndHandles path={selectedArrowPath} zoom={view.z} onStart={(end, e) => startEndDrag(single, end, e)} />
          )}
          {anchorBox && <AnchorDots box={anchorBox} hot={anchorTarget?.side ?? null} zoom={view.z} />}
          {draftD && <ArrowDraft d={draftD} zoom={view.z} />}
          {frameDraft && (
            <div
              className="pointer-events-none absolute left-0 top-0 rounded-[10px] border-accent bg-accent-soft"
              style={{
                width: frameDraft.w,
                height: frameDraft.h,
                transform: `translate(${frameDraft.x}px, ${frameDraft.y}px)`,
                borderWidth: 1.5 / view.z,
              }}
            />
          )}
          {marquee && <Marquee box={marquee} zoom={view.z} />}
          <PeerCursors peers={peers} zoom={view.z} />
          <AgentCursors agents={agents} zoom={view.z} />
        </div>

        {shapes.size === 0 && !editId && <EmptyHint readOnly={readOnly} />}
        {chip && <AuthorChip at={{ x: chip.at.x, y: chip.at.y + 6 }} name={chip.name} agent={chip.agent} />}

        {barAt && (
          <SelectionBar
            at={barAt}
            below={barAt.below}
            shapes={selected}
            onColor={recolor}
            onFont={size => store.transact(() => selected.forEach(s => store.update(s.id, { fontSize: size })))}
            onAlign={align => single && store.update(single.id, { align })}
            onFront={() => restack(true)}
            onBack={() => restack(false)}
            onDuplicate={duplicate}
            onDelete={removeSelected}
            onRemoveImage={() => single && store.update(single.id, { image: null } as unknown as Partial<Shape>)}
            onOpen={() => single?.url && openUrl(single.url)}
          />
        )}

        <TitleBar
          name={cfg.name}
          kind={cfg.kind}
          status={status}
          readOnly={readOnly}
          peers={peers}
          agents={agents}
          onPeer={peer => {
            if (!peer.cursor) return
            const { w, h } = sizeRef.current
            flight.fly(revealView({ ...peer.cursor, w: 1, h: 1 }, view, w, h))
          }}
          onAgent={agent => {
            if (!agent.cursor) return
            const { w, h } = sizeRef.current
            flight.fly(revealView({ ...agent.cursor, w: 1, h: 1 }, view, w, h))
          }}
        />
        <TopRight onSearch={() => (search.open ? search.close() : search.show())} searchOpen={search.open} onHelp={() => setHelp(true)} />
        <SearchBox search={search} onReveal={revealHit} />

        <Toolbar
          tool={tool}
          onTool={next => {
            if (next === 'image') openImagePicker(null)
            else if (next === 'link') setLinkAt(center0())
            else setTool(next)
            viewport.current?.focus({ preventScroll: true })
          }}
          color={noteColor}
          onColor={c => {
            setNoteColor(c)
            if (selected.some(s => s.type === 'sticky')) recolor(c)
          }}
          readOnly={readOnly}
        />
        <ZoomBar
          zoom={view.z}
          onZoom={zoomBy}
          onFit={fitAll}
          onReset={zoomReset}
          canUndo={history.undo}
          canRedo={history.redo}
          onUndo={undo}
          onRedo={redo}
          readOnly={readOnly}
        />
        <CompactBar onFit={fitAll} canUndo={history.undo} canRedo={history.redo} onUndo={undo} onRedo={redo} zoom={view.z} readOnly={readOnly} />
        {linkAt && (
          <LinkPrompt
            onSubmit={url => {
              addLink(url, linkAt)
              setLinkAt(null)
              viewport.current?.focus({ preventScroll: true })
            }}
            onClose={() => {
              setLinkAt(null)
              viewport.current?.focus({ preventScroll: true })
            }}
          />
        )}
        <Toasts toasts={toasts} />
        {help && <ShortcutsSheet onClose={() => setHelp(false)} />}
        <input
          ref={fileInput}
          type="file"
          accept="image/*"
          className="hidden"
          aria-hidden="true"
          tabIndex={-1}
          onChange={e => {
            const file = e.currentTarget.files?.[0]
            const target = imageAt.current
            e.currentTarget.value = ''
            if (file) void placeImage(file, target?.frame ?? null, target?.at ?? center0(), target?.free ?? true)
          }}
        />
      </div>
    </BoardContext.Provider>
  )
}

/** Frame label size on screen (mirrors FrameView). */
const labelPx = (zoom: number) => 13 / Math.min(1, zoom) * zoom
