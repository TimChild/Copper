import { beforeEach, describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { pickKey } from '../canvas/checklist'
import { CanvasStore } from '../canvas/doc'
import { applyOps, readCanvas, type OpsContext } from '../ops'

let store: CanvasStore
let ctx: OpsContext
const scout = { id: 'agent:s', name: 'Scout', color: '#123456' }
const run = (ops: unknown) => applyOps(ctx, { ops, as: scout })
const read = (id: string) => readCanvas({ store, canvas: { id: 'c', name: 'B', kind: 'shared' }, viewport: null, selection: [], now: 0 }).shapes.find(s => s.id === id)!

beforeEach(() => {
  store = new CanvasStore(new Y.Doc())
  ctx = { store, viewportCenter: () => ({ x: 0, y: 0 }) }
})

describe('checklist ops', () => {
  it('adds a checklist with defaults, rows from labels, picks, and a fitted size', () => {
    const r = run([{ op: 'add', shape: { type: 'checklist', id: 'tue', x: 0, y: 0, title: 'Tue', rows: ['Ann', 'Bob', { label: 'Cy', id: 'cy' }], picks: { Ann: 'yes', cy: 'No' } } }])
    expect(r.errors).toEqual([])
    const s = store.get('tue')!
    expect(s).toMatchObject({ type: 'checklist', title: 'Tue', columns: ['Yes', 'No'], color: 'green', w: 324, by: 'Scout' })
    expect(s.h).toBe(49 + 28 + 34 * 3 + 14)
    expect(s.rows!.map(r => r.label)).toEqual(['Ann', 'Bob', 'Cy'])
    expect(s.rows![2]!.id).toBe('cy')
    expect(s.picks!.cy).toMatchObject({ col: 'No', by: 'Scout', byId: 'agent:s' })
    expect(Object.values(s.picks!).map(p => p.col).sort()).toEqual(['No', 'Yes'])
  })

  it('takes one column as a to-do list, sized narrower', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'todo', columns: ['Done'], rows: ['Book table'], picks: { 'book table': true } } }])
    expect(store.get('todo')).toMatchObject({ w: 280, h: 49 + 34 + 14, columns: ['Done'] })
    expect(read('todo')).toMatchObject({ rows: [{ label: 'Book table', pick: 'Done', by: 'Scout' }], tally: { Done: 1 } })
  })

  it('fails the whole add on a bad pick, column or row, writing nothing', () => {
    const r = run([
      { op: 'add', shape: { type: 'checklist', rows: ['Ann'], picks: { Ann: 'Maybe' } } },
      { op: 'add', shape: { type: 'checklist', columns: ['A', 'B', 'C', 'D', 'E'] } },
      { op: 'add', shape: { type: 'checklist', rows: 'Ann' } },
      { op: 'add', shape: { type: 'checklist', rows: ['Ann'], fontSize: 20 } },
    ])
    expect(r.applied).toBe(0)
    expect(r.errors.map(e => e.index)).toEqual([0, 1, 2, 3])
    expect(r.errors[0]!.error).toMatch(/no column "Maybe"/)
    expect(r.errors[3]!.error).toMatch(/unknown prop `fontSize`/)
    expect(store.shapes.size).toBe(0)
  })

  it('updates picks one row at a time without touching the others', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', rows: ['Ann', 'Bob', 'Cy'], picks: { Ann: 'Yes', Bob: 'No' } } }])
    const m = store.shapes.get('c')!
    const bobPick = m.get(pickKey(store.get('c')!.rows![1]!.id))
    const r = run([{ op: 'update', id: 'c', patch: { picks: { Ann: null, Cy: 'yes' } } }])
    expect(r.errors).toEqual([])
    const out = read('c')
    expect(out.rows!.map(r => r.pick)).toEqual([null, 'No', 'Yes'])
    expect(out.tally).toEqual({ Yes: 1, No: 1 })
    // Bob's pick is the same value: never rewritten.
    expect(m.get(pickKey(store.get('c')!.rows![1]!.id))).toBe(bobPick)
  })

  it('replaces rows keeping ids (and picks) of rows that stay; renames columns', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', rows: ['Ann', 'Bob'], picks: { Ann: 'Yes', Bob: 'No' } } }])
    const annId = store.get('c')!.rows![0]!.id
    run([{ op: 'update', id: 'c', patch: { rows: ['Bob', 'Dee', 'Ann'], columns: ['Yes', 'No', 'Maybe'], picks: { Dee: 'maybe' } } }])
    const s = store.get('c')!
    expect(s.rows!.map(r => r.label)).toEqual(['Bob', 'Dee', 'Ann'])
    expect(s.rows![2]!.id).toBe(annId)
    expect(s.columns).toEqual(['Yes', 'No', 'Maybe'])
    expect(read('c').rows!.map(r => r.pick)).toEqual(['No', 'Maybe', 'Yes'])
    expect(s.w).toBe(14 * 2 + 168 + 64 * 3)
    // Columns replaced: a pick naming a column that went is dropped.
    run([{ op: 'update', id: 'c', patch: { columns: ['Yes', 'Maybe'], rows: ['Bob', 'Dee'] } }])
    expect(read('c').rows!.map(r => r.pick)).toEqual([null, 'Maybe'])
    expect([...store.shapes.get('c')!.keys()].filter(k => k.startsWith('pick:'))).toHaveLength(1)
  })

  it('reports update errors and leaves the shape as it was', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', title: 'T', rows: ['Ann'] } }])
    const r = run([{ op: 'update', id: 'c', patch: { title: 'New', picks: { Zed: 'Yes' } } }])
    expect(r.errors[0]!.error).toMatch(/no row "Zed"/)
    expect(store.get('c')!.title).toBe('T')
  })

  it('reads as title, columns, rows with picks and a tally; titles are capped at 500', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', title: 'x'.repeat(600), rows: ['Ann', 'Bob'], picks: { Bob: 'Yes' } } }])
    const s = read('c')
    expect(s.title).toHaveLength(500)
    expect(s.columns).toEqual(['Yes', 'No'])
    expect(s.rows![0]).toEqual({ id: expect.any(String), label: 'Ann', pick: null })
    expect(s.rows![1]).toMatchObject({ label: 'Bob', pick: 'Yes', by: 'Scout', at: expect.any(Number) })
    expect(s.tally).toEqual({ Yes: 1, No: 0 })
    expect(s).not.toHaveProperty('picks')
  })

  it('moves, resizes (with a floor) and deletes like any box', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', x: 0, y: 0, rows: ['Ann'] } }])
    run([
      { op: 'move', id: 'c', dx: 10, dy: 20 },
      { op: 'resize', id: 'c', w: 50, h: 50 },
    ])
    expect(store.get('c')).toMatchObject({ x: 10, y: 20, w: 200, h: 72 })
    run([{ op: 'delete', id: 'c' }])
    expect(store.shapes.has('c')).toBe(false)
  })

  it('takes text/label as its title', () => {
    run([{ op: 'add', shape: { type: 'checklist', id: 'c', text: 'Wed dinner' } }])
    expect(store.get('c')!.title).toBe('Wed dinner')
  })
})
