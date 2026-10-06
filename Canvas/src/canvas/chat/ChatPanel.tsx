/**
 * The chat panel, docked on the right of the board: messages grouped by
 * author with day lines and short times, your own on the right, mentions as
 * chips (yours stronger), links that open in a tab, and the composer. It
 * follows the newest message unless you scrolled up — then a pill says how
 * many came in. What is on screen with the page visible counts as read.
 */
import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import { ArrowDown, Trash2, X } from 'lucide-react'
import { postToHost } from '../../host-bridge'
import { IconButton, cn } from '../components/ui'
import { ChatAvatar, Composer } from './Composer'
import type { ChatHub } from './hub'
import { fullTime, groupMessages, segments, shortTime, stableColor, type ChatGroup, type ChatMember, type ChatMessage } from './model'

/** Shown at first; "Show earlier messages" adds as many again. */
const PAGE = 150
/** Within this of the bottom counts as at the bottom. */
const BOTTOM_PX = 48

const FLASH_CSS = `
@keyframes chat-flash { 0%, 35% { box-shadow: 0 0 0 2px var(--accent); } 100% { box-shadow: 0 0 0 2px transparent; } }
.chat-flash { animation: chat-flash 1.8s ease-out both; }
@media (prefers-reduced-motion: reduce) { .chat-flash { animation: none; box-shadow: 0 0 0 2px var(--accent); } }
.chat-scroll { scrollbar-width: thin; }
`

const useNow = (ms: number) => {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), ms)
    return () => clearInterval(t)
  }, [ms])
  return now
}

function Body({ message, me, own }: { message: ChatMessage; me: string; own: boolean }) {
  if (message.deleted) return <span className="italic text-ink-4">Message deleted</span>
  return (
    <>
      {segments(message.text, message.mentions).map((s, i) => {
        if (s.kind === 'mention') {
          const mine = s.id === me
          return (
            <span
              key={i}
              data-mention={s.id}
              className={cn(
                'rounded-[5px] px-[3px] py-px font-medium',
                mine
                  ? 'bg-accent text-accent-ink'
                  : own
                    ? 'bg-surface/85 text-accent-strong shadow-[0_0_0_1px_var(--line)] dark:bg-black/25 dark:text-accent'
                    : 'bg-accent/15 text-accent-strong dark:text-accent'
              )}
            >
              @{s.name}
            </span>
          )
        }
        if (s.kind === 'link')
          return (
            <a
              key={i}
              href={s.url}
              className="text-accent-strong underline decoration-accent/40 underline-offset-2 hover:decoration-accent dark:text-accent"
              onClick={e => {
                e.preventDefault()
                postToHost({ type: 'openUrl', url: s.url })
              }}
            >
              {s.text}
            </a>
          )
        return <span key={i}>{s.text}</span>
      })}
    </>
  )
}

const Group = memo(function Group({
  group,
  me,
  color,
  now,
  flash,
  newLine,
  onDelete,
  readOnly,
}: {
  group: ChatGroup
  me: string
  color: string
  now: number
  flash: { id: string; at: number } | null
  newLine: string | null
  onDelete: (id: string) => void
  readOnly: boolean
}) {
  const mine = group.mine
  return (
    <div className="flex flex-col">
      {group.day && (
        <div className="my-3 flex items-center gap-3 px-1 text-[11px] font-medium text-ink-4" role="separator" aria-label={group.day}>
          <span className="h-px flex-1 bg-line" />
          {group.day}
          <span className="h-px flex-1 bg-line" />
        </div>
      )}
      {newLine === group.messages[0]?.id && <NewLine />}
      <div className={cn('mt-2.5 flex gap-2', mine ? 'flex-row-reverse' : 'flex-row')}>
        {!mine && (
          <span className="mt-[18px]">
            <ChatAvatar name={group.authorName} color={color} />
          </span>
        )}
        <div className={cn('flex min-w-0 max-w-[86%] flex-col gap-[3px]', mine ? 'items-end' : 'items-start')}>
          <div className={cn('flex items-baseline gap-1.5 px-1 text-[11.5px] leading-4', mine && 'flex-row-reverse')}>
            <span className="truncate font-semibold text-ink-2">{mine ? 'You' : group.authorName}</span>
            <time className="shrink-0 text-ink-4" dateTime={new Date(group.at).toISOString()} title={fullTime(group.at)}>
              {shortTime(group.at, now)}
            </time>
          </div>
          {group.messages.map((m, i) => (
            <div key={m.id} className="contents">
              {i > 0 && newLine === m.id && <NewLine />}
              <div className={cn('group/msg relative flex max-w-full items-center gap-1', mine && 'flex-row-reverse')}>
                <div
                  data-message={m.id}
                  title={i > 0 ? fullTime(m.at) : undefined}
                  className={cn(
                    'min-w-0 max-w-full whitespace-pre-wrap break-words rounded-[12px] px-2.5 py-[6px] text-[13px] leading-[19px] [overflow-wrap:anywhere] select-text',
                    mine ? 'bg-accent-soft text-ink' : 'bg-surface-2 text-ink',
                    m.deleted && 'bg-transparent px-1 py-0.5 text-[12px]',
                    flash?.id === m.id && 'chat-flash'
                  )}
                  key={flash?.id === m.id ? flash.at : undefined}
                >
                  <Body message={m} me={me} own={mine} />
                </div>
                {mine && !m.deleted && !readOnly && (
                  <button
                    type="button"
                    aria-label="Delete message"
                    title="Delete for everyone"
                    className="flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-ink-4 opacity-0 outline-none transition-opacity hover:bg-surface-2 hover:text-danger focus-visible:opacity-100 focus-visible:ring-2 focus-visible:ring-accent/60 group-hover/msg:opacity-100"
                    onClick={() => onDelete(m.id)}
                  >
                    <Trash2 className="h-3.5 w-3.5" aria-hidden="true" />
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
})

function NewLine() {
  return (
    <div className="my-2 flex items-center gap-2 px-1 text-[10.5px] font-semibold uppercase tracking-[0.04em] text-accent" aria-label="New messages">
      <span className="h-px flex-1 bg-accent/40" />
      New
    </div>
  )
}

function colorOf(id: string, members: readonly ChatMember[]) {
  return members.find(m => m.id === id)?.color ?? stableColor(id)
}

export function ChatPanel({ hub }: { hub: ChatHub }) {
  useSyncExternalStore(hub.subscribe, hub.getVersion)
  const { messages, config, unread, focus } = hub
  const me = hub.me
  const readOnly = hub.readOnly
  const now = useNow(30_000)
  const list = useRef<HTMLDivElement>(null)
  const [limit, setLimit] = useState(PAGE)
  const [atBottom, setAtBottom] = useState(true)
  const atBottomRef = useRef(true)
  const [missed, setMissed] = useState(0)
  const lastCount = useRef(messages.length)
  const lastId = useRef(messages[messages.length - 1]?.id)
  const [visible, setVisible] = useState(() => typeof document === 'undefined' || document.visibilityState !== 'hidden')
  // Where "New" goes: the first unread when the panel opened (kept while it stays open).
  const [newLine, setNewLine] = useState<string | null>(() => unread.firstId)

  // A revealed message older than what is shown widens the window to it.
  const focusIndex = focus ? messages.findIndex(m => m.id === focus.id) : -1
  const span = focusIndex >= 0 ? Math.max(limit, messages.length - focusIndex + 20) : limit
  const shown = useMemo(() => messages.slice(-span), [messages, span])
  const groups = useMemo(() => groupMessages(shown, me, now), [shown, me, now])
  const hidden = messages.length - shown.length

  useEffect(() => {
    const onVis = () => setVisible(document.visibilityState !== 'hidden')
    document.addEventListener('visibilitychange', onVis)
    return () => document.removeEventListener('visibilitychange', onVis)
  }, [])

  const toBottom = useCallback((smooth = false) => {
    const el = list.current
    if (!el) return
    el.scrollTo({ top: el.scrollHeight, behavior: smooth ? 'smooth' : 'auto' })
    atBottomRef.current = true
    setAtBottom(true)
    setMissed(0)
  }, [])

  // Opened at the bottom (or at the revealed message, below).
  useLayoutEffect(() => {
    if (!hub.focus) toBottom()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // New messages: follow them when at the bottom (and always your own), else count them.
  useLayoutEffect(() => {
    const count = messages.length
    const last = messages[count - 1]
    if (last && last.id !== lastId.current) {
      const grew = count >= lastCount.current
      if (atBottomRef.current || last.authorId === me) toBottom()
      else if (grew) setMissed(n => n + 1)
    }
    lastCount.current = count
    lastId.current = last?.id
  }, [messages, me, toBottom])

  // A reveal: scroll the message to the middle and flash it.
  useEffect(() => {
    if (!focus) return
    const frame = requestAnimationFrame(() => {
      const el = list.current?.querySelector<HTMLElement>(`[data-message="${CSS.escape(focus.id)}"]`)
      if (!el || !list.current) return
      el.scrollIntoView({ block: 'center' })
      const box = list.current
      const bottom = box.scrollHeight - box.scrollTop - box.clientHeight <= BOTTOM_PX
      atBottomRef.current = bottom
      setAtBottom(bottom)
      hub.markSeen(focus.id)
    })
    return () => cancelAnimationFrame(frame)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focus?.id, focus?.at])

  // At the bottom with the page showing: read.
  useEffect(() => {
    if (atBottom && visible && unread.count > 0) hub.markRead()
  }, [atBottom, visible, unread.count, messages, hub])

  useEffect(() => {
    if (unread.firstId && !newLine && !atBottomRef.current) setNewLine(unread.firstId)
  }, [unread.firstId, newLine])

  const onScroll = () => {
    const el = list.current
    if (!el) return
    const bottom = el.scrollHeight - el.scrollTop - el.clientHeight <= BOTTOM_PX
    if (bottom !== atBottomRef.current) {
      atBottomRef.current = bottom
      setAtBottom(bottom)
    }
    if (bottom) setMissed(0)
    if (el.scrollTop < 24 && hidden > 0) {
      const before = el.scrollHeight
      setLimit(l => l + PAGE)
      requestAnimationFrame(() => {
        if (list.current) list.current.scrollTop += list.current.scrollHeight - before
      })
    }
  }

  const memberCount = config.members.length
  return (
    <aside
      aria-label="Canvas chat"
      data-testid="canvas-chat"
      className="flex h-full w-full flex-col bg-surface"
      onPointerDown={e => e.stopPropagation()}
      onDoubleClick={e => e.stopPropagation()}
    >
      <style>{FLASH_CSS}</style>
      <header className="flex h-[52px] shrink-0 items-center gap-2 border-b border-line pl-4 pr-2">
        <h2 className="text-[13.5px] font-semibold tracking-[-0.005em] text-ink">Chat</h2>
        {memberCount > 0 && (
          <span className="truncate text-[12px] text-ink-3">
            {memberCount} {memberCount === 1 ? 'person' : 'people'}
          </span>
        )}
        <span className="flex-1" />
        <IconButton size="sm" label="Hide chat" keys="C" tipBelow tipEnd onClick={() => hub.setOpen(false)}>
          <X className="h-4 w-4" />
        </IconButton>
      </header>
      <div className="relative min-h-0 flex-1">
        <div
          ref={list}
          role="log"
          aria-label="Messages"
          className="chat-scroll absolute inset-0 overflow-y-auto overflow-x-hidden px-3 pb-3 pt-1"
          onScroll={onScroll}
        >
          {hidden > 0 && (
            <div className="flex justify-center pt-2">
              <button
                type="button"
                className="rounded-full px-2.5 py-1 text-[11.5px] font-medium text-ink-3 hover:bg-surface-2 hover:text-ink-2"
                onClick={() => setLimit(l => l + PAGE)}
              >
                Show earlier messages
              </button>
            </div>
          )}
          {messages.length === 0 ? (
            <div className="flex h-full flex-col items-center justify-center px-6 text-center">
              <p className="text-[13.5px] font-semibold text-ink-2">No messages yet</p>
              <p className="mt-1 text-[12.5px] leading-relaxed text-ink-3">
                Talk about this canvas with the people on it. Type <span className="font-semibold text-ink-2">@</span> to mention someone.
              </p>
            </div>
          ) : (
            groups.map(g => (
              <Group
                key={g.key}
                group={g}
                me={me}
                color={colorOf(g.authorId, config.members)}
                now={now}
                flash={focus}
                newLine={newLine}
                onDelete={id => hub.remove(id)}
                readOnly={readOnly}
              />
            ))
          )}
        </div>
        {(!atBottom && (missed > 0 || unread.count > 0)) && (
          <div className="pointer-events-none absolute inset-x-0 bottom-2 flex justify-center">
            <button
              type="button"
              className="pop-in pointer-events-auto flex items-center gap-1.5 rounded-full bg-[#1d1d1f] px-3 py-1 text-[12px] font-medium text-white shadow-2 hover:bg-black dark:bg-[#f2f2ef] dark:text-[#1d1d1f] dark:hover:bg-white"
              onClick={() => toBottom(true)}
            >
              <ArrowDown className="h-3.5 w-3.5" aria-hidden="true" />
              {Math.max(missed, unread.count)} new {Math.max(missed, unread.count) === 1 ? 'message' : 'messages'}
            </button>
          </div>
        )}
      </div>
      <Composer hub={hub} members={config.members} readOnly={readOnly} />
    </aside>
  )
}

