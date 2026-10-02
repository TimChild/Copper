import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { Awareness } from 'y-protocols/awareness'
import { CanvasStore } from '../doc'
import {
  FRAME_SANDBOX,
  FrameBus,
  FrameNav,
  KEEP_PX,
  LIVE_SIZE,
  MAX_MOUNTED,
  frameName,
  frameUrl,
  framesToMount,
  makeNonce,
  mayWrite,
  parseFrameEvent,
  parseFrameName,
  sameUrl,
} from '../frames'
import { LIVE_MIN, MIN_SIZE, minSizeOf } from '../resize'
import { readHumanPresence } from '../presence'
import { applyOps, readCanvas } from '../../ops'
import { Controller } from '../../controller'

describe('frame addresses', () => {
  it('takes http(s) only, normalised', () => {
    expect(frameUrl('https://a.b')).toBe('https://a.b/')
    expect(frameUrl('http://a.b/x?y#z')).toBe('http://a.b/x?y#z')
    for (const bad of ['javascript:alert(1)', 'file:///etc/passwd', 'data:text/html,hi', 'copper://canvas/x', 'nope', '', null, undefined])
      expect(frameUrl(bad)).toBeNull()
  })

  it('treats two spellings of one page as the same', () => {
    expect(sameUrl('https://a.b', 'https://a.b/')).toBe(true)
    expect(sameUrl('https://a.b/x', 'https://a.b/y')).toBe(false)
    expect(sameUrl(null, null)).toBe(true)
    expect(sameUrl('https://a.b', null)).toBe(false)
  })

  it('never lets a frame reach the board or navigate it unasked', () => {
    const flags = FRAME_SANDBOX.split(' ')
    expect(flags).toContain('allow-scripts')
    expect(flags).toContain('allow-same-origin')
    expect(flags).not.toContain('allow-top-navigation')
    expect(flags).toContain('allow-top-navigation-by-user-activation')
  })
})

describe('frame names', () => {
  it('round-trip, ids with colons included', () => {
    const nonce = makeNonce()
    expect(nonce).toMatch(/^[0-9a-f]{18}$/)
    expect(makeNonce()).not.toBe(nonce)
    expect(parseFrameName(frameName('web1', nonce))).toEqual({ id: 'web1', nonce })
    expect(parseFrameName(frameName('a:b', 'n'))).toEqual({ id: 'a:b', nonce: 'n' })
  })

  it('refuses anything else', () => {
    for (const bad of ['', 'copper-frame:', 'copper-frame:id', 'copper-frame:id:', 'copper-frame::n', 'other:id:n', 7, null])
      expect(parseFrameName(bad)).toBeNull()
  })
})

describe('frame reports', () => {
  const name = frameName('web1', 'abc')

  it('reads nav, escape and blank, as JSON or objects', () => {
    expect(parseFrameEvent({ name, kind: 'nav', url: 'https://a.b/x', title: '  A  ', icon: 'https://a.b/i.png' })).toEqual({
      name,
      kind: 'nav',
      url: 'https://a.b/x',
      title: 'A',
      icon: 'https://a.b/i.png',
    })
    expect(parseFrameEvent(JSON.stringify({ name, kind: 'escape' }))).toEqual({ name, kind: 'escape' })
    expect(parseFrameEvent({ name, kind: 'blank', url: 'https://a.b' })).toEqual({ name, kind: 'blank', url: 'https://a.b/' })
  })

  it('drops icons that are not https, and bad events', () => {
    expect(parseFrameEvent({ name, kind: 'nav', url: 'https://a.b', title: 'A', icon: 'javascript:1' })).toEqual({
      name,
      kind: 'nav',
      url: 'https://a.b/',
      title: 'A',
    })
    expect(parseFrameEvent({ name, kind: 'nav', url: 'javascript:1', title: '' })).toBeNull()
    expect(parseFrameEvent({ name: 'x', kind: 'nav', url: 'https://a.b' })).toBeNull()
    expect(parseFrameEvent({ name, kind: 'party', url: 'https://a.b' })).toBeNull()
    expect(parseFrameEvent('{nope')).toBeNull()
    expect(parseFrameEvent([1])).toBeNull()
  })

  it('go to the view that owns the name, and only while it does', () => {
    const bus = new FrameBus()
    const seen: string[] = []
    const off = bus.on(name, e => seen.push(e.kind))
    expect(bus.emit({ name, kind: 'escape' })).toBe(true)
    expect(bus.emit({ name: frameName('web1', 'other'), kind: 'escape' })).toBe(false)
    off()
    expect(bus.emit({ name, kind: 'escape' })).toBe(false)
    expect(seen).toEqual(['escape'])
  })

  it('reach the controller through frameEvent and frameHost', () => {
    const c = new Controller()
    const seen: unknown[] = []
    c.frames.on(name, e => seen.push(e))
    expect(c.frameEvent(JSON.stringify({ name, kind: 'nav', url: 'https://a.b', title: 'A' }))).toBe(true)
    expect(c.frameEvent({ name, kind: 'nav', url: 'ftp://a.b' })).toBe(false)
    expect(seen).toHaveLength(1)
    expect(c.frames.reports).toBe(false)
    c.frameHost('{"reports":true}')
    expect(c.frames.reports).toBe(true)
    c.frameHost({})
    expect(c.frames.reports).toBe(false)
  })
})

describe('which frames get an iframe', () => {
  const visible = { x: 0, y: 0, w: 2000, h: 1000 }
  const at = (id: string, x: number, y = 0, w = 900, h = 600) => ({ id, x, y, w, h })

  it('mounts those on screen and big enough, nearest the middle first, within budget', () => {
    const frames = Array.from({ length: 10 }, (_, i) => at(`f${i}`, i * 120, 0, 300, 200))
    const got = framesToMount(frames, { visible, zoom: 1, active: null, mounted: new Set() })
    expect(got.size).toBe(MAX_MOUNTED)
    expect(got.has('f0')).toBe(false)
    expect(got.has('f8')).toBe(true)
  })

  it('skips frames off screen or too small to read, but always keeps the one in use', () => {
    const frames = [at('near', 100), at('far', 9000), at('tiny', 100, 0, 200, 200)]
    expect([...framesToMount(frames, { visible, zoom: 1, active: null, mounted: new Set() })]).toEqual(['near'])
    expect(framesToMount(frames, { visible, zoom: 1, active: 'far', mounted: new Set() }).has('far')).toBe(true)
    expect(framesToMount(frames, { visible, zoom: 0.2, active: null, mounted: new Set() }).size).toBe(0)
  })

  it('lets a mounted frame keep its iframe a little past the edge and a little smaller', () => {
    const edge = [at('edge', 2100, 0, 900, 600)]
    expect(framesToMount(edge, { visible, zoom: 1, active: null, mounted: new Set() }).size).toBe(0)
    expect(framesToMount(edge, { visible, zoom: 1, active: null, mounted: new Set(['edge']) }).size).toBe(1)
    const zoom = (KEEP_PX + 10) / 900
    expect(framesToMount([at('z', 0)], { visible, zoom, active: null, mounted: new Set() }).size).toBe(0)
    expect(framesToMount([at('z', 0)], { visible, zoom, active: null, mounted: new Set(['z']) }).size).toBe(1)
  })
})

describe('a frame’s own history', () => {
  it('follows reports and remote moves, and walks back and forward', () => {
    const nav = new FrameNav('https://a.b/1')
    expect(nav.report('https://a.b/1')).toBe(false)
    expect(nav.report('https://a.b/2')).toBe(true)
    expect(nav.remote('https://a.b/3')).toBe(true)
    expect(nav.canBack).toBe(true)
    expect(nav.back()).toBe('https://a.b/2')
    // The frame then says it is there: not a new step.
    expect(nav.report('https://a.b/2')).toBe(false)
    expect(nav.canForward).toBe(true)
    expect(nav.forward()).toBe('https://a.b/3')
    expect(nav.forward()).toBeNull()
    nav.back()
    nav.back()
    expect(nav.current).toBe('https://a.b/1')
    expect(nav.back()).toBeNull()
    // Somewhere new from the middle drops what was ahead.
    nav.report('https://a.b/9')
    expect(nav.canForward).toBe(false)
  })

  it('bumps its version for subscribers', () => {
    const nav = new FrameNav('https://a.b/')
    let n = 0
    const off = nav.subscribe(() => n++)
    nav.report('https://a.b/x')
    nav.back()
    off()
    nav.forward()
    expect(n).toBe(2)
    expect(nav.getVersion()).toBe(3)
  })
})

describe('who writes a frame’s address', () => {
  const base = { active: false, readOnly: false, now: 1000, chromeUntil: 0, quietUntil: 0 }
  it('only the person using it, or just pressing its buttons, and never while following', () => {
    expect(mayWrite(base)).toBe(false)
    expect(mayWrite({ ...base, active: true })).toBe(true)
    expect(mayWrite({ ...base, chromeUntil: 2000 })).toBe(true)
    expect(mayWrite({ ...base, active: true, quietUntil: 2000 })).toBe(false)
    expect(mayWrite({ ...base, active: true, readOnly: true })).toBe(false)
  })
})

describe('live links on the board', () => {
  const ctx = () => ({ store: new CanvasStore(new Y.Doc()), viewportCenter: () => ({ x: 0, y: 0 }) })

  it('adds `web` as a live link at a page’s size, readable by older clients as a link', () => {
    const c = ctx()
    const r = applyOps(c, { ops: [{ op: 'add', shape: { type: 'web', id: 'w', url: 'https://en.wikipedia.org/wiki/Monkey' } }] })
    expect(r.errors).toEqual([])
    expect(c.store.get('w')).toMatchObject({ type: 'link', live: true, title: 'en.wikipedia.org', ...LIVE_SIZE })
    const read = readCanvas({ store: c.store, canvas: { id: 'c', name: 'C', kind: 'personal' }, viewport: null, selection: [] }, {})
    expect(read.shapes.find(s => s.id === 'w')).toMatchObject({ type: 'link', live: true })
  })

  it('takes `live`/`embed` on a link, and refuses a live frame that is not a web page', () => {
    const c = ctx()
    const r = applyOps(c, {
      ops: [
        { op: 'add', shape: { type: 'link', id: 'a', url: 'https://a.b', embed: true } },
        { op: 'add', shape: { type: 'link', id: 'b', url: 'mailto:x@y.z', live: true } },
        { op: 'add', shape: { type: 'link', id: 'c', url: 'https://a.b', live: 'yes' } },
        { op: 'add', shape: { type: 'iframe', id: 'd', url: 'https://a.b', w: 10, h: 10 } },
      ],
    })
    expect(c.store.get('a')?.live).toBe(true)
    expect(r.errors.map(e => e.index)).toEqual([1, 2])
    expect(c.store.get('d')).toMatchObject({ live: true, w: LIVE_MIN.w, h: LIVE_MIN.h })
  })

  it('drops the old page’s name and icon when an update moves a link without naming it', () => {
    const c = ctx()
    applyOps(c, { ops: [{ op: 'add', shape: { type: 'web', id: 'w', url: 'https://a.b/1', title: 'One', favicon: 'https://a.b/i.png' } }] })
    applyOps(c, { ops: [{ op: 'update', id: 'w', patch: { url: 'https://a.b/2' } }] })
    expect(c.store.get('w')).toMatchObject({ title: 'a.b', favicon: 'https://a.b/i.png' })
    applyOps(c, { ops: [{ op: 'update', id: 'w', patch: { url: 'https://c.d/', title: 'C' } }] })
    expect(c.store.get('w')?.title).toBe('C')
    expect(c.store.get('w')?.favicon).toBeUndefined()
  })

  it('grows a card that is turned live, and keeps a live frame from shrinking past its minimum', () => {
    const c = ctx()
    applyOps(c, { ops: [{ op: 'add', shape: { type: 'link', id: 'l', url: 'https://a.b' } }] })
    expect(applyOps(c, { ops: [{ op: 'update', id: 'l', patch: { live: true } }] }).errors).toEqual([])
    expect(c.store.get('l')).toMatchObject({ live: true, ...LIVE_SIZE })
    applyOps(c, { ops: [{ op: 'resize', id: 'l', w: 1, h: 1 }] })
    expect(c.store.get('l')).toMatchObject(LIVE_MIN)
    expect(minSizeOf({ type: 'link' })).toEqual(MIN_SIZE.link)
    expect(minSizeOf({ type: 'link', live: true })).toEqual(LIVE_MIN)
    expect(minSizeOf({ type: 'sticky', live: true })).toEqual(MIN_SIZE.sticky)
  })
})

describe('presence: the frame someone is using', () => {
  it('is read from awareness, and wins between one person’s two windows', () => {
    const me = new Awareness(new Y.Doc())
    const user = { id: 'ada', name: 'Ada', color: '#123456' }
    me.states.set(me.clientID + 1, { user, cursor: { x: 1, y: 2 }, selection: [], frame: null })
    me.states.set(me.clientID + 2, { user, cursor: null, selection: [], frame: 'web1' })
    const people = readHumanPresence(me)
    expect(people).toHaveLength(1)
    expect(people[0]!.frame).toBe('web1')
  })
})
