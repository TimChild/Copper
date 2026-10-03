import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { fromBase64, toBase64 } from '../canvas/base64'
import { CanvasStore } from '../canvas/doc'
import { Controller, WRITING_MS, parseInit } from '../controller'
import { DevRelay } from '../dev-relay'
import type { PageMessage } from '../host-bridge'
import { BridgeSocket } from '../bridge-socket'

let messages: PageMessage[]
let route: ((m: PageMessage) => void) | null
let c: Controller

const init = (extra: Record<string, unknown> = {}) =>
  c.init({ docId: 'd1', name: 'Board', kind: 'shared', me: { id: 'u1', name: 'Ada', color: '#f00' }, state: null, online: false, readOnly: false, ...extra })

beforeEach(() => {
  messages = []
  route = null
  vi.stubGlobal('window', {
    __copperHost: {
      messages: [],
      onMessage: (m: PageMessage) => {
        messages.push(m)
        route?.(m)
      },
    },
  })
  vi.spyOn(console, 'debug').mockImplementation(() => {})
  c = new Controller()
})

afterEach(() => {
  c.session?.destroy()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
  vi.useRealTimers()
  BridgeSocket.current = null
})

const updates = () => messages.filter((m): m is Extract<PageMessage, { type: 'update' }> => m.type === 'update')

describe('parseInit', () => {
  it('fills defaults and accepts JSON', () => {
    expect(parseInit('{"docId":"x"}')).toMatchObject({ docId: 'x', name: 'Canvas', kind: 'personal', online: false, readOnly: false, state: null })
    expect(parseInit({ me: { id: 'u' } }).me).toMatchObject({ id: 'u', name: 'You' })
    expect(() => parseInit(5)).toThrow()
  })
})

describe('Controller', () => {
  it('applies init.state before anything else and does not echo it', () => {
    const src = new CanvasStore(new Y.Doc())
    src.create({ type: 'sticky', id: 'kept', text: 'from disk' })
    init({ state: toBase64(Y.encodeStateAsUpdate(src.doc)) })
    expect(c.session!.store.get('kept')?.text).toBe('from disk')
    // Only the meta bookkeeping goes out, never the stored state itself.
    const sent = updates()
    expect(sent).toHaveLength(1)
    const probe = new Y.Doc()
    Y.applyUpdate(probe, fromBase64(sent[0]!.b64))
    expect(probe.getMap('shapes').size).toBe(0)
    expect(probe.getMap('meta').get('name')).toBe('Board')
  })

  it('posts every local change as an update the host can replay', () => {
    init()
    const out = JSON.parse(JSON.stringify(c.apply({ ops: [{ op: 'add', shape: { type: 'sticky', id: 'n', text: 'hi' } }] })))
    expect(out).toEqual({ applied: 1, ids: ['n'], errors: [] })
    const replay = new Y.Doc()
    for (const u of updates()) Y.applyUpdate(replay, fromBase64(u.b64))
    expect(new CanvasStore(replay).get('n')?.text).toBe('hi')
  })

  it('does not echo updates the host hands over', () => {
    init()
    messages = []
    const other = new CanvasStore(new Y.Doc())
    other.create({ type: 'frame', id: 'remote' })
    c.applyUpdate(toBase64(Y.encodeStateAsUpdate(other.doc)))
    expect(c.session!.store.get('remote')).toBeTruthy()
    expect(updates()).toHaveLength(0)
  })

  it('exports the whole state', () => {
    init()
    c.apply([{ op: 'add', shape: { type: 'sticky', id: 'x' } }])
    const copy = new Y.Doc()
    Y.applyUpdate(copy, fromBase64(c.exportState()))
    expect(copy.getMap('shapes').has('x')).toBe(true)
  })

  it('marks an agent writing, then removes its presence', () => {
    vi.useFakeTimers()
    init()
    c.apply({ ops: [{ op: 'add', shape: { type: 'sticky', x: 0, y: 0 } }], as: { id: 'agent:s', name: 'Scout', color: '#0f0' } })
    expect(c.session!.store.agents.get('agent:s')).toMatchObject({ name: 'Scout', color: '#0f0', status: 'writing', cursor: { x: 100, y: 100 } })
    vi.advanceTimersByTime(WRITING_MS + 10)
    expect(c.session!.store.agents.has('agent:s')).toBe(false)
  })

  it('shows ops without `as` as a generic agent', () => {
    init()
    const r = c.apply([{ op: 'add', shape: { type: 'sticky', id: 'g' } }])
    expect(r.applied).toBe(1)
    expect(c.session!.store.get('g')?.by).toBe('Agent')
    expect(c.session!.store.agents.get('agent')).toMatchObject({ status: 'writing' })
  })

  it('debounces presence messages and only emits when people change', () => {
    vi.useFakeTimers()
    init()
    messages = []
    c.setAgent({ id: 'agent:presence', name: 'Scout', color: '#0f0', cursor: { x: 5, y: 6 }, status: 'thinking' })
    expect(messages.filter(m => m.type === 'presence')).toHaveLength(0)
    vi.advanceTimersByTime(399)
    expect(messages.filter(m => m.type === 'presence')).toHaveLength(0)
    vi.advanceTimersByTime(1)
    expect(messages.filter(m => m.type === 'presence')).toEqual([
      { type: 'presence', people: [{ id: 'agent:presence', name: 'Scout', color: '#0f0', kind: 'agent' }] },
    ])
    c.setAgent({ id: 'agent:presence', cursor: { x: 50, y: 60 } })
    vi.advanceTimersByTime(500)
    expect(messages.filter(m => m.type === 'presence')).toHaveLength(1)
    c.setAgent({ id: 'agent:presence', remove: true })
    vi.advanceTimersByTime(400)
    expect(messages.filter(m => m.type === 'presence')).toHaveLength(2)
    expect(messages.filter(m => m.type === 'presence').at(-1)).toEqual({ type: 'presence', people: [] })
  })

  it('sets and removes agents from the host', () => {
    init()
    c.setAgent({ id: 'a1', name: 'Helper', color: '#00f', cursor: { x: 5, y: 6 }, status: 'thinking' })
    expect(c.session!.store.agents.get('a1')).toMatchObject({ name: 'Helper', status: 'thinking', cursor: { x: 5, y: 6 } })
    c.setAgent('{"id":"a1","status":"idle"}')
    expect(c.session!.store.agents.get('a1')).toMatchObject({ name: 'Helper', status: 'idle' })
    c.setAgent({ id: 'a1', remove: true })
    expect(c.session!.store.agents.has('a1')).toBe(false)
    expect(() => c.setAgent({ name: 'no id' })).toThrow()
  })

  it('selects by id, tells the host about the page’s own selections only', () => {
    init()
    c.apply([
      { op: 'add', shape: { type: 'sticky', id: 'a' } },
      { op: 'add', shape: { type: 'sticky', id: 'b' } },
    ])
    messages = []
    c.setSelection(['a', 'ghost', 'shape:b'])
    expect(c.getSelection()).toEqual(['a', 'b'])
    expect(messages.filter(m => m.type === 'selection')).toEqual([{ type: 'selection', ids: ['a', 'b'] }])
    c.setSelection(['a'], true)
    expect(messages.filter(m => m.type === 'selection')).toHaveLength(1)
    expect(c.session!.awareness.getLocalState()?.selection).toEqual(['a'])
    // Deleting a selected shape drops it from the selection.
    c.apply([{ op: 'delete', id: 'a' }])
    expect(c.getSelection()).toEqual([])
  })

  it('reads with the canvas identity and the viewport', () => {
    init()
    c.setViewInfo({ view: { x: 100, y: 50, z: 2 }, width: 800, height: 600 })
    const r = c.read('{}')
    expect(r.canvas).toEqual({ id: 'd1', name: 'Board', kind: 'shared' })
    expect(r.viewport).toEqual({ x: -50, y: -25, w: 400, h: 300, zoom: 2 })
  })

  it('places unpositioned shapes around the viewport centre', () => {
    init()
    c.setViewInfo({ view: { x: 0, y: 0, z: 1 }, width: 1000, height: 800 })
    const r = c.apply([{ op: 'add', shape: { type: 'sticky', id: 'p' } }])
    expect(r.errors).toEqual([])
    expect(c.session!.store.get('p')).toMatchObject({ x: 400, y: 300 })
  })

  it('refuses ops on a read-only canvas and before init', () => {
    expect(c.apply([{ op: 'clear' }]).errors[0]!.error).toMatch(/init/)
    init({ readOnly: true })
    expect(c.apply([{ op: 'add', shape: { type: 'sticky' } }]).errors[0]!.error).toMatch(/read-only/)
  })

  it('starts fresh on a second init', () => {
    init()
    c.apply([{ op: 'add', shape: { type: 'sticky', id: 'old' } }])
    const first = c.session
    init({ docId: 'd2' })
    expect(c.session).not.toBe(first)
    expect(c.session!.store.get('old')).toBeUndefined()
  })
})

describe('host status', () => {
  it('is idempotent, outlives init, and clears on null', () => {
    let bumps = 0
    c.subscribe(() => bumps++)
    expect(c.getHostStatus()).toBeNull()
    c.setHostStatus({ mode: 'shared-offline', pending: 2 })
    const first = c.getHostStatus()
    expect(first).toEqual({ mode: 'shared-offline', pending: 2 })
    expect(bumps).toBe(1)
    // The same status again changes nothing and wakes nobody.
    c.setHostStatus('{"mode":"shared-offline","pending":2}')
    expect(c.getHostStatus()).toBe(first)
    expect(bumps).toBe(1)
    init()
    expect(c.getHostStatus()).toEqual({ mode: 'shared-offline', pending: 2 })
    c.setHostStatus({ mode: 'shared-live' })
    expect(c.getHostStatus()).toEqual({ mode: 'shared-live' })
    c.setHostStatus(null)
    expect(c.getHostStatus()).toBeNull()
  })

  it('keeps the last good status when given a bad one', () => {
    c.setHostStatus({ mode: 'local' })
    expect(() => c.setHostStatus({ mode: 'nope' })).toThrow()
    expect(c.getHostStatus()).toEqual({ mode: 'local' })
  })
})

describe('online, through the relayed socket', () => {
  it('syncs both ways with the server and goes live', async () => {
    const relay = new DevRelay(0)
    const seeded = new CanvasStore(relay.doc)
    seeded.create({ type: 'sticky', id: 'server', text: 'on the server' })
    const client = relay.connect({
      wsMessage: b64 => BridgeSocket.deliver(b64),
      wsState: s => BridgeSocket.setState(s),
    })
    route = m => client.receive(m)
    init({ online: true })
    const s = c.session!
    expect(s.status).toBe('connecting')
    await vi.waitFor(() => expect(s.status).toBe('online'))
    expect(s.store.get('server')?.text).toBe('on the server')
    // Local edits reach the server, and are still posted for the host to keep.
    messages = []
    c.apply([{ op: 'add', shape: { type: 'frame', id: 'mine', title: 'Mine' } }])
    expect(updates().length).toBeGreaterThan(0)
    await vi.waitFor(() => expect(new CanvasStore(relay.doc).get('mine')?.title).toBe('Mine'))
    // Server-side changes arrive and are not echoed to the host as local.
    messages = []
    seeded.update('server', { color: 'blue' })
    await vi.waitFor(() => expect(s.store.get('server')?.color).toBe('blue'))
    expect(updates()).toHaveLength(0)
    // A dropped connection goes offline, then reconnects by itself.
    relay.dropAll()
    await vi.waitFor(() => expect(s.status).not.toBe('online'))
    await vi.waitFor(() => expect(s.status).toBe('online'), { timeout: 4000 })
  })
})
