import { beforeEach, describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { CanvasStore } from '../canvas/doc'
import { applyOps, parseApplyInput, type OpsContext } from '../ops'

let store: CanvasStore
let ctx: OpsContext
const run = (ops: unknown, as?: unknown) => applyOps(ctx, as ? { ops, as } : { ops })

beforeEach(() => {
  store = new CanvasStore(new Y.Doc())
  ctx = { store, viewportCenter: () => ({ x: 0, y: 0 }) }
})

describe('parseApplyInput', () => {
  it('takes {ops, as}, a bare array, or JSON of either', () => {
    expect(parseApplyInput([{ op: 'clear' }]).ops).toHaveLength(1)
    expect(parseApplyInput('{"ops":[],"as":{"id":"a1","name":"Scout","color":"#0f0"}}').as).toEqual({ id: 'a1', name: 'Scout', color: '#0f0' })
    expect(parseApplyInput({ ops: [], as: 'Scout' }).as).toEqual({ id: 'agent:Scout', name: 'Scout' })
    expect(() => parseApplyInput('{nope')).toThrow(/JSON/)
    expect(() => parseApplyInput({ ops: 1 })).toThrow(/array/)
  })
})

describe('add', () => {
  it('adds every type with defaults, attribution and a stacking order', () => {
    const r = run(
      [
        { op: 'add', shape: { type: 'sticky', x: 0, y: 0, text: '**hi**' } },
        { op: 'add', shape: { type: 'text', x: 0, y: 300, text: 'Title', fontSize: 32, align: 'center' } },
        { op: 'add', shape: { type: 'frame', x: 500, y: 0, title: 'Group' } },
        { op: 'add', shape: { type: 'image', x: 0, y: 600, src: 'data:image/png;base64,AAAA', naturalW: 1000, naturalH: 500 } },
        { op: 'add', shape: { type: 'link', x: 1200, y: 0, url: 'https://www.example.com/a' } },
      ],
      { id: 'agent:s', name: 'Scout', color: '#123456' }
    )
    expect(r.errors).toEqual([])
    expect(r.applied).toBe(5)
    const [sticky, text, frame, image, link] = r.ids.map(id => store.get(id!)!)
    expect(sticky).toMatchObject({ type: 'sticky', w: 200, h: 200, color: 'yellow', text: '**hi**', by: 'Scout', z: 1 })
    expect(text).toMatchObject({ fontSize: 32, align: 'center', z: 2 })
    expect(frame).toMatchObject({ title: 'Group', color: 'gray', w: 480, h: 320 })
    expect(image).toMatchObject({ w: 480, h: 240, naturalW: 1000, naturalH: 500 })
    expect(link).toMatchObject({ url: 'https://www.example.com/a', title: 'example.com', w: 300, h: 84 })
  })

  it('places a shape without x/y in free space near the viewport centre', () => {
    ctx.viewportCenter = () => ({ x: 1000, y: 1000 })
    const r = run([
      { op: 'add', shape: { type: 'sticky' } },
      { op: 'add', shape: { type: 'sticky' } },
    ])
    const [a, b] = r.ids.map(id => store.get(id!)!)
    expect(a).toMatchObject({ x: 900, y: 900 })
    expect(Math.abs(b!.x - a!.x) >= 200 + 24 || Math.abs(b!.y - a!.y) >= 200 + 24).toBe(true)
  })

  it('keeps a caller id and rejects a duplicate', () => {
    const r = run([
      { op: 'add', shape: { type: 'sticky', id: 'n1' } },
      { op: 'add', shape: { type: 'sticky', id: 'n1' } },
    ])
    expect(r.ids).toEqual(['n1', null])
    expect(r.errors[0]).toMatchObject({ index: 1, op: 'add', error: expect.stringMatching(/already exists/) })
  })

  it('accepts friendly spellings: text for a frame title, string arrow ends', () => {
    run([
      { op: 'add', shape: { type: 'frame', id: 'f', text: 'Ideas', x: 0, y: 0 } },
      { op: 'add', shape: { type: 'sticky', id: 's', x: 600, y: 0 } },
      { op: 'add', shape: { type: 'arrow', id: 'a', from: 'f', to: 'shape:s', text: 'goes to' } },
    ])
    expect(store.get('f')?.title).toBe('Ideas')
    expect(store.get('a')).toMatchObject({ from: { ref: 'f' }, to: { ref: 's' }, label: 'goes to' })
  })

  it('reports bad shapes, one error per op, and applies the rest', () => {
    const r = run([
      { op: 'add', shape: { type: 'blob' } },
      { op: 'add', shape: { type: 'sticky', color: 'chartreuse' } },
      { op: 'add', shape: { type: 'sticky', wobble: 1 } },
      { op: 'add', shape: { type: 'image' } },
      { op: 'add', shape: { type: 'image', src: 'ftp://x/y.png' } },
      { op: 'add', shape: { type: 'link', url: 'javascript:alert(1)' } },
      { op: 'add', shape: { type: 'arrow', from: 'nope', to: 'nada' } },
      { op: 'add', shape: { type: 'sticky', w: -5 } },
      { op: 'add', shape: { type: 'sticky', color: '#abc' } },
    ])
    expect(r.applied).toBe(1)
    expect(r.errors.map(e => e.index)).toEqual([0, 1, 2, 3, 4, 5, 6, 7])
    expect(r.errors[2]!.error).toMatch(/unknown prop `wobble`/)
  })

  it('refuses a data URL over 2 MB', () => {
    const big = `data:image/png;base64,${'A'.repeat(2 * 1024 * 1024)}`
    const r = run([{ op: 'add', shape: { type: 'image', src: big } }])
    expect(r.errors[0]!.error).toMatch(/over 2 MB/)
  })

  it('sizes a frame to the image it holds', () => {
    const r = run([{ op: 'add', shape: { type: 'frame', image: { src: 'https://x.dev/a.png', naturalW: 1280, naturalH: 720 } } }])
    expect(store.get(r.ids[0]!)).toMatchObject({ w: 640, h: 360, image: { src: 'https://x.dev/a.png' } })
  })
})

describe('update, move, resize', () => {
  beforeEach(() => {
    run([
      { op: 'add', shape: { type: 'frame', id: 'f', x: 0, y: 0, w: 600, h: 400 } },
      { op: 'add', shape: { type: 'sticky', id: 'in', x: 50, y: 50, text: 'inside' } },
      { op: 'add', shape: { type: 'sticky', id: 'out', x: 1000, y: 0 } },
      { op: 'connect', id: 'a', from: 'in', to: 'out' },
      { op: 'add', shape: { type: 'arrow', id: 'free', from: { x: 0, y: 900 }, to: { x: 100, y: 900 } } },
    ])
  })

  it('merges a patch, replacing text through the Y.Text', () => {
    const before = store.shapes.get('in')!.get('text')
    const r = run([{ op: 'update', id: 'in', patch: { text: 'still inside', color: 'pink' } }])
    expect(r.errors).toEqual([])
    expect(store.get('in')).toMatchObject({ text: 'still inside', color: 'pink' })
    expect(store.shapes.get('in')!.get('text')).toBe(before)
  })

  it('updates arrow ends and labels, and refuses a box on an arrow', () => {
    expect(run([{ op: 'update', id: 'a', patch: { label: 'next', to: { ref: 'f', side: 'top' } } }]).errors).toEqual([])
    expect(store.get('a')).toMatchObject({ label: 'next', to: { ref: 'f', side: 'top' } })
    expect(run([{ op: 'update', id: 'a', patch: { x: 5 } }]).errors[0]!.error).toMatch(/no box/)
    expect(run([{ op: 'update', id: 'a', patch: { from: 'f', to: 'f' } }]).errors[0]!.error).toMatch(/same shape/)
  })

  it('removes a frame image with null', () => {
    run([{ op: 'update', id: 'f', patch: { image: 'https://x.dev/i.png' } }])
    expect(store.get('f')?.image?.src).toBe('https://x.dev/i.png')
    run([{ op: 'update', id: 'f', patch: { image: null } }])
    expect(store.get('f')?.image).toBeUndefined()
  })

  it('rejects updates to missing shapes and disallowed props', () => {
    const r = run([
      { op: 'update', id: 'ghost', patch: { color: 'blue' } },
      { op: 'update', id: 'in', patch: { url: 'https://x.dev' } },
      { op: 'update', id: 'in' },
    ])
    expect(r.errors.map(e => e.error)).toEqual([expect.stringMatching(/no shape ghost/), expect.stringMatching(/unknown prop `url`/), expect.stringMatching(/needs `patch/)])
  })

  it('moves a shape; a frame carries what sits inside it', () => {
    run([{ op: 'move', id: 'f', dx: 100, dy: -10 }])
    expect(store.get('f')).toMatchObject({ x: 100, y: -10 })
    expect(store.get('in')).toMatchObject({ x: 150, y: 40 })
    expect(store.get('out')).toMatchObject({ x: 1000, y: 0 })
  })

  it('moves the free ends of an arrow', () => {
    run([{ op: 'move', id: 'free', dx: 10, dy: 10 }])
    expect(store.get('free')).toMatchObject({ from: { x: 10, y: 910 }, to: { x: 110, y: 910 } })
  })

  it('resizes with the type minimum, and refuses arrows', () => {
    run([{ op: 'resize', id: 'in', w: 10, h: 500 }])
    expect(store.get('in')).toMatchObject({ w: 96, h: 500 })
    expect(run([{ op: 'resize', id: 'a', w: 10, h: 10 }]).errors[0]!.error).toMatch(/no size/)
    expect(run([{ op: 'resize', id: 'in', w: 'big', h: 1 }]).errors[0]!.error).toMatch(/positive/)
  })
})

describe('delete, connect, clear', () => {
  it('deletes a shape and the arrows ending on it', () => {
    run([
      { op: 'add', shape: { type: 'sticky', id: 'a', x: 0, y: 0 } },
      { op: 'add', shape: { type: 'sticky', id: 'b', x: 400, y: 0 } },
      { op: 'connect', id: 'ab', from: 'a', to: 'b' },
    ])
    const r = run([{ op: 'delete', id: 'a' }])
    expect(r.ids).toEqual(['a'])
    expect(store.shapes.has('ab')).toBe(false)
    expect(run([{ op: 'delete', id: 'a' }]).errors[0]!.error).toMatch(/no shape/)
  })

  it('connects two shapes, with sides, label and colour', () => {
    run([
      { op: 'add', shape: { type: 'sticky', id: 'a', x: 0, y: 0 } },
      { op: 'add', shape: { type: 'sticky', id: 'b', x: 400, y: 0 } },
    ])
    const r = run([{ op: 'connect', from: 'a', to: 'b', label: 'then', color: 'blue', fromSide: 'right', toSide: 'left' }], {
      id: 'x',
      name: 'Scout',
    })
    expect(store.get(r.ids[0]!)).toMatchObject({
      type: 'arrow',
      from: { ref: 'a', side: 'right' },
      to: { ref: 'b', side: 'left' },
      label: 'then',
      color: 'blue',
      by: 'Scout',
    })
    const bad = run([
      { op: 'connect', from: 'a', to: 'a' },
      { op: 'connect', from: 'a', to: 'zz' },
      { op: 'connect', from: 'a', to: 'b', fromSide: 'middle' },
    ])
    expect(bad.applied).toBe(0)
    expect(bad.errors).toHaveLength(3)
  })

  it('clears every shape but keeps meta and agents', () => {
    run([{ op: 'add', shape: { type: 'sticky' } }])
    store.meta.set('name', 'Board')
    store.agents.set('x', { name: 'Scout' })
    const r = run([{ op: 'clear' }])
    expect(r).toMatchObject({ applied: 1, ids: [null], errors: [] })
    expect(store.shapes.size).toBe(0)
    expect(store.meta.get('name')).toBe('Board')
    expect(store.agents.has('x')).toBe(true)
  })
})

describe('applyOps as a whole', () => {
  it('applies the batch in one transaction', () => {
    let updates = 0
    store.doc.on('update', () => updates++)
    run([
      { op: 'add', shape: { type: 'sticky' } },
      { op: 'add', shape: { type: 'sticky' } },
      { op: 'add', shape: { type: 'frame' } },
    ])
    expect(updates).toBe(1)
  })

  it('is undoable as one step', () => {
    run([
      { op: 'add', shape: { type: 'sticky' } },
      { op: 'add', shape: { type: 'sticky' } },
    ])
    store.undo.undo()
    expect(store.shapes.size).toBe(0)
  })

  it('refuses everything on a read-only canvas', () => {
    ctx.readOnly = true
    const r = run([{ op: 'add', shape: { type: 'sticky' } }])
    expect(r).toMatchObject({ applied: 0, ids: [null] })
    expect(r.errors[0]!.error).toMatch(/read-only/)
  })

  it('reports unknown ops, non-objects and bad input without throwing', () => {
    const r = run([{ op: 'paint' }, 7])
    expect(r.errors.map(e => e.index)).toEqual([0, 1])
    expect(applyOps(ctx, 'garbage').errors[0]).toMatchObject({ index: -1 })
    expect(applyOps(ctx, { ops: new Array(501).fill({ op: 'clear' }) }).errors[0]!.error).toMatch(/at most 500/)
  })

  it('reports where the agent should rest', () => {
    const r = run([{ op: 'add', shape: { type: 'sticky', x: 0, y: 0 } }], { id: 'x', name: 'S' })
    expect(r.anchor).toEqual({ x: 100, y: 100 })
    expect(r.actor).toEqual({ id: 'x', name: 'S' })
  })
})
