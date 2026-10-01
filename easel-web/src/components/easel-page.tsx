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
 *
 * What this component does NOT hold in React state, so that it re-renders
 * only when the document, the selection or the tool changes:
 * - the camera (lib/camera.ts): input moves it, once per frame it writes the
 *   layer transform and the grid straight to the DOM; a pan or zoom commits
 *   nothing here;
 * - where shapes are mid-gesture (lib/live-boxes.ts): drag, resize and drawn
 *   boxes re-render only the shapes involved and write the doc on release;
 * - the marquee rect, which sticky is being edited, and cursors (awareness).
 */
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
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
import { useRemoteLasers } from '../lib/awareness'
import { LaserTrails } from '../laser'
import {
  ArrowLabel,
  ArrowLine,
  FrameShape,
  SelectionBarAt,
  StickyShape,
  type BarAnchor,
} from './canvas-shapes'
import { BoardContext, createBoard } from './board-context'
import { CameraLaser, Marquee } from './board-overlays'
import { ShapeHandles } from './resize-handles'
import { PeerCursors } from './peer-cursors'
import { Toolbar, ZoomCluster } from './toolbar'
import { TitleChip } from './title-chip'
import { counters, mark, registerBoard } from '../debug'

type Gesture =
  | { kind: 'pan'; start: Point; view: View }
  | {
      kind: 'move'
      /** The shape under the pointer at pointerdown. */
      hit: string
      ids: string[]
      start: Point
      /** Each moved shape's box at pointerdown. */
      from: Map<string, Box>
      /** Where the drag has them now (shown through live boxes). */
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
const sameSet = (a: Set<string>, b: Set<string>) =>
  a.size === b.size && [...a].every(id => b.has(id))

/** How long after a laser stroke ends before awareness forgets it. */
const LASER_LINGER_MS = 3200
/**
 * While a drawn box grows, write it to the doc this often: peers see it,
 * and the gaps stay under the undo capture timeout (500 ms) so drawing a
 * box is still one undo step with its creation.
 */
const CREATE_SYNC_MS = 200
/** The layer is promoted (will-change) until the camera rests this long. */
const SETTLE_MS = 150

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
  counters.pageRenders++
  const { doc, awareness, config, host } = session
  const viewer = config.viewer
  const markerId = useId()
  const shapes = useSyncExternalStore(doc.subscribeShapes, doc.getShapesSnapshot)
  const trails = useMemo(() => new LaserTrails(), [])
  useRemoteLasers(awareness, trails)
  const board = useMemo(() => createBoard(), [])
  const { camera, live, marquee } = board
  useEffect(() => () => camera.destroy(), [camera])

  const viewport = useRef<HTMLDivElement>(null)
  const layer = useRef<HTMLDivElement>(null)
  const gesture = useRef<Gesture | null>(null)
  const [selected, setSelected] = useState<Set<string>>(EMPTY)
  const [tool, setTool] = useState<Tool>('select')
  const [spaceDown, setSpaceDown] = useState(false)
  const [arrowFrom, setArrowFrom] = useState<string | null>(null)
  const [labelEditing, setLabelEditing] = useState<string | null>(null)
  const lastSent = useRef({ cursor: 0, laser: 0, create: 0 })
  /** Pointer in viewport px while it is over the board; pastes land here. */
  const pointer = useRef<Point | null>(null)
  const lastTap = useRef({ id: '', at: 0 })
  const laserLinger = useRef<ReturnType<typeof setTimeout> | null>(null)
  const panning = tool === 'hand' || spaceDown

  useLayoutEffect(() => {
    counters.pageCommits++
  })

  const select = (ids: Iterable<string>) => {
    const next = new Set(ids)
    setSelected(prev => (sameSet(prev, next) ? prev : next))
  }
  const selectOne = (id: string) => select([id])

  const boxOf = (id: string | undefined): Box | null => {
    if (!id) return null
    const shape = shapes.get(id)
    return shape && shape.type !== 'arrow' ? shape : null
  }
  const boxOfRef = (ref: string | undefined) =>
    ref?.startsWith('shape:') ? boxOf(refId(ref)) : null

  // The viewport's page rect, read once and dropped when it can change, so
  // a pointer or wheel event never forces layout to learn it.
  const rect = useRef<DOMRect | null>(null)
  useEffect(() => {
    const el = viewport.current
    if (!el) return
    const drop = () => {
      rect.current = null
    }
    const ro = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(drop)
    ro?.observe(el)
    window.addEventListener('resize', drop)
    window.addEventListener('scroll', drop, true)
    return () => {
      ro?.disconnect()
      window.removeEventListener('resize', drop)
      window.removeEventListener('scroll', drop, true)
    }
  }, [])
  const clientPoint = (e: { clientX: number; clientY: number }): Point => {
    rect.current ??= viewport.current!.getBoundingClientRect()
    return { x: e.clientX - rect.current.left, y: e.clientY - rect.current.top }
  }

  // The camera writes the layer transform and the dot grid itself, once a
  // frame. While it moves, the layer is flagged `data-moving` (CSS may
  // promote it) until the camera has rested for SETTLE_MS.
  useLayoutEffect(() => {
    const el = viewport.current
    const lay = layer.current
    if (!el || !lay) return
    let settle: ReturnType<typeof setTimeout> | null = null
    const write = (v: View) => {
      lay.style.transform = `translate(${v.x}px, ${v.y}px) scale(${v.z})`
      const grid = 24 * v.z
      el.style.backgroundSize = `${grid}px ${grid}px`
      el.style.backgroundPosition = `${v.x}px ${v.y}px`
    }
    write(camera.applied())
    const off = camera.onApply(v => {
      write(v)
      if (settle) clearTimeout(settle)
      else lay.dataset.moving = ''
      settle = setTimeout(() => {
        settle = null
        delete lay.dataset.moving
      }, SETTLE_MS)
    })
    return () => {
      off()
      if (settle) clearTimeout(settle)
    }
  }, [camera])

  const fit = useCallback(
    (now = false) => {
      const el = viewport.current
      if (!el) return
      const boxes = [...doc.getShapesSnapshot().values()].filter(
        s => s.type !== 'arrow'
      )
      const view = fitBoxes(boxes, el.clientWidth, el.clientHeight)
      if (now) camera.setNow(view)
      else camera.set(view)
    },
    [doc, camera]
  )
  const fitAll = useCallback(() => fit(), [fit])

  // Frame the board once on open, before the first paint: everything that
  // was saved, or the origin.
  useLayoutEffect(() => {
    fit(true)
  }, [fit])

  useEffect(() => {
    registerBoard({
      getView: () => camera.get(),
      setView: view => camera.set(view),
      fit: fitAll,
    })
    return () => registerBoard(null)
  }, [camera, fitAll])

  // First paint with shapes: when the board shows content after `config`.
  useEffect(() => {
    if (shapes.size === 0) return
    mark('firstCommit')
    requestAnimationFrame(() => setTimeout(() => mark('painted')))
  }, [shapes.size])

  // Wheel must be non-passive to stop the page from scrolling; two fingers
  // pan, ⌘/ctrl + wheel (and a trackpad pinch, which arrives as ctrl+wheel)
  // zooms around the pointer. Safari also sends gesture events for a pinch.
  // All of it moves the camera, which applies once per frame.
  useEffect(() => {
    const el = viewport.current
    if (!el) return
    const at = (e: { clientX: number; clientY: number }) => {
      rect.current ??= el.getBoundingClientRect()
      return { x: e.clientX - rect.current.left, y: e.clientY - rect.current.top }
    }
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      const unit = e.deltaMode === 1 ? 16 : 1
      const dx = e.deltaX * unit
      const dy = e.deltaY * unit
      if (e.ctrlKey || e.metaKey) {
        const p = at(e)
        camera.set(v => zoomAt(v, Math.exp(-dy * 0.01), p))
      } else {
        camera.set(v => ({ ...v, x: v.x - dx, y: v.y - dy }))
      }
    }
    let pinch: { z: number } | null = null
    const onGestureStart = (e: Event) => {
      e.preventDefault()
      pinch = { z: camera.get().z }
    }
    const onGestureChange = (e: Event) => {
      e.preventDefault()
      const g = e as GestureEventLike
      if (!pinch) return
      const p = at(g)
      const z = pinch.z * g.scale
      camera.set(v => zoomTo(v, z, p))
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
  }, [camera])

  const zoomBy = useCallback(
    (factor: number) => {
      const el = viewport.current
      if (!el) return
      camera.set(v =>
        zoomAt(v, factor, { x: el.clientWidth / 2, y: el.clientHeight / 2 })
      )
    },
    [camera]
  )

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
            camera.set(v =>
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
  }, [zoomBy, camera])

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

  /** Put the caret in a shape's text. */
  const startEditing = (id: string) => focusShapeText(id)

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
    startEditing(id)
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
    const view = camera.get()
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
      const from = new Map<string, Box>()
      for (const other of ids) {
        const b = boxOf(other)
        if (b) from.set(other, { x: b.x, y: b.y, w: b.w, h: b.h })
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
    const { x, y, w, h } = shape
    gesture.current = {
      kind: 'resize',
      id: shape.id,
      handle,
      type: shape.type,
      start: screenToCanvas(camera.get(), clientPoint(e)),
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
    const view = camera.get()
    const c = screenToCanvas(view, p)
    if (now - lastSent.current.cursor > 33) {
      lastSent.current.cursor = now
      // Only peers render cursors; this no longer re-renders the board.
      awareness.setLocalStateField('cursor', c)
    }
    const g = gesture.current
    if (!g) return
    switch (g.kind) {
      case 'laser': {
        // A fast circle delivers several points per frame; the coalesced
        // ones are what keep the trail round instead of polygonal.
        const batch = e.nativeEvent.getCoalescedEvents?.() ?? []
        if (batch.length > 1) {
          for (const ev of batch) trails.move(screenToCanvas(view, clientPoint(ev)))
        } else {
          trails.move(c)
        }
        publishLaser()
        return
      }
      case 'pan':
        camera.set({
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
        live.set([[g.id, box]])
        return
      }
      case 'marquee': {
        const rect = rectFrom(g.start, c)
        marquee.set(rect)
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
          lastSent.current.create = now
          return
        }
        live.set([[g.id, box]])
        if (now - lastSent.current.create > CREATE_SYNC_MS) {
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
        const boxes: [string, Box & { lifted: true }][] = []
        for (const [id, from] of g.from) {
          const moved = { x: from.x + dx, y: from.y + dy }
          at.set(id, moved)
          boxes.push([id, { ...from, ...moved, lifted: true }])
        }
        g.at = at
        live.set(boxes)
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
        if (g.at) {
          doc.undo.stopCapturing()
          doc.updateShape(g.id, g.at)
          doc.undo.stopCapturing()
        }
        live.clear()
        return
      case 'marquee':
        marquee.set(null)
        return
      case 'create': {
        if (g.id) {
          if (g.at) doc.updateShape(g.id, g.at)
          live.clear()
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
          // One write for the whole drag, and one undo step of its own.
          doc.undo.stopCapturing()
          doc.moveShapes(g.at)
          doc.undo.stopCapturing()
          live.clear()
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
        else startEditing(g.hit)
        return
      }
    }
  }

  /** Double-click on empty paper: a new note right there. */
  const onDoubleClick = (e: ReactMouseEvent<HTMLDivElement>) => {
    if (tool !== 'select' || panning) return
    if ((e.target as Element).closest('[data-ref], .easel-card')) return
    const c = screenToCanvas(camera.get(), clientPoint(e))
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
    return screenToCanvas(camera.get(), {
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
      ? screenToCanvas(camera.get(), pointer.current)
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
    const at = screenToCanvas(camera.get(), clientPoint(e))
    const into = [...shapes.values()]
      .reverse()
      .find(s => s.type === 'frame' && pointInBox(at, s))
    void placeImage(file, into?.id ?? null, at)
  }

  // Stable for the memoized children.
  const startResizeRef = useRef(startResize)
  startResizeRef.current = startResize
  const onHandle = useCallback(
    (shape: Shape, handle: Handle, e: ReactPointerEvent<HTMLElement>) =>
      startResizeRef.current(shape, handle, e),
    []
  )
  const stopLabelEditing = useCallback(() => setLabelEditing(null), [])

  // ---- render ----

  const byLabel = (shape: Shape) =>
    shape.by && shape.by !== viewer.name ? shape.by : undefined
  const frames: Shape[] = []
  const stickies: Shape[] = []
  const arrows: { shape: Shape; from: Shape; to: Shape }[] = []
  for (const shape of shapes.values()) {
    if (shape.type === 'frame') frames.push(shape)
    else if (shape.type === 'sticky') stickies.push(shape)
    else {
      const from = shape.from?.startsWith('shape:') ? shapes.get(refId(shape.from)) : undefined
      const to = shape.to?.startsWith('shape:') ? shapes.get(refId(shape.to)) : undefined
      if (from && to && from.type !== 'arrow' && to.type !== 'arrow')
        arrows.push({ shape, from, to })
    }
  }
  const shapeProps = (shape: Shape) => ({
    shape,
    selected: selected.has(shape.id),
    pending: arrowFrom === shape.id,
    by: byLabel(shape),
  })

  const selectedShapes = [...selected].flatMap(id => {
    const s = shapes.get(id)
    return s ? [s] : []
  })
  const one = selectedShapes.length === 1 ? selectedShapes[0] : undefined
  const resizable =
    tool === 'select' && one && isResizable(one.type) ? one : null
  // Where the selection bar hangs, in canvas coords: above the selection,
  // or above an arrow's middle. The bar itself follows the camera.
  const anchor = ((): BarAnchor | null => {
    if (tool !== 'select' || !selectedShapes.length) return null
    if (one?.type === 'arrow') {
      const ends = arrows.find(a => a.shape.id === one.id)
      const seg = ends ? boxSegment(ends.from, ends.to) : null
      if (!seg) return null
      return { x: (seg.x1 + seg.x2) / 2, y: (seg.y1 + seg.y2) / 2, lift: -18 }
    }
    const boxes = selectedShapes.filter(s => s.type !== 'arrow')
    if (!boxes.length) return null
    const minX = Math.min(...boxes.map(b => b.x))
    const maxX = Math.max(...boxes.map(b => b.x + b.w))
    const minY = Math.min(...boxes.map(b => b.y))
    return { x: (minX + maxX) / 2, y: minY, lift: -12, minTop: 56 }
  })()

  const cursor = panning
    ? 'easel-cursor-grab'
    : tool === 'laser'
      ? 'easel-cursor-laser'
      : tool === 'select'
        ? 'easel-cursor-default'
        : 'easel-cursor-crosshair'

  return (
    <BoardContext.Provider value={board}>
      <div
        ref={viewport}
        role="application"
        aria-label="Easel"
        tabIndex={0}
        className={`easel-viewport ${cursor}`}
        data-tool={tool}
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
        <div ref={layer} className="easel-layer">
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
            {arrows.map(({ shape, from, to }) => (
              <ArrowLine
                key={shape.id}
                shape={shape}
                from={from}
                to={to}
                selected={selected.has(shape.id)}
                markerId={markerId}
              />
            ))}
          </svg>

          {/* A picture is opaque content, so it covers the lines. */}
          {frames
            .filter(shape => shape.image)
            .map(shape => (
              <FrameShape key={shape.id} {...shapeProps(shape)} />
            ))}

          {arrows.map(({ shape, from, to }) => (
            <ArrowLabel
              key={shape.id}
              shape={shape}
              from={from}
              to={to}
              editing={labelEditing === shape.id}
              selected={selected.has(shape.id)}
              onDone={stopLabelEditing}
            />
          ))}

          {stickies.map(shape => (
            <StickyShape key={shape.id} {...shapeProps(shape)} />
          ))}

          {resizable && (
            <ShapeHandles
              shape={resizable}
              onStart={(handle, e) => onHandle(resizable, handle, e)}
            />
          )}

          <Marquee />

          <PeerCursors awareness={awareness} />
        </div>

        <div className="easel-laser-overlay" aria-hidden="true">
          <CameraLaser trails={trails} />
        </div>

        {anchor && (
          <SelectionBarAt
            anchor={anchor}
            shapes={selectedShapes}
            onDelete={removeSelected}
          />
        )}

        {shapes.size === 0 && (
          <p className="easel-hint">Double-click to add a note · L for laser</p>
        )}

        <TitleChip title={title} onChange={next => doc.setTitle(next)} />

        <Toolbar tool={tool} onTool={changeTool} onPickImage={pickImage} />

        <ZoomCluster onZoom={zoomBy} onFit={fitAll} />
      </div>
    </BoardContext.Provider>
  )
}
