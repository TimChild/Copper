/**
 * The message field: Enter sends, Shift+Enter is a new line, and "@" opens a
 * picker of the people on this canvas. A picked person is kept beside the
 * draft by id; their "@Name" is tinted in the field and becomes a token
 * bound to that id when the message goes (`composeText`). Paste is plain
 * text — the field is a textarea, so nothing a clipboard holds is HTML here.
 */
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from 'react'
import { ArrowUp } from 'lucide-react'
import { initials } from '../colors'
import { cn } from '../components/ui'
import type { ChatHub } from './hub'
import { MAX_TEXT, filterMembers, mentionQuery, mentionRanges, type ChatMember, type Picked } from './model'

const LISTBOX_ID = 'chat-mention-list'
const MAX_FIELD_PX = 148

function Avatar({ name, color, size = 24, dashed }: { name: string; color: string; size?: number; dashed?: boolean }) {
  return (
    <span
      aria-hidden="true"
      className={cn(
        'flex shrink-0 items-center justify-center rounded-full font-semibold',
        dashed ? 'border border-dashed border-ink-4 text-ink-3' : 'text-white'
      )}
      style={{ width: size, height: size, fontSize: size <= 20 ? 9 : 10.5, ...(dashed ? {} : { background: color }) }}
    >
      {initials(name)}
    </span>
  )
}

export { Avatar as ChatAvatar }

/** Bold the part of a name the query matched. */
function Matched({ text, query }: { text: string; query: string }) {
  const q = query.trim().toLowerCase()
  const i = q ? text.toLowerCase().indexOf(q) : -1
  if (i < 0) return <>{text}</>
  return (
    <>
      {text.slice(0, i)}
      <span className="font-semibold text-ink">{text.slice(i, i + q.length)}</span>
      {text.slice(i + q.length)}
    </>
  )
}

export function Composer({ hub, members, readOnly }: { hub: ChatHub; members: readonly ChatMember[]; readOnly: boolean }) {
  const field = useRef<HTMLTextAreaElement>(null)
  const backdrop = useRef<HTMLDivElement>(null)
  const [draft, setDraft] = useState('')
  const [picked, setPicked] = useState<Picked[]>([])
  const [caret, setCaret] = useState(0)
  const [active, setActive] = useState(0)
  const [dismissed, setDismissed] = useState<number | null>(null)
  const [error, setError] = useState('')
  const composing = useRef(false)

  const ranges = useMemo(() => mentionRanges(draft, picked), [draft, picked])
  // An @ that is already a picked mention isn't a question any more.
  const query = useMemo(() => {
    const q = readOnly ? null : mentionQuery(draft, caret)
    return q && !ranges.some(r => r.start === q.start) ? q : null
  }, [draft, caret, readOnly, ranges])
  const open = !!query && dismissed !== query.start
  const me = hub.me
  const matches = useMemo(() => (query ? filterMembers(members, query.query, me, 8) : []), [members, query, me])
  const invitedMatches = useMemo(() => {
    if (!query) return []
    const q = query.query.trim().toLowerCase()
    return hub.config.invited.filter(p => !q || p.name.toLowerCase().includes(q) || p.email.toLowerCase().includes(q)).slice(0, 3)
  }, [query, hub.config.invited])
  const others = members.filter(m => m.id !== me).length

  useEffect(() => {
    if (open) hub.wantMembers()
  }, [open, hub])

  // The board's C (or a reveal) asks for the keyboard.
  const focusAsk = hub.focusComposer
  useEffect(() => {
    if (focusAsk > 0) field.current?.focus({ preventScroll: true })
  }, [focusAsk])

  // Grow with the text, up to a few lines; the backdrop follows the field.
  useLayoutEffect(() => {
    const el = field.current
    if (!el) return
    el.style.height = '0px'
    el.style.height = `${Math.min(MAX_FIELD_PX, el.scrollHeight)}px`
    if (backdrop.current) backdrop.current.scrollTop = el.scrollTop
  }, [draft])

  const pick = (m: ChatMember) => {
    if (!query) return
    const before = draft.slice(0, query.start)
    const after = draft.slice(caret).replace(/^[^\s]*/u, '')
    const inserted = `@${m.name} `
    const next = before + inserted + after.replace(/^\s/u, '')
    const at = before.length + inserted.length
    setDraft(next)
    setPicked(p => [...p.filter(x => x.id !== m.id || x.name !== m.name), { id: m.id, name: m.name }])
    setCaret(at)
    setActive(0)
    requestAnimationFrame(() => {
      const el = field.current
      if (!el) return
      el.focus({ preventScroll: true })
      el.setSelectionRange(at, at)
    })
  }

  const send = () => {
    if (readOnly) return
    if (!draft.trim()) return
    const result = hub.sendDraft(draft, ranges)
    if (!result.ok) {
      setError(result.error ?? 'That message could not be sent')
      return
    }
    setDraft('')
    setPicked([])
    setCaret(0)
    setError('')
    setDismissed(null)
  }

  const onKeyDown = (e: ReactKeyboardEvent<HTMLTextAreaElement>) => {
    if (composing.current || e.nativeEvent.isComposing) return
    if (open && matches.length > 0) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault()
        const d = e.key === 'ArrowDown' ? 1 : -1
        setActive(a => (a + d + matches.length) % matches.length)
        return
      }
      if (e.key === 'Enter' || e.key === 'Tab') {
        e.preventDefault()
        pick(matches[Math.min(active, matches.length - 1)]!)
        return
      }
    }
    if (open && e.key === 'Escape') {
      e.preventDefault()
      e.stopPropagation()
      setDismissed(query.start)
      return
    }
    if (e.key === 'Enter' && !e.shiftKey && !e.altKey && !e.metaKey && !e.ctrlKey) {
      e.preventDefault()
      send()
      return
    }
    if (e.key === 'Escape') {
      e.preventDefault()
      field.current?.blur()
      document.querySelector<HTMLElement>('[role="application"]')?.focus({ preventScroll: true })
    }
  }

  // The field's text with every bound mention tinted, drawn under the field.
  const marked = useMemo(() => {
    const parts: (string | { text: string; key: string })[] = []
    let at = 0
    for (const r of ranges) {
      if (r.start > at) parts.push(draft.slice(at, r.start))
      parts.push({ text: draft.slice(r.start, r.end), key: `${r.start}` })
      at = r.end
    }
    parts.push(draft.slice(at) + '\u200b')
    return parts
  }, [draft, ranges])

  const length = draft.length
  const near = length > MAX_TEXT - 400
  const activeId = open && matches.length ? `${LISTBOX_ID}-${Math.min(active, matches.length - 1)}` : undefined

  return (
    <div className="relative shrink-0 border-t border-line px-3 pb-3 pt-2.5">
      {open && (
        <div
          id={LISTBOX_ID}
          role="listbox"
          aria-label="People on this canvas"
          className="pop-in absolute inset-x-3 bottom-[calc(100%-4px)] z-10 max-h-[280px] overflow-y-auto overflow-x-hidden rounded-[12px] border border-line bg-surface p-1 shadow-2"
          onMouseDown={e => e.preventDefault()}
        >
          <p className="px-2 pb-1 pt-1.5 text-[11px] font-medium text-ink-3">
            {!hub.config.membersKnown ? 'Loading the people on this canvas…' : 'People on this canvas'}
          </p>
          {matches.map((m, i) => (
            <div
              key={m.id}
              id={`${LISTBOX_ID}-${i}`}
              role="option"
              aria-selected={i === active}
              data-name={m.name}
              className={cn(
                'flex cursor-default items-center gap-2.5 rounded-lg px-2 py-1.5',
                i === active ? 'bg-accent-soft' : 'hover:bg-surface-2'
              )}
              onMouseEnter={() => setActive(i)}
              onClick={() => pick(m)}
            >
              <Avatar name={m.name} color={m.color ?? '#888'} />
              <span className="flex min-w-0 flex-1 flex-col leading-tight">
                <span className="truncate text-[13px] text-ink-2">
                  <Matched text={m.name} query={query?.query ?? ''} />
                </span>
                {m.email && m.email !== m.name && <span className="truncate text-[11.5px] text-ink-3">{m.email}</span>}
              </span>
              {i === active && <span className="shrink-0 text-[10.5px] font-medium text-ink-4">↵</span>}
            </div>
          ))}
          {hub.config.membersKnown && matches.length === 0 && (
            <p className="px-2 py-2 text-[12.5px] text-ink-3">
              {others === 0
                ? 'Only you are on this canvas so far. Share it to bring people in.'
                : query?.query
                  ? `No one on this canvas matches “${query.query}”`
                  : 'No one else to mention'}
            </p>
          )}
          {invitedMatches.length > 0 && (
            <>
              <p className="px-2 pb-1 pt-2 text-[11px] font-medium text-ink-3">Invited · can be mentioned once they join</p>
              {invitedMatches.map(p => (
                <div key={p.email || p.name} aria-disabled="true" className="flex items-center gap-2.5 rounded-lg px-2 py-1.5 opacity-70">
                  <Avatar name={p.name} color="" dashed />
                  <span className="flex min-w-0 flex-1 flex-col leading-tight">
                    <span className="truncate text-[13px] text-ink-3">{p.name}</span>
                    {p.email && p.email !== p.name && <span className="truncate text-[11.5px] text-ink-4">{p.email}</span>}
                  </span>
                  <span className="shrink-0 rounded-md bg-surface-2 px-1.5 py-0.5 text-[10.5px] font-medium text-ink-3">Invited</span>
                </div>
              ))}
            </>
          )}
        </div>
      )}
      <div
        className={cn(
          'relative rounded-[12px] border border-line-2 bg-surface transition-[border-color,box-shadow] duration-100',
          'focus-within:border-accent/55 focus-within:shadow-[0_0_0_3px_var(--accent-soft)]',
          readOnly && 'opacity-60'
        )}
      >
        <div
          ref={backdrop}
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 overflow-hidden whitespace-pre-wrap break-words py-[9px] pl-3 pr-11 text-[13px] leading-[19px] text-transparent"
        >
          {marked.map((p, i) =>
            typeof p === 'string' ? (
              <span key={i}>{p}</span>
            ) : (
              <mark key={p.key} className="rounded-[4px] bg-accent/20 text-transparent shadow-[0_0_0_1.5px_color-mix(in_srgb,var(--accent)_20%,transparent)]">
                {p.text}
              </mark>
            )
          )}
        </div>
        <textarea
          ref={field}
          rows={1}
          value={draft}
          disabled={readOnly}
          maxLength={MAX_TEXT}
          spellCheck
          placeholder={readOnly ? 'This canvas is view only' : 'Message · @ to mention'}
          aria-label="Message"
          aria-autocomplete="list"
          aria-expanded={open}
          aria-controls={open ? LISTBOX_ID : undefined}
          aria-activedescendant={activeId}
          className="relative block w-full resize-none overflow-y-auto bg-transparent py-[9px] pl-3 pr-11 text-[13px] leading-[19px] text-ink outline-none placeholder:text-ink-4"
          style={{ maxHeight: MAX_FIELD_PX }}
          onChange={e => {
            setDraft(e.target.value)
            setCaret(e.target.selectionStart ?? e.target.value.length)
            setError('')
            if (dismissed !== null && !e.target.value.includes('@')) setDismissed(null)
            setActive(0)
          }}
          onSelect={e => setCaret(e.currentTarget.selectionStart ?? 0)}
          onScroll={e => {
            if (backdrop.current) backdrop.current.scrollTop = e.currentTarget.scrollTop
          }}
          onKeyDown={onKeyDown}
          onCompositionStart={() => (composing.current = true)}
          onCompositionEnd={() => (composing.current = false)}
          onBlur={() => setDismissed(query?.start ?? null)}
          onFocus={() => setDismissed(null)}
        />
        <button
          type="button"
          aria-label="Send (↵)"
          disabled={readOnly || !draft.trim()}
          onMouseDown={e => e.preventDefault()}
          onClick={send}
          className="absolute bottom-[5px] right-[5px] flex h-[28px] w-[28px] items-center justify-center rounded-[8px] bg-accent text-accent-ink outline-none transition-colors hover:bg-accent-strong focus-visible:ring-2 focus-visible:ring-accent/60 disabled:bg-surface-2 disabled:text-ink-4"
        >
          <ArrowUp className="h-4 w-4" strokeWidth={2.25} aria-hidden="true" />
        </button>
      </div>
      <div className="mt-1.5 flex min-h-[16px] items-center justify-between gap-2 px-0.5 text-[11px] text-ink-4">
        {error ? (
          <span role="alert" className="text-danger">
            {error}
          </span>
        ) : (
          <span className="truncate">
            <span className="font-medium text-ink-3">↵</span> send · <span className="font-medium text-ink-3">⇧↵</span> new line
          </span>
        )}
        {near && <span className={cn('shrink-0 tabular-nums', length >= MAX_TEXT && 'text-danger')}>{MAX_TEXT - length}</span>}
      </div>
    </div>
  )
}
