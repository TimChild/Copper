import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import {
  CHAT_KEY,
  MAX_MESSAGES,
  appendMessage,
  composeText,
  excerpt,
  filterMembers,
  groupMessages,
  mentionQuery,
  mentionRanges,
  mentionToken,
  plainText,
  readLog,
  readMessage,
  segments,
  stableColor,
  unreadState,
  type ChatMessage,
} from '../chat/model'

const ADA = 'aaaaaaaa-0000-4000-8000-000000000001'
const ANN = 'aaaaaaaa-0000-4000-8000-000000000002'
const BOB = 'aaaaaaaa-0000-4000-8000-000000000003'

const msg = (over: Partial<ChatMessage> = {}): ChatMessage => ({
  id: over.id ?? Math.random().toString(36).slice(2),
  authorId: ADA,
  authorName: 'Ada Lovelace',
  text: 'hi',
  mentions: [],
  at: 1_000,
  ...over,
})

describe('chat storage', () => {
  it('reads tolerant entries and drops junk and duplicates', () => {
    expect(readMessage(null)).toBeNull()
    expect(readMessage({ text: 'no id' })).toBeNull()
    const m = readMessage({ id: 'x', authorId: ADA.toUpperCase(), text: 'a'.repeat(5000), mentions: [ANN, 3, ANN], at: 'soon' })!
    expect(m.authorId).toBe(ADA)
    expect(m.text.length).toBe(4000)
    expect(m.mentions).toEqual([ANN])
    expect(m.at).toBe(0)
    expect(m.authorName).toBe('Someone')
    const deleted = readMessage({ id: 'y', text: 'secret', mentions: [ANN], deleted: true })!
    expect(deleted.text).toBe('')
    expect(deleted.mentions).toEqual([])
  })

  it('appends into a top-level Y.Array named chat and caps it', () => {
    const doc = new Y.Doc()
    for (let i = 0; i < MAX_MESSAGES + 5; i++) appendMessage(doc, msg({ id: `m${i}`, at: i }))
    const arr = doc.getArray(CHAT_KEY)
    expect(arr.length).toBe(MAX_MESSAGES)
    const log = readLog(arr)
    expect(log[0]!.id).toBe('m5')
    expect(log[log.length - 1]!.id).toBe(`m${MAX_MESSAGES + 4}`)
  })

  it('merges two people appending at once', () => {
    const a = new Y.Doc()
    const b = new Y.Doc()
    appendMessage(a, msg({ id: 'a1', at: 1 }))
    appendMessage(b, msg({ id: 'b1', at: 2, authorId: ANN }))
    Y.applyUpdate(a, Y.encodeStateAsUpdate(b))
    Y.applyUpdate(b, Y.encodeStateAsUpdate(a))
    expect(readLog(a.getArray(CHAT_KEY)).map(m => m.id).sort()).toEqual(['a1', 'b1'])
    expect(readLog(b.getArray(CHAT_KEY)).map(m => m.id)).toEqual(readLog(a.getArray(CHAT_KEY)).map(m => m.id))
  })
})

describe('mention tokens', () => {
  it('draws only listed tokens as chips and keeps text safe', () => {
    const text = `hey ${mentionToken(ANN, 'Ann')} and ${mentionToken(BOB, 'Bob')} <b>x</b> https://example.com/a.`
    const segs = segments(text, [ANN])
    expect(segs.filter(s => s.kind === 'mention')).toEqual([{ kind: 'mention', id: ANN, name: 'Ann' }])
    // Bob's token isn't listed: it stays text, as does the markup.
    expect(segs.some(s => s.kind === 'text' && s.text.includes('<@'))).toBe(true)
    expect(segs.some(s => s.kind === 'text' && s.text.includes('<b>x</b>'))).toBe(true)
    expect(segs.find(s => s.kind === 'link')).toEqual({ kind: 'link', text: 'https://example.com/a', url: 'https://example.com/a' })
  })

  it('names in tokens lose their delimiters', () => {
    expect(mentionToken(ANN.toUpperCase(), 'An|n <x>')).toBe(`<@${ANN}|An n  x>`.replace('  ', ' '))
  })

  it('plain text and excerpts read tokens as @Name', () => {
    const text = `${mentionToken(ANN, 'Ann')} lunch?\n\nsoon`
    expect(plainText(text, [ANN])).toBe('@Ann lunch?\n\nsoon')
    expect(excerpt(text, [ANN])).toBe('@Ann lunch? soon')
    expect(excerpt('x'.repeat(300), []).length).toBe(200)
    expect(excerpt('x'.repeat(300), []).endsWith('…')).toBe(true)
  })
})

describe('composing', () => {
  it('finds the @query at the caret', () => {
    expect(mentionQuery('hi @an', 6)).toEqual({ start: 3, query: 'an' })
    expect(mentionQuery('@', 1)).toEqual({ start: 0, query: '' })
    expect(mentionQuery('mail a@b', 8)).toBeNull()
    expect(mentionQuery('hi @ada lo', 10)).toEqual({ start: 3, query: 'ada lo' })
    expect(mentionQuery('hi @ ada', 8)).toBeNull()
    expect(mentionQuery('(@an', 4)).toEqual({ start: 1, query: 'an' })
  })

  it('binds picked names to ids, longest first, and not when typed over', () => {
    const picked = [
      { id: ANN, name: 'Ada' },
      { id: ADA, name: 'Ada Lovelace' },
    ]
    const r = mentionRanges('@Ada Lovelace and @Ada, @Adams', picked)
    expect(r.map(x => [x.name, x.start])).toEqual([
      ['Ada Lovelace', 0],
      ['Ada', 18],
    ])
  })

  it('tokens only members, and notes a self-mention without notifying', () => {
    const members = new Set([ANN, ADA])
    const out = composeText('  @Ann and @Bob and @Ada Lovelace  ', [{ id: ANN, name: 'Ann' }, { id: BOB, name: 'Bob' }, { id: ADA, name: 'Ada Lovelace' }], members, ADA)
    expect(out.text).toBe(`${mentionToken(ANN, 'Ann')} and @Bob and ${mentionToken(ADA, 'Ada Lovelace')}`)
    expect(out.mentions).toEqual([ANN, ADA])
  })

  it('filters members: never me, best match first', () => {
    const members = [
      { id: ADA, name: 'Ada Lovelace', email: 'ada@example.com' },
      { id: ANN, name: 'Ann Example', email: 'ann@example.com' },
      { id: BOB, name: 'Bob Banner', email: 'robert@example.com' },
    ]
    expect(filterMembers(members, '', ADA).map(m => m.name)).toEqual(['Ann Example', 'Bob Banner'])
    expect(filterMembers(members, 'an', null).map(m => m.name)).toEqual(['Ann Example', 'Bob Banner'])
    expect(filterMembers(members, 'rob', null).map(m => m.name)).toEqual(['Bob Banner'])
    expect(filterMembers(members, 'love', null).map(m => m.name)).toEqual(['Ada Lovelace'])
    expect(filterMembers(members, 'zed', null)).toEqual([])
  })
})

describe('reading', () => {
  it('groups by author within five minutes and by day', () => {
    const day = new Date(2026, 9, 6, 12).getTime()
    const g = groupMessages(
      [
        msg({ id: '1', at: day }),
        msg({ id: '2', at: day + 60_000 }),
        msg({ id: '3', at: day + 120_000, authorId: ANN, authorName: 'Ann' }),
        msg({ id: '4', at: day + 20 * 60_000, authorId: ANN, authorName: 'Ann' }),
        msg({ id: '5', at: day + 86_400_000 }),
      ],
      ADA,
      day + 86_400_000
    )
    expect(g.map(x => x.messages.map(m => m.id))).toEqual([['1', '2'], ['3'], ['4'], ['5']])
    expect(g[0]!.mine).toBe(true)
    expect(g[0]!.day).toBe('Yesterday')
    expect(g[1]!.day).toBeNull()
    expect(g[3]!.day).toBe('Today')
  })

  it('counts unread after the mark, mentions of me, and server-flagged ones', () => {
    const log = [
      msg({ id: '1', authorId: ANN, at: 1 }),
      msg({ id: '2', authorId: ANN, at: 2, mentions: [ADA] }),
      msg({ id: '3', authorId: ADA, at: 3 }),
      msg({ id: '4', authorId: ANN, at: 4, mentions: [ADA] }),
      msg({ id: '5', authorId: ANN, at: 5 }),
    ]
    expect(unreadState(log, ADA, { id: '3', at: 3 })).toEqual({ count: 2, mentions: 1, firstId: '4', mentionIds: ['4'] })
    expect(unreadState(log, ADA, { id: '3', at: 3 }, ['2'])).toEqual({ count: 3, mentions: 2, firstId: '2', mentionIds: ['2', '4'] })
    // The marked message went (capped away): fall back to time.
    expect(unreadState(log, ADA, { id: 'gone', at: 4 }).count).toBe(1)
    expect(unreadState(log, ADA, { id: null, at: null }).count).toBe(4)
  })

  it('gives a person the colour Copper gives them', () => {
    expect(stableColor(ADA)).toBe(stableColor(ADA.toUpperCase()))
    expect(stableColor(ADA)).toMatch(/^#[0-9A-F]{6}$/)
  })
})
