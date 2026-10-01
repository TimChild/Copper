import { beforeEach, describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { CanvasStore } from '../canvas/doc'
import { applyOps, describeSrc, readCanvas, READ_TEXT_LIMIT, type ReadContext } from '../ops'

let store: CanvasStore
let ctx: ReadContext

beforeEach(() => {
  store = new CanvasStore(new Y.Doc())
  ctx = {
    store,
    canvas: { id: 'c1', name: 'Board', kind: 'shared' },
    viewport: { x: -100, y: -100, w: 1000, h: 800, zoom: 1 },
    selection: ['s1'],
    now: 1_000_000,
  }
  applyOps(
    { store, viewportCenter: () => ({ x: 0, y: 0 }) },
    {
      ops: [
        { op: 'add', shape: { type: 'frame', id: 'f', x: 0, y: 0, w: 600, h: 400, title: 'Plan' } },
        { op: 'add', shape: { type: 'sticky', id: 's1', x: 20, y: 20, text: 'x'.repeat(800) } },
        { op: 'add', shape: { type: 'link', id: 'l', x: 2000, y: 2000, url: 'https://a.dev', title: 'A' } },
        { op: 'add', shape: { type: 'image', id: 'i', x: 300, y: 50, src: `data:image/png;base64,${'A'.repeat(4000)}`, naturalW: 10, naturalH: 10 } },
        { op: 'connect', id: 'ar', from: 's1', to: 'l', label: 'far' },
      ],
      as: { id: 'agent:s', name: 'Scout' },
    }
  )
  store.agents.set('agent:s', { name: 'Scout', color: '#0f0', cursor: { x: 1, y: 2 }, status: 'idle', updatedAt: 999_000 })
  store.agents.set('agent:old', { name: 'Old', color: '', cursor: null, status: 'idle', updatedAt: 1 })
})

describe('readCanvas', () => {
  it('returns the canvas, viewport, shapes, live agents and selection', () => {
    const r = readCanvas(ctx)
    expect(r.canvas).toEqual({ id: 'c1', name: 'Board', kind: 'shared' })
    expect(r.viewport).toEqual({ x: -100, y: -100, w: 1000, h: 800, zoom: 1 })
    expect(r.selection).toEqual(['s1'])
    expect(r.count).toBe(5)
    expect(r.agents.map(a => a.id)).toEqual(['agent:s'])
    expect(r.shapes.map(s => s.id)).toEqual(['f', 's1', 'i', 'ar', 'l'])
  })

  it('summarises each type with its own text field', () => {
    const by = Object.fromEntries(readCanvas(ctx).shapes.map(s => [s.id, s]))
    expect(by.f).toMatchObject({ type: 'frame', title: 'Plan', by: 'Scout', color: 'gray' })
    expect(by.s1).toMatchObject({ type: 'sticky', frame: 'f', x: 20, y: 20, w: 200, h: 200 })
    expect(by.l).toMatchObject({ type: 'link', url: 'https://a.dev/', title: 'A' })
    expect(by.ar).toMatchObject({ type: 'arrow', label: 'far', from: { ref: 's1' }, to: { ref: 'l' } })
    expect(by.ar!.w).toBeGreaterThan(0)
    expect(by.i!.src).toBe('data:image/png (3 KB)')
  })

  it('truncates text to 500 characters unless full', () => {
    const s1 = readCanvas(ctx).shapes.find(s => s.id === 's1')!
    expect(s1.text).toHaveLength(READ_TEXT_LIMIT + 1)
    expect(s1.text!.endsWith('…')).toBe(true)
    expect(readCanvas(ctx, '{"full":true}').shapes.find(s => s.id === 's1')!.text).toHaveLength(800)
  })

  it('filters by ids, types and the visible area', () => {
    expect(readCanvas(ctx, { ids: ['shape:l', 'f'] }).shapes.map(s => s.id)).toEqual(['f', 'l'])
    expect(readCanvas(ctx, { types: ['sticky'] }).shapes.map(s => s.id)).toEqual(['s1'])
    expect(readCanvas(ctx, { inView: true }).shapes.map(s => s.id)).not.toContain('l')
  })

  it('omits the viewport when it is unknown and tolerates bad options', () => {
    ctx.viewport = null
    const r = readCanvas(ctx, 'not json')
    expect(r.viewport).toBeUndefined()
    expect(r.shapes).toHaveLength(5)
  })

  it('never returns Yjs objects', () => {
    const json = JSON.stringify(readCanvas(ctx))
    expect(JSON.parse(json).shapes).toHaveLength(5)
  })
})

describe('describeSrc', () => {
  it('keeps https URLs and summarises data URLs', () => {
    expect(describeSrc('https://x.dev/a.png')).toBe('https://x.dev/a.png')
    expect(describeSrc(`data:image/webp;base64,${'A'.repeat(4 * 1024 * 1024 / 3)}`)).toMatch(/^data:image\/webp \(1\.0 MB\)$/)
  })
})
