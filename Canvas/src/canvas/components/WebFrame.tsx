/**
 * A live web frame: a link shape with `live`, showing its site in an
 * <iframe> under a slim title bar (`canvas/frames.ts` has the rules).
 *
 * Until it is in use, a transparent shield lies over the page, so a frame
 * selects, drags, marquees and zooms like any other shape; it comes off when
 * the frame is activated (a click on the selected frame, a double-click, ↵)
 * and goes back with Esc or a click on the board.
 */
import { memo, useCallback, useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from 'react'
import {
  ArrowLeft,
  ArrowRight,
  ExternalLink,
  Globe,
  LoaderCircle,
  LogIn,
  MousePointerClick,
  RectangleHorizontal,
  RotateCw,
  ShieldAlert,
} from 'lucide-react'
import { controller } from '../../controller'
import { hueOf } from '../colors'
import { FRAME } from '../doc'
import {
  BAR_H,
  FRAME_ALLOW,
  FRAME_SANDBOX,
  FrameNav,
  frameName,
  frameUrl,
  makeNonce,
  mayWrite,
  sameUrl,
  type FrameEvent,
} from '../frames'
import type { Shape } from '../types'
import { useBoard } from './context'
import { hostLabel, place } from './Shapes'
import { cn } from './ui'

export interface FrameUser {
  clientId: number
  name: string
  color: string
}

type Trouble = 'refused' | 'blank' | 'timeout'

/** A report becomes a write after this quiet (an address); titles alone wait longer. */
const WRITE_MS = 350
const TITLE_WRITE_MS = 3000
/** After following someone, this frame's own redirects are its own business. */
const FOLLOW_QUIET_MS = 2500
/** A press on Back, Forward, Reload or the address lets what loads next be written. */
const CHROME_NAV_MS = 8000
/** Loaded, and the host's script never said so: the document isn't the site's. */
const SILENT_MS = 1500
/**
 * Nothing at all for this long — not even the document's first report, which
 * comes at DOMContentLoaded: say so rather than show a blank box forever (an
 * address that doesn't resolve never fires the iframe's load). The iframe
 * keeps loading under the card, and a late report takes the card away.
 */
const NO_LOAD_MS = 10000

interface Props {
  shape: Shape
  selected: boolean
  active: boolean
  /** It may have a real iframe now (on screen, big enough, within budget). */
  mounted: boolean
  /** A board gesture is under way: the page must not take the pointer. */
  busy: boolean
  zoom: number
  /** Other people using this frame right now. */
  users: readonly FrameUser[]
  onDeactivate: () => void
  onLive: (id: string, live: boolean) => void
}

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

function BarButton({ label, onClick, disabled, children }: { label: string; onClick: () => void; disabled?: boolean; children: ReactNode }) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      disabled={disabled}
      className="flex h-[26px] w-[26px] shrink-0 items-center justify-center rounded-md text-ink-3 hover:bg-surface-2 hover:text-ink disabled:pointer-events-none disabled:opacity-35"
      onPointerDown={stop}
      onDoubleClick={stop}
      onClick={e => {
        e.stopPropagation()
        onClick()
      }}
    >
      {children}
    </button>
  )
}

function Favicon({ src, host, size }: { src?: string; host: string; size: number }) {
  const [failed, setFailed] = useState<string | null>(null)
  const hue = hueOf(host)
  if (src && failed !== src)
    return <img src={src} alt="" draggable={false} onError={() => setFailed(src)} className="shrink-0 object-contain" style={{ width: size, height: size }} />
  return (
    <span
      className="flex shrink-0 items-center justify-center rounded-[4px] font-bold"
      style={{ width: size, height: size, fontSize: size * 0.62, background: `hsl(${hue} 55% 92%)`, color: `hsl(${hue} 45% 38%)` }}
      aria-hidden="true"
    >
      {host ? host.slice(0, 1).toUpperCase() : <Globe style={{ width: size * 0.7, height: size * 0.7 }} />}
    </span>
  )
}

/** The iframe itself; remounted (a new `key`) to load from scratch. Its first src is kept: later moves are imperative. */
function Page({
  name,
  initial,
  frameRef,
  busy,
  onLoad,
}: {
  name: string
  initial: string
  frameRef: React.RefObject<HTMLIFrameElement | null>
  busy: boolean
  onLoad: () => void
}) {
  const [src] = useState(initial)
  return (
    <iframe
      ref={frameRef}
      name={name}
      src={src}
      title={hostLabel(src)}
      sandbox={FRAME_SANDBOX}
      allow={FRAME_ALLOW}
      allowFullScreen
      referrerPolicy="strict-origin-when-cross-origin"
      onLoad={onLoad}
      className="absolute inset-0 h-full w-full border-0 bg-white"
      style={{ pointerEvents: busy ? 'none' : undefined }}
    />
  )
}

export const WebFrame = memo(function WebFrame({ shape, selected, active, mounted, busy, zoom, users, onDeactivate, onLive }: Props) {
  const board = useBoard()
  const url = frameUrl(shape.url) ?? ''
  const host = hostLabel(url || shape.url || '')
  const [nonce] = useState(makeNonce)
  const name = frameName(shape.id, nonce)
  const [nav] = useState(() => new FrameNav(url))
  useSyncExternalStore(nav.subscribe, nav.getVersion)
  const frame = useRef<HTMLIFrameElement>(null)
  const [page, setPage] = useState<{ title: string; icon?: string } | null>(null)
  const [loading, setLoading] = useState(true)
  const [trouble, setTrouble] = useState<Trouble | null>(null)
  const [epoch, setEpoch] = useState(0)
  const [address, setAddress] = useState<string | null>(null)
  const timing = useRef({ lastReport: 0, loadMark: 0, quietUntil: 0, chromeUntil: 0, silent: 0 as ReturnType<typeof setTimeout> | 0 })
  const writeTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const latest = useRef({ active, onDeactivate, readOnly: board.readOnly })
  useEffect(() => {
    latest.current = { active, onDeactivate, readOnly: board.readOnly }
  })

  /** Put where this frame is (and what it is called) in the shape, once it settles. */
  const write = useCallback(
    (to: string, title: string | undefined, icon: string | undefined, moved: boolean) => {
      if (writeTimer.current) clearTimeout(writeTimer.current)
      writeTimer.current = setTimeout(
        () => {
          writeTimer.current = null
          const cur = board.store.get(shape.id)
          if (!cur || !cur.live) return
          const patch: Partial<Shape> = {}
          const movedHost = hostLabel(cur.url ?? '') !== hostLabel(to)
          if (!sameUrl(cur.url, to)) patch.url = to
          const t = title?.trim()
          if (t && t !== cur.title) patch.title = t
          else if (!t && patch.url && movedHost) patch.title = hostLabel(to)
          if (icon && icon !== cur.favicon) patch.favicon = icon
          else if (!icon && movedHost && cur.favicon) patch.favicon = ''
          if (Object.keys(patch).length) board.store.update(shape.id, patch, FRAME)
        },
        moved ? WRITE_MS : TITLE_WRITE_MS
      )
    },
    [board.store, shape.id]
  )
  useEffect(
    () => () => {
      if (writeTimer.current) clearTimeout(writeTimer.current)
      if (timing.current.silent) clearTimeout(timing.current.silent)
    },
    []
  )

  /** Move the iframe without adding to the board's own history (every frame shares it). */
  const go = useCallback((to: string) => {
    const el = frame.current
    if (!el) return
    setLoading(true)
    try {
      el.contentWindow?.location.replace(to)
    } catch {
      el.src = to
    }
  }, [])

  // The host's reports for this frame.
  useEffect(
    () =>
      controller.frames.on(name, (e: FrameEvent) => {
        const t = timing.current
        if (e.kind === 'escape') {
          if (latest.current.active) latest.current.onDeactivate()
          return
        }
        t.lastReport = performance.now()
        if (e.kind === 'blank') {
          setTrouble('blank')
          return
        }
        setTrouble(null)
        setLoading(false)
        setPage({ title: e.title, icon: e.icon })
        const moved = nav.report(e.url)
        const may = mayWrite({ active: latest.current.active, readOnly: latest.current.readOnly, now: t.lastReport, ...t })
        if (may) write(e.url, e.title, e.icon, moved)
        else if (!latest.current.readOnly && e.title.trim()) {
          // A frame added with only its address (an agent's, a pasted link)
          // gets the page's own name: the same page here as for everyone, so
          // whoever's frame says so first, nobody's write undoes another's.
          const cur = board.store.get(shape.id)
          if (cur?.live && sameUrl(cur.url, e.url) && (!cur.title.trim() || cur.title === hostLabel(cur.url ?? ''))) {
            const patch: Partial<Shape> = { title: e.title.trim() }
            if (e.icon && !cur.favicon) patch.favicon = e.icon
            board.store.update(shape.id, patch, FRAME)
          }
        }
      }),
    [name, nav, write, board.store, shape.id]
  )

  // Someone else moved it (or an agent, or undo): follow, quietly.
  useEffect(() => {
    if (!url || !nav.remote(url)) return
    // What we were about to write is older than what just arrived.
    if (writeTimer.current) clearTimeout(writeTimer.current)
    writeTimer.current = null
    timing.current.quietUntil = performance.now() + FOLLOW_QUIET_MS
    go(url)
  }, [url, nav, go])

  // A fresh iframe: watch for it never saying it loaded.
  useEffect(() => {
    if (!mounted) return
    const t = timing.current
    const start = performance.now()
    t.loadMark = start
    // Asked when the time is up: the host says it reports only after init,
    // often after the board's frames are already mounted.
    const timer = setTimeout(() => {
      if (controller.frames.reports && t.lastReport < start) setTrouble(prev => prev ?? 'timeout')
    }, NO_LOAD_MS)
    return () => clearTimeout(timer)
  }, [mounted, epoch])

  const onLoad = useCallback(() => {
    const t = timing.current
    const since = t.loadMark
    t.loadMark = performance.now()
    setLoading(false)
    if (t.silent) clearTimeout(t.silent)
    t.silent = setTimeout(() => {
      t.silent = 0
      // Outside Copper nobody reports, so silence means nothing.
      if (!controller.frames.reports) return
      if (t.lastReport < since) setTrouble('refused')
    }, SILENT_MS)
  }, [])

  useEffect(() => {
    if (active) frame.current?.focus()
  }, [active])

  const chrome = (to: string) => {
    const t = timing.current
    t.chromeUntil = performance.now() + CHROME_NAV_MS
    t.quietUntil = 0
    setTrouble(null)
    if (!frame.current) setEpoch(n => n + 1)
    go(to)
    if (!board.readOnly) write(to, undefined, undefined, true)
  }
  const back = () => {
    const to = nav.back()
    if (to) chrome(to)
  }
  const forward = () => {
    const to = nav.forward()
    if (to) chrome(to)
  }
  /**
   * Signed out in the frame: sign in where the site is the page itself (a
   * tab — its own cookies, every kind of them, and passkeys), and the frame
   * reloads when the board is looked at again, with whatever of that
   * sign-in a frame is allowed to see (docs/canvas.md, "Live web frames").
   */
  const signIn = () => {
    awaitingSignIn.current = true
    board.openUrl(nav.current || shape.url || '')
  }
  const awaitingSignIn = useRef(false)
  const reloadRef = useRef<() => void>(() => {})
  useEffect(() => {
    const back = () => {
      if (document.visibilityState !== 'visible' || !awaitingSignIn.current) return
      awaitingSignIn.current = false
      reloadRef.current()
    }
    document.addEventListener('visibilitychange', back)
    return () => document.removeEventListener('visibilitychange', back)
  }, [])
  const reload = () => {
    setTrouble(null)
    if (!frame.current) {
      setEpoch(n => n + 1)
      return
    }
    timing.current.chromeUntil = performance.now() + CHROME_NAV_MS
    go(nav.current)
  }
  useEffect(() => {
    reloadRef.current = reload
  })
  const retry = () => {
    setTrouble(null)
    setLoading(true)
    setEpoch(n => n + 1)
  }
  const submitAddress = (raw: string) => {
    const v = raw.trim()
    setAddress(null)
    if (!v) return
    const to = frameUrl(/^[a-z][a-z0-9+.-]*:/i.test(v) ? v : `https://${v}`)
    if (!to) return
    nav.report(to)
    chrome(to)
  }

  const title = page?.title || shape.title.trim() || host
  const icon = page?.icon ?? shape.favicon
  const screenW = shape.w * zoom
  const roomy = screenW >= 520
  // Slow is not refused: a frame still loading stays under its card.
  const showPage = mounted && !!url && (!trouble || trouble === 'timeout')
  const ring = active ? 'var(--accent)' : users[0]?.color
  const lead = users[0]

  return (
    <div
      data-id={shape.id}
      data-kind="link"
      data-live="1"
      className="group absolute left-0 top-0 flex flex-col overflow-visible rounded-[12px]"
      style={{
        ...place(shape),
        boxShadow: ring ? `0 0 0 ${(active ? 2.5 : 3) / zoom}px ${ring}, var(--shadow-note)` : 'var(--shadow-note)',
      }}
    >
      {lead && (
        <div
          className="pointer-events-none absolute right-0 top-0 z-10 flex origin-bottom-right items-center gap-1 whitespace-nowrap rounded-full px-2 py-[3px] text-[11.5px] font-semibold text-white shadow-1"
          style={{ backgroundColor: lead.color, translate: `0 calc(-100% - ${6 / zoom}px)`, scale: String(1 / zoom) }}
          data-testid="frame-user"
        >
          <MousePointerClick className="h-3 w-3" aria-hidden="true" />
          {users.length > 1 ? `${lead.name} +${users.length - 1}` : lead.name}
        </div>
      )}
      <div className="flex h-full w-full flex-col overflow-hidden rounded-[12px] border border-line bg-surface">
        <div
          data-part="web-bar"
          className="flex shrink-0 items-center gap-1 border-b border-line bg-surface px-1.5 text-ink"
          style={{ height: BAR_H }}
        >
          {roomy && (
            <>
              <BarButton label="Back" onClick={back} disabled={!nav.canBack}>
                <ArrowLeft className="h-3.5 w-3.5" />
              </BarButton>
              <BarButton label="Forward" onClick={forward} disabled={!nav.canForward}>
                <ArrowRight className="h-3.5 w-3.5" />
              </BarButton>
            </>
          )}
          <BarButton label="Reload" onClick={reload}>
            {loading && showPage ? <LoaderCircle className="h-3.5 w-3.5 animate-spin" /> : <RotateCw className="h-3.5 w-3.5" />}
          </BarButton>
          <div className="mx-1 flex min-w-0 flex-1 items-center gap-2">
            <Favicon src={icon} host={host} size={16} />
            {active ? (
              <input
                aria-label="Address"
                value={address ?? nav.current}
                spellCheck={false}
                onPointerDown={stop}
                onDoubleClick={stop}
                onFocus={e => e.currentTarget.select()}
                onChange={e => setAddress(e.currentTarget.value)}
                onBlur={() => setAddress(null)}
                onKeyDown={e => {
                  e.stopPropagation()
                  if (e.key === 'Enter') submitAddress(e.currentTarget.value)
                  if (e.key === 'Escape') {
                    setAddress(null)
                    e.currentTarget.blur()
                  }
                }}
                className="h-[26px] min-w-0 flex-1 rounded-md bg-surface-2 px-2 text-[12.5px] text-ink outline-none focus:ring-2 focus:ring-accent/40"
              />
            ) : (
              <p className="min-w-0 flex-1 truncate text-[13px] leading-none" title={nav.current}>
                <span className="font-semibold">{title}</span>
                {title !== host && <span className="text-ink-3"> · {host}</span>}
              </p>
            )}
          </div>
          {active && roomy && (
            <span className="shrink-0 rounded-md border border-line px-1.5 py-[2px] text-[10.5px] font-semibold text-ink-3" title="Esc returns to the board">
              Esc
            </span>
          )}
          {roomy && (
            <button
              type="button"
              title="Signed out here? Sign in in a tab — this frame reloads when you come back"
              className="flex h-[26px] shrink-0 items-center gap-1 rounded-md px-1.5 text-[12px] font-semibold text-ink-3 hover:bg-surface-2 hover:text-ink"
              onPointerDown={stop}
              onDoubleClick={stop}
              onClick={e => {
                e.stopPropagation()
                signIn()
              }}
            >
              <LogIn className="h-3.5 w-3.5" aria-hidden="true" />
              Sign in
            </button>
          )}
          <BarButton label="Open in a tab" onClick={() => board.openUrl(nav.current || shape.url || '')}>
            <ExternalLink className="h-3.5 w-3.5" />
          </BarButton>
          {!board.readOnly && (
            <BarButton label="Show as card" onClick={() => onLive(shape.id, false)}>
              <RectangleHorizontal className="h-3.5 w-3.5" />
            </BarButton>
          )}
        </div>
        <div data-part="web-body" className="relative min-h-0 flex-1 bg-surface-2">
          {showPage ? (
            <Page key={epoch} name={name} initial={nav.current} frameRef={frame} busy={busy || !active} onLoad={onLoad} />
          ) : trouble ? null : (
            <Placeholder title={title} host={host} icon={icon} zoom={zoom} />
          )}
          {trouble && (
            <Refused
              host={host}
              trouble={trouble}
              zoom={zoom}
              onOpen={() => board.openUrl(nav.current || shape.url || '')}
              onRetry={retry}
              onCard={board.readOnly ? undefined : () => onLive(shape.id, false)}
            />
          )}
          {!(active && showPage) && (
            <div data-part="web-shield" className="absolute inset-0" aria-hidden="true">
              {!busy && !trouble && (
                <div className="pointer-events-none absolute inset-0 flex items-center justify-center opacity-0 transition-opacity group-hover:opacity-100">
                  <span
                    className="flex items-center gap-1.5 whitespace-nowrap rounded-full bg-[#1d1d1f]/85 px-3 py-1.5 text-[12px] font-semibold text-white shadow-2"
                    style={{ scale: String(1 / zoom) }}
                  >
                    <MousePointerClick className="h-3.5 w-3.5" aria-hidden="true" />
                    {selected ? 'Click to use' : 'Double-click to use'}
                  </span>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  )
})

/** A live frame without its iframe (zoomed out, off screen, over budget): what it is. */
function Placeholder({ title, host, icon, zoom }: { title: string; host: string; icon?: string; zoom: number }) {
  // Readable however far out the board is: it is the only thing there to read.
  const k = Math.min(3, Math.max(1, 1 / zoom))
  return (
    <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 overflow-hidden p-6 text-center">
      <div style={{ scale: String(k) }} className="flex flex-col items-center gap-2">
        <Favicon src={icon} host={host} size={36} />
        <p className="line-clamp-2 max-w-[420px] text-[15px] font-semibold leading-snug text-ink">{title}</p>
        <p className="text-[12.5px] text-ink-3">{host} · live</p>
      </div>
    </div>
  )
}

function Refused({
  host,
  trouble,
  zoom,
  onOpen,
  onRetry,
  onCard,
}: {
  host: string
  trouble: Trouble
  zoom: number
  onOpen: () => void
  onRetry: () => void
  onCard?: () => void
}) {
  const why =
    trouble === 'blank'
      ? 'It hides itself when it is shown inside another page.'
      : trouble === 'timeout'
        ? 'It hasn’t loaded: the address may be wrong, or the site is slow.'
        : 'Or it didn’t load. In a tab it works as usual, signed in as you.'
  const k = Math.min(2.5, Math.max(1, 1 / zoom))
  return (
    <div data-testid="frame-refused" className="absolute inset-0 z-[1] flex items-center justify-center bg-surface p-6 text-center">
      <div className="flex max-w-[360px] flex-col items-center gap-2" style={{ scale: String(k) }}>
        <ShieldAlert className="h-7 w-7 text-ink-3" aria-hidden="true" />
        <p className="text-[14.5px] font-semibold text-ink">
          {trouble === 'refused' ? `${host} doesn’t allow embedding` : `${host} can’t be shown here`}
        </p>
        <p className="text-[12.5px] leading-snug text-ink-3">{why}</p>
        <div className="relative z-[2] mt-1.5 flex items-center gap-1.5" onPointerDown={stop} onDoubleClick={stop}>
          <button type="button" className="h-7 rounded-lg bg-accent px-2.5 text-[12.5px] font-semibold text-accent-ink hover:bg-accent-strong" onClick={onOpen}>
            Open in tab
          </button>
          <button type="button" className="h-7 rounded-lg px-2.5 text-[12.5px] font-semibold text-ink-2 hover:bg-surface-2" onClick={onRetry}>
            Try again
          </button>
          {onCard && (
            <button type="button" className={cn('h-7 rounded-lg px-2.5 text-[12.5px] font-semibold text-ink-2 hover:bg-surface-2')} onClick={onCard}>
              Show as card
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
