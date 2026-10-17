import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { CanvasStore } from '../canvas/doc'
import { ChatHub } from '../canvas/chat/hub'
import { withChat } from '../canvas/chat/api'
import { Controller } from '../controller'
import { BridgeSocket } from '../bridge-socket'
import type { PageMessage } from '../host-bridge'
import { applyOps, MAX_OPS, readBoard, readCanvas, type CanvasRead, type ReadContext } from '../ops'
import { PAGE_BYTES, PAGE_LIMIT, utf8Bytes, type CanvasOverview } from '../read-pages'

let store: CanvasStore
let ctx: ReadContext
const apply = (ops: unknown[]) => applyOps({ store, viewportCenter: () => ({ x: 0, y: 0 }) }, { ops })
const read = (opts: unknown = {}) => readCanvas(ctx, opts)
const overview = (opts: Record<string, unknown> = {}) => readBoard(ctx, { ...opts, overview: true }) as CanvasOverview

beforeEach(() => {
  store = new CanvasStore(new Y.Doc())
  ctx = { store, canvas: { id: 'c1', name: 'Big', kind: 'local' }, viewport: { x: 0, y: 0, w: 1000, h: 800, zoom: 1 }, selection: [], now: 0 }
})

/** 10 frames (slides) of 30 stickies each, 40 loose notes, 20 arrows, 5 live links, 3 checklists, 2 timelines, 6 threads. */
function bigBoard() {
  const ops: unknown[] = []
  for (let f = 0; f < 10; f++) {
    ops.push({ op: 'add', shape: { type: 'frame', id: `f${f}`, x: f * 2000, y: 0, w: 1800, h: 1200, title: `Slide ${f}` } })
    for (let i = 0; i < 30; i++)
      ops.push({ op: 'add', shape: { type: 'sticky', id: `s${f}_${i}`, x: f * 2000 + 20 + (i % 6) * 290, y: 40 + Math.floor(i / 6) * 230, text: `note ${f}.${i}${i === 7 ? ' Budget' : ''}` } })
  }
  for (let i = 0; i < 40; i++) ops.push({ op: 'add', shape: { type: 'sticky', id: `loose${i}`, x: (i % 10) * 250, y: 3000 + Math.floor(i / 10) * 250, text: `loose ${i}` } })
  for (let i = 0; i < 20; i++) ops.push({ op: 'connect', id: `a${i}`, from: `s0_${i}`, to: `s0_${i + 1}`, label: i === 3 ? 'BUDGET link' : '' })
  for (let i = 0; i < 5; i++) ops.push({ op: 'add', shape: { type: 'web', id: `w${i}`, x: i * 1100, y: 5000, url: `https://site${i}.example/` } })
  for (let i = 0; i < 3; i++) ops.push({ op: 'add', shape: { type: 'checklist', id: `cl${i}`, x: 6000 + i * 500, y: 5000, title: `RSVP ${i}`, rows: ['Ann', 'Bob'] } })
  for (let i = 0; i < 2; i++) ops.push({ op: 'add', shape: { type: 'timeline', id: `tl${i}`, x: 8000, y: 5000 + i * 700, start: '2026-10-01', end: '2026-12-31' } })
  ops.push({ op: 'add', shape: { type: 'link', id: 'card', x: 9000, y: 9000, url: 'https://docs.example/budget' } })
  ops.push({ op: 'add', shape: { type: 'sticky', id: 'gone', x: 12000, y: 12000, text: 'deleted below' } })
  const r = apply(ops)
  expect(r.errors).toEqual([])
  const threads = apply([
    { op: 'comment', on: 's0_0', text: 'first' },
    { op: 'comment', on: 's9_29', text: 'last slide' },
    { op: 'comment', on: 'loose39', text: 'loose' },
    { op: 'comment', on: 'tl1', text: 'timeline' },
    { op: 'comment', on: 'gone', text: 'orphan' },
    { op: 'comment', on: 'f3', text: 'on a frame' },
  ])
  expect(threads.errors).toEqual([])
  apply([{ op: 'delete', id: 'gone' }])
}

/** Every page from the first, following `next`. */
function pages(opts: Record<string, unknown> = {}, between?: (page: number) => void): CanvasRead[] {
  const out: CanvasRead[] = []
  let cursor: string | undefined
  for (let n = 0; n < 200; n++) {
    const page = read(cursor ? { cursor } : opts)
    out.push(page)
    if (!page.next) return out
    cursor = page.next
    between?.(n)
  }
  throw new Error('paging never ended')
}

describe('a board that fits in one answer', () => {
  it('answers exactly as before, plus total and returned', () => {
    apply([
      { op: 'add', shape: { type: 'frame', id: 'f', x: 0, y: 0, w: 600, h: 400, title: 'Plan' } },
      { op: 'add', shape: { type: 'sticky', id: 's', x: 20, y: 20, text: 'hi' } },
      { op: 'comment', on: 's', text: 'q' },
    ])
    const r = read()
    expect(Object.keys(r).sort()).toEqual(['agents', 'canvas', 'comments', 'count', 'returned', 'selection', 'shapes', 'total', 'viewport'])
    expect(r.total).toBe(2)
    expect(r.returned).toBe(2)
    expect(r.next).toBeUndefined()
    expect(r.note).toBeUndefined()
    // Today's order: by y, then x, then id.
    expect(r.shapes.map(s => s.id)).toEqual(['f', 's'])
    expect(r.comments).toHaveLength(1)
  })
})

describe('paging a big board', () => {
  beforeEach(bigBoard)

  it('pages at the default limit, frames first, every shape exactly once, and the totals add up', () => {
    const all = pages()
    const ids = all.flatMap(p => p.shapes.map(s => s.id))
    const total = all[0]!.total!
    expect(total).toBe(store.liveAll().length)
    expect(new Set(ids).size).toBe(ids.length)
    expect(ids).toHaveLength(total)
    expect(all.map(p => p.returned)).toEqual(all.map(p => p.shapes.length))
    expect(all.reduce((n, p) => n + p.returned!, 0)).toBe(total)
    expect(all[0]!.shapes.length).toBeLessThanOrEqual(PAGE_LIMIT)
    // Frames first, then the rest — each by y, then x, then id.
    expect(ids.slice(0, 10)).toEqual(['f0', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9'])
    const rest = all.flatMap(p => p.shapes).slice(10)
    for (let i = 1; i < rest.length; i++) {
      const [a, b] = [rest[i - 1]!, rest[i]!]
      expect(a.y < b.y || (a.y === b.y && (a.x < b.x || (a.x === b.x && a.id < b.id)))).toBe(true)
    }
    expect(all.at(-1)!.next).toBeUndefined()
  })

  it('puts the frame list and the note on the first page of an un-narrowed read', () => {
    const first = read()
    const total = first.total!
    expect(first.note).toBe(`Showing 1–${first.returned} of ${total} shapes. Pass cursor to continue, or overview / frame / region / types / query to narrow.`)
    expect(first.frames).toHaveLength(10)
    expect(first.frames![0]).toEqual({ id: 'f0', title: 'Slide 0', x: 0, y: 0, w: 1800, h: 1200, shapes: 30 + 20 })
    const second = read({ cursor: first.next })
    expect(second.frames).toBeUndefined()
    expect(second.note).toMatch(new RegExp(`^Showing ${first.returned! + 1}–`))
  })

  it('takes a smaller limit, and caps it at 500', () => {
    expect(read({ limit: 7 }).shapes).toHaveLength(7)
    expect(pages({ limit: 50 }).length).toBeGreaterThan(6)
    expect(() => read({ limit: 0 })).toThrow(/limit/)
    expect(read({ limit: 100000 }).returned).toBeLessThanOrEqual(500)
  })

  it('keeps its place across inserts and deletes between pages: nothing unchanged repeats or goes missing', () => {
    const before = new Set(store.liveAll().map(s => s.id))
    const deleted = new Set<string>()
    const seen: string[] = []
    let cursor: string | undefined
    for (let n = 0; ; n++) {
      const page = read(cursor ? { cursor } : { limit: 60 })
      expect(page.returned).toBeLessThanOrEqual(60)
      seen.push(...page.shapes.map(s => s.id))
      if (!page.next) break
      cursor = page.next
      // Between pages: shapes added ahead of and behind the cursor, one read shape and one unread deleted.
      const unread = store.liveAll().find(s => s.type !== 'frame' && !seen.includes(s.id) && !deleted.has(s.id) && s.id.startsWith('loose'))
      // A note no arrow leads to (deleting one with arrows takes the arrows too: those changed).
      const done = seen.find(id => /^s[1-9]_/.test(id) && !deleted.has(id))
      const ops: unknown[] = [
        { op: 'add', shape: { type: 'sticky', id: `early${n}`, x: -500, y: -500 - n, text: 'behind the cursor' } },
        { op: 'add', shape: { type: 'sticky', id: `late${n}`, x: 0, y: 20000 + n, text: 'ahead of the cursor' } },
      ]
      if (unread) {
        ops.push({ op: 'delete', id: unread.id })
        deleted.add(unread.id)
      }
      if (done) {
        ops.push({ op: 'delete', id: done })
        deleted.add(done)
      }
      expect(apply(ops).errors).toEqual([])
      if (n > 40) throw new Error('paging never ended')
    }
    expect(new Set(seen).size).toBe(seen.length)
    for (const id of before) if (!deleted.has(id) || seen.includes(id)) expect(seen).toContain(id)
    for (const id of seen) expect(id.startsWith('early')).toBe(false)
    expect(seen.filter(id => id.startsWith('late')).length).toBeGreaterThan(0)
  })

  it('stops each page near 48 KB, and still moves on when one shape is bigger than that', () => {
    const long = 'x'.repeat(5000)
    const ops = Array.from({ length: 60 }, (_, i) => ({ op: 'update', id: `loose${i % 40}`, patch: { text: `${i} ${long}` } }))
    apply(ops)
    for (const page of pages({ full: true })) expect(utf8Bytes(JSON.stringify(page))).toBeLessThanOrEqual(PAGE_BYTES)
    apply([{ op: 'update', id: 'loose0', patch: { text: 'y'.repeat(19_000) + '€'.repeat(900) } }])
    const huge = pages({ full: true, ids: ['loose0', 'loose1', 'loose2', 'loose3', 'loose4', 'loose5', 'loose6', 'loose7', 'loose8', 'loose9', 'loose10'] })
    expect(huge.flatMap(p => p.shapes.map(s => s.id)).sort()).toEqual(['loose0', 'loose1', 'loose10', 'loose2', 'loose3', 'loose4', 'loose5', 'loose6', 'loose7', 'loose8', 'loose9'])
  })

  it('rides each comment thread with the page that holds its shape; one whose shape is gone goes first', () => {
    const all = pages({ limit: 40 })
    const threads = all.flatMap(p => p.comments)
    expect(threads).toHaveLength(6)
    expect(new Set(threads.map(t => t.id)).size).toBe(6)
    expect(all[0]!.comments.map(t => t.anchor)).toContain('gone')
    for (const p of all) {
      const here = new Set(p.shapes.map(s => s.id))
      for (const t of p.comments) if (t.anchor !== 'gone') expect(here.has(t.anchor)).toBe(true)
    }
  })
})

describe('narrowing', () => {
  beforeEach(bigBoard)
  const ids = (r: CanvasRead) => r.shapes.map(s => s.id).sort()

  it('frame: the frame and what lies inside it, with its threads', () => {
    const r = read({ frame: 'f0' })
    expect(r.shapes).toHaveLength(1 + 30 + 20)
    expect(ids(r)).toContain('f0')
    expect(ids(r).filter(id => id.startsWith('a'))).toHaveLength(20)
    expect(r.shapes.every(s => s.id === 'f0' || s.frame === 'f0' || s.type === 'arrow')).toBe(true)
    expect(r.comments.map(t => t.anchor)).toEqual(['s0_0'])
    expect(read({ frame: 'shape:f3' }).comments.map(t => t.anchor)).toEqual(['f3'])
  })

  it('region: whatever intersects it', () => {
    const r = read({ region: { x: 5000, y: 4900, w: 3000, h: 400 } })
    expect(ids(r)).toEqual(['cl0', 'cl1', 'cl2', 'w4'])
  })

  it('types: as the read reports them — checklist and timeline cards, live links as web', () => {
    expect(ids(read({ types: ['checklist'] }))).toEqual(['cl0', 'cl1', 'cl2'])
    expect(ids(read({ types: ['timeline'] }))).toEqual(['tl0', 'tl1'])
    expect(ids(read({ types: ['web'] }))).toEqual(['w0', 'w1', 'w2', 'w3', 'w4'])
    expect(ids(read({ types: ['link'] }))).toEqual(['card', 'w0', 'w1', 'w2', 'w3', 'w4'])
    expect(read({ types: ['frame', 'arrow'] }).shapes).toHaveLength(30)
    expect(() => read({ types: ['note'] })).toThrow(/unknown type "note"/)
  })

  it('query: case-insensitive over text, titles, labels and urls', () => {
    expect(ids(read({ query: 'budget' }))).toEqual(['a3', 'card', ...Array.from({ length: 10 }, (_, f) => `s${f}_7`)].sort())
    expect(ids(read({ query: 'SLIDE 9' }))).toEqual(['f9'])
    expect(ids(read({ query: 'site3.EXAMPLE' }))).toEqual(['w3'])
    expect(ids(read({ query: 'rsvp 2' }))).toEqual(['cl2'])
  })

  it('filters combine, and a narrowed read that is too big still pages', () => {
    expect(ids(read({ frame: 'f1', query: 'note 1.2' }))).toEqual(['s1_2', 's1_20', 's1_21', 's1_22', 's1_23', 's1_24', 's1_25', 's1_26', 's1_27', 's1_28', 's1_29'])
    const sticky = pages({ types: ['sticky'], limit: 100 })
    expect(sticky.length).toBe(4)
    expect(sticky[0]!.frames).toBeUndefined()
    expect(sticky[0]!.note).toBe(`Showing 1–100 of ${sticky[0]!.total} shapes. Pass cursor to continue.`)
    expect(sticky.flatMap(p => p.shapes).every(s => s.type === 'sticky')).toBe(true)
  })

  it('a cursor carries its filters; other filters with it, another canvas or a made-up one are refused', () => {
    const first = read({ types: ['sticky'], limit: 10 })
    expect(read({ cursor: first.next }).shapes.every(s => s.type === 'sticky')).toBe(true)
    expect(read({ cursor: first.next, types: ['sticky'] }).returned).toBe(10)
    expect(() => read({ cursor: first.next, types: ['frame'] })).toThrow(/other filters/)
    expect(() => read({ cursor: 'nonsense' })).toThrow(/cursor/)
    expect(() => readCanvas({ ...ctx, canvas: { ...ctx.canvas, id: 'other' } }, { cursor: first.next })).toThrow(/another canvas/)
  })

  it('names the mistake: an unknown frame, a shape that is not one, a bad region', () => {
    expect(() => read({ frame: 'nope' })).toThrow(/no shape nope/)
    expect(() => read({ frame: 's0_0' })).toThrow(/is a sticky, not a frame/)
    expect(() => read({ region: { x: 0, y: 0, w: -1, h: 5 } })).toThrow(/positive/)
    expect(() => read({ region: [0, 0, 1, 1] })).toThrow(/region/)
  })
})

describe('overview', () => {
  beforeEach(bigBoard)

  it('counts the board without listing its shapes', () => {
    const o = overview()
    expect(o).not.toHaveProperty('shapes')
    expect(o.overview).toBe(true)
    expect(o.total).toBe(store.liveAll().length)
    expect(o.counts).toEqual({ frame: 10, sticky: 340, arrow: 20, web: 5, link: 1, checklist: 3, timeline: 2 })
    expect(Object.values(o.counts).reduce((a, b) => a + b, 0)).toBe(o.total)
    expect(o.frames).toHaveLength(10)
    expect(o.frames.map(f => f.shapes)).toEqual([50, 30, 30, 30, 30, 30, 30, 30, 30, 30])
    expect(o.comments).toEqual({ threads: 6, open: 6 })
    expect(o.bounds).toMatchObject({ x: 0, y: 0 })
    expect(o.bounds!.w).toBeGreaterThanOrEqual(19800)
    expect(o.note).toMatch(/^Overview only: \d+ shapes\./)
    expect(utf8Bytes(JSON.stringify(o))).toBeLessThan(6000)
  })

  it('narrowed: counts what matches, frames say where it is', () => {
    const o = overview({ query: 'budget' })
    expect(o.total).toBe(12)
    expect(o.counts).toEqual({ sticky: 10, arrow: 1, link: 1 })
    expect(o.frames.find(f => f.id === 'f0')!.shapes).toBe(2)
    expect(o.comments).toEqual({ threads: 0, open: 0 })
  })

  it('is only for the page API: readCanvas ignores overview', () => {
    expect(readCanvas(ctx, { overview: true, limit: 5 }).shapes).toHaveLength(5)
  })
})

describe('canvas_apply on a big board', () => {
  it('takes 1000 ops in one call and refuses 1001', () => {
    expect(MAX_OPS).toBe(1000)
    const ops = Array.from({ length: 1000 }, (_, i) => ({ op: 'add', shape: { type: 'sticky', id: `n${i}`, x: i * 10, y: 0 } }))
    expect(apply(ops).applied).toBe(1000)
    expect(apply([...ops, ops[0]]).errors[0]!.error).toMatch(/at most 1000/)
  })

  it('places a batch of unpositioned shapes without reading the board per shape, none overlapping', () => {
    bigBoard()
    const filler = Array.from({ length: 900 }, (_, i) => ({ op: 'add', shape: { type: 'sticky', x: -3000 + (i % 30) * 210, y: -3000 + Math.floor(i / 30) * 210 } }))
    apply(filler)
    const spy = vi.spyOn(store, 'liveAll')
    const t0 = performance.now()
    const r = apply(Array.from({ length: 120 }, (_, i) => ({ op: 'add', shape: { type: 'sticky', id: `p${i}`, text: `${i}` } })))
    const ms = performance.now() - t0
    expect(r.errors).toEqual([])
    expect(spy.mock.calls.length).toBeLessThanOrEqual(1)
    expect(ms).toBeLessThan(3000)
    const placed = r.ids.map(id => store.live(id!)!)
    for (let i = 0; i < placed.length; i++)
      for (let j = i + 1; j < placed.length; j++) {
        const [a, b] = [placed[i]!, placed[j]!]
        expect(a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h).toBe(false)
      }
  })

  it('reads the board again after an op that moves things, so the next placement sees it', () => {
    apply([{ op: 'add', shape: { type: 'sticky', id: 'far', x: 5000, y: 5000, w: 600, h: 600 } }])
    const r = apply([
      { op: 'add', shape: { type: 'sticky', id: 'p1' } },
      // Onto the middle of the view, where the next one would have gone.
      { op: 'move', id: 'far', dx: -5300, dy: -5300 },
      { op: 'add', shape: { type: 'sticky', id: 'p2' } },
    ])
    expect(r.errors).toEqual([])
    const overlap = (a: { x: number; y: number; w: number; h: number }, b: typeof a) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    const [far, p1, p2] = [store.live('far')!, store.live('p1')!, store.live('p2')!]
    expect(overlap(far, p2)).toBe(false)
    expect(overlap(p1, p2)).toBe(false)
  })
})

describe('chat on a paged read', () => {
  const ADA = 'aaaaaaaa-0000-4000-8000-000000000001'
  let c: Controller
  let hub: ChatHub
  beforeEach(() => {
    vi.stubGlobal('window', { __copperHost: { messages: [], onMessage: (_m: PageMessage) => {} } })
    vi.spyOn(console, 'debug').mockImplementation(() => {})
    c = new Controller()
    hub = new ChatHub(fn => c.subscribe(fn))
    c.init({ docId: 'd1', name: 'Board', kind: 'shared', me: { id: ADA, name: 'Ada', color: '#f00' }, state: null, online: false, readOnly: false })
    hub.attach(c.session)
    hub.configure({ enabled: true, members: [{ id: ADA, name: 'Ada', email: 'ada@example.com' }] })
    for (let i = 0; i < 30; i++) hub.sendDraft(`message ${i}`, [])
  })
  afterEach(() => {
    c.session?.destroy()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
    BridgeSocket.current = null
  })

  it('rides a whole read as before, the first page with its last ten, and no later page or overview', () => {
    const api = withChat({ read: (o?: unknown) => JSON.stringify(c.read(o ?? {})) }, hub)
    expect(JSON.parse(api.read({})).chat).toHaveLength(30)
    c.apply(Array.from({ length: 250 }, (_, i) => ({ op: 'add', shape: { type: 'sticky', id: `n${i}`, x: i * 10, y: 0 } })))
    const first = JSON.parse(api.read({}))
    expect(first.next).toBeTruthy()
    expect(first.chat).toHaveLength(10)
    expect(first.chat.at(-1).text).toBe('message 29')
    expect(JSON.parse(api.read({ cursor: first.next })).chat).toBeUndefined()
    expect(JSON.parse(api.read(JSON.stringify({ overview: true }))).chat).toBeUndefined()
  })
})
