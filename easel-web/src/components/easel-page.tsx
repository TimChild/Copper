/**
 * The easel board. Forked from the wiki app's
 * apps/web/src/modules/wiki/routes/wiki-canvas-page.tsx without the wiki
 * parts (page cards, drawer, search, comments, closed cards, ring layout,
 * canvas agent), plus: multi-select with a marquee, group move, a Hand tool
 * and Space-to-pan, drag-to-size creation, double-click to add a note, a
 * file picker, pinch zoom, ⌘0/⌘=/⌘− and the laser pointer.
 *
 * Coordinates: one layer has `transform: translate(x, y) scale(z)` with its
 * origin top-left, so `screen = canvas * z + (x, y)`.
 */
import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ClipboardEvent as ReactClipboardEvent,
  type DragEvent as ReactDragEvent,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
} from 'react'
import type { EaselSession } from '../session'
import { SHAPE_SIZE, type Shape } from '../doc/easel-doc'
import {
  boxSegment,
  boxesIntersect,
  fitBoxes,
  pointInBox,
  rectFrom,
  screenToCanvas,
  zoomAt,
  zoomTo,
  type Box,
  type Point,
  type View,
} from '../lib/canvas-geometry'
import {
  MIN_SIZE,
  isResizable,
  resizeBox,
  type Handle,
  type ResizableType,
} from '../lib/canvas-resize'
import { TOOLS, focusShapeText, type Tool } from '../lib/canvas-tools'
import { frameSizeFor, imageFile, saveEaselImage } from '../lib/canvas-images'
import { usePeers, useRemoteLasers } from '../lib/awareness'
import { LaserCanvas, LaserTrails } from '../laser'
import { ArrowLabel, FrameShape, SelectionBar, StickyShape } from './canvas-shapes'
import { ResizeHandles } from './resize-handles'
import { PeerCursors } from './peer-cursors'
import { Toolbar, ZoomCluster } from './toolbar'
import { TitleChip } from './title-chip'

type Gesture =
  | { kind: 'pan'; start: Point; view: View }
  | {
      kind: 'move'
      /** The shape under the pointer at pointerdown. */
      hit: string
      ids: string[]
      start: Point
      /** Each moved shape's top-left at pointerdown. */
      from: Map<string, Point>
      /** Last drag positions; state may lag a frame behind the pointer. */
      at?: Map<string, Point>
    }
  | {
      kind: 'resize'
      id: string
      handle: Handle
      type: ResizableType
      /** Pointer in canvas coords and the shape's box at pointerdown. */
      start: Point
      box: Box
      at?: Box
    }
  | { kind: 'marquee'; start: Point; base: Set<string> }
  | {
      kind: 'create'
      type: 'sticky' | 'frame'
      start: Point
      /** Set once the drag is long enough to be a drawn box. */
      id: string | null
      at?: Box
    }
  | { kind: 'arrow'; from: string }
  | { kind: 'laser' }

const EMPTY = new Set<string>()
const refId = (ref: string) => ref.slice(ref.indexOf(':') + 1)
const isTextField = (el: EventTarget | null) =>
  el instanceof HTMLElement &&
  (el.isContentEditable || el.closest('input, textarea') !== null)

/** How long after a laser stroke ends before awareness forgets it. */
const LASER_LINGER_MS = 3200

/** Safari's pinch events; not in lib.dom. */
interface GestureEventLike extends Event {
  scale: number
  clientX: number
  clientY: number
}

export function EaselPage({
  session,
  title,
}: {
  session: EaselSession
  title: string
}) {
  const { doc, awareness, config, host } = session
  const viewer = config.viewer
  const markerId = useId()
  const shapes = useSyncExternalStore(doc.subscribeShapes, doc.getShapesSnapshot)
  const peers = usePeers(awareness)
  const trails = useMemo(() => new LaserTrails(), [])
  useRemoteLasers(awareness, trails)

  const viewport = useRef<HTMLDivElement>(null)
  const [view, setView] = useState<View>({ x: 0, y: 0, z: 1 })
  const gesture = useRef<Gesture | null>(null)
  const [dragging, setDragging] = useState<Map<string, Point> | null>(null)
  const [resizing, setResizing] = useState<{ id: string; box: Box } | null>(
    null
  )
  const [marquee, setMarquee] = useState<Box | null>(null)
  const [selected, setSelected] = useState<Set<string>>(EMPTY)
  const [tool, setTool] = useState<Tool>('select')
  const [spaceDown, setSpaceDown] = useState(false)
  const [arrowFrom, setArrowFrom] = useState<string | null>(null)
  const [labelEditing, setLabelEditing] = useState<string | null>(null)
  const lastSent = useRef({ move: 0, cursor: 0, size: 0, laser: 0, create: 0 })
  /** Pointer in viewport px while it is over the board; pastes land here. */
  const pointer = useRef<Point | null>(null)
  const lastTap = useRef({ id: '', at: 0 })
  const laserLinger = useRef<ReturnType<typeof setTimeout> | null>(null)
  const panning = tool === 'hand' || spaceDown

  const select = (ids: Iterable<string>) => setSelected(new Set(ids))
  const selectOne = (id: string) => setSelected(new Set([id]))

  /** A shape with the local drag/resize applied, so it moves at frame rate. */
  const placed = (shape: Shape): Shape => {
    const moved = dragging?.get(shape.id)
    if (moved) return { ...shape, ...moved }
    if (resizing?.id === shape.id) return { ...shape, ...resizing.box }
    return shape
  }

  const boxOf = (id: string | undefined): Box | null => {
    if (!id) return null
    const shape = shapes.get(id)
    return shape && shape.type !== 'arrow' ? placed(shape) : null
  }
  const boxOfRef = (ref: string | undefined) =>
    ref?.startsWith('shape:') ? boxOf(refId(ref)) : null

  const clientPoint = (e: { clientX: number; clientY: number }): Point => {
    const rect = viewport.current!.getBoundingClientRect()
    return { x: e.clientX - rect.left, y: e.clientY - rect.top }
  }

  const fit = useCallback(() => {
    const el = viewport.current
    if (!el) return
    const boxes = [...doc.getShapesSnapshot().values()].filter(
      s => s.type !== 'arrow'
    )
    setView(fitBoxes(boxes, el.clientWidth, el.clientHeight))
  }, [doc])

  // Frame the board once on open: everything that was saved, or the origin.
  const fitted = useRef(false)
  useEffect(() => {
    if (fitted.current || !viewport.current) return
    fitted.current = true
    fit()
  }, [fit])

  // Wheel must be non-passive to stop the page from scrolling; two fingers
  // pan, ⌘/ctrl + wheel (and a trackpad pinch, which arrives as ctrl+wheel)
  // zooms around the pointer. Safari also sends gesture events for a pinch.
  useEffect(() => {
    const el = viewport.current
    if (!el) return
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      const unit = e.deltaMode === 1 ? 16 : 1
      const dx = e.deltaX * unit
      const dy = e.deltaY * unit
      if (e.ctrlKey || e.metaKey) {
        const rect = el.getBoundingClientRect()
        const p = { x: e.clientX - rect.left, y: e.clientY - rect.top }
        setView(v => zoomAt(v, Math.exp(-dy * 0.01), p))
      } else {
        setView(v => ({ ...v, x: v.x - dx, y: v.y - dy }))
      }
    }
    let pinch: { z: number } | null = null
    const onGestureStart = (e: Event) => {
      e.preventDefault()
      setView(v => {
        pinch = { z: v.z }
        return v
      })
    }
    const onGestureChange = (e: Event) => {
      e.preventDefault()
      const g = e as GestureEventLike
      if (!pinch) return
      const rect = el.getBoundingClientRect()
      const p = { x: g.clientX - rect.left, y: g.clientY - rect.top }
      const z = pinch.z * g.scale
      setView(v => zoomTo(v, z, p))
    }
    const onGestureEnd = (e: Event) => {
      e.preventDefault()
      pinch = null
    }
    el.addEventListener('wheel', onWheel, { passive: false })
    el.addEventListener('gesturestart', onGestureStart)
    el.addEventListener('gesturechange', onGestureChange)
    el.addEventListener('gestureend', onGestureEnd)
    return () => {
      el.removeEventListener('wheel', onWheel)
      el.removeEventListener('gesturestart', onGestureStart)
      el.removeEventListener('gesturechange', onGestureChange)
      el.removeEventListener('gestureend', onGestureEnd)
    }
  }, [])

  const zoomBy = useCallback((factor: number) => {
    const el = viewport.current
    if (!el) return
    setView(v =>
      zoomAt(v, factor, { x: el.clientWidth / 2, y: el.clientHeight / 2 })
    )
  }, [])

  // Every key is handled at the window, not the viewport: focus is on
  // `body` after a title or label blurs, and the shortcuts must still work.
  // Zoom shortcuts always (WebKit would page-zoom otherwise), Space-to-pan
  // and the board keys unless a text field has focus.
  const boardKeys = useRef<(e: KeyboardEvent) => void>(() => {})
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey) {
        if (e.key === '0') {
          e.preventDefault()
          const el = viewport.current
          if (el)
            setView(v =>
              zoomTo(v, 1, { x: el.clientWidth / 2, y: el.clientHeight / 2 })
            )
          return
        }
        if (e.key === '=' || e.key === '+') {
          e.preventDefault()
          zoomBy(1.2)
          return
        }
        if (e.key === '-' || e.key === '_') {
          e.preventDefault()
          zoomBy(1 / 1.2)
          return
        }
      }
      if (e.code === 'Space' && !isTextField(e.target)) {
        e.preventDefault()
        if (!e.repeat) setSpaceDown(true)
        return
      }
      boardKeys.current(e)
    }
    const onKeyUp = (e: KeyboardEvent) => {
      if (e.code === 'Space') setSpaceDown(false)
    }
    const onBlur = () => setSpaceDown(false)
    window.addEventListener('keydown', onKeyDown)
    window.addEventListener('keyup', onKeyUp)
    window.addEventListener('blur', onBlur)
    return () => {
      window.removeEventListener('keydown', onKeyDown)
      window.removeEventListener('keyup', onKeyUp)
      window.removeEventListener('blur', onBlur)
    }
  }, [zoomBy])

  // Leaving the laser tool mid-stroke drops the stroke.
  useEffect(() => {
    if (tool !== 'laser' && gesture.current?.kind === 'laser') {
      gesture.current = null
      trails.cancel()
      awareness.setLocalStateField('laser', null)
    }
  }, [tool, trails, awareness])

  useEffect(
    () => () => {
      if (laserLinger.current) clearTimeout(laserLinger.current)
    },
    []
  )

  /** Put the local stroke into awareness, at most ~30 times a second. */
  const publishLaser = (force = false) => {
    const now = performance.now()
    if (!force && now - lastSent.current.laser < 33) return
    lastSent.current.laser = now
    awareness.setLocalStateField('laser', trails.localWire())
  }

  const changeTool = (next: Tool) => {
    setTool(next)
    setArrowFrom(null)
  }

  const createAt = (type: 'sticky' | 'frame', box: Box) => {
    doc.undo.stopCapturing()
    const id = doc.createShape({
      type,
      ...box,
      color: type === 'frame' ? 'gray' : 'yellow',
      by: viewer.name,
    })
    return id
  }

  const finishCreate = (id: string) => {
    changeTool('select')
    selectOne(id)
    focusShapeText(id)
  }

  const createArrow = (from: string, to: string) => {
    doc.undo.stopCapturing()
    const id = doc.createShape({
      type: 'arrow',
      from: `shape:${from}`,
      to: `shape:${to}`,
      by: viewer.name,
    })
    setArrowFrom(null)
    changeTool('select')
    selectOne(id)
  }

  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.button !== 0 && e.button !== 1) return
    // The board takes keyboard focus (Delete, tool keys, undo) unless the
    // click lands inside the text someone is already editing.
    const active = document.activeElement
    if (!(active instanceof Node && active.contains(e.target as Node)))
      viewport.current?.focus({ preventScroll: true })
    const p = clientPoint(e)
    const c = screenToCanvas(view, p)
    e.currentTarget.setPointerCapture(e.pointerId)
    gesture.current = null

    if (tool === 'laser') {
      if (laserLinger.current) clearTimeout(laserLinger.current)
      trails.begin(c, viewer.color)
      gesture.current = { kind: 'laser' }
      publishLaser(true)
      return
    }

    if (panning || e.button === 1) {
      gesture.current = { kind: 'pan', start: p, view }
      return
    }

    if (tool === 'sticky' || tool === 'frame') {
      gesture.current = { kind: 'create', type: tool, start: c, id: null }
      return
    }

    const ref = (e.target as Element).closest<HTMLElement | SVGElement>(
      '[data-ref]'
    )?.dataset.ref
    const id = ref ? refId(ref) : undefined
    const box = boxOfRef(ref)

    if (tool === 'arrow') {
      if (!id || !box) {
        setArrowFrom(null)
        return
      }
      if (arrowFrom && arrowFrom !== id) return createArrow(arrowFrom, id)
      setArrowFrom(id)
      gesture.current = { kind: 'arrow', from: id }
      return
    }

    if (id && shapes.has(id)) {
      if (e.shiftKey) {
        setSelected(prev => {
          const next = new Set(prev)
          if (next.has(id)) next.delete(id)
          else next.add(id)
          return next
        })
        return
      }
      const ids = selected.has(id) ? [...selected] : [id]
      if (!selected.has(id)) selectOne(id)
      const from = new Map<string, Point>()
      for (const other of ids) {
        const b = boxOf(other)
        if (b) from.set(other, { x: b.x, y: b.y })
      }
      gesture.current = { kind: 'move', hit: id, ids, start: p, from }
      return
    }

    // Empty paper: rubber-band a selection (Shift adds to the current one).
    gesture.current = {
      kind: 'marquee',
      start: c,
      base: e.shiftKey ? new Set(selected) : new Set(),
    }
    if (!e.shiftKey) setSelected(EMPTY)
    setArrowFrom(null)
  }

  /** Pointerdown on a resize handle: capture on the handle so its cursor sticks. */
  const startResize = (
    shape: Shape,
    handle: Handle,
    e: ReactPointerEvent<HTMLElement>
  ) => {
    if (e.button !== 0 || !isResizable(shape.type)) return
    e.stopPropagation()
    e.currentTarget.setPointerCapture(e.pointerId)
    const { x, y, w, h } = placed(shape)
    gesture.current = {
      kind: 'resize',
      id: shape.id,
      handle,
      type: shape.type,
      start: screenToCanvas(view, clientPoint(e)),
      box: { x, y, w, h },
    }
  }

  /** A drawn box from `start` to `c`, at least the type's minimum, anchored at `start`. */
  const drawnBox = (type: 'sticky' | 'frame', start: Point, c: Point): Box => {
    const min = MIN_SIZE[type]
    const r = rectFrom(start, c)
    const w = Math.max(min.w, r.w)
    const h = Math.max(min.h, r.h)
    return {
      x: c.x < start.x ? start.x - w : start.x,
      y: c.y < start.y ? start.y - h : start.y,
      w,
      h,
    }
  }

  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const p = clientPoint(e)
    pointer.current = p
    const now = performance.now()
    const c = screenToCanvas(view, p)
    if (now - lastSent.current.cursor > 33) {
      lastSent.current.cursor = now
      awareness.setLocalStateField('cursor', c)
    }
    const g = gesture.current
    if (!g) return
    switch (g.kind) {
      case 'laser':
        trails.move(c)
        publishLaser()
        return
      case 'pan':
        setView({
          ...g.view,
          x: g.view.x + p.x - g.start.x,
          y: g.view.y + p.y - g.start.y,
        })
        return
      case 'resize': {
        const box = resizeBox(
          g.box,
          g.handle,
          { x: c.x - g.start.x, y: c.y - g.start.y },
          MIN_SIZE[g.type]
        )
        g.at = box
        setResizing({ id: g.id, box })
        if (now - lastSent.current.size > 33) {
          lastSent.current.size = now
          doc.updateShape(g.id, box)
        }
        return
      }
      case 'marquee': {
        const rect = rectFrom(g.start, c)
        setMarquee(rect)
        const hits = [...shapes.values()]
          .filter(s => s.type !== 'arrow' && boxesIntersect(rect, s))
          .map(s => s.id)
        select([...g.base, ...hits])
        return
      }
      case 'create': {
        const startScreen = {
          x: g.start.x * view.z + view.x,
          y: g.start.y * view.z + view.y,
        }
        if (!g.id && Math.hypot(p.x - startScreen.x, p.y - startScreen.y) < 6)
          return
        const box = drawnBox(g.type, g.start, c)
        g.at = box
        if (!g.id) {
          g.id = createAt(g.type, box)
          return
        }
        if (now - lastSent.current.create > 33) {
          lastSent.current.create = now
          doc.updateShape(g.id, box)
        }
        return
      }
      case 'move': {
        if (!g.at && Math.hypot(p.x - g.start.x, p.y - g.start.y) < 4) return
        const dx = (p.x - g.start.x) / view.z
        const dy = (p.y - g.start.y) / view.z
        const at = new Map<string, Point>()
        for (const [id, from] of g.from)
          at.set(id, { x: from.x + dx, y: from.y + dy })
        g.at = at
        setDragging(at)
        if (now - lastSent.current.move > 50) {
          lastSent.current.move = now
          doc.moveShapes(at)
        }
        return
      }
      case 'arrow':
        return
    }
  }

  const onPointerUp = (e: ReactPointerEvent<HTMLDivElement>) => {
    const g = gesture.current
    gesture.current = null
    if (!g) return
    switch (g.kind) {
      case 'laser':
        trails.end()
        publishLaser(true)
        laserLinger.current = setTimeout(() => {
          awareness.setLocalStateField('laser', null)
        }, LASER_LINGER_MS)
        return
      case 'pan':
        return
      case 'resize':
        if (g.at) doc.updateShape(g.id, g.at)
        setResizing(null)
        return
      case 'marquee':
        setMarquee(null)
        return
      case 'create': {
        if (g.id) {
          if (g.at) doc.updateShape(g.id, g.at)
          finishCreate(g.id)
          return
        }
        const { w, h } = SHAPE_SIZE[g.type]
        const id = createAt(g.type, {
          x: g.start.x - w / 2,
          y: g.start.y - h / 2,
          w,
          h,
        })
        finishCreate(id)
        return
      }
      case 'arrow': {
        // Drag onto another shape completes the arrow; a plain click leaves
        // the source pending so the next click can pick the target.
        const under = document
          .elementFromPoint(e.clientX, e.clientY)
          ?.closest<HTMLElement | SVGElement>('[data-ref]')?.dataset.ref
        const target = under ? refId(under) : undefined
        if (target && target !== g.from && boxOf(target))
          createArrow(g.from, target)
        return
      }
      case 'move': {
        if (g.at) {
          doc.moveShapes(g.at)
          setDragging(null)
          return
        }
        // A click without a drag selects just the one under the pointer.
        selectOne(g.hit)
        const now = performance.now()
        const double =
          lastTap.current.id === g.hit && now - lastTap.current.at < 350
        lastTap.current = { id: g.hit, at: now }
        if (!double) return
        if (shapes.get(g.hit)?.type === 'arrow') setLabelEditing(g.hit)
        else focusShapeText(g.hit)
        return
      }
    }
  }

  /** Double-click on empty paper: a new note right there. */
  const onDoubleClick = (e: ReactMouseEvent<HTMLDivElement>) => {
    if (tool !== 'select' || panning) return
    if ((e.target as Element).closest('[data-ref], .easel-card')) return
    const c = screenToCanvas(view, clientPoint(e))
    const { w, h } = SHAPE_SIZE.sticky
    const id = createAt('sticky', { x: c.x - w / 2, y: c.y - h / 2, w, h })
    finishCreate(id)
  }

  /** Delete the selection, as one undo step clear of what came before. */
  const removeSelected = () => {
    if (selected.size === 0) return
    doc.undo.stopCapturing()
    doc.deleteShapes(selected)
    doc.undo.stopCapturing()
    setSelected(EMPTY)
    viewport.current?.focus({ preventScroll: true })
  }

  const nudge = (dx: number, dy: number) => {
    if (selected.size === 0) return
    const moves: [string, Point][] = []
    for (const id of selected) {
      const b = boxOf(id)
      if (b) moves.push([id, { x: b.x + dx, y: b.y + dy }])
    }
    doc.moveShapes(moves)
  }

  const onKeyDown = (e: KeyboardEvent) => {
    if (isTextField(e.target)) {
      // Escape leaves any field; Enter finishes a one-line one (frame
      // title, arrow label, easel title). Stickies keep Enter for new lines.
      const oneLine = e.target instanceof HTMLInputElement
      if (e.key === 'Escape' || (e.key === 'Enter' && oneLine)) {
        ;(e.target as HTMLElement).blur()
        viewport.current?.focus({ preventScroll: true })
      }
      return
    }
    const key = e.key.toLowerCase()
    if ((e.metaKey || e.ctrlKey) && !e.altKey) {
      if (key === 'z' || key === 'y') {
        e.preventDefault()
        if (key === 'y' || e.shiftKey) doc.undo.redo()
        else doc.undo.undo()
        return
      }
      if (key === 'a') {
        e.preventDefault()
        select(shapes.keys())
        return
      }
      return
    }
    if (e.altKey) return
    if (e.key === 'Escape') {
      if (tool !== 'select') changeTool('select')
      else setSelected(EMPTY)
      setArrowFrom(null)
      return
    }
    if ((e.key === 'Delete' || e.key === 'Backspace') && selected.size) {
      e.preventDefault()
      removeSelected()
      return
    }
    if (e.key.startsWith('Arrow') && selected.size) {
      e.preventDefault()
      const step = e.shiftKey ? 10 : 1
      if (e.key === 'ArrowLeft') nudge(-step, 0)
      if (e.key === 'ArrowRight') nudge(step, 0)
      if (e.key === 'ArrowUp') nudge(0, -step)
      if (e.key === 'ArrowDown') nudge(0, step)
      return
    }
    const next = TOOLS.find(t => t.key === key)
    if (next) changeTool(next.tool)
  }
  boardKeys.current = onKeyDown

  /** The frame an element sits in, e.g. the title field someone pastes into. */
  const frameOf = (el: EventTarget | null) => {
    const ref =
      el instanceof Element
        ? el.closest<HTMLElement>('[data-ref^="shape:"]')?.dataset.ref
        : undefined
    const shape = ref ? shapes.get(refId(ref)) : undefined
    return shape?.type === 'frame' ? shape.id : null
  }

  /** Put a picture in frame `into`, or in a new frame sized to it at `at`. */
  const placeImage = async (file: File, into: string | null, at: Point) => {
    try {
      const { image, width, height } = await saveEaselImage(file, host)
      doc.undo.stopCapturing()
      if (into && doc.getShapesSnapshot().has(into)) {
        doc.updateShape(into, { image })
        selectOne(into)
      } else {
        const { w, h } = frameSizeFor(width, height)
        const id = doc.createShape({
          type: 'frame',
          x: at.x - w / 2,
          y: at.y - h / 2,
          w,
          h,
          color: 'gray',
          image,
          by: viewer.name,
        })
        selectOne(id)
      }
      doc.undo.stopCapturing()
    } catch (error) {
      host.log(
        'warn',
        `could not add the picture: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  }

  const viewportCentre = (): Point => {
    const el = viewport.current!
    return screenToCanvas(view, {
      x: el.clientWidth / 2,
      y: el.clientHeight / 2,
    })
  }

  /** From the toolbar's picker: into the selected frame, else centred. */
  const pickImage = (file: File) => {
    const one = selected.size === 1 ? shapes.get([...selected][0]!) : undefined
    void placeImage(file, one?.type === 'frame' ? one.id : null, viewportCentre())
  }

  /**
   * ⌘V with a picture: into the frame whose title is focused, else the
   * selected frame, else a new frame under the pointer. Other text fields
   * (stickies) keep their paste.
   */
  const onPaste = (e: ReactClipboardEvent<HTMLDivElement>) => {
    const file = imageFile(e.clipboardData)
    if (!file) return
    const titled = frameOf(e.target)
    if (isTextField(e.target) && !titled) return
    e.preventDefault()
    const one = selected.size === 1 ? shapes.get([...selected][0]!) : undefined
    const at = pointer.current
      ? screenToCanvas(view, pointer.current)
      : viewportCentre()
    void placeImage(file, titled ?? (one?.type === 'frame' ? one.id : null), at)
  }

  const onDragOver = (e: ReactDragEvent<HTMLDivElement>) => {
    if (isTextField(e.target) || !e.dataTransfer.types.includes('Files')) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
  }

  /** A dropped picture goes into the topmost frame under it, or a new one. */
  const onDrop = (e: ReactDragEvent<HTMLDivElement>) => {
    if (isTextField(e.target) || !e.dataTransfer.types.includes('Files')) return
    // Always claim a file drop, so the browser never navigates to the file.
    e.preventDefault()
    const file = imageFile(e.dataTransfer)
    if (!file) return
    const at = screenToCanvas(view, clientPoint(e))
    const into = [...shapes.values()]
      .reverse()
      .find(s => s.type === 'frame' && pointInBox(at, s))
    void placeImage(file, into?.id ?? null, at)
  }

  // ---- render ----

  const byLabel = (shape: Shape) =>
    shape.by && shape.by !== viewer.name ? shape.by : undefined
  const shapeList = [...shapes.values()].map(placed)
  const frames = shapeList.filter(shape => shape.type === 'frame')
  const stickies = shapeList.filter(shape => shape.type === 'sticky')
  const arrows = shapeList.flatMap(shape => {
    const a = shape.type === 'arrow' ? boxOfRef(shape.from) : null
    const b = a ? boxOfRef(shape.to) : null
    const seg = a && b ? boxSegment(a, b) : null
    return seg ? [{ shape, seg }] : []
  })
  const shapeProps = (shape: Shape) => ({
    shape,
    at: { x: shape.x, y: shape.y },
    selected: selected.has(shape.id),
    pending: arrowFrom === shape.id,
    lifted: dragging?.has(shape.id) ?? false,
    by: byLabel(shape),
  })
  const grid = 24 * view.z

  const selectedShapes = [...selected].flatMap(id => {
    const s = shapes.get(id)
    return s ? [placed(s)] : []
  })
  const one = selectedShapes.length === 1 ? selectedShapes[0] : undefined
  const resizable =
    tool === 'select' && one && isResizable(one.type) ? one : null
  // Screen point for the selection bar: above the selection, or above an arrow's middle.
  const barAt = ((): Point | null => {
    if (tool !== 'select' || !selectedShapes.length || dragging || resizing)
      return null
    if (marquee) return null
    if (one?.type === 'arrow') {
      const seg = arrows.find(a => a.shape.id === one.id)?.seg
      if (!seg) return null
      return {
        x: view.x + ((seg.x1 + seg.x2) / 2) * view.z,
        y: view.y + ((seg.y1 + seg.y2) / 2) * view.z - 18,
      }
    }
    const boxes = selectedShapes.filter(s => s.type !== 'arrow')
    if (!boxes.length) return null
    const minX = Math.min(...boxes.map(b => b.x))
    const maxX = Math.max(...boxes.map(b => b.x + b.w))
    const minY = Math.min(...boxes.map(b => b.y))
    return {
      x: view.x + ((minX + maxX) / 2) * view.z,
      y: Math.max(56, view.y + minY * view.z - 12),
    }
  })()

  const cursor = panning
    ? 'easel-cursor-grab'
    : tool === 'laser'
      ? 'easel-cursor-laser'
      : tool === 'select'
        ? 'easel-cursor-default'
        : 'easel-cursor-crosshair'

  return (
    <div
      ref={viewport}
      role="application"
      aria-label="Easel"
      tabIndex={0}
      className={`easel-viewport ${cursor}`}
      data-tool={tool}
      style={{
        backgroundSize: `${grid}px ${grid}px`,
        backgroundPosition: `${view.x}px ${view.y}px`,
      }}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      onDoubleClick={onDoubleClick}
      onPaste={onPaste}
      onDragOver={onDragOver}
      onDrop={onDrop}
      onPointerLeave={() => {
        pointer.current = null
        awareness.setLocalStateField('cursor', null)
      }}
    >
      <div
        className="easel-layer"
        style={{
          transform: `translate(${view.x}px, ${view.y}px) scale(${view.z})`,
        }}
      >
        {frames
          .filter(shape => !shape.image)
          .map(shape => (
            <FrameShape key={shape.id} {...shapeProps(shape)} />
          ))}

        <svg
          className="easel-arrows"
          width={1}
          height={1}
          aria-hidden="true"
        >
          <defs>
            {(['arrow', 'active'] as const).map(state => (
              <marker
                key={state}
                id={`${markerId}-${state}`}
                viewBox="0 0 10 10"
                refX="10"
                refY="5"
                markerWidth="7"
                markerHeight="7"
                orient="auto-start-reverse"
              >
                <path
                  d="M0,0 L10,5 L0,10 z"
                  className={
                    state === 'active'
                      ? 'easel-arrow-head-active'
                      : 'easel-arrow-head'
                  }
                />
              </marker>
            ))}
          </defs>
          {arrows.map(({ shape, seg }) => {
            const on = selected.has(shape.id)
            return (
              <g key={shape.id} data-ref={`shape:${shape.id}`}>
                <line
                  {...seg}
                  stroke="transparent"
                  strokeWidth={14}
                  style={{ pointerEvents: 'stroke' }}
                />
                <line
                  {...seg}
                  strokeWidth={on ? 2.5 : 2}
                  strokeLinecap="round"
                  className={on ? 'easel-arrow-line-active' : 'easel-arrow-line'}
                  markerEnd={`url(#${markerId}-${on ? 'active' : 'arrow'})`}
                />
              </g>
            )
          })}
        </svg>

        {/* A picture is opaque content, so it covers the lines. */}
        {frames
          .filter(shape => shape.image)
          .map(shape => (
            <FrameShape key={shape.id} {...shapeProps(shape)} />
          ))}

        {arrows.map(({ shape, seg }) => (
          <ArrowLabel
            key={shape.id}
            shape={shape}
            at={{ x: (seg.x1 + seg.x2) / 2, y: (seg.y1 + seg.y2) / 2 }}
            editing={labelEditing === shape.id}
            selected={selected.has(shape.id)}
            onDone={() => setLabelEditing(null)}
          />
        ))}

        {stickies.map(shape => (
          <StickyShape key={shape.id} {...shapeProps(shape)} />
        ))}

        {resizable && (
          <ResizeHandles
            box={resizable}
            zoom={view.z}
            onStart={(handle, e) => startResize(resizable, handle, e)}
          />
        )}

        {marquee && (
          <div
            className="easel-marquee"
            style={{
              transform: `translate(${marquee.x}px, ${marquee.y}px)`,
              width: marquee.w,
              height: marquee.h,
              borderWidth: 1 / view.z,
            }}
          />
        )}

        <PeerCursors peers={peers} zoom={view.z} />
      </div>

      <div className="easel-laser-overlay" aria-hidden="true">
        <LaserCanvas trails={trails} view={view} />
      </div>

      {barAt && (
        <SelectionBar shapes={selectedShapes} at={barAt} onDelete={removeSelected} />
      )}

      {shapes.size === 0 && (
        <p className="easel-hint">Double-click to add a note · L for laser</p>
      )}

      <TitleChip title={title} onChange={next => doc.setTitle(next)} />

      <Toolbar tool={tool} onTool={changeTool} onPickImage={pickImage} />

      <ZoomCluster zoom={view.z} onZoom={zoomBy} onFit={fit} />
    </div>
  )
}
