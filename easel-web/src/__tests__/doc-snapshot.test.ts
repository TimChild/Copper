import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { createEaselDoc } from '../doc/easel-doc'

describe('doc snapshot keeps untouched shapes identical', () => {
  it('re-reads only what a transaction touched', () => {
    const d = createEaselDoc()
    const a = d.createShape({ type: 'sticky', x: 0, y: 0, text: 'a' })
    const b = d.createShape({ type: 'sticky', x: 300, y: 0, text: 'b' })
    const before = d.getShapesSnapshot()
    const aBefore = before.get(a)!
    const bBefore = before.get(b)!

    d.moveShapes([[a, { x: 10, y: 20 }]])
    const after = d.getShapesSnapshot()
    expect(after).not.toBe(before)
    expect(after.get(a)).not.toBe(aBefore)
    expect(after.get(a)).toMatchObject({ x: 10, y: 20 })
    // The other note is the same object, so a memoized component skips it.
    expect(after.get(b)).toBe(bBefore)

    // Text edits go through the nested Y.Text and touch only that shape.
    d.setShapeText(b, 'b!')
    const typed = d.getShapesSnapshot()
    expect(typed.get(a)).toBe(after.get(a))
    expect(typed.get(b)?.text).toBe('b!')
    d.destroy()
  })

  it('keeps the very same Map when a write changes nothing visible', () => {
    const d = createEaselDoc()
    const a = d.createShape({ type: 'sticky', x: 5, y: 5 })
    const snap = d.getShapesSnapshot()
    d.moveShapes([[a, { x: 5, y: 5 }]])
    d.updateShape(a, { color: 'yellow' })
    expect(d.getShapesSnapshot()).toBe(snap)
    d.destroy()
  })

  it('keeps insertion order and handles deletes and remote updates', () => {
    const d = createEaselDoc()
    const a = d.createShape({ type: 'sticky' })
    const b = d.createShape({ type: 'frame' })
    const c = d.createShape({ type: 'arrow', from: `shape:${a}`, to: `shape:${b}` })
    expect([...d.getShapesSnapshot().keys()]).toEqual([a, b, c])
    d.deleteShapes([a])
    // The arrow on it goes too.
    expect([...d.getShapesSnapshot().keys()]).toEqual([b])

    // A peer's update arriving as bytes reads the same as local edits.
    const peer = createEaselDoc()
    Y.applyUpdate(peer.doc, Y.encodeStateAsUpdate(d.doc))
    const bPeer = peer.getShapesSnapshot().get(b)!
    d.updateShape(b, { w: 999 })
    Y.applyUpdate(peer.doc, Y.encodeStateAsUpdate(d.doc))
    expect(peer.getShapesSnapshot().get(b)).not.toBe(bPeer)
    expect(peer.getShapesSnapshot().get(b)?.w).toBe(999)
    d.destroy()
    peer.destroy()
  })
})
