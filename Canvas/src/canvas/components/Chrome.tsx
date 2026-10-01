/**
 * Screen-space chrome: the tool bar, zoom and history cluster, the title
 * pill with sync status and who is here, the selection bar, the link prompt,
 * the shortcuts sheet, the empty-board hint and toasts.
 */
import { useEffect, useRef, useState, type ReactNode } from 'react'
import {
  AlignCenter,
  AlignLeft,
  AlignRight,
  ArrowUpRight,
  BringToFront,
  Copy,
  ExternalLink,
  Frame as FrameIcon,
  Hand,
  ImageIcon,
  ImageOff,
  Keyboard,
  Link2,
  Lock,
  Maximize,
  Minus,
  MousePointer2,
  Plus,
  Redo2,
  Search,
  SendToBack,
  Sparkles,
  StickyNote,
  Trash2,
  Type,
  Undo2,
  X,
} from 'lucide-react'
import { COLOR_LABEL, SHAPE_COLORS, initials, swatchOf } from '../colors'
import type { CanvasAgent, NamedColor, Shape, ShapeColor } from '../types'
import type { PeerView } from './Overlays'
import { AgentDot } from './Overlays'
import { Divider, IconButton, Kbd, MOD, Panel, cn } from './ui'

export type Tool = 'select' | 'hand' | 'sticky' | 'text' | 'frame' | 'arrow' | 'image' | 'link'

export const TOOL_KEYS: Record<string, Tool> = {
  v: 'select',
  h: 'hand',
  s: 'sticky',
  n: 'sticky',
  t: 'text',
  f: 'frame',
  a: 'arrow',
  x: 'arrow',
  i: 'image',
  l: 'link',
}

const TOOLS: { tool: Tool; label: string; key: string; icon: ReactNode; edit?: boolean }[] = [
  { tool: 'select', label: 'Select', key: 'V', icon: <MousePointer2 className="h-[18px] w-[18px]" /> },
  { tool: 'hand', label: 'Hand', key: 'H', icon: <Hand className="h-[18px] w-[18px]" /> },
  { tool: 'sticky', label: 'Sticky note', key: 'S', icon: <StickyNote className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'text', label: 'Text', key: 'T', icon: <Type className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'frame', label: 'Frame', key: 'F', icon: <FrameIcon className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'arrow', label: 'Arrow', key: 'A', icon: <ArrowUpRight className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'image', label: 'Image', key: 'I', icon: <ImageIcon className="h-[18px] w-[18px]" />, edit: true },
  { tool: 'link', label: 'Link', key: 'L', icon: <Link2 className="h-[18px] w-[18px]" />, edit: true },
]

function Swatch({
  color,
  active,
  onPick,
  size = 'md',
}: {
  color: NamedColor
  active: boolean
  onPick: (c: NamedColor) => void
  size?: 'sm' | 'md'
}) {
  return (
    <button
      type="button"
      aria-label={COLOR_LABEL[color]}
      aria-pressed={active}
      className={cn(
        'tip-host shrink-0 rounded-full border border-black/10 outline-none transition-transform hover:scale-110 focus-visible:ring-2 focus-visible:ring-accent dark:border-white/20',
        size === 'md' ? 'h-[22px] w-[22px]' : 'h-[18px] w-[18px]',
        active && 'ring-2 ring-accent ring-offset-2 ring-offset-surface'
      )}
      style={{ background: swatchOf(color) }}
      onClick={() => onPick(color)}
    />
  )
}

export function Toolbar({
  tool,
  onTool,
  color,
  onColor,
  readOnly,
}: {
  tool: Tool
  onTool: (tool: Tool) => void
  color: NamedColor
  onColor: (c: NamedColor) => void
  readOnly: boolean
}) {
  const [palette, setPalette] = useState(false)
  const tools = readOnly ? TOOLS.filter(t => !t.edit) : TOOLS
  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-3 flex justify-center px-3">
      <Panel role="toolbar" aria-label="Tools" className="pointer-events-auto relative flex max-w-full items-center gap-0.5 p-1">
        {tools.map((t, i) => (
          <span key={t.tool} className="contents">
            {i === 2 && <Divider />}
            <IconButton label={t.label} keys={t.key} active={tool === t.tool} onClick={() => onTool(t.tool)}>
              {t.icon}
            </IconButton>
          </span>
        ))}
        {!readOnly && (
          <>
            <Divider />
            <button
              type="button"
              aria-label="Note colour"
              aria-expanded={palette}
              className="tip-host flex h-9 w-9 items-center justify-center rounded-[10px] hover:bg-surface-2"
              onClick={() => setPalette(p => !p)}
            >
              <span className="h-[20px] w-[20px] rounded-full border border-black/10 dark:border-white/20" style={{ background: swatchOf(color) }} />
              {!palette && (
                <span className="tip flex items-center gap-1.5 rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
                  Colour for new notes
                </span>
              )}
            </button>
            {palette && (
              <Panel className="pop-in absolute bottom-[calc(100%+8px)] right-0 flex items-center gap-2 px-2.5 py-2">
                {SHAPE_COLORS.map(c => (
                  <Swatch
                    key={c}
                    color={c}
                    active={color === c}
                    onPick={next => {
                      onColor(next)
                      setPalette(false)
                    }}
                  />
                ))}
              </Panel>
            )}
          </>
        )}
      </Panel>
    </div>
  )
}

export function ZoomBar({
  zoom,
  onZoom,
  onFit,
  onReset,
  canUndo,
  canRedo,
  onUndo,
  onRedo,
  readOnly,
}: {
  zoom: number
  onZoom: (factor: number) => void
  onFit: () => void
  onReset: () => void
  canUndo: boolean
  canRedo: boolean
  onUndo: () => void
  onRedo: () => void
  readOnly: boolean
}) {
  return (
    <Panel className="pointer-events-auto absolute bottom-3 right-3 hidden items-center gap-0.5 p-1 min-[880px]:flex">
      {!readOnly && (
        <>
          <IconButton size="sm" label="Undo" keys={`${MOD}Z`} disabled={!canUndo} onClick={onUndo}>
            <Undo2 className="h-4 w-4" />
          </IconButton>
          <IconButton size="sm" label="Redo" keys={`⇧${MOD}Z`} disabled={!canRedo} onClick={onRedo}>
            <Redo2 className="h-4 w-4" />
          </IconButton>
          <Divider />
        </>
      )}
      <IconButton size="sm" label="Zoom out" keys="−" onClick={() => onZoom(1 / 1.25)}>
        <Minus className="h-4 w-4" />
      </IconButton>
      <button
        type="button"
        aria-label="Zoom to 100%"
        className="tip-host h-7 w-12 rounded-lg text-center text-[12px] font-medium tabular-nums text-ink-2 hover:bg-surface-2"
        onClick={onReset}
      >
        {Math.round(zoom * 100)}%
        <span className="tip flex items-center gap-1.5 rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
          Zoom to 100% <span className="rounded bg-white/15 px-1 text-[10.5px] dark:bg-black/10">⇧0</span>
        </span>
      </button>
      <IconButton size="sm" label="Zoom in" keys="+" onClick={() => onZoom(1.25)}>
        <Plus className="h-4 w-4" />
      </IconButton>
      <IconButton size="sm" label="Zoom to fit" keys="⇧1" tipEnd onClick={onFit}>
        <Maximize className="h-[15px] w-[15px]" />
      </IconButton>
    </Panel>
  )
}

/** The compact cluster for narrow windows: history and fit only, above the tools. */
export function CompactBar({
  onFit,
  canUndo,
  canRedo,
  onUndo,
  onRedo,
  zoom,
  readOnly,
}: {
  onFit: () => void
  canUndo: boolean
  canRedo: boolean
  onUndo: () => void
  onRedo: () => void
  zoom: number
  readOnly: boolean
}) {
  return (
    <Panel className="pointer-events-auto absolute bottom-[68px] right-3 flex items-center gap-0.5 p-1 min-[880px]:hidden">
      {!readOnly && (
        <>
          <IconButton size="sm" label="Undo" keys={`${MOD}Z`} disabled={!canUndo} onClick={onUndo}>
            <Undo2 className="h-4 w-4" />
          </IconButton>
          <IconButton size="sm" label="Redo" keys={`⇧${MOD}Z`} disabled={!canRedo} onClick={onRedo}>
            <Redo2 className="h-4 w-4" />
          </IconButton>
        </>
      )}
      <IconButton size="sm" label={`Zoom to fit (${Math.round(zoom * 100)}%)`} keys="⇧1" tipEnd onClick={onFit}>
        <Maximize className="h-[15px] w-[15px]" />
      </IconButton>
    </Panel>
  )
}

export type SyncState = 'local' | 'connecting' | 'online' | 'offline'

const STATUS: Record<SyncState, { label: string; dot: string; hint: string }> = {
  local: { label: 'On this Mac', dot: 'bg-ink-4', hint: 'Saved on this Mac' },
  connecting: { label: 'Connecting', dot: 'bg-warning', hint: 'Connecting to the cloud…' },
  online: { label: 'Live', dot: 'bg-success', hint: 'Synced: changes appear for everyone' },
  offline: { label: 'Offline', dot: 'bg-ink-4', hint: 'Offline: changes sync when the connection is back' },
}

function Avatar({
  name,
  color,
  ring,
  agent,
  onClick,
}: {
  name: string
  color: string
  ring?: boolean
  agent?: CanvasAgent
  onClick?: () => void
}) {
  return (
    <button
      type="button"
      aria-label={agent ? `${name}, ${agent.status}` : name}
      onClick={onClick}
      className="tip-host tip-below relative -ml-1.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full border-2 border-surface text-[11px] font-semibold text-white first:ml-0"
      style={{ background: color }}
    >
      {agent ? <Sparkles className="h-3.5 w-3.5" aria-hidden="true" /> : initials(name)}
      {ring && <span className="absolute -inset-[3px] rounded-full border-2" style={{ borderColor: color }} />}
      {agent && <AgentDot agent={agent} className="absolute -bottom-0.5 -right-0.5 rounded-full ring-2 ring-surface" />}
      <span className="tip tip-below flex items-center gap-1.5 rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
        {name}
        {agent && agent.status !== 'idle' && <span className="opacity-70">{agent.status}…</span>}
      </span>
    </button>
  )
}

export function TitleBar({
  name,
  kind,
  status,
  readOnly,
  peers,
  agents,
  onPeer,
  onAgent,
}: {
  name: string
  kind: string
  status: SyncState
  readOnly: boolean
  peers: readonly PeerView[]
  agents: readonly CanvasAgent[]
  onPeer: (peer: PeerView) => void
  onAgent: (agent: CanvasAgent) => void
}) {
  const s = STATUS[status]
  const people = dedupePeers(peers)
  const shown = people.slice(0, 5)
  return (
    <div className="pointer-events-none absolute left-3 right-[120px] top-3 flex min-w-0 items-center gap-2">
      <Panel className="pointer-events-auto flex min-w-0 items-center gap-2.5 py-1.5 pl-3 pr-3">
        <span className="tip-host tip-below relative flex h-2 w-2 shrink-0">
          {status === 'connecting' && <span className={cn('pulse-ring absolute h-full w-full rounded-full', s.dot)} />}
          <span className={cn('relative h-2 w-2 rounded-full', s.dot)} aria-hidden="true" />
          <span className="tip tip-below rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
            {s.hint}
          </span>
        </span>
        <h1 className="min-w-0 truncate text-[13.5px] font-semibold tracking-[-0.005em] text-ink">{name}</h1>
        {kind === 'personal' && (
          <span className="tip-host tip-below flex shrink-0 items-center gap-1 rounded-md bg-surface-2 px-1.5 py-0.5 text-[11px] font-medium text-ink-3">
            <Lock className="h-3 w-3" aria-hidden="true" />
            Private
            <span className="tip tip-below rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]">
              Only you can see this canvas
            </span>
          </span>
        )}
        {readOnly && <span className="shrink-0 rounded-md bg-surface-2 px-1.5 py-0.5 text-[11px] font-medium text-ink-3">View only</span>}
        <span className="hidden shrink-0 text-[12px] text-ink-3 min-[560px]:inline" aria-live="polite">
          {s.label}
        </span>
      </Panel>
      {(shown.length > 0 || agents.length > 0) && (
        <Panel className="pointer-events-auto flex shrink-0 items-center gap-1 py-1 pl-1.5 pr-1.5">
          <div className="flex items-center">
            {shown.map(p => (
              <Avatar key={p.id} name={p.name} color={p.color} onClick={() => onPeer(p)} />
            ))}
            {people.length > shown.length && (
              <span className="-ml-1.5 flex h-7 w-7 items-center justify-center rounded-full border-2 border-surface bg-surface-3 text-[10.5px] font-semibold text-ink-2">
                +{people.length - shown.length}
              </span>
            )}
          </div>
          {agents.length > 0 && shown.length > 0 && <Divider />}
          <div className="flex items-center">
            {agents.slice(0, 4).map(a => (
              <Avatar key={a.id} name={a.name} color={a.color || 'var(--accent)'} agent={a} onClick={() => onAgent(a)} />
            ))}
          </div>
        </Panel>
      )}
    </div>
  )
}

/** One avatar per person, however many windows they have open. */
export function dedupePeers(peers: readonly PeerView[]): PeerView[] {
  const seen = new Map<string, PeerView>()
  for (const p of peers) if (!seen.has(p.id) || (p.cursor && !seen.get(p.id)!.cursor)) seen.set(p.id, p)
  return [...seen.values()]
}

export function TopRight({ onSearch, searchOpen, onHelp }: { onSearch: () => void; searchOpen: boolean; onHelp: () => void }) {
  return (
    <Panel className="pointer-events-auto absolute right-3 top-3 flex items-center gap-0.5 p-1">
      <IconButton size="sm" label="Search" keys={`${MOD}F`} tipBelow tipEnd active={searchOpen} onClick={onSearch}>
        <Search className="h-4 w-4" />
      </IconButton>
      <IconButton size="sm" label="Keyboard shortcuts" keys="?" tipBelow tipEnd onClick={onHelp}>
        <Keyboard className="h-4 w-4" />
      </IconButton>
    </Panel>
  )
}

/** Colours, text size and order for the selection, floating above it. */
export function SelectionBar({
  at,
  shapes,
  onColor,
  onFont,
  onAlign,
  onFront,
  onBack,
  onDuplicate,
  onDelete,
  onRemoveImage,
  onOpen,
  below,
}: {
  at: { x: number; y: number }
  shapes: readonly Shape[]
  onColor: (c: ShapeColor) => void
  onFont: (size: number) => void
  onAlign: (a: 'left' | 'center' | 'right') => void
  onFront: () => void
  onBack: () => void
  onDuplicate: () => void
  onDelete: () => void
  onRemoveImage: () => void
  onOpen: () => void
  below: boolean
}) {
  const single = shapes.length === 1 ? shapes[0]! : null
  const colorable = shapes.some(s => s.type !== 'image')
  const current = single?.color
  const texty = shapes.length > 0 && shapes.every(s => s.type === 'sticky' || s.type === 'text')
  const font = single?.fontSize ?? (single?.type === 'text' ? 20 : 16)
  const sizes = single?.type === 'text' ? [16, 20, 28, 40] : [12, 16, 22, 30]
  return (
    <Panel
      role="toolbar"
      aria-label="Selection"
      data-testid="selection-bar"
      className="pop-in absolute z-30 flex items-center gap-1 rounded-full px-1.5 py-1"
      style={{ left: at.x, top: at.y, translate: below ? '-50% 0' : '-50% -100%' }}
    >
      {colorable && (
        <div className="flex items-center gap-1.5 px-1">
          {SHAPE_COLORS.map(c => (
            <Swatch key={c} size="sm" color={c} active={current === c} onPick={onColor} />
          ))}
        </div>
      )}
      {texty && (
        <>
          <Divider />
          <div className="flex items-center" role="group" aria-label="Text size">
            {sizes.map((s, i) => (
              <button
                key={s}
                type="button"
                aria-pressed={single ? font === s : undefined}
                aria-label={`Text size ${['small', 'medium', 'large', 'extra large'][i]}`}
                className={cn(
                  'flex h-7 w-7 items-center justify-center rounded-full font-semibold text-ink-2 hover:bg-surface-2',
                  single && font === s && 'bg-surface-3 text-ink'
                )}
                style={{ fontSize: 10 + i * 2 }}
                onClick={() => onFont(s)}
              >
                {['S', 'M', 'L', 'XL'][i]}
              </button>
            ))}
          </div>
        </>
      )}
      {single?.type === 'text' && (
        <>
          <Divider />
          {(['left', 'center', 'right'] as const).map(a => (
            <IconButton
              key={a}
              size="sm"
              label={`Align ${a}`}
              active={(single.align ?? 'left') === a}
              className="rounded-full"
              onClick={() => onAlign(a)}
            >
              {a === 'left' ? <AlignLeft className="h-4 w-4" /> : a === 'center' ? <AlignCenter className="h-4 w-4" /> : <AlignRight className="h-4 w-4" />}
            </IconButton>
          ))}
        </>
      )}
      {single?.type === 'link' && (
        <>
          <Divider />
          <IconButton size="sm" label="Open link" keys="↵" className="rounded-full" onClick={onOpen}>
            <ExternalLink className="h-4 w-4" />
          </IconButton>
        </>
      )}
      {single?.type === 'frame' && single.image && (
        <>
          <Divider />
          <IconButton size="sm" label="Remove image" className="rounded-full" onClick={onRemoveImage}>
            <ImageOff className="h-4 w-4" />
          </IconButton>
        </>
      )}
      <Divider />
      <IconButton size="sm" label="Bring to front" keys={`${MOD}]`} className="rounded-full" onClick={onFront}>
        <BringToFront className="h-4 w-4" />
      </IconButton>
      <IconButton size="sm" label="Send to back" keys={`${MOD}[`} className="rounded-full" onClick={onBack}>
        <SendToBack className="h-4 w-4" />
      </IconButton>
      <IconButton size="sm" label="Duplicate" keys={`${MOD}D`} className="rounded-full" onClick={onDuplicate}>
        <Copy className="h-4 w-4" />
      </IconButton>
      <IconButton
        size="sm"
        label="Delete"
        keys="⌫"
        className="rounded-full hover:!bg-danger/10 hover:!text-danger"
        onClick={onDelete}
      >
        <Trash2 className="h-4 w-4" />
      </IconButton>
    </Panel>
  )
}

/** Ask for an address; Enter puts a link card on the board. */
export function LinkPrompt({ onSubmit, onClose }: { onSubmit: (url: string) => void; onClose: () => void }) {
  const ref = useRef<HTMLInputElement>(null)
  const [value, setValue] = useState('')
  const [error, setError] = useState('')
  useEffect(() => ref.current?.focus(), [])
  const submit = () => {
    const v = value.trim()
    if (!v) return onClose()
    const withScheme = /^[a-z][a-z0-9+.-]*:/i.test(v) ? v : `https://${v}`
    try {
      const u = new URL(withScheme)
      if (!['http:', 'https:', 'mailto:', 'copper:'].includes(u.protocol)) throw new Error('scheme')
      onSubmit(u.toString())
    } catch {
      setError('That does not look like a web address.')
    }
  }
  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-[72px] flex justify-center px-3">
      <Panel className="pop-in pointer-events-auto w-[min(420px,100%)] p-2">
        <form
          className="flex items-center gap-2"
          onSubmit={e => {
            e.preventDefault()
            submit()
          }}
        >
          <Link2 className="ml-1.5 h-4 w-4 shrink-0 text-ink-3" aria-hidden="true" />
          <input
            ref={ref}
            aria-label="Link address"
            value={value}
            placeholder="Paste a link…"
            spellCheck={false}
            onChange={e => {
              setValue(e.target.value)
              setError('')
            }}
            onKeyDown={e => {
              e.stopPropagation()
              if (e.key === 'Escape') onClose()
            }}
            className="h-8 min-w-0 flex-1 bg-transparent text-[13.5px] text-ink outline-none placeholder:text-ink-4"
          />
          <button type="submit" className="h-7 shrink-0 rounded-lg bg-accent px-2.5 text-[12.5px] font-semibold text-accent-ink hover:bg-accent-strong">
            Add
          </button>
          <IconButton size="sm" label="Cancel" keys="Esc" onClick={onClose}>
            <X className="h-4 w-4" />
          </IconButton>
        </form>
        {error && <p className="px-2 pb-0.5 pt-1.5 text-[12px] text-danger">{error}</p>}
      </Panel>
    </div>
  )
}

const SHORTCUTS: [string, string[]][] = [
  ['Select', ['V']],
  ['Hand (or hold Space)', ['H']],
  ['Sticky note', ['S']],
  ['Text', ['T']],
  ['Frame', ['F']],
  ['Arrow', ['A']],
  ['Image', ['I']],
  ['Link', ['L']],
  ['Edit the selected note', ['↵']],
  ['New note beside / below', [`${MOD}↵`, `⇧${MOD}↵`]],
  ['Delete', ['⌫']],
  ['Duplicate', [`${MOD}D`]],
  ['Select all', [`${MOD}A`]],
  ['Copy, cut, paste', [`${MOD}C`, `${MOD}X`, `${MOD}V`]],
  ['Undo / redo', [`${MOD}Z`, `⇧${MOD}Z`]],
  ['Nudge', ['←↑↓→', '⇧ ×10']],
  ['Bring to front / send to back', [`${MOD}]`, `${MOD}[`]],
  ['Search', [`${MOD}F`]],
  ['Zoom in / out', ['+', '−']],
  ['Zoom to fit / selection', ['⇧1', '⇧2']],
  ['Zoom to 100%', ['⇧0']],
  ['Bold / italic in a note', [`${MOD}B`, `${MOD}I`]],
]

export function ShortcutsSheet({ onClose }: { onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' || e.key === '?') {
        e.preventDefault()
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [onClose])
  return (
    <div
      className="absolute inset-0 z-50 flex items-center justify-center bg-black/10 p-4 dark:bg-black/30"
      onPointerDown={e => {
        e.stopPropagation()
        onClose()
      }}
    >
      <Panel role="dialog" aria-label="Keyboard shortcuts" className="pop-in max-h-full w-[min(560px,100%)] overflow-y-auto p-5" onPointerDown={e => e.stopPropagation()}>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-[15px] font-semibold">Keyboard shortcuts</h2>
          <IconButton size="sm" label="Close" keys="Esc" onClick={onClose}>
            <X className="h-4 w-4" />
          </IconButton>
        </div>
        <dl className="grid grid-cols-1 gap-x-6 gap-y-1.5 min-[520px]:grid-cols-2">
          {SHORTCUTS.map(([label, keys]) => (
            <div key={label} className="flex items-center justify-between gap-3 py-0.5">
              <dt className="truncate text-[12.5px] text-ink-2">{label}</dt>
              <dd className="flex shrink-0 gap-1">
                {keys.map(k => (
                  <Kbd key={k}>{k}</Kbd>
                ))}
              </dd>
            </div>
          ))}
        </dl>
        <p className="mt-4 text-[12px] text-ink-3">
          Drop images, links and text onto the board. Double-click empty space for a sticky. Scroll to pan, pinch or {MOD}scroll to zoom.
        </p>
      </Panel>
    </div>
  )
}

export function EmptyHint({ readOnly }: { readOnly: boolean }) {
  return (
    <div className="pointer-events-none absolute inset-0 flex items-center justify-center p-6">
      <div className="pop-in max-w-[360px] text-center">
        <div className="mx-auto mb-4 flex h-12 w-12 rotate-[-4deg] items-center justify-center rounded-[6px] shadow-note" style={{ background: 'var(--paper-yellow)' }}>
          <StickyNote className="h-5 w-5" style={{ color: 'var(--ink-on-yellow)' }} aria-hidden="true" />
        </div>
        <p className="text-[15px] font-semibold text-ink">{readOnly ? 'Nothing here yet' : 'A blank canvas'}</p>
        {!readOnly && (
          <p className="mt-1.5 text-[13px] leading-relaxed text-ink-3">
            Double-click anywhere for a sticky, press <Kbd>S</Kbd> <Kbd>T</Kbd> <Kbd>F</Kbd> for notes, text and frames, or drop
            in images and links.
          </p>
        )}
      </div>
    </div>
  )
}

export interface Toast {
  id: number
  text: string
  tone: 'info' | 'error'
}

export function Toasts({ toasts }: { toasts: readonly Toast[] }) {
  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-[76px] flex flex-col items-center gap-2 px-3" aria-live="polite">
      {toasts.map(t => (
        <div
          key={t.id}
          className={cn(
            'pop-in rounded-full px-3.5 py-1.5 text-[12.5px] font-medium shadow-2',
            t.tone === 'error' ? 'bg-danger text-white' : 'bg-[#1d1d1f] text-white dark:bg-[#f2f2ef] dark:text-[#1d1d1f]'
          )}
        >
          {t.text}
        </div>
      ))}
    </div>
  )
}

/** Small "by …" chip under a hovered shape that someone else made. */
export function AuthorChip({ at, name, agent }: { at: { x: number; y: number }; name: string; agent: boolean }) {
  return (
    <div
      className="pop-in pointer-events-none absolute z-20 flex items-center gap-1 rounded-full bg-surface px-2 py-[3px] text-[11px] font-medium text-ink-2 shadow-2"
      style={{ left: at.x, top: at.y }}
    >
      {agent && <Sparkles className="h-3 w-3 text-accent" aria-hidden="true" />}
      {name}
    </div>
  )
}
