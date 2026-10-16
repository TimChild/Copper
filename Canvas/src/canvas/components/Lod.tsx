/**
 * The simplified shapes the board draws when it is zoomed out so far that
 * their text could not be read (`canvas/lod.ts`): the shape's own colour
 * block and box, and one heading line, at the size and place the full view
 * draws them. They carry the same `data-id` / `data-kind`, so selecting,
 * moving, double-clicking (which opens the full view to edit) and the
 * context menu work on them as on the full ones; comment pins, cursors and
 * selection outlines are overlays and don't change.
 *
 * Notes — the hundreds of them a big board has — are drawn together in one
 * SVG (`LowNotes`), not as a positioned element each: WebKit paints every
 * positioned element as a layer of its own, and walking 800 of them for every
 * tile a pan or zoom exposes was most of what those frames cost. They sit
 * above the board's other boxes and under its arrows.
 */
import { memo, type CSSProperties } from 'react'
import { CHECKLIST_MIN } from '../checklist'
import { inkOn, paperOf, strokeOf } from '../colors'
import { countRender } from '../debug'
import { barWidth, headingLine } from '../lod'
import { TIMELINE_MIN } from '../timeline'
import { STICKY_FONT, TEXT_FONT, type Shape } from '../types'
import { place } from './Shapes'

export type LowKind = 'text' | 'checklist' | 'timeline'

/**
 * `bars`: the text is too small even for a heading line to be read (`LOD_BAR_PX`):
 * lines draw as soft bars of the same length and place.
 */
export const LowShape = memo(function LowShape({ shape, kind, bars }: { shape: Shape; kind: LowKind; bars: boolean }) {
  countRender('shapeRenders')
  switch (kind) {
    case 'text':
      return <LowText shape={shape} bars={bars} />
    case 'checklist':
      return <LowCard shape={shape} kind="checklist" bars={bars} />
    case 'timeline':
      return <LowCard shape={shape} kind="timeline" bars={bars} />
  }
})

/** One line of text, or the bar that stands for it. */
function Line(props: { text: string; font: number; bars: boolean; maxW: number; className?: string; style?: CSSProperties }) {
  const { text, font, bars, maxW, className, style } = props
  if (!bars)
    return (
      <div className={`truncate ${className ?? ''}`} style={{ fontSize: font, ...style }}>
        {text}
      </div>
    )
  const lead = style?.lineHeight ? Number(style.lineHeight) : 1.3
  return (
    <div className={className} style={{ ...style, fontSize: font, height: `${lead}em`, display: 'flex', alignItems: 'center' }}>
      {/* A translucent colour, not `opacity`: 800 bars must not each open a transparency layer. */}
      <div style={{ width: barWidth(text, font, maxW), height: '0.55em', borderRadius: '0.2em', background: 'color-mix(in srgb, currentColor 30%, transparent)' }} />
    </div>
  )
}

function LowText({ shape, bars }: { shape: Shape; bars: boolean }) {
  const font = shape.fontSize ?? TEXT_FONT
  const line = headingLine(shape.text)
  const color = shape.color === 'gray' ? 'var(--ink)' : strokeOf(shape.color)
  const align = shape.align ?? 'left'
  return (
    <div
      data-id={shape.id}
      data-kind="text"
      data-lod="low"
      className="absolute left-0 top-0"
      style={{ ...place(shape), color, textAlign: align }}
    >
      {line.text && (
        <Line
          text={line.text}
          font={font}
          bars={bars}
          maxW={shape.w}
          className="font-medium"
          style={{ lineHeight: 1.3, justifyContent: align === 'center' ? 'center' : align === 'right' ? 'flex-end' : undefined }}
        />
      )}
    </div>
  )
}

/** Row height and the room above the rows of a checklist card (`checklist.css`). */
const CL_ROW_H = 34
const CL_HEADS_H = 28

/** A checklist or timeline: its card, its band and title; a checklist's rows as one line each, its ticks as boxes. */
function LowCard({ shape, kind, bars }: { shape: Shape; kind: 'checklist' | 'timeline'; bars: boolean }) {
  const title = shape.title.trim()
  const white = shape.color === 'white'
  const band = white ? 'var(--surface-2)' : paperOf(shape.color)
  const bandInk = white ? 'var(--ink)' : inkOn(shape.color)
  const accent = strokeOf(shape.color)
  const min = kind === 'checklist' ? CHECKLIST_MIN.h : TIMELINE_MIN.h
  const h = Math.max(shape.h, min)
  const style = {
    width: shape.w,
    height: h,
    transform: `translate(${shape.x}px, ${shape.y}px)`,
    boxShadow: 'none',
  } as CSSProperties
  const bandH = kind === 'checklist' ? 48 : 62
  const rows = kind === 'checklist' ? (shape.rows ?? []) : []
  const picks = shape.picks ?? {}
  const heads = (shape.columns?.length ?? 1) > 1 ? CL_HEADS_H : 0
  const fit = Math.max(0, Math.floor((h - bandH - heads - 4) / CL_ROW_H))
  return (
    <div data-id={shape.id} data-kind={kind} data-lod="low" className={`${kind === 'checklist' ? 'cl-card' : 'tl-card'} absolute left-0 top-0`} style={style}>
      <div
        className="flex items-center px-[14px]"
        style={{ height: bandH + heads, background: `color-mix(in srgb, ${band} 78%, var(--surface))`, color: bandInk }}
      >
        <Line text={title || 'Untitled'} font={15} bars={bars} maxW={shape.w - 28} className="min-w-0 flex-1 font-[650]" style={{ lineHeight: 1.3, opacity: title ? 1 : 0.5 }} />
      </div>
      {rows.slice(0, fit).map(row => (
        <div key={row.id} className="mx-[4px] flex items-center gap-[10px] px-[10px]" style={{ height: CL_ROW_H, marginTop: row === rows[0] ? 4 : 0 }}>
          <span
            className="shrink-0 rounded-[4px]"
            style={{ width: 16, height: 16, border: `1.5px solid ${accent}`, background: picks[row.id] ? accent : 'transparent' }}
          />
          <Line text={row.label} font={14} bars={bars} maxW={shape.w - 60} className="min-w-0 flex-1" style={{ lineHeight: 1.3 }} />
        </div>
      ))}
    </div>
  )
}

/** A note's heading line cut to what fits (`…`), by an average glyph width: at this size nobody can tell. */
function fitLine(text: string, font: number, maxW: number) {
  const most = Math.max(0, Math.floor(maxW / (font * 0.55)))
  return text.length <= most ? text : `${text.slice(0, Math.max(0, most - 1)).trimEnd()}…`
}

/** Note padding and line height (`StickyView`). */
const NOTE_PAD_X = 15
const NOTE_PAD_TOP = 14
const NOTE_LEAD = 1.38

const LowNote = memo(function LowNote({ shape, bars }: { shape: Shape; bars: boolean }) {
  countRender('shapeRenders')
  const font = shape.fontSize ?? STICKY_FONT
  const line = headingLine(shape.text)
  const size = line.heading ? font * 1.25 : font
  const cy = shape.y + NOTE_PAD_TOP + (size * NOTE_LEAD) / 2
  const maxW = shape.w - NOTE_PAD_X * 2
  const ink = inkOn(shape.color)
  return (
    <g data-id={shape.id} data-kind="sticky" data-lod="low" style={{ pointerEvents: 'visiblePainted' }}>
      <rect x={shape.x} y={shape.y} width={shape.w} height={shape.h} rx={4} style={{ fill: paperOf(shape.color) }} />
      {line.text &&
        (bars ? (
          <rect
            x={shape.x + NOTE_PAD_X}
            y={cy - size * 0.275}
            width={barWidth(line.text, size, maxW)}
            height={size * 0.55}
            rx={size * 0.2}
            style={{ fill: ink, fillOpacity: 0.3 }}
          />
        ) : (
          <text x={shape.x + NOTE_PAD_X} y={cy} dominantBaseline="central" fontSize={size} fontWeight={line.heading ? 700 : undefined} style={{ fill: ink }}>
            {fitLine(line.text, size, maxW)}
          </text>
        ))}
    </g>
  )
})

/** Every simplified note, in order, in one SVG layer (see the top of this file). */
export const LowNotes = memo(function LowNotes({ notes, bars }: { notes: readonly Shape[]; bars: ReadonlySet<string> }) {
  if (!notes.length) return null
  return (
    <svg className="pointer-events-none absolute left-0 top-0 overflow-visible" width={1} height={1} aria-hidden="true">
      {notes.map(s => (
        <LowNote key={s.id} shape={s} bars={bars.has(s.id)} />
      ))}
    </svg>
  )
})
