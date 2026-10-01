import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { AGENT, CanvasStore, HOST, LOCAL, readEndpoint, readShape } from '../doc'

const fresh = () => new CanvasStore(new Y.Doc())

describe('CanvasStore', () => {
  it('creates shapes with type defaults, rounded boxes and a Y.Text body', () => {
    const store = fresh()
    const id = store.create({ type: 'sticky', x: 10.4, y: 20.6, text: 'hi' })
    const m = store.shapes.get(id)!
    expect(m.get('text')).toBeInstanceOf(Y.Text)
    expect(store.get(id)).toMatchObject({ type: 'sticky', x: 10, y: 21, w: 200, h: 200, color: 'yellow', text: 'hi', z: 1 })
    const frame = store.create({ type: 'frame' })
    expect(store.get(frame)).toMatchObject({ color: 'gray', w: 480, h: 320, z: 2 })
  })

  it('keeps a caller id unless it is taken', () => {
    const store = fresh()
    expect(store.create({ type: 'text', id: 'mine' })).toBe('mine')
    expect(store.create({ type: 'text', id: 'mine' })).not.toBe('mine')
  })

  it('updates only the given keys and splices text', () => {
    const store = fresh()
    const id = store.create({ type: 'sticky', text: 'buy milk' })
    const text = store.shapes.get(id)!.get('text')
    store.update(id, { color: 'blue', text: 'buy oat milk' })
    expect(store.shapes.get(id)!.get('text')).toBe(text)
    expect(store.get(id)).toMatchObject({ color: 'blue', text: 'buy oat milk' })
  })

  it('reads a plain-string body written by another writer, and upgrades it on edit', () => {
    const store = fresh()
    const m = new Y.Map<unknown>()
    m.set('type', 'sticky')
    m.set('text', 'from a server')
    store.shapes.set('srv', m)
    expect(store.get('srv')?.text).toBe('from a server')
    store.setText('srv', 'from a server, edited')
    expect(store.shapes.get('srv')!.get('text')).toBeInstanceOf(Y.Text)
    expect(store.get('srv')?.text).toBe('from a server, edited')
  })

  it('deletes a shape with its arrows and brings both back on undo', () => {
    const store = fresh()
    const a = store.create({ type: 'sticky', x: 0, y: 0, text: 'Keep me' })
    const b = store.create({ type: 'frame', x: 400, y: 0, title: 'Frame' })
    const arrow = store.create({ type: 'arrow', from: { ref: a }, to: { ref: b, side: 'left' } })
    store.undo.stopCapturing()
    expect(store.remove([a]).sort()).toEqual([a, arrow].sort())
    expect(store.shapes.has(a)).toBe(false)
    expect(store.shapes.has(arrow)).toBe(false)
    expect(store.shapes.has(b)).toBe(true)
    store.undo.undo()
    expect(store.shapes.has(a)).toBe(true)
    expect(store.shapes.has(arrow)).toBe(true)
    expect(store.get(a)?.text).toBe('Keep me')
    store.undo.redo()
    expect(store.shapes.has(a)).toBe(false)
  })

  it('undoes local and agent edits but never host or remote ones', () => {
    const doc = new Y.Doc()
    const store = new CanvasStore(doc)
    const mine = store.create({ type: 'sticky' }, LOCAL)
    store.undo.stopCapturing()
    const agents = store.create({ type: 'sticky' }, AGENT)
    store.undo.stopCapturing()
    // Something the host hands over (stored or relayed).
    const other = new Y.Doc()
    const remote = new CanvasStore(other).create({ type: 'frame' })
    Y.applyUpdate(doc, Y.encodeStateAsUpdate(other), HOST)
    expect(store.shapes.has(remote)).toBe(true)
    store.undo.undo()
    expect(store.shapes.has(agents)).toBe(false)
    store.undo.undo()
    expect(store.shapes.has(mine)).toBe(false)
    expect(store.undo.canUndo()).toBe(false)
    expect(store.shapes.has(remote)).toBe(true)
  })

  it('keeps unchanged shapes identical across snapshots', () => {
    const store = fresh()
    const a = store.create({ type: 'sticky' })
    const b = store.create({ type: 'sticky' })
    const before = store.getShapes()
    store.update(b, { color: 'pink' })
    const after = store.getShapes()
    expect(after).not.toBe(before)
    expect(after.get(a)).toBe(before.get(a))
    expect(after.get(b)).not.toBe(before.get(b))
  })

  it('notifies subscribers and stops after unsubscribe', () => {
    const store = fresh()
    let calls = 0
    const off = store.subscribe(() => calls++)
    store.create({ type: 'sticky' })
    off()
    store.create({ type: 'sticky' })
    expect(calls).toBe(1)
  })

  it('moves many shapes in one transaction', () => {
    const store = fresh()
    const a = store.create({ type: 'sticky', x: 0, y: 0 })
    const arrow = store.create({ type: 'arrow', from: { x: 0, y: 0 }, to: { ref: a } })
    let updates = 0
    store.doc.on('update', () => updates++)
    store.moveMany([
      [a, { x: 10, y: 10 }],
      [arrow, { from: { x: 5, y: 5 } }],
    ])
    expect(updates).toBe(1)
    expect(store.get(a)).toMatchObject({ x: 10, y: 10 })
    expect(store.get(arrow)?.from).toEqual({ x: 5, y: 5 })
  })

  it('tracks max and min z', () => {
    const store = fresh()
    store.create({ type: 'sticky', z: 5 })
    store.create({ type: 'sticky', z: -3 })
    expect(store.maxZ()).toBe(5)
    expect(store.minZ()).toBe(-3)
  })
})

describe('tolerant reads', () => {
  it('ignores things that are not shapes', () => {
    expect(readShape('x', 'nope')).toBeNull()
    const m = new Y.Doc().getMap('m')
    const inner = new Y.Map<unknown>()
    m.set('s', inner)
    inner.set('type', 'blob')
    expect(readShape('s', inner)).toBeNull()
  })

  it('falls back on bad colours and missing numbers', () => {
    const doc = new Y.Doc()
    const m = doc.getMap<Y.Map<unknown>>('shapes')
    const s = new Y.Map<unknown>()
    m.set('s', s)
    s.set('type', 'frame')
    s.set('color', 'chartreuse')
    s.set('x', 'ten')
    expect(readShape('s', s)).toMatchObject({ color: 'gray', x: 0, w: 480 })
    s.set('color', '#12ab9f')
    expect(readShape('s', s)?.color).toBe('#12ab9f')
  })

  it('reads endpoints in every accepted spelling', () => {
    expect(readEndpoint('abc')).toEqual({ ref: 'abc' })
    expect(readEndpoint('shape:abc')).toEqual({ ref: 'abc' })
    expect(readEndpoint({ ref: 'abc', side: 'top' })).toEqual({ ref: 'abc', side: 'top' })
    expect(readEndpoint({ ref: 'abc', side: 'middle' })).toEqual({ ref: 'abc' })
    expect(readEndpoint({ x: 1.6, y: 2.2 })).toEqual({ x: 2, y: 2 })
    expect(readEndpoint({})).toBeNull()
    expect(readEndpoint('')).toBeNull()
  })
})
