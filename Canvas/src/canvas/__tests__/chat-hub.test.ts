import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { Controller } from '../../controller'
import type { PageMessage } from '../../host-bridge'
import { BridgeSocket } from '../../bridge-socket'
import { ChatHub, parseChatPatch } from '../chat/hub'
import { createChatApi, sendFromTool, withChat } from '../chat/api'
import { CHAT_KEY, mentionToken, readLog } from '../chat/model'

const ADA = 'aaaaaaaa-0000-4000-8000-000000000001'
const ANN = 'aaaaaaaa-0000-4000-8000-000000000002'
const BOB = 'aaaaaaaa-0000-4000-8000-000000000003'

let messages: PageMessage[]
let c: Controller
let hub: ChatHub

const members = [
  { id: ADA, name: 'Ada Lovelace', email: 'ada@example.com' },
  { id: ANN, name: 'Ann Example', email: 'ann@example.com' },
]

const init = (extra: Record<string, unknown> = {}) => {
  c.init({ docId: 'd1', name: 'Board', kind: 'shared', me: { id: ADA, name: 'Ada Lovelace', color: '#f00' }, state: null, online: false, readOnly: false, ...extra })
  hub.attach(c.session)
}

const posted = (type: string) => messages.filter(m => m.type === type) as unknown as Record<string, unknown>[]

beforeEach(() => {
  messages = []
  vi.stubGlobal('window', { __copperHost: { messages: [], onMessage: (m: PageMessage) => messages.push(m) } })
  vi.spyOn(console, 'debug').mockImplementation(() => {})
  c = new Controller()
  hub = new ChatHub(fn => c.subscribe(fn))
})

afterEach(() => {
  c.session?.destroy()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  BridgeSocket.current = null
})

describe('setChat', () => {
  it('parses a patch tolerantly', () => {
    expect(parseChatPatch(null)).toBeNull()
    expect(parseChatPatch('{"enabled":true,"members":[{"id":"X","name":"","email":"x@example.com"},{"bad":1}]}')).toEqual({
      enabled: true,
      members: [{ id: 'x', name: 'x@example.com', email: 'x@example.com', color: expect.any(String) }],
      membersKnown: true,
    })
    expect(() => parseChatPatch(3)).toThrow()
  })

  it('is off until the host enables it, and never sends then', () => {
    init()
    expect(hub.available).toBe(false)
    expect(hub.send('hi').ok).toBe(false)
    hub.configure({ enabled: true, members })
    expect(hub.available).toBe(true)
  })
})

describe('sending', () => {
  it('writes to the doc instantly, only for members, and asks the host to notify', () => {
    init()
    hub.configure({ enabled: true, members, mentionsApi: true, lastReadId: null, lastReadAt: 0 })
    const r = hub.sendDraft('@Ann Example lunch? cc @Bob', [
      { id: ANN, name: 'Ann Example' },
      { id: BOB, name: 'Bob' },
    ])
    expect(r.ok).toBe(true)
    const log = readLog(c.session!.doc.getArray(CHAT_KEY))
    expect(log).toHaveLength(1)
    expect(log[0]!.text).toBe(`${mentionToken(ANN, 'Ann Example')} lunch? cc @Bob`)
    expect(log[0]!.mentions).toEqual([ANN])
    expect(log[0]!.authorId).toBe(ADA)
    const mention = posted('mention')
    expect(mention).toHaveLength(1)
    expect(mention[0]).toMatchObject({ messageId: log[0]!.id, userIds: [ANN], excerpt: '@Ann Example lunch? cc @Bob' })
    // The write reached the host as an ordinary update (stored, relayed).
    expect(posted('update').length).toBeGreaterThan(0)
    // Writing reads everything before it.
    expect(posted('chatRead').at(-1)).toMatchObject({ id: log[0]!.id })
  })

  it('does not call the mentions API on an older cloud, or for a self-mention', () => {
    init()
    hub.configure({ enabled: true, members, mentionsApi: false })
    hub.sendDraft('@Ann Example hi', [{ id: ANN, name: 'Ann Example' }])
    expect(posted('mention')).toHaveLength(0)
    hub.configure({ mentionsApi: true })
    hub.sendDraft('note to @Ada Lovelace', [{ id: ADA, name: 'Ada Lovelace' }])
    expect(posted('mention')).toHaveLength(0)
    expect(readLog(c.session!.doc.getArray(CHAT_KEY))[1]!.mentions).toEqual([ADA])
  })

  it('refuses on a view-only canvas, empty text, and over 4000 characters', () => {
    init({ readOnly: true })
    hub.configure({ enabled: true, members })
    expect(hub.send('hi').error).toMatch(/view only/)
    init()
    hub.configure({ enabled: true, members })
    expect(hub.send('   ').ok).toBe(false)
    expect(hub.send('x'.repeat(4001)).ok).toBe(false)
  })

  it('sends from a tool by name or email, adding @Name when missing', () => {
    init()
    hub.configure({ enabled: true, members, mentionsApi: true })
    const r = sendFromTool(hub, { text: 'the venue is booked', mentions: ['ann@example.com'] })
    expect(r.ok).toBe(true)
    expect(readLog(c.session!.doc.getArray(CHAT_KEY))[0]!.text).toBe(`${mentionToken(ANN, 'Ann Example')} the venue is booked`)
    expect(sendFromTool(hub, { text: 'x', mentions: ['nobody@example.com'] }).error).toMatch(/not on this canvas/)
  })

  it('deletes only your own message, leaving a tombstone', () => {
    init()
    hub.configure({ enabled: true, members })
    const id = hub.send('oops').id!
    expect(hub.remove(id)).toBe(true)
    expect(hub.read()[0]).toMatchObject({ id, deleted: true, text: '' })
  })
})

describe('unread and read marks', () => {
  const fromAnn = (doc: Y.Doc, id: string, at: number, mention = false) => {
    const arr = doc.getArray(CHAT_KEY)
    arr.push([{ id, authorId: ANN, authorName: 'Ann Example', text: mention ? `${mentionToken(ADA, 'Ada Lovelace')} hi` : 'hi', mentions: mention ? [ADA] : [], at }])
  }

  it('counts what came after the mark and clears it when read', () => {
    init()
    hub.configure({ enabled: true, members, lastReadId: null, lastReadAt: 0 })
    fromAnn(c.session!.doc, 'a', 1)
    fromAnn(c.session!.doc, 'b', 2, true)
    expect(hub.unread).toMatchObject({ count: 2, mentions: 1, mentionIds: ['b'] })
    hub.markRead()
    expect(hub.unread.count).toBe(0)
    expect(posted('chatRead').at(-1)).toMatchObject({ id: 'b', mentionIds: ['b'] })
  })

  it('treats history as read the first time a canvas is opened here', () => {
    init()
    fromAnn(c.session!.doc, 'old', 1)
    hub.configure({ enabled: true, members, known: false })
    expect(hub.unread.count).toBe(0)
    expect(posted('chatRead').at(-1)).toMatchObject({ id: 'old' })
    fromAnn(c.session!.doc, 'new', 2)
    expect(hub.unread.count).toBe(1)
  })

  it('…except an unanswered mention of me, from which on it is new', () => {
    init()
    fromAnn(c.session!.doc, 'a', 1)
    fromAnn(c.session!.doc, 'b', 2, true)
    fromAnn(c.session!.doc, 'c', 3)
    hub.configure({ enabled: true, members, known: false })
    expect(hub.unread).toMatchObject({ count: 2, mentions: 1, firstId: 'b' })
  })

  it('…but a mention I answered (from another Mac) is read', () => {
    init()
    fromAnn(c.session!.doc, 'a', 1, true)
    c.session!.doc.getArray(CHAT_KEY).push([{ id: 'mine', authorId: ADA, authorName: 'Ada Lovelace', text: 'yes', mentions: [], at: 2 }])
    fromAnn(c.session!.doc, 'c', 3)
    hub.configure({ enabled: true, members, known: false })
    expect(hub.unread.count).toBe(0)
  })

  it('keeps a server-flagged mention unread until it is seen', () => {
    init()
    fromAnn(c.session!.doc, 'm', 1, true)
    hub.configure({ enabled: true, members, lastReadId: 'm', lastReadAt: 1, mentioned: ['m'] })
    expect(hub.unread).toMatchObject({ count: 1, mentions: 1 })
    hub.markSeen('m')
    expect(hub.unread.count).toBe(0)
    expect(posted('chatRead').at(-1)).toMatchObject({ mentionIds: ['m'] })
  })
})

describe('the panel', () => {
  it('toggles, tells the host, and does not echo what the host said', () => {
    init()
    hub.configure({ enabled: true, members })
    hub.toggle()
    expect(hub.config.open).toBe(true)
    expect(posted('chat').at(-1)).toEqual({ type: 'chat', open: true })
    const before = posted('chat').length
    createChatApi(hub).showChat(false)
    expect(hub.config.open).toBe(false)
    expect(posted('chat').length).toBe(before)
  })

  it('reveals a message (or waits for it to sync) and opens the panel', () => {
    init()
    hub.configure({ enabled: true, members })
    expect(hub.reveal({ id: 'later' })).toBe(true)
    expect(hub.config.open).toBe(true)
    expect(hub.focus).toBeNull()
    c.session!.doc.getArray(CHAT_KEY).push([{ id: 'later', authorId: ANN, authorName: 'Ann', text: 'x', mentions: [], at: 1 }])
    expect(hub.focus?.id).toBe('later')
    hub.setOpen(false)
    expect(hub.focus).toBeNull()
  })

  it('canvas read includes recent chat when chat is on', () => {
    init()
    hub.configure({ enabled: true, members })
    hub.sendDraft('@Ann Example hello', [{ id: ANN, name: 'Ann Example' }])
    const api = withChat({ read: (_opts?: unknown) => JSON.stringify({ shapes: [] }) }, hub)
    const out = JSON.parse(api.read({}))
    expect(out.chat).toHaveLength(1)
    expect(out.chat[0]).toMatchObject({ from: 'Ada Lovelace', text: '@Ann Example hello', mentions: [{ id: ANN, name: 'Ann Example' }] })
    hub.configure(null)
    expect(JSON.parse(api.read({})).chat).toBeUndefined()
  })
})
