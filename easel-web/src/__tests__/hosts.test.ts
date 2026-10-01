// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { createCopperHost } from '../host/copper'
import {
  DEFAULT_EASEL_ID,
  STANDALONE_VIEWER,
  createStandaloneHost,
  easelIdFromSearch,
  storageKey,
} from '../host/standalone'
import type { PageMessage } from '../host/types'
import { base64ToBytes, bytesToBase64 } from '../host/base64'
import { openEaselSession } from '../session'

describe('copper host (the bridge)', () => {
  const handler = { postMessage: vi.fn<(m: PageMessage) => void>() }
  beforeEach(() => {
    handler.postMessage.mockClear()
    delete window.__easelHost
  })

  it('defines window.__easelHost before sending ready, and resolves on config', async () => {
    const host = createCopperHost(handler)
    expect(window.__easelHost).toBeDefined()
    expect(handler.postMessage).not.toHaveBeenCalled()
    const ready = host.ready()
    expect(handler.postMessage).toHaveBeenCalledWith({ v: 1, type: 'ready' })
    // Asking twice sends one `ready`.
    void host.ready()
    expect(handler.postMessage).toHaveBeenCalledTimes(1)

    window.__easelHost!.receive({
      v: 1,
      type: 'config',
      easel: { id: 'abc', title: 'Board', createdAt: 1700000000 },
      viewer: { id: 'v1', name: 'Collin', color: '#ff5a36' },
      state: null,
      mode: 'local',
    })
    const config = await ready
    expect(config).toEqual({
      easel: { id: 'abc', title: 'Board', createdAt: 1700000000 },
      viewer: { id: 'v1', name: 'Collin', color: '#ff5a36' },
      state: null,
      mode: 'local',
    })
    // After config arrives, ready() resolves at once with the same thing.
    expect(await host.ready()).toBe(config)
  })

  it('accepts receive(<json string>) too', async () => {
    const host = createCopperHost(handler)
    const ready = host.ready()
    window.__easelHost!.receive(
      JSON.stringify({
        v: 1,
        type: 'config',
        easel: { id: 'abc', title: 'Board', createdAt: 1 },
        viewer: { id: 'v1', name: 'C', color: '#000' },
        state: 'AAA=',
        mode: 'local',
      })
    )
    expect((await ready).state).toBe('AAA=')
  })

  it('posts save, open and log with the contract shapes', () => {
    const host = createCopperHost(handler)
    host.save('BASE64', 'My easel')
    expect(handler.postMessage).toHaveBeenLastCalledWith({
      v: 1,
      type: 'save',
      state: 'BASE64',
      title: 'My easel',
    })
    host.open('https://example.com')
    expect(handler.postMessage).toHaveBeenLastCalledWith({
      v: 1,
      type: 'open',
      url: 'https://example.com',
    })
    host.open('https://example.com', true)
    expect(handler.postMessage).toHaveBeenLastCalledWith({
      v: 1,
      type: 'open',
      url: 'https://example.com',
      background: true,
    })
    handler.postMessage.mockClear()
    host.open('copper-easel://easel/x')
    host.open('javascript:alert(1)')
    expect(handler.postMessage).not.toHaveBeenCalled()
    host.log('warn', 'hmm')
    expect(handler.postMessage).toHaveBeenLastCalledWith({
      v: 1,
      type: 'log',
      level: 'warn',
      message: 'hmm',
    })
  })

  it('uploads a file as base64 and resolves on file:done', async () => {
    const host = createCopperHost(handler)
    const file = new File([new Uint8Array([1, 2, 3])], 'shot.png', {
      type: 'image/png',
    })
    const upload = host.uploadFile(file)
    await vi.waitFor(() => expect(handler.postMessage).toHaveBeenCalled())
    const sent = handler.postMessage.mock.lastCall![0]
    expect(sent).toMatchObject({
      v: 1,
      type: 'file',
      name: 'shot.png',
      mime: 'image/png',
      data: 'AQID',
    })
    const reqId = (sent as Extract<PageMessage, { type: 'file' }>).reqId
    expect(reqId).toMatch(/[0-9a-f-]{36}/)
    window.__easelHost!.receive({
      v: 1,
      type: 'file:done',
      reqId,
      fileId: 'f.png',
      url: 'copper-easel://easel/files/abc/f.png',
    })
    expect(await upload).toEqual({
      fileId: 'f.png',
      url: 'copper-easel://easel/files/abc/f.png',
    })
  })

  it('rejects on file:error and on oversize files', async () => {
    const host = createCopperHost(handler)
    const file = new File([new Uint8Array([1])], 'x.png', { type: 'image/png' })
    const upload = host.uploadFile(file)
    await vi.waitFor(() => expect(handler.postMessage).toHaveBeenCalled())
    const { reqId } = handler.postMessage.mock.lastCall![0] as Extract<
      PageMessage,
      { type: 'file' }
    >
    window.__easelHost!.receive({
      v: 1,
      type: 'file:error',
      reqId,
      message: 'disk full',
    })
    await expect(upload).rejects.toThrow('disk full')

    const big = { size: 16 * 1024 * 1024, type: 'image/png', name: 'big' } as File
    await expect(host.uploadFile(big)).rejects.toThrow(/15 MB/)
  })

  it('runs flush listeners on a native flush', () => {
    const host = createCopperHost(handler)
    const fn = vi.fn()
    const off = host.onFlush(fn)
    window.__easelHost!.receive({ v: 1, type: 'flush' })
    expect(fn).toHaveBeenCalledTimes(1)
    off()
    window.__easelHost!.receive({ v: 1, type: 'flush' })
    expect(fn).toHaveBeenCalledTimes(1)
  })

  it('renders file refs from the scheme', () => {
    const host = createCopperHost(handler)
    expect(host.fileUrl('abc', 'f.png')).toBe(
      'copper-easel://easel/files/abc/f.png'
    )
  })
})

describe('standalone host', () => {
  beforeEach(() => localStorage.clear())

  it('reads the id from ?id= or falls back to the default', () => {
    expect(easelIdFromSearch('?id=ABC-123')).toBe('abc-123')
    expect(easelIdFromSearch('?x=1')).toBeNull()
    expect(easelIdFromSearch('?id=../etc')).toBeNull()
  })

  it('answers ready with a fresh config and the standalone viewer', async () => {
    const host = createStandaloneHost({ search: '' })
    const config = await host.ready()
    expect(config.easel.id).toBe(DEFAULT_EASEL_ID)
    expect(config.easel.title).toBe('Untitled Easel')
    expect(config.state).toBeNull()
    expect(config.viewer).toEqual(STANDALONE_VIEWER)
    expect(config.mode).toBe('local')
  })

  it('round-trips state and title through localStorage, keyed by id', async () => {
    const doc = new Y.Doc()
    doc.getMap('meta').set('title', 'Kept')
    const state = bytesToBase64(Y.encodeStateAsUpdate(doc))

    const host = createStandaloneHost({ search: '?id=one' })
    await host.ready()
    host.save(state, 'Kept')
    expect(localStorage.getItem(storageKey('one'))).toContain('"title":"Kept"')

    const again = createStandaloneHost({ search: '?id=one' })
    const config = await again.ready()
    expect(config.easel.title).toBe('Kept')
    const copy = new Y.Doc()
    Y.applyUpdate(copy, base64ToBytes(config.state!))
    expect(copy.getMap('meta').get('title')).toBe('Kept')

    const other = await createStandaloneHost({ search: '?id=two' }).ready()
    expect(other.state).toBeNull()
  })

  it('turns an uploaded picture into a file id with the right extension and an object URL', async () => {
    const host = createStandaloneHost({
      search: '?id=pics',
      objectUrl: () => 'blob:fake',
    })
    const file = new File([new Uint8Array([1, 2])], 'p.jpeg', {
      type: 'image/jpeg',
    })
    const { fileId, url } = await host.uploadFile(file)
    expect(fileId).toMatch(/^[0-9a-f-]{36}\.jpg$/)
    expect(url).toBe('blob:fake')
    expect(host.fileUrl('pics', fileId)).toBe('blob:fake')
    // A new session (no object URL) still finds the data-URL copy.
    const later = createStandaloneHost({ search: '?id=pics' })
    expect(later.fileUrl('pics', fileId)).toMatch(/^data:image\/jpeg;base64,/)
    expect(later.fileUrl('pics', 'missing.png')).toBe('')
  })
})

describe('session', () => {
  beforeEach(() => localStorage.clear())

  it('opens, applies saved state, fills meta, and saves on change', async () => {
    vi.useFakeTimers()
    try {
      const host = createStandaloneHost({ search: '?id=sess' })
      const save = vi.spyOn(host, 'save')
      const first = await openEaselSession(host)
      expect(first.doc.title()).toBe('Untitled Easel')
      expect(first.doc.getMeta().createdAt).toBeTypeOf('number')
      // ensureMeta wrote createdAt: that is one save for a new easel.
      vi.advanceTimersByTime(500)
      expect(save).toHaveBeenCalledTimes(1)

      first.doc.createShape({ type: 'sticky', text: 'hello' })
      first.doc.setTitle('Sess')
      vi.advanceTimersByTime(500)
      expect(save).toHaveBeenCalledTimes(2)
      expect(save.mock.lastCall![1]).toBe('Sess')
      first.close()

      const second = await openEaselSession(createStandaloneHost({ search: '?id=sess' }))
      expect(second.doc.title()).toBe('Sess')
      expect([...second.doc.getShapesSnapshot().values()][0]?.text).toBe('hello')
      // Loading saved state is not a change.
      const save2 = vi.spyOn(second.host, 'save')
      vi.advanceTimersByTime(1000)
      expect(save2).not.toHaveBeenCalled()
      second.close()
    } finally {
      vi.useRealTimers()
    }
  })

  it('starts awareness with the contract shape', async () => {
    const session = await openEaselSession(createStandaloneHost({ search: '?id=aw' }))
    expect(session.awareness.getLocalState()).toEqual({
      user: STANDALONE_VIEWER,
      cursor: null,
      laser: null,
    })
    session.close()
  })
})
