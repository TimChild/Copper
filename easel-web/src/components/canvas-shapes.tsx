/**
 * Stickies, frames, arrow labels and the selection bar. A frame is a titled
 * area for grouping notes, and holds one picture.
 *
 * Lifted from the wiki app's apps/web/src/modules/wiki/components/canvas-shapes.tsx:
 * the doc comes from context instead of module imports, the toolbar moved to
 * toolbar.tsx, Tailwind became data attributes + app.css, and the selection
 * bar takes every selected shape (multi-select) rather than one.
 *
 * Every shape is memoized and gets only primitives plus its own `Shape`
 * object (which the doc snapshot keeps identical until that shape changes).
 * Where a shape *is* during a drag or resize comes from the board's live
 * boxes, which each shape reads for its own id: moving one note re-renders
 * that note and the arrows on it, nothing else.
 */
import { memo, useLayoutEffect, useRef, useState } from 'react'
import { SHAPE_COLORS, type Shape } from '../doc/easel-doc'
import { imageSrc } from '../lib/canvas-images'
import { boxSegment, type Point } from '../lib/canvas-geometry'
import { useCameraView } from '../lib/camera'
import { useLiveActive, useLiveBox } from '../lib/live-boxes'
import { useStoreSelect } from '../lib/store'
import { useBoard } from './board-context'
import { useEasel } from './easel-context'
import { Icon } from './icons'
import { MarkdownLiteInline } from './markdown-lite'
import { StickyEditor } from './sticky-editor'
import { counters } from '../debug'

/** Sticky body size; the rendered view shrinks from here to fit its box. */
const STICKY_FONT = 14
const STICKY_FONT_MIN = 9

/**
 * Shrink a rendered sticky's font until its content fits the box, like
 * FigJam's auto-size text. Runs on every text or size change, so a remote
 * peer's typing refits live too.
 */
function useFitText(deps: unknown[], paused = false) {
  const ref = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    const el = ref.current
    // While the note is being edited the box scrolls instead; refit on blur.
    if (!el || paused) return
    // The editor's document is the thing that grows; the box around it clips.
    const content = el.querySelector<HTMLElement>('.tiptap') ?? el
    let size = STICKY_FONT
    el.style.fontSize = `${size}px`
    while (
      size > STICKY_FONT_MIN &&
      content.scrollHeight > el.clientHeight + 1
    ) {
      size -= 1
      el.style.fontSize = `${size}px`
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  return ref
}

/**
 * Focus state of a shape's text field. Stickies edit in place (see
 * `StickyEditor`); a frame title swaps its input for rendered markdown.
 */
function useFieldFocus() {
  const [focused, setFocused] = useState(false)
  return {
    focused,
    onFocus: () => setFocused(true),
    onBlur: () => setFocused(false),
  }
}

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

/**
 * Actions for the selection: colours, remove picture, delete. Lives in
 * screen space above the shapes, so it stays the same size at any zoom.
 */
export function SelectionBar({
  shapes,
  at,
  onDelete,
}: {
  shapes: Shape[]
  /** Screen point the bar's bottom edge is centred on. */
  at: Point
  onDelete: () => void
}) {
  const { doc } = useEasel()
  const colourable = shapes.filter(s => s.type !== 'arrow')
  const only = shapes.length === 1 ? shapes[0] : undefined
  const kind =
    shapes.length > 1
      ? `${shapes.length} items`
      : only?.type === 'arrow'
        ? 'arrow'
        : only?.type === 'frame'
          ? 'frame'
          : 'note'
  const current = colourable.every(s => s.color === colourable[0]?.color)
    ? colourable[0]?.color
    : undefined
  return (
    <div
      role="toolbar"
      aria-label={`Selected ${kind}`}
      data-testid="selection-bar"
      className="easel-card easel-selection-bar"
      style={{ left: at.x, top: at.y }}
      onPointerDown={stop}
    >
      {colourable.length > 0 && (
        <>
          {SHAPE_COLORS.map(c => (
            <button
              key={c}
              type="button"
              aria-label={`Colour ${c}`}
              aria-pressed={current === c}
              className="easel-swatch"
              data-color={c}
              onClick={() => {
                for (const s of colourable) doc.updateShape(s.id, { color: c })
              }}
            />
          ))}
          <span className="easel-bar-sep" aria-hidden="true" />
        </>
      )}
      {only?.type === 'frame' && only.image && (
        <>
          <button
            type="button"
            aria-label="Remove image"
            title="Remove image"
            className="easel-bar-button"
            onClick={() => doc.updateShape(only.id, { image: '' })}
          >
            <Icon name="eraser" size={14} />
          </button>
        </>
      )}
      <button
        type="button"
        aria-label={`Delete ${kind}`}
        title={`Delete ${kind} (Delete)`}
        className="easel-bar-button easel-bar-danger"
        onClick={onDelete}
      >
        <Icon name="trash" size={14} />
      </button>
    </div>
  )
}

interface ShapeProps {
  shape: Shape
  selected: boolean
  pending: boolean
  /** Creator label, when it is someone other than the viewer. */
  by?: string
}

export const StickyShape = memo(function StickyShape({
  shape,
  selected,
  pending,
  by,
}: ShapeProps) {
  counters.shapeRenders++
  const { doc, host } = useEasel()
  const { live } = useBoard()
  const liveBox = useLiveBox(live, shape.id)
  const box = liveBox ?? shape
  const lifted = liveBox?.lifted ?? false
  const field = useFieldFocus()
  const fit = useFitText([shape.text, box.w, box.h, field.focused], field.focused)
  return (
    <div
      data-ref={`shape:${shape.id}`}
      className="easel-sticky"
      data-color={shape.color}
      data-selected={selected || undefined}
      data-pending={pending || undefined}
      data-lifted={lifted || undefined}
      style={{
        width: box.w,
        height: box.h,
        transform: `translate(${box.x}px, ${box.y}px)`,
      }}
    >
      <div ref={fit} className="easel-sticky-body">
        <StickyEditor
          value={shape.text}
          onChange={md => doc.setShapeText(shape.id, md)}
          onOpenLink={href => host.open(href)}
          onFocus={field.onFocus}
          onBlur={field.onBlur}
        />
      </div>
      {by && <span className="easel-by">{by}</span>}
    </div>
  )
})

export const FrameShape = memo(function FrameShape({
  shape,
  selected,
  pending,
  by,
}: ShapeProps) {
  counters.shapeRenders++
  const { doc, host, easelId } = useEasel()
  const { live } = useBoard()
  const liveBox = useLiveBox(live, shape.id)
  const box = liveBox ?? shape
  const field = useFieldFocus()
  const rendered = !field.focused && shape.text.trim() !== ''
  const src = shape.image ? imageSrc(shape.image, host, easelId) : ''
  return (
    <div
      data-ref={`shape:${shape.id}`}
      className="easel-frame"
      data-selected={selected || undefined}
      data-pending={pending || undefined}
      data-lifted={liveBox?.lifted || undefined}
      style={{
        width: box.w,
        height: box.h,
        transform: `translate(${box.x}px, ${box.y}px)`,
      }}
    >
      <div className="easel-frame-title" data-color={shape.color}>
        <div className="easel-frame-title-field">
          <input
            aria-label="Frame title"
            value={shape.text}
            placeholder="Frame"
            onChange={e => doc.setShapeText(shape.id, e.target.value)}
            onPointerDown={stop}
            onFocus={field.onFocus}
            onBlur={field.onBlur}
            onKeyDown={e => {
              if (e.key === 'Enter' || e.key === 'Escape')
                e.currentTarget.blur()
            }}
            className="easel-frame-input"
            data-inert={!selected || undefined}
            data-hidden={rendered || undefined}
          />
          {rendered && (
            <MarkdownLiteInline
              source={shape.text}
              className="easel-frame-rendered"
            />
          )}
        </div>
        {by && <span className="easel-by">{by}</span>}
      </div>
      {shape.image ? (
        <img
          src={src}
          alt={shape.text.trim() || 'Pasted image'}
          draggable={false}
          decoding="async"
          className="easel-frame-image"
        />
      ) : (
        selected && (
          <p className="easel-frame-hint">Paste or drop a picture</p>
        )
      )}
    </div>
  )
})

interface ArrowProps {
  shape: Shape
  /** The shapes the arrow runs between, as the doc has them. */
  from: Shape
  to: Shape
  selected: boolean
}

/** The arrow's segment, following either end while a gesture moves it. */
function useArrowSegment(from: Shape, to: Shape) {
  const { live } = useBoard()
  const a = useLiveBox(live, from.id) ?? from
  const b = useLiveBox(live, to.id) ?? to
  return boxSegment(a, b)
}

/** One arrow inside the board's <svg>. */
export const ArrowLine = memo(function ArrowLine({
  shape,
  from,
  to,
  selected,
  markerId,
}: ArrowProps & { markerId: string }) {
  counters.shapeRenders++
  const seg = useArrowSegment(from, to)
  if (!seg) return null
  return (
    <g data-ref={`shape:${shape.id}`}>
      <line
        {...seg}
        stroke="transparent"
        strokeWidth={14}
        style={{ pointerEvents: 'stroke' }}
      />
      <line
        {...seg}
        strokeWidth={selected ? 2.5 : 2}
        strokeLinecap="round"
        className={selected ? 'easel-arrow-line-active' : 'easel-arrow-line'}
        markerEnd={`url(#${markerId}-${selected ? 'active' : 'arrow'})`}
      />
    </g>
  )
})

/** An arrow's label at the midpoint; an inline input while editing. */
export const ArrowLabel = memo(function ArrowLabel({
  shape,
  from,
  to,
  editing,
  selected,
  onDone,
}: ArrowProps & {
  editing: boolean
  onDone: () => void
}) {
  counters.shapeRenders++
  const { doc } = useEasel()
  const seg = useArrowSegment(from, to)
  if (!seg || (!editing && !shape.text)) return null
  const at = { x: (seg.x1 + seg.x2) / 2, y: (seg.y1 + seg.y2) / 2 }
  return (
    <div
      data-ref={`shape:${shape.id}`}
      className="easel-arrow-label"
      style={{
        transform: `translate(${at.x}px, ${at.y}px) translate(-50%, -50%)`,
      }}
    >
      {editing ? (
        <input
          autoFocus
          aria-label="Arrow label"
          value={shape.text}
          placeholder="Label"
          onChange={e => doc.setShapeText(shape.id, e.target.value)}
          onPointerDown={stop}
          onBlur={onDone}
          onKeyDown={e => {
            if (e.key === 'Enter' || e.key === 'Escape') onDone()
          }}
          className="easel-arrow-input"
        />
      ) : (
        <span className="easel-arrow-text" data-selected={selected || undefined}>
          {shape.text}
        </span>
      )}
    </div>
  )
})

/** Where the selection bar hangs, in canvas coords (the camera is applied later). */
export interface BarAnchor {
  x: number
  y: number
  /** Screen px above the anchor. */
  lift: number
  /** Keep the bar below the title chip. */
  minTop?: number
}

/**
 * The selection bar in screen space: follows the camera every frame, and
 * hides while a drag, resize or marquee is in flight, all without the page.
 */
export function SelectionBarAt({
  anchor,
  shapes,
  onDelete,
}: {
  anchor: BarAnchor
  shapes: Shape[]
  onDelete: () => void
}) {
  const { camera, live, marquee } = useBoard()
  const view = useCameraView(camera)
  const moving = useLiveActive(live)
  const banding = useStoreSelect(marquee, isBanding)
  if (moving || banding) return null
  const y = view.y + anchor.y * view.z + anchor.lift
  return (
    <SelectionBar
      shapes={shapes}
      at={{
        x: view.x + anchor.x * view.z,
        y: anchor.minTop === undefined ? y : Math.max(anchor.minTop, y),
      }}
      onDelete={onDelete}
    />
  )
}
const isBanding = (m: unknown) => m !== null
