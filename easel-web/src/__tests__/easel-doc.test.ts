// Ported from the wiki app's __tests__/canvas-undo.test.ts onto the per-easel
// factory, plus meta and schema-tolerance cases.
import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import {
  DEFAULT_TITLE,
  SHAPE_SIZE,
  createEaselDoc,
  readShape,
} from '../doc/easel-doc'

describe('delete + undo', () => {
  it('deletes a note with its arrows and brings both back on undo', () => {
    const easel = createEaselDoc()
    const a = easel.createShape({ type: 'sticky', x: 0, y: 0, text: 'Keep me' })
    const b = easel.createShape({ type: 'frame', x: 400, y: 0, text: 'Frame' })
    const arrow = easel.createShape({
      type: 'arrow',
      from: `shape:${a}`,
      to: `shape:${b}`,
    })
    easel.undo.stopCapturing()

    easel.deleteShape(a)
    expect(easel.shapes.has(a)).toBe(false)
    expect(easel.shapes.has(arrow)).toBe(false)
    expect(easel.shapes.has(b)).toBe(true)

    easel.undo.undo()
    expect(easel.shapes.has(a)).toBe(true)
    expect(easel.shapes.has(arrow)).toBe(true)
    expect(easel.shapes.get(a)?.get('text')?.toString()).toBe('Keep me')

    easel.undo.redo()
    expect(easel.shapes.has(a)).toBe(false)
  })

  it('deletes a multi-selection in one undo step', () => {
    const easel = createEaselDoc()
    const a = easel.createShape({ type: 'sticky' })
    const b = easel.createShape({ type: 'sticky' })
    const c = easel.createShape({ type: 'sticky' })
    easel.undo.stopCapturing()
    easel.deleteShapes([a, b])
    expect(easel.getShapesSnapshot().size).toBe(1)
    easel.undo.undo()
    expect(easel.getShapesSnapshot().size).toBe(3)
    expect(easel.shapes.has(c)).toBe(true)
  })

  it('keeps two easels apart', () => {
    const one = createEaselDoc()
    const two = createEaselDoc()
    one.createShape({ type: 'sticky' })
    expect(one.getShapesSnapshot().size).toBe(1)
    expect(two.getShapesSnapshot().size).toBe(0)
  })
})

describe('shapes', () => {
  it('fills defaults per type and rounds positions', () => {
    const easel = createEaselDoc()
    const id = easel.createShape({ type: 'frame', x: 10.4, y: 20.6 })
    const shape = easel.getShapesSnapshot().get(id)!
    expect(shape).toMatchObject({
      type: 'frame',
      x: 10,
      y: 21,
      w: SHAPE_SIZE.frame.w,
      h: SHAPE_SIZE.frame.h,
      color: 'yellow',
      text: '',
    })
  })

  it('moves many shapes in one transaction', () => {
    const easel = createEaselDoc()
    const a = easel.createShape({ type: 'sticky' })
    const b = easel.createShape({ type: 'sticky' })
    let updates = 0
    easel.doc.on('update', () => updates++)
    easel.moveShapes([
      [a, { x: 100, y: 100 }],
      [b, { x: 200.4, y: 200 }],
    ])
    expect(updates).toBe(1)
    expect(easel.getShapesSnapshot().get(b)).toMatchObject({ x: 200, y: 200 })
  })

  it('splices text instead of replacing it', () => {
    const easel = createEaselDoc()
    const id = easel.createShape({ type: 'sticky', text: 'buy milk' })
    easel.setShapeText(id, 'buy oat milk')
    expect(easel.getShapesSnapshot().get(id)?.text).toBe('buy oat milk')
  })

  it('drops unknown shape types and tolerates partial ones', () => {
    // Maps must be integrated into a doc before `.get()` reads anything.
    const easel = createEaselDoc()
    const embed = new Y.Map<unknown>()
    const partial = new Y.Map<unknown>()
    easel.shapes.set('e', embed)
    easel.shapes.set('p', partial)
    embed.set('type', 'embed')
    partial.set('type', 'sticky')
    partial.set('color', 'chartreuse')
    expect(readShape('e', embed)).toBeNull()
    expect(easel.getShapesSnapshot().has('e')).toBe(false)
    expect(readShape('p', partial)).toMatchObject({
      type: 'sticky',
      x: 0,
      y: 0,
      w: 200,
      h: 140,
      color: 'yellow',
      text: '',
    })
  })

  it('is a superset of wiki:canvas, so a wiki-app doc loads as is', () => {
    const source = new Y.Doc()
    const shapes = source.getMap<Y.Map<unknown>>('shapes')
    const m = new Y.Map<unknown>()
    m.set('type', 'sticky')
    m.set('x', 5)
    m.set('y', 6)
    m.set('text', new Y.Text('from the wiki app'))
    shapes.set('s1', m)
    const easel = createEaselDoc()
    Y.applyUpdate(easel.doc, Y.encodeStateAsUpdate(source))
    expect(easel.getShapesSnapshot().get('s1')?.text).toBe('from the wiki app')
    expect(easel.title()).toBe(DEFAULT_TITLE)
  })
})

describe('meta', () => {
  it('defaults the title and fills createdAt once', () => {
    const easel = createEaselDoc()
    expect(easel.title()).toBe(DEFAULT_TITLE)
    easel.ensureMeta({ title: 'Launch plan', createdAt: 1700000000 })
    expect(easel.getMeta()).toEqual({
      title: 'Launch plan',
      createdAt: 1700000000,
    })
    // A later config (say, after a reload) never overwrites what is there.
    easel.ensureMeta({ title: 'Other', createdAt: 1 })
    expect(easel.getMeta()).toEqual({
      title: 'Launch plan',
      createdAt: 1700000000,
    })
  })

  it('setTitle trims and falls back to the default when blank', () => {
    const easel = createEaselDoc()
    easel.setTitle('  Ideas  ')
    expect(easel.title()).toBe('Ideas')
    easel.setTitle('   ')
    expect(easel.title()).toBe(DEFAULT_TITLE)
  })

  it('title edits are not part of shape undo', () => {
    const easel = createEaselDoc()
    easel.createShape({ type: 'sticky' })
    easel.setTitle('Named')
    easel.undo.undo()
    expect(easel.getShapesSnapshot().size).toBe(0)
    expect(easel.title()).toBe('Named')
  })
})
