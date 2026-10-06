/**
 * Chat on a shared canvas: the message format kept in the canvas document,
 * and the pure helpers around it (mention tokens, excerpts, grouping, unread).
 *
 * Messages live in the canvas Y.Doc as a top-level `Y.Array` named `chat`
 * of plain objects, so they sync and persist with the board itself:
 *
 *   {id, authorId, authorName, text, mentions: [userId], at (ms), editedAt?, deleted?}
 *
 * A mention is a token in the text bound to a user id — `<@id|Name>` — and
 * the id is also listed in `mentions`. Only a token whose id is listed there
 * is drawn as a chip; anything else that merely looks like one is text.
 * Agents and older readers see the token, which still reads as "@Name".
 */
import * as Y from 'yjs'

export const CHAT_KEY = 'chat'
/** The doc keeps at most this many; the client that appends past it drops the oldest. */
export const MAX_MESSAGES = 1000
/** Characters in a stored message (tokens included). */
export const MAX_TEXT = 4000
/** What the mentions API takes as an excerpt. */
export const EXCERPT_MAX = 200
/** Messages from one author this close together read as one group. */
export const GROUP_MS = 5 * 60 * 1000

export interface ChatMessage {
  id: string
  authorId: string
  authorName: string
  text: string
  mentions: string[]
  at: number
  editedAt?: number
  deleted?: boolean
}

/** Someone on the canvas, as the host lists them. */
export interface ChatMember {
  id: string
  name: string
  email: string
  role?: string
  color?: string
}

/** Invited, not joined yet: shown in the list, mentionable once they join. */
export interface ChatInvitee {
  name: string
  email: string
}

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v)
const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** User ids compare lowercased (uuids from the cloud, either case). */
export const normId = (id: string) => id.trim().toLowerCase()

/** Tolerant read of one stored entry (another client, an agent, an older page). */
export function readMessage(v: unknown): ChatMessage | null {
  const o = v instanceof Y.Map ? (v.toJSON() as Record<string, unknown>) : v
  if (!isObject(o)) return null
  const id = typeof o.id === 'string' && o.id ? o.id : null
  if (!id) return null
  const text = typeof o.text === 'string' ? o.text.slice(0, MAX_TEXT) : ''
  const mentions = Array.isArray(o.mentions)
    ? [...new Set(o.mentions.filter((m): m is string => typeof m === 'string' && m.length > 0).map(normId))]
    : []
  const msg: ChatMessage = {
    id,
    authorId: typeof o.authorId === 'string' ? normId(o.authorId) : '',
    authorName: typeof o.authorName === 'string' && o.authorName.trim() ? o.authorName.trim().slice(0, 120) : 'Someone',
    text,
    mentions,
    at: finite(o.at) ? o.at : 0,
  }
  if (finite(o.editedAt)) msg.editedAt = o.editedAt
  if (o.deleted === true) {
    msg.deleted = true
    msg.text = ''
    msg.mentions = []
  }
  return msg
}

export function readLog(arr: Y.Array<unknown>): ChatMessage[] {
  const out: ChatMessage[] = []
  const seen = new Set<string>()
  for (const v of arr.toArray()) {
    const m = readMessage(v)
    if (!m || seen.has(m.id)) continue
    seen.add(m.id)
    out.push(m)
  }
  return out
}

/** Append one message; past the cap the oldest go (in the same transaction). */
export function appendMessage(doc: Y.Doc, msg: ChatMessage, origin: unknown = 'chat') {
  const arr = doc.getArray<unknown>(CHAT_KEY)
  doc.transact(() => {
    arr.push([{ ...msg }])
    const over = arr.length - MAX_MESSAGES
    if (over > 0) arr.delete(0, over)
  }, origin)
}

/** Replace one message in place (a delete leaves a tombstone so replies keep their place). */
export function replaceMessage(doc: Y.Doc, id: string, next: ChatMessage, origin: unknown = 'chat'): boolean {
  const arr = doc.getArray<unknown>(CHAT_KEY)
  let index = -1
  arr.toArray().forEach((v, i) => {
    if (index < 0 && isObject(v) && v.id === id) index = i
  })
  if (index < 0) return false
  doc.transact(() => {
    arr.delete(index, 1)
    arr.insert(index, [{ ...next }])
  }, origin)
  return true
}

// ---- mention tokens -------------------------------------------------------------

/** `<@id|Name>`: the name is the one shown when it was written. */
export const TOKEN_RE = /<@([^|<>\s]{1,80})\|([^<>|\n]{1,80})>/g

/** Names inside a token can't hold its delimiters. */
export const cleanName = (name: string) => name.replace(/[<>|\n\r]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80) || 'Someone'

export const mentionToken = (id: string, name: string) => `<@${normId(id)}|${cleanName(name)}>`

export type Segment =
  | { kind: 'text'; text: string }
  | { kind: 'mention'; id: string; name: string }
  | { kind: 'link'; text: string; url: string }

const URL_RE = /\bhttps?:\/\/[^\s<>"']+[^\s<>"'.,;:!?)\]}]/gi

function linkify(text: string, out: Segment[]) {
  let at = 0
  for (const m of text.matchAll(URL_RE)) {
    const start = m.index ?? 0
    if (start > at) out.push({ kind: 'text', text: text.slice(at, start) })
    out.push({ kind: 'link', text: m[0], url: m[0] })
    at = start + m[0].length
  }
  if (at < text.length) out.push({ kind: 'text', text: text.slice(at) })
}

/** A message's text as chips, links and plain runs. */
export function segments(text: string, mentions: readonly string[]): Segment[] {
  const listed = new Set(mentions.map(normId))
  const out: Segment[] = []
  let at = 0
  for (const m of text.matchAll(TOKEN_RE)) {
    const id = normId(m[1] ?? '')
    if (!listed.has(id)) continue
    const start = m.index ?? 0
    if (start > at) linkify(text.slice(at, start), out)
    out.push({ kind: 'mention', id, name: m[2] ?? 'Someone' })
    at = start + m[0].length
  }
  if (at < text.length) linkify(text.slice(at), out)
  return out
}

/** Tokens as "@Name": what an excerpt, a notification or an agent reads. */
export function plainText(text: string, mentions: readonly string[]): string {
  return segments(text, mentions)
    .map(s => (s.kind === 'mention' ? `@${s.name}` : s.text))
    .join('')
}

/** One line of at most `max` characters, for the mentions API and notifications. */
export function excerpt(text: string, mentions: readonly string[], max = EXCERPT_MAX): string {
  const flat = plainText(text, mentions).replace(/\s+/g, ' ').trim()
  if (flat.length <= max) return flat
  return `${flat.slice(0, max - 1).trimEnd()}…`
}

// ---- composing ------------------------------------------------------------------

/** A person picked from the autocomplete, kept beside the draft by name. */
export interface Picked {
  id: string
  name: string
}

const WORD = /[\p{L}\p{N}_]/u

/**
 * Where each picked "@Name" sits in the draft: a name followed by a letter
 * or digit isn't the mention any more (it was typed over). Longest names
 * first, so "@Ada Lovelace" wins over "@Ada".
 */
export function mentionRanges(draft: string, picked: readonly Picked[]): { start: number; end: number; id: string; name: string }[] {
  const names = [...picked].sort((a, b) => b.name.length - a.name.length)
  const taken: boolean[] = new Array(draft.length).fill(false)
  const out: { start: number; end: number; id: string; name: string }[] = []
  for (const p of names) {
    const needle = `@${p.name}`
    let from = 0
    for (;;) {
      const at = draft.indexOf(needle, from)
      if (at < 0) break
      from = at + 1
      const end = at + needle.length
      const next = draft[end]
      if (next !== undefined && WORD.test(next)) continue
      let free = true
      for (let i = at; i < end; i++) if (taken[i]) free = false
      if (!free) continue
      for (let i = at; i < end; i++) taken[i] = true
      out.push({ start: at, end, id: normId(p.id), name: p.name })
    }
  }
  return out.sort((a, b) => a.start - b.start)
}

/**
 * The draft as it is stored: every picked "@Name" whose person is still a
 * member becomes a token; the rest stays the text it reads as.
 */
export function composeText(
  draft: string,
  picked: readonly Picked[],
  memberIds: ReadonlySet<string>,
  me?: string
): { text: string; mentions: string[] } {
  const ranges = mentionRanges(draft, picked).filter(r => memberIds.has(r.id))
  let text = ''
  let at = 0
  const mentions: string[] = []
  for (const r of ranges) {
    text += draft.slice(at, r.start) + mentionToken(r.id, r.name)
    at = r.end
    if (r.id !== (me && normId(me)) && !mentions.includes(r.id)) mentions.push(r.id)
  }
  text += draft.slice(at)
  // A mention of yourself is drawn as one but notifies nobody.
  const selfMentioned = me ? ranges.some(r => r.id === normId(me)) : false
  if (selfMentioned && me && !mentions.includes(normId(me))) mentions.push(normId(me))
  return { text: text.replace(/\s+$/u, '').replace(/^\s+/u, ''), mentions }
}

/** The people to notify for a message: everyone it mentions but its author. */
export const notifyIds = (msg: ChatMessage) => msg.mentions.filter(id => id !== msg.authorId)

/**
 * The "@query" being typed at `caret`, if any: an @ at the start or after a
 * space or opening punctuation, then up to 40 characters with no line break
 * (a space is allowed: "@ada lo" still looks for Ada Lovelace).
 */
export function mentionQuery(value: string, caret: number): { start: number; query: string } | null {
  const before = value.slice(0, caret)
  const at = before.lastIndexOf('@')
  if (at < 0) return null
  const prev = at > 0 ? before[at - 1]! : ''
  if (prev && !/[\s([{"'“‘]/u.test(prev)) return null
  const query = before.slice(at + 1)
  if (query.length > 40 || /[\n\r]/.test(query) || /\s\s/.test(query) || query.startsWith(' ')) return null
  return { start: at, query }
}

/** Members matching a query, best first: name start, word start, email start, then anywhere. */
export function filterMembers<T extends { id: string; name: string; email: string }>(
  members: readonly T[],
  query: string,
  me: string | null,
  limit = 8
): T[] {
  const q = query.trim().toLowerCase()
  const mine = me ? normId(me) : ''
  const scored: { m: T; score: number }[] = []
  for (const m of members) {
    if (normId(m.id) === mine) continue
    const name = m.name.toLowerCase()
    const email = m.email.toLowerCase()
    let score = -1
    if (!q) score = 1
    else if (name.startsWith(q)) score = 5
    else if (name.split(/[\s._-]+/).some(w => w.startsWith(q))) score = 4
    else if (email.startsWith(q)) score = 3
    else if (name.includes(q)) score = 2
    else if (email.includes(q)) score = 1
    if (score >= 0) scored.push({ m, score })
  }
  scored.sort((a, b) => b.score - a.score || a.m.name.localeCompare(b.m.name))
  return scored.slice(0, limit).map(s => s.m)
}

// ---- reading the log ------------------------------------------------------------

export interface ChatGroup {
  key: string
  authorId: string
  authorName: string
  mine: boolean
  /** A day line goes above this group ("Today", "Yesterday", "Mon, Oct 5"). */
  day: string | null
  at: number
  messages: ChatMessage[]
}

const dayKey = (at: number) => {
  const d = new Date(at)
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`
}

export function dayLabel(at: number, now = Date.now()): string {
  const d = new Date(at)
  const today = new Date(now)
  const start = (x: Date) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime()
  const days = Math.round((start(today) - start(d)) / 86_400_000)
  if (days === 0) return 'Today'
  if (days === 1) return 'Yesterday'
  const sameYear = d.getFullYear() === today.getFullYear()
  return d.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric', ...(sameYear ? {} : { year: 'numeric' }) })
}

/** Consecutive messages from one author within GROUP_MS on one day, oldest first. */
export function groupMessages(messages: readonly ChatMessage[], me: string, now = Date.now()): ChatGroup[] {
  const out: ChatGroup[] = []
  const mine = normId(me)
  let lastDay = ''
  for (const m of messages) {
    const day = dayKey(m.at || now)
    const last = out[out.length - 1]
    const prev = last?.messages[last.messages.length - 1]
    const joins = last && prev && last.authorId === m.authorId && day === lastDay && Math.abs(m.at - prev.at) <= GROUP_MS && !prev.deleted
    if (joins) {
      last.messages.push(m)
      continue
    }
    out.push({
      key: m.id,
      authorId: m.authorId,
      authorName: m.authorName,
      mine: m.authorId === mine,
      day: day !== lastDay ? dayLabel(m.at || now, now) : null,
      at: m.at,
      messages: [m],
    })
    lastDay = day
  }
  return out
}

/** "now", "4 min", then the time of day ("14:05" or "2:05 PM", as the Mac says). */
export function shortTime(at: number, now = Date.now()): string {
  const ago = now - at
  if (ago < 45_000) return 'now'
  if (ago < 3_600_000) return `${Math.max(1, Math.round(ago / 60_000))} min`
  return new Date(at).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
}

export function fullTime(at: number): string {
  return new Date(at).toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
}

export interface ReadMark {
  id: string | null
  at: number | null
}

export interface UnreadState {
  /** Other people's messages after the read mark (or flagged by the server). */
  count: number
  /** Among them, those that mention me. */
  mentions: number
  /** The first unread message, for the "new" line. */
  firstId: string | null
  /** Ids of unread messages that mention me. */
  mentionIds: string[]
}

/**
 * Unread: messages by someone else after the read mark — by position when the
 * marked message is still in the log, else by time — plus any the server
 * still holds as an unread mention of me.
 */
export function unreadState(messages: readonly ChatMessage[], me: string, mark: ReadMark, serverMentioned: readonly string[] = []): UnreadState {
  const mine = normId(me)
  const flagged = new Set(serverMentioned)
  let from = 0
  if (mark.id) {
    const i = messages.findIndex(m => m.id === mark.id)
    if (i >= 0) from = i + 1
    else if (mark.at !== null) from = firstAfter(messages, mark.at)
  } else if (mark.at !== null) from = firstAfter(messages, mark.at)
  const out: UnreadState = { count: 0, mentions: 0, firstId: null, mentionIds: [] }
  messages.forEach((m, i) => {
    if (m.deleted || m.authorId === mine) return
    const after = i >= from
    if (!after && !flagged.has(m.id)) return
    out.count++
    if (!out.firstId) out.firstId = m.id
    if (m.mentions.includes(mine)) {
      out.mentions++
      out.mentionIds.push(m.id)
    }
  })
  return out
}

function firstAfter(messages: readonly ChatMessage[], at: number): number {
  for (let i = messages.length - 1; i >= 0; i--) if (messages[i]!.at <= at) return i + 1
  return 0
}

// ---- colours --------------------------------------------------------------------

/** Copper's presence colours (CanvasColors.presence), so an author's avatar matches their cursor. */
export const PRESENCE = ['#E5484D', '#F76B15', '#D6A400', '#30A46C', '#12A594', '#0090FF', '#3E63DD', '#8E4EC6', '#D6409F']

/** The same colour Copper gives a person (FNV-1a over the lowercased id, as CanvasColors.stable). */
export function stableColor(seed: string): string {
  let hash = 0x811c9dc5
  const bytes = new TextEncoder().encode(seed.toLowerCase())
  for (const b of bytes) hash = Math.imul(hash ^ b, 16_777_619) >>> 0
  return PRESENCE[hash % PRESENCE.length]!
}
