import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  POSTER_EVERY_MS,
  POSTER_MAX_WIDTH,
  POSTER_SILENT_AFTER,
  POSTER_TIMEOUT_MS,
  PosterBroker,
  PosterCache,
  isPosterData,
  type PosterMessage,
} from '../posters'
import { Controller } from '../../controller'
import { createApi } from '../../api'

const jpeg = (n = 64) => `data:image/jpeg;base64,${'A'.repeat(n)}`
const poster = (url: string, src = jpeg()) => ({ url, src, w: 640, h: 400, at: 0 })
const rect = { x: 10.4, y: 20.6, w: 600, h: 400 }

describe('the poster cache', () => {
  it('keeps one picture per frame, for its url, and drops it when the url moved on', () => {
    const c = new PosterCache()
    c.set('f1', poster('https://a.b/'))
    expect(c.peek('f1', 'https://a.b')?.url).toBe('https://a.b/')
    expect(c.peek('f1', 'https://a.b/other')).toBeNull()
    expect(c.count).toBe(1)
    expect(c.get('f1', 'https://a.b/other')).toBeNull()
    expect(c.count).toBe(0)
    expect(c.bytes).toBe(0)
  })

  it('matches the url the shape had when the page had redirected away from it', () => {
    const c = new PosterCache()
    c.set('f1', { ...poster('https://a.b/en/'), alias: 'https://a.b/' })
    expect(c.peek('f1', 'https://a.b/')).not.toBeNull()
    expect(c.peek('f1', 'https://a.b/en/')).not.toBeNull()
  })

  it('evicts least recently used pictures past its budget, telling their frames', () => {
    const c = new PosterCache(250)
    const told: string[] = []
    for (const id of ['a', 'b', 'c']) c.subscribe(id, () => told.push(id))
    c.set('a', poster('https://a/', jpeg(80)))
    c.set('b', poster('https://b/', jpeg(80)))
    c.get('a', 'https://a/')
    c.set('c', poster('https://c/', jpeg(80)))
    // a was used after b: b goes.
    expect(c.peek('b', 'https://b/')).toBeNull()
    expect(c.peek('a', 'https://a/')).not.toBeNull()
    expect(c.peek('c', 'https://c/')).not.toBeNull()
    expect(c.bytes).toBeLessThanOrEqual(250)
    expect(told).toEqual(['a', 'b', 'c', 'b'])
  })

  it('replaces a frame’s picture in place', () => {
    const c = new PosterCache()
    c.set('a', poster('https://a/', jpeg(100)))
    c.set('a', poster('https://a/', jpeg(10)))
    expect(c.count).toBe(1)
    expect(c.bytes).toBe(jpeg(10).length)
  })
})

describe('what the host may answer', () => {
  it('takes base64 JPEG, PNG and WebP data URLs only', () => {
    expect(isPosterData(jpeg())).toBe(true)
    expect(isPosterData(`data:image/png;base64,${'iVBOR'.repeat(10)}`)).toBe(true)
    expect(isPosterData(`data:image/webp;base64,${'UklG'.repeat(10)}`)).toBe(true)
    for (const bad of [null, undefined, 42, '', 'data:image/jpeg;base64,', 'data:image/svg+xml;base64,' + 'A'.repeat(40), 'javascript:alert(1)', 'https://a.b/x.jpg', `data:image/jpeg;base64,${'<'.repeat(40)}`])
      expect(isPosterData(bad)).toBe(false)
    expect(isPosterData(jpeg(4 * 1024 * 1024))).toBe(false)
  })
})

describe('asking the host', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  const setup = () => {
    const sent: PosterMessage[] = []
    const broker = new PosterBroker(m => sent.push(m), () => ({ w: 640, h: 427 }))
    return { sent, broker }
  }

  it('posts the request with a rounded rect and caches the answer by shape id + url', async () => {
    const { sent, broker } = setup()
    const got = broker.ask({ name: 'copper-frame:f1:n', id: 'f1', url: 'https://a.b/', rect }, 0)
    expect(sent).toEqual([{ type: 'framePoster', name: 'copper-frame:f1:n', id: 'f1', url: 'https://a.b/', rect: { x: 10, y: 21, w: 600, h: 400 }, maxWidth: POSTER_MAX_WIDTH }])
    expect(broker.answer('copper-frame:f1:n', jpeg())).toBe(true)
    await expect(got).resolves.toBe(true)
    expect(broker.cache.peek('f1', 'https://a.b/')).toMatchObject({ w: 640, h: 427, src: jpeg() })
  })

  it('asks a frame at most once per 30 s, and joins an ask in flight', async () => {
    const { sent, broker } = setup()
    expect(broker.due('f1', 0)).toBe(true)
    const one = broker.ask({ name: 'n1', id: 'f1', url: 'https://a/', rect }, 0)
    const two = broker.ask({ name: 'n1', id: 'f1', url: 'https://a/', rect }, 10)
    expect(sent).toHaveLength(1)
    expect(broker.asking('n1')).toBe(true)
    expect(broker.due('f1', POSTER_EVERY_MS - 1)).toBe(false)
    expect(broker.due('f1', POSTER_EVERY_MS)).toBe(true)
    broker.answer('n1', null)
    await expect(one).resolves.toBe(false)
    await expect(two).resolves.toBe(false)
    expect(broker.cache.count).toBe(0)
  })

  it('ignores answers nobody asked for, and junk', () => {
    const { broker } = setup()
    expect(broker.answer('copper-frame:x:y', jpeg())).toBe(false)
    expect(broker.answer(42, jpeg())).toBe(false)
    void broker.ask({ name: 'n', id: 'f', url: 'https://a/', rect }, 0)
    expect(broker.answer('n', 'javascript:alert(1)')).toBe(true)
    expect(broker.cache.count).toBe(0)
  })

  it('gives up on a host that never answers, and stops being waited on', async () => {
    const { broker } = setup()
    expect(broker.silent).toBe(false)
    const asks = Array.from({ length: POSTER_SILENT_AFTER }, (_, i) => broker.ask({ name: `n${i}`, id: `f${i}`, url: 'https://a/', rect }, 0))
    vi.advanceTimersByTime(POSTER_TIMEOUT_MS)
    for (const a of asks) await expect(a).resolves.toBe(false)
    expect(broker.silent).toBe(true)
    // One answer later and it is a host that makes posters after all.
    void broker.ask({ name: 'late', id: 'g', url: 'https://a/', rect }, 0)
    broker.answer('late', null)
    expect(broker.silent).toBe(false)
  })
})

describe('copperCanvas.framePoster', () => {
  it('reaches the controller’s broker and never throws', () => {
    const c = new Controller()
    const api = createApi(c)
    void c.posters.ask({ name: 'copper-frame:f1:n', id: 'f1', url: 'https://a.b/', rect }, 0)
    expect(api.framePoster('copper-frame:f1:n', jpeg())).toBe(true)
    expect(c.posters.cache.peek('f1', 'https://a.b/')).not.toBeNull()
    expect(api.framePoster('copper-frame:f1:n', jpeg())).toBe(false)
    expect(api.framePoster(undefined, undefined)).toBe(false)
    void c.posters.ask({ name: 'copper-frame:f2:n', id: 'f2', url: 'https://c.d/', rect }, 0)
    expect(api.framePoster({ name: 'copper-frame:f2:n', dataUrl: jpeg() }, undefined)).toBe(true)
  })
})
