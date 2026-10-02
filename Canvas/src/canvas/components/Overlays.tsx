/**
 * World-space overlays drawn above the shapes: selection outlines, resize
 * handles, arrow end handles and anchor dots, peers' cursors and selections,
 * agents' cursors, search rings, the marquee. Sizes are divided by the zoom
 * so they stay the same on screen.
 */
import { memo, type CSSProperties, type PointerEvent as ReactPointerEvent } from 'react'
import { Sparkles } from 'lucide-react'
import type { ArrowPath } from '../arrows'
import { isBusy } from '../agents'
import { SIDES, sidePoint, type Box, type Point, type Segment, type Side } from '../geometry'
import { CORNER_HANDLES, EDGE_HANDLES, HANDLE_CURSOR, type Handle } from '../resize'
import type { CanvasAgent } from '../types'
import { cn } from './ui'

const CORNER_PX = 9
const EDGE_PX = 10

const at = (handle: Handle) => ({
  x: handle.includes('w') ? '0%' : handle.includes('e') ? '100%' : '50%',
  y: handle.includes('n') ? '0%' : handle.includes('s') ? '100%' : '50%',
})

export function ResizeHandles({
  box,
  zoom,
  corners = true,
  edges = true,
  onStart,
}: {
  box: Box
  zoom: number
  corners?: boolean
  edges?: boolean
  onStart: (handle: Handle, e: ReactPointerEvent<HTMLElement>) => void
}) {
  const corner = CORNER_PX / zoom
  const edge = EDGE_PX / zoom
  const props = (handle: Handle, style: CSSProperties) => ({
    'data-handle': handle,
    className: 'pointer-events-auto absolute touch-none',
    style: { ...style, cursor: HANDLE_CURSOR[handle] },
    onPointerDown: (e: ReactPointerEvent<HTMLElement>) => onStart(handle, e),
  })
  return (
    <div
      className="pointer-events-none absolute left-0 top-0"
      style={{ width: box.w, height: box.h, transform: `translate(${box.x}px, ${box.y}px)` }}
    >
      {edges &&
        EDGE_HANDLES.map(handle => {
          const vertical = handle === 'e' || handle === 'w'
          const { x, y } = at(handle)
          return (
            <div
              key={handle}
              {...props(
                handle,
                vertical
                  ? { left: x, top: corner, bottom: corner, width: edge, transform: 'translateX(-50%)' }
                  : { top: y, left: corner, right: corner, height: edge, transform: 'translateY(-50%)' }
              )}
            />
          )
        })}
      {corners &&
        CORNER_HANDLES.map(handle => {
          const { x, y } = at(handle)
          return (
            <div
              key={handle}
              {...props(handle, {
                left: x,
                top: y,
                width: corner,
                height: corner,
                borderWidth: 1.5 / zoom,
                borderRadius: 2.5 / zoom,
                transform: 'translate(-50%, -50%)',
              })}
              className="pointer-events-auto absolute touch-none border-accent bg-surface"
            />
          )
        })}
    </div>
  )
}

/**
 * The shape whose text is being edited: a heavier outline with a soft halo
 * and no handles, so editing never reads as merely selected.
 */
export function EditingOutline({ box, zoom }: { box: Box; zoom: number }) {
  const pad = 3 / zoom
  return (
    <div
      data-part="editing-outline"
      className="pointer-events-none absolute left-0 top-0"
      style={{
        width: box.w + pad * 2,
        height: box.h + pad * 2,
        transform: `translate(${box.x - pad}px, ${box.y - pad}px)`,
        border: `${2 / zoom}px solid var(--accent)`,
        borderRadius: 7 / zoom,
        boxShadow: `0 0 0 ${4 / zoom}px var(--accent-soft)`,
      }}
    />
  )
}

/** Outline around each selected box, plus a dashed group box for several. */
export const SelectionOutlines = memo(function SelectionOutlines({
  boxes,
  group,
  zoom,
  color = 'var(--accent)',
  dashed = false,
}: {
  boxes: readonly Box[]
  group: Box | null
  zoom: number
  color?: string
  dashed?: boolean
}) {
  const w = 1.5 / zoom
  const pad = 3 / zoom
  return (
    <>
      {boxes.map((b, i) => (
        <div
          key={i}
          className="pointer-events-none absolute left-0 top-0"
          style={{
            width: b.w + pad * 2,
            height: b.h + pad * 2,
            transform: `translate(${b.x - pad}px, ${b.y - pad}px)`,
            border: `${w}px ${dashed ? 'dashed' : 'solid'} ${color}`,
            borderRadius: 6 / zoom,
          }}
        />
      ))}
      {group && (
        <div
          className="pointer-events-none absolute left-0 top-0"
          style={{
            width: group.w + pad * 4,
            height: group.h + pad * 4,
            transform: `translate(${group.x - pad * 2}px, ${group.y - pad * 2}px)`,
            border: `${w}px dashed ${color}`,
            borderRadius: 8 / zoom,
            opacity: 0.8,
          }}
        />
      )}
    </>
  )
})

/** The selected arrow's ends: drag one onto a shape (or its side) to reattach. */
export function ArrowEndHandles({
  path,
  zoom,
  onStart,
}: {
  path: ArrowPath
  zoom: number
  onStart: (end: 'from' | 'to', e: ReactPointerEvent<HTMLElement>) => void
}) {
  const r = 6 / zoom
  const ends: ['from' | 'to', Point][] = [
    ['from', { x: path.seg.x1, y: path.seg.y1 }],
    ['to', { x: path.seg.x2, y: path.seg.y2 }],
  ]
  return (
    <>
      {ends.map(([end, p]) => (
        <div
          key={end}
          data-part={`end-${end}`}
          aria-label={end === 'from' ? 'Arrow start' : 'Arrow end'}
          className="pointer-events-auto absolute left-0 top-0 cursor-grab touch-none rounded-full border-accent bg-surface"
          style={{
            width: r * 2,
            height: r * 2,
            borderWidth: 2 / zoom,
            transform: `translate(${p.x - r}px, ${p.y - r}px)`,
          }}
          onPointerDown={e => onStart(end, e)}
        />
      ))}
    </>
  )
}

/** Side midpoints of a box an arrow can snap to; the hot one is filled. */
export function AnchorDots({ box, hot, zoom }: { box: Box; hot?: Side | null; zoom: number }) {
  const r = 5 / zoom
  return (
    <>
      <div
        className="pointer-events-none absolute left-0 top-0"
        style={{
          width: box.w,
          height: box.h,
          transform: `translate(${box.x}px, ${box.y}px)`,
          boxShadow: `0 0 0 ${1.5 / zoom}px var(--accent)`,
          borderRadius: 4 / zoom,
          opacity: hot === undefined ? 0.6 : 1,
        }}
      />
      {SIDES.map(side => {
        const p = sidePoint(box, side)
        const on = hot === side
        return (
          <div
            key={side}
            className={cn('pointer-events-none absolute left-0 top-0 rounded-full border-accent', on ? 'bg-accent' : 'bg-surface')}
            style={{
              width: r * 2 * (on ? 1.3 : 1),
              height: r * 2 * (on ? 1.3 : 1),
              borderWidth: 1.5 / zoom,
              transform: `translate(${p.x - r * (on ? 1.3 : 1)}px, ${p.y - r * (on ? 1.3 : 1)}px)`,
            }}
          />
        )
      })}
    </>
  )
}

/** A dashed preview of the arrow being drawn. */
export function ArrowDraft({ d, zoom }: { d: string; zoom: number }) {
  return (
    <svg className="pointer-events-none absolute left-0 top-0 overflow-visible" width={1} height={1} aria-hidden="true">
      <path
        d={d}
        fill="none"
        stroke="var(--accent)"
        strokeWidth={2}
        strokeDasharray={`${6 / zoom} ${5 / zoom}`}
        strokeLinecap="round"
      />
    </svg>
  )
}

export function Marquee({ box, zoom }: { box: Box; zoom: number }) {
  return (
    <div
      className="pointer-events-none absolute left-0 top-0 rounded-[2px] bg-accent-soft"
      style={{
        width: box.w,
        height: box.h,
        transform: `translate(${box.x}px, ${box.y}px)`,
        border: `${1 / zoom}px solid var(--accent)`,
      }}
    />
  )
}

export interface PeerView {
  clientId: number
  id: string
  name: string
  color: string
  cursor: Point | null
  selection: string[]
  /** The live frame they are using, if any. */
  frame?: string | null
}

/** People's pointers: an arrow and a name tag in their colour, screen-sized. */
export const PeerCursors = memo(function PeerCursors({ peers, zoom }: { peers: readonly PeerView[]; zoom: number }) {
  return (
    <>
      {peers.map(peer =>
        peer.cursor ? (
          <div
            key={peer.clientId}
            className="pointer-events-none absolute left-0 top-0 origin-top-left transition-transform duration-[60ms] ease-linear"
            style={{ transform: `translate(${peer.cursor.x}px, ${peer.cursor.y}px) scale(${1 / zoom})` }}
          >
            <svg width="18" height="20" viewBox="0 0 18 20" aria-hidden="true" className="drop-shadow-sm">
              <path d="M2 1.5 L16 10 L9.3 11.4 L5.8 18.2 z" fill={peer.color} stroke="white" strokeWidth="1.5" strokeLinejoin="round" />
            </svg>
            <span
              className="-mt-1 ml-3.5 inline-block whitespace-nowrap rounded-full px-2 py-[3px] text-[11.5px] font-semibold text-white shadow-1"
              style={{ backgroundColor: peer.color }}
            >
              {peer.name}
            </span>
          </div>
        ) : null
      )}
    </>
  )
})

const STATUS_LABEL = { idle: 'idle', thinking: 'thinking…', writing: 'writing…' } as const

export function AgentDot({ agent, className }: { agent: Pick<CanvasAgent, 'status'>; className?: string }) {
  const busy = isBusy(agent.status)
  return (
    <span className={cn('relative inline-flex h-2 w-2 shrink-0', className)} aria-hidden="true">
      {busy && <span className="pulse-ring absolute inline-flex h-full w-full rounded-full bg-success" />}
      <span className={cn('relative inline-flex h-2 w-2 rounded-full', busy ? 'bg-success' : 'bg-ink-4')} />
    </span>
  )
}

/**
 * Agents' cursors: a sparkle tag with the agent's name and status. They glide
 * (unless motion is reduced) so an agent placing things reads as motion.
 */
export const AgentCursors = memo(function AgentCursors({ agents, zoom }: { agents: readonly CanvasAgent[]; zoom: number }) {
  return (
    <>
      {agents.map(agent =>
        agent.cursor ? (
          <div
            key={agent.id}
            data-testid="agent-cursor"
            className="pointer-events-none absolute left-0 top-0 origin-top-left transition-transform duration-500 ease-out"
            style={{ transform: `translate(${agent.cursor.x}px, ${agent.cursor.y}px) scale(${1 / zoom})` }}
          >
            <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
              <path
                d="M1.5 1.5 L14.5 6.4 L8 8 L6.4 14.5 z"
                fill="white"
                stroke={agent.color || 'var(--accent)'}
                strokeWidth="2"
                strokeLinejoin="round"
              />
            </svg>
            <span
              className="ml-3.5 mt-0.5 inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border-2 bg-surface py-[2px] pl-[3px] pr-2 text-[11.5px] font-semibold text-ink shadow-2"
              style={{ borderColor: agent.color || 'var(--accent)' }}
              title={`${agent.name} · ${STATUS_LABEL[agent.status]}`}
            >
              <span
                className="inline-flex h-[18px] w-[18px] items-center justify-center rounded-full text-white"
                style={{ backgroundColor: agent.color || 'var(--accent)' }}
              >
                <Sparkles className="h-[11px] w-[11px]" aria-hidden="true" />
              </span>
              {agent.name}
              {agent.status !== 'idle' && <span className="font-normal text-ink-3">{STATUS_LABEL[agent.status]}</span>}
              <AgentDot agent={agent} />
            </span>
          </div>
        ) : null
      )}
    </>
  )
})

export interface RingPlace {
  ref: string
  on: boolean
  box: Box
  seg?: Segment
}

/** Search rings: faint around every hit, strong around the current one. */
export function SearchRings({ places, zoom }: { places: readonly RingPlace[]; zoom: number }) {
  const gap = 6 / zoom
  return (
    <>
      <svg className="pointer-events-none absolute left-0 top-0 overflow-visible" width={1} height={1} aria-hidden="true">
        {places.map(p =>
          p.seg ? (
            <line
              key={p.ref}
              {...p.seg}
              strokeLinecap="round"
              strokeWidth={(p.on ? 12 : 8) / zoom}
              stroke="var(--accent)"
              strokeOpacity={p.on ? 0.4 : 0.15}
            />
          ) : null
        )}
      </svg>
      {places.map(p =>
        p.seg ? null : (
          <div
            key={p.ref}
            data-search-ring={p.on ? 'active' : 'hit'}
            className={cn('pointer-events-none absolute left-0 top-0 border-solid border-accent', !p.on && 'opacity-40')}
            style={{
              width: p.box.w + gap * 2,
              height: p.box.h + gap * 2,
              transform: `translate(${p.box.x - gap}px, ${p.box.y - gap}px)`,
              borderWidth: (p.on ? 3 : 1.5) / zoom,
              borderRadius: 10 / zoom + gap,
              boxShadow: p.on ? `0 0 0 ${4 / zoom}px var(--accent-soft)` : undefined,
            }}
          />
        )
      )}
    </>
  )
}
