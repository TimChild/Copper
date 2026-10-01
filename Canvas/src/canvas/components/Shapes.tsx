/**
 * Shape views in world coordinates: stickies, text, frames, images, link
 * cards (DOM) and arrows (one SVG layer, with labels as DOM). Each view is
 * memoised on its plain shape, so a change re-renders only what changed.
 */
import { memo, useLayoutEffect, useRef, useState, type CSSProperties, type RefObject } from 'react'
import { ExternalLink, Globe } from 'lucide-react'
import type { ArrowPath } from '../arrows'
import { hueOf, inkOn, paperOf, strokeOf } from '../colors'
import { toggleTask } from '../markdown-lite'
import { STICKY_FONT, TEXT_FONT, isNamedColor, type Shape } from '../types'
import { useBoard } from './context'
import { MarkdownLite } from './MarkdownLite'
import { TextEditor } from './TextEditor'
import { cn, useMountFocus } from './ui'

const STICKY_FONT_MIN = 9

/** One-line in-place field (frame titles, arrow labels): Enter or Esc finishes. */
function InlineField({
  label,
  value,
  placeholder,
  onChange,
  onDone,
  className,
  style,
}: {
  label: string
  value: string
  placeholder: string
  onChange: (next: string) => void
  onDone: () => void
  className?: string
  style?: CSSProperties
}) {
  const ref = useRef<HTMLInputElement>(null)
  useMountFocus(ref)
  return (
    <input
      ref={ref}
      aria-label={label}
      defaultValue={value}
      placeholder={placeholder}
      onChange={e => onChange(e.currentTarget.value)}
      onBlur={onDone}
      onKeyDown={e => {
        e.stopPropagation()
        if (e.key === 'Enter' || e.key === 'Escape') {
          e.preventDefault()
          onDone()
        }
      }}
      onPointerDown={e => e.stopPropagation()}
      onDoubleClick={e => e.stopPropagation()}
      className={className}
      style={style}
    />
  )
}

const place = (s: Pick<Shape, 'x' | 'y' | 'w' | 'h'>) => ({
  width: s.w,
  height: s.h,
  transform: `translate(${s.x}px, ${s.y}px)`,
})

/**
 * Shrink the rendered sticky's font until its content fits the box, like
 * FigJam's auto-size text. Refits on every text or size change, so a peer's
 * typing refits live too.
 */
function useFitText(ref: RefObject<HTMLDivElement | null>, base: number, deps: unknown[], paused: boolean) {
  const [size, setSize] = useState(base)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el || paused) return
    const content = el.firstElementChild as HTMLElement | null
    let s = base
    el.style.fontSize = `${s}px`
    while (s > STICKY_FONT_MIN && content && content.scrollHeight > el.clientHeight + 1) {
      s -= 1
      el.style.fontSize = `${s}px`
    }
    setSize(s)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [base, paused, ...deps])
  return size
}

interface ViewProps {
  shape: Shape
  editing: boolean
}

export const StickyView = memo(function StickyView({ shape, editing }: ViewProps) {
  const board = useBoard()
  const base = shape.fontSize ?? STICKY_FONT
  const fitRef = useRef<HTMLDivElement>(null)
  const fitSize = useFitText(fitRef, base, [shape.text, shape.w, shape.h], editing)
  const empty = !shape.text.trim()
  return (
    <div
      data-id={shape.id}
      data-kind="sticky"
      className="absolute left-0 top-0 flex flex-col rounded-[4px] shadow-note"
      style={{ ...place(shape), background: paperOf(shape.color), color: inkOn(shape.color) }}
    >
      <div
        ref={fitRef}
        className={cn('relative min-h-0 flex-1 overflow-hidden px-[15px] pb-[13px] pt-[14px] leading-[1.38]', editing && 'cursor-text')}
        style={{ fontSize: editing ? fitSize : undefined }}
      >
        {editing ? (
          <TextEditor
            label="Sticky note"
            value={shape.text}
            placeholder="Type something…"
            onChange={text => board.store.setText(shape.id, text)}
            onDone={() => board.endEdit(shape.id)}
            onSibling={dir => board.sibling(shape.id, dir)}
            className="h-full overflow-y-auto leading-[1.38]"
          />
        ) : (
          <>
            <MarkdownLite
              source={shape.text}
              onOpenUrl={board.openUrl}
              onToggleTask={line => {
                if (!board.readOnly) board.store.setText(shape.id, toggleTask(shape.text, line))
              }}
            />
            {empty && <span className="pointer-events-none absolute left-[15px] top-[14px] opacity-35">Type something…</span>}
          </>
        )}
      </div>
    </div>
  )
})

export const TextView = memo(function TextView({ shape, editing }: ViewProps) {
  const board = useBoard()
  const font = shape.fontSize ?? TEXT_FONT
  const color = shape.color === 'gray' ? 'var(--ink)' : strokeOf(shape.color)
  const align = shape.align ?? 'left'
  return (
    <div
      data-id={shape.id}
      data-kind="text"
      className="absolute left-0 top-0"
      style={{ ...place(shape), color, fontSize: font, lineHeight: 1.3, textAlign: align }}
    >
      {editing ? (
        <TextEditor
          label="Text"
          value={shape.text}
          placeholder="Text"
          autoGrow
          onHeight={h => board.autoHeight(shape.id, h)}
          onChange={text => board.store.setText(shape.id, text)}
          onDone={() => board.endEdit(shape.id)}
          className="overflow-hidden font-medium leading-[1.3]"
          style={{ textAlign: align }}
        />
      ) : shape.text.trim() ? (
        <MarkdownLite source={shape.text} className="font-medium" onOpenUrl={board.openUrl} />
      ) : (
        <span className="font-medium opacity-35">Text</span>
      )}
    </div>
  )
})

/** Frame label size: constant on screen when zoomed out, scaling with the board when zoomed in. */
const labelSize = (zoom: number) => 13 / Math.min(1, zoom)

export const FrameView = memo(function FrameView({
  shape,
  editing,
  selected,
  zoom,
}: ViewProps & { selected: boolean; zoom: number }) {
  const board = useBoard()
  const fill =
    shape.color === 'white' || shape.color === 'gray'
      ? 'var(--frame-fill)'
      : isNamedColor(shape.color)
        ? `color-mix(in srgb, ${paperOf(shape.color)} 62%, transparent)`
        : `color-mix(in srgb, ${shape.color} 22%, transparent)`
  const font = labelSize(zoom)
  return (
    <div data-id={shape.id} data-kind="frame" className="absolute left-0 top-0" style={place(shape)}>
      <div
        data-part="frame-title"
        className="absolute left-0 flex max-w-full items-end"
        style={{ bottom: '100%', height: font * 2, fontSize: font, paddingBottom: font * 0.35 }}
      >
        {editing ? (
          <InlineField
            label="Frame title"
            value={shape.title}
            placeholder="Frame"
            onChange={title => board.store.update(shape.id, { title })}
            onDone={() => board.endEdit(shape.id)}
            className="min-w-[8em] rounded-md bg-surface px-1.5 font-semibold text-ink shadow-1 outline outline-2 outline-accent"
            style={{ width: Math.max(160, shape.w * 0.6) }}
          />
        ) : (
          <span className={cn('truncate px-0.5 font-semibold', selected ? 'text-accent' : 'text-ink-3')}>
            {shape.title.trim() || 'Frame'}
          </span>
        )}
      </div>
      <div
        data-part="frame-body"
        className={cn('absolute inset-0 overflow-hidden rounded-[10px] border', selected ? 'border-transparent' : 'border-line-2')}
        style={{ background: fill }}
      >
        {shape.image && (
          <img
            src={shape.image.src}
            alt={shape.title.trim() || 'Image in frame'}
            draggable={false}
            className="pointer-events-none h-full w-full object-contain"
          />
        )}
        {!shape.image && selected && !board.readOnly && (
          <p className="pointer-events-none flex h-full items-center justify-center text-[13px] text-ink-4">
            Drop or paste an image
          </p>
        )}
      </div>
    </div>
  )
})

export const ImageView = memo(function ImageView({ shape }: { shape: Shape }) {
  const [failed, setFailed] = useState(false)
  return (
    <div
      data-id={shape.id}
      data-kind="image"
      className="absolute left-0 top-0 overflow-hidden rounded-[6px] bg-surface-2 shadow-note"
      style={place(shape)}
    >
      {shape.src && !failed ? (
        <img
          src={shape.src}
          alt=""
          draggable={false}
          onError={() => setFailed(true)}
          className="pointer-events-none h-full w-full object-cover"
        />
      ) : (
        <div className="flex h-full items-center justify-center text-[12px] text-ink-4">Image unavailable</div>
      )}
    </div>
  )
})

function hostLabel(url: string) {
  try {
    const u = new URL(url)
    return (u.hostname || u.protocol.replace(':', '')).replace(/^www\./, '')
  } catch {
    return url
  }
}

export const LinkView = memo(function LinkView({ shape, selected }: { shape: Shape; selected: boolean }) {
  const board = useBoard()
  const [iconFailed, setIconFailed] = useState(false)
  const host = hostLabel(shape.url ?? '')
  const title = shape.title.trim() || host
  const accent = shape.color !== 'white' ? strokeOf(shape.color) : null
  const hue = hueOf(host)
  const compact = shape.h < 72
  return (
    <div
      data-id={shape.id}
      data-kind="link"
      className="group absolute left-0 top-0 flex items-center gap-3 overflow-hidden rounded-[12px] border border-line bg-surface px-3 text-ink shadow-note"
      style={{ ...place(shape), borderLeft: accent ? `4px solid ${accent}` : undefined }}
      title={shape.url}
    >
      <div
        className="flex h-9 w-9 shrink-0 items-center justify-center overflow-hidden rounded-[9px]"
        style={{ background: shape.favicon && !iconFailed ? 'var(--surface-2)' : `hsl(${hue} 55% 92%)` }}
      >
        {shape.favicon && !iconFailed ? (
          <img src={shape.favicon} alt="" draggable={false} onError={() => setIconFailed(true)} className="h-5 w-5 object-contain" />
        ) : host ? (
          <span className="text-[15px] font-bold" style={{ color: `hsl(${hue} 45% 38%)` }}>
            {host.slice(0, 1).toUpperCase()}
          </span>
        ) : (
          <Globe className="h-4 w-4 text-ink-3" aria-hidden="true" />
        )}
      </div>
      <div className="min-w-0 flex-1">
        <p className={cn('font-semibold leading-snug', compact ? 'truncate text-[13px]' : 'line-clamp-2 text-[14px]')}>{title}</p>
        <p className="truncate text-[12px] text-ink-3">{host}</p>
      </div>
      <button
        type="button"
        aria-label={`Open ${host}`}
        className={cn(
          'flex h-7 w-7 shrink-0 items-center justify-center rounded-lg text-ink-3 transition-opacity hover:bg-surface-2 hover:text-ink',
          selected ? 'opacity-100' : 'opacity-0 group-hover:opacity-100'
        )}
        onPointerDown={e => e.stopPropagation()}
        onDoubleClick={e => e.stopPropagation()}
        onClick={e => {
          e.stopPropagation()
          if (shape.url) board.openUrl(shape.url)
        }}
      >
        <ExternalLink className="h-3.5 w-3.5" aria-hidden="true" />
      </button>
    </div>
  )
})

// ---- arrows -----------------------------------------------------------------

export interface DrawnArrow {
  shape: Shape
  path: ArrowPath
}

/** Arrowhead as a filled triangle, pointing along the path's last tangent. */
function head(path: ArrowPath, size: number): string {
  const tip = { x: path.seg.x2, y: path.seg.y2 }
  const from = path.c2 ?? { x: path.seg.x1, y: path.seg.y1 }
  let dx = tip.x - from.x
  let dy = tip.y - from.y
  const len = Math.hypot(dx, dy) || 1
  dx /= len
  dy /= len
  const back = { x: tip.x - dx * size, y: tip.y - dy * size }
  const half = size * 0.48
  const l = { x: back.x - dy * half, y: back.y + dx * half }
  const r = { x: back.x + dy * half, y: back.y - dx * half }
  const f = (n: number) => Math.round(n * 10) / 10
  return `M${f(tip.x)},${f(tip.y)} L${f(l.x)},${f(l.y)} L${f(r.x)},${f(r.y)} Z`
}

const arrowStroke = (s: Shape) => (s.color === 'gray' ? 'var(--stroke-gray)' : strokeOf(s.color))

export const ArrowLayer = memo(function ArrowLayer({
  arrows,
  selected,
  zoom,
}: {
  arrows: readonly DrawnArrow[]
  selected: ReadonlySet<string>
  zoom: number
}) {
  const width = 2
  const hit = Math.max(14, 14 / zoom)
  return (
    <svg className="pointer-events-none absolute left-0 top-0 overflow-visible" width={1} height={1} aria-hidden="true">
      {arrows.map(({ shape, path }) => {
        const on = selected.has(shape.id)
        const stroke = arrowStroke(shape)
        return (
          <g key={shape.id} data-id={shape.id} data-kind="arrow">
            <path d={path.d} fill="none" stroke="transparent" strokeWidth={hit} style={{ pointerEvents: 'stroke' }} />
            {on && (
              <path
                d={path.d}
                fill="none"
                stroke="var(--accent)"
                strokeOpacity={0.28}
                strokeWidth={width + 6 / zoom}
                strokeLinecap="round"
              />
            )}
            <path d={path.d} fill="none" stroke={stroke} strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" />
            <path d={head(path, 11)} fill={stroke} stroke={stroke} strokeWidth={1.5} strokeLinejoin="round" style={{ pointerEvents: 'fill' }} />
          </g>
        )
      })}
    </svg>
  )
})

export const ArrowLabel = memo(function ArrowLabel({
  shape,
  path,
  editing,
  selected,
}: {
  shape: Shape
  path: ArrowPath
  editing: boolean
  selected: boolean
}) {
  const board = useBoard()
  const label = shape.label ?? ''
  if (!editing && !label) return null
  return (
    <div
      data-id={shape.id}
      data-kind="arrow-label"
      className="absolute left-0 top-0"
      style={{ transform: `translate(${path.mid.x}px, ${path.mid.y}px) translate(-50%, -50%)` }}
    >
      {editing ? (
        <InlineField
          label="Arrow label"
          value={label}
          placeholder="Label"
          onChange={next => board.store.update(shape.id, { label: next })}
          onDone={() => board.endEdit(shape.id)}
          className="w-40 rounded-lg border border-accent bg-surface px-2 py-1 text-center text-[13px] text-ink shadow-2 outline-none"
        />
      ) : (
        <span
          className={cn(
            'block max-w-[280px] cursor-default truncate rounded-lg border bg-surface px-2 py-[3px] text-[13px] font-medium text-ink-2 shadow-1',
            selected ? 'border-accent' : 'border-line'
          )}
        >
          {label}
        </span>
      )}
    </div>
  )
})
