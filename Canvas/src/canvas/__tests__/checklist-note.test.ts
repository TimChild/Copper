import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { addColumn, addRow, isChecklist, removeColumn, removeRow, renameColumn, setRowLabel, setTitle, togglePick } from '../checklist'
import { checklistMarkdown, parseChecklistText } from '../checklist-text'
import { CanvasStore, HOST } from '../doc'
import { toggleTask } from '../markdown-lite'
import { boardSearchItems } from '../search'

const ann = { name: 'Ann', id: 'u-ann' }
const ada = { name: 'Ada Lovelace', id: 'u-ada' }

function note(text: string, columns?: string[]) {
  const store = new CanvasStore(new Y.Doc())
  const id = store.create({ type: 'sticky', id: 'n', view: 'checklist', text, ...(columns ? { columns } : {}) })
  return { store, id }
}

/** Two replicas of one doc that exchange updates only when told to. */
function pair(text: string, columns?: string[]) {
  const a = note(text, columns)
  const b = new CanvasStore(new Y.Doc())
  Y.applyUpdate(b.doc, Y.encodeStateAsUpdate(a.store.doc), HOST)
  const sync = () => {
    const ua = Y.encodeStateAsUpdate(a.store.doc, Y.encodeStateVector(b.doc))
    const ub = Y.encodeStateAsUpdate(b.doc, Y.encodeStateVector(a.store.doc))
    Y.applyUpdate(b.doc, ua, HOST)
    Y.applyUpdate(a.store.doc, ub, HOST)
  }
  return { a: a.store, b, id: a.id, sync }
}

/** What a Copper from before the checklist view does on a click on a note's task box. */
const oldTick = (store: CanvasStore, id: string, line: number) => store.setText(id, toggleTask(store.get(id)!.text, line))

const picks = (store: CanvasStore, id: string) => {
  const s = store.get(id)!
  return s.rows!.map(r => [r.label, s.picks![r.id]?.col ?? null])
}

describe('the checklist text', () => {
  it('reads the first heading as the title and each task line as a row', () => {
    const p = parseChecklistText('Intro\n## Going ##\n- [ ] Ann\n* [x] Ada Lovelace\n1. [X] Bob\nnot a row\n- plain bullet\n- [ ] \n### Second', ['Going'])
    expect(p.title).toBe('Going')
    expect(p.rows.map(r => [r.label, r.pick])).toEqual([
      ['Ann', null],
      ['Ada Lovelace', 'Going'],
      ['Bob', 'Going'],
      ['', null],
    ])
  })

  it('reads a suffix naming a column as the pick; any other suffix is part of the label', () => {
    const p = parseChecklistText('- [x] Ann · No\n- [x] Bob\n- [ ] Cy · no\n- [x] Dee · team lead\n- [xx] Eve · Yes', ['Yes', 'No'])
    expect(p.rows.map(r => [r.label, r.pick])).toEqual([
      ['Ann', 'No'],
      ['Bob', 'Yes'],
      ['Cy', null],
      ['Dee · team lead', 'Yes'],
      ['Eve', 'Yes'],
    ])
  })

  it('writes what it reads', () => {
    const text = checklistMarkdown('Going', [{ label: 'Ann', pick: null }, { label: 'Ada', pick: 'No' }], ['Yes', 'No'])
    expect(text).toBe('### Going\n- [ ] Ann\n- [x] Ada · No')
    expect(checklistMarkdown('', [{ label: 'Ann', pick: 'Done' }], ['Done'])).toBe('- [x] Ann')
  })
})

describe('a note in the checklist view', () => {
  it('reads as a checklist card; who picked only when it agrees with the text', () => {
    const { store, id } = note('### Going\n- [ ] Ann\n- [x] Ada Lovelace')
    const s = store.get(id)!
    expect(isChecklist(s)).toBe(true)
    expect(s).toMatchObject({ type: 'sticky', view: 'checklist', title: 'Going', columns: ['Done'] })
    expect(picks(store, id)).toEqual([
      ['Ann', null],
      ['Ada Lovelace', 'Done'],
    ])
    expect(s.picks!.t1).toMatchObject({ by: '', at: 0 })
    store.shapes.get(id)!.set('who:ada lovelace', { col: 'Done', by: 'Ada Lovelace', byId: 'u-ada', at: 5 })
    store.shapes.get(id)!.set('who:ann', { col: 'Done', by: 'Ann', byId: 'u-ann', at: 5 })
    expect(store.get(id)!.picks!.t1).toMatchObject({ by: 'Ada Lovelace', at: 5 })
    // Ann's line is unticked (an older Copper cleared it): her who is not shown.
    expect(store.get(id)!.picks!.t0).toBeUndefined()
  })

  it('a click edits only its own line: box and suffix', () => {
    const { store, id } = note('### Dinner\n- [ ] Ann\n- [ ] Bob', ['Yes', 'No'])
    togglePick(store, id, 't1', 'No', ann)
    expect(store.get(id)!.text).toBe('### Dinner\n- [ ] Ann\n- [x] Bob · No')
    expect(store.shapes.get(id)!.get('who:bob')).toMatchObject({ col: 'No', by: 'Ann' })
    togglePick(store, id, 't1', 'Yes', ann)
    expect(store.get(id)!.text).toBe('### Dinner\n- [ ] Ann\n- [x] Bob · Yes')
    togglePick(store, id, 't1', 'Yes', ann)
    expect(store.get(id)!.text).toBe('### Dinner\n- [ ] Ann\n- [ ] Bob')
    expect(store.shapes.get(id)!.has('who:bob')).toBe(false)
  })

  it('one column: a tick, no suffix; an old tick with no suffix is the first column', () => {
    const { store, id } = note('### Going\n- [ ] Ann\n- [ ] Ada')
    togglePick(store, id, 't0', 'Done', ann)
    expect(store.get(id)!.text).toBe('### Going\n- [x] Ann\n- [ ] Ada')
    oldTick(store, id, 2)
    expect(picks(store, id)).toEqual([
      ['Ann', 'Done'],
      ['Ada', 'Done'],
    ])
  })

  it('a click finds its row by label when the text moved under it', () => {
    const { store, id } = note('- [ ] Ann\n- [ ] Bob')
    store.setText(id, '- [ ] Zed\n- [ ] Ann\n- [ ] Bob')
    togglePick(store, id, 't0', 'Done', ann, 'local', 'Ann')
    expect(store.get(id)!.text).toBe('- [ ] Zed\n- [x] Ann\n- [ ] Bob')
  })

  it('a new click and an older Copper tick on different rows at the same moment both stick', () => {
    const { a, b, id, sync } = pair('### Wed\n- [ ] Ann\n- [ ] Bob\n- [ ] Cy\n- [ ] Dee', ['Yes', 'No'])
    togglePick(a, id, 't0', 'No', ada)
    togglePick(a, id, 't3', 'Yes', ada)
    oldTick(b, id, 2) // Bob, ticked in a note by an older Copper
    oldTick(b, id, 3) // Cy
    sync()
    for (const s of [a, b]) {
      expect(s.get(id)!.text).toBe('### Wed\n- [x] Ann · No\n- [x] Bob\n- [x] Cy\n- [x] Dee · Yes')
      expect(picks(s, id)).toEqual([
        ['Ann', 'No'],
        ['Bob', 'Yes'],
        ['Cy', 'Yes'],
        ['Dee', 'Yes'],
      ])
      expect(s.get(id)!.picks!.t0).toMatchObject({ by: 'Ada Lovelace' })
    }
  })

  it('an older Copper unticking a picked line clears the pick (its suffix is left, read as no pick)', () => {
    const { store, id } = note('- [x] Ann · No', ['Yes', 'No'])
    oldTick(store, id, 0)
    expect(store.get(id)!.text).toBe('- [ ] Ann · No')
    expect(picks(store, id)).toEqual([['Ann', null]])
    togglePick(store, id, 't0', 'Yes', ann)
    expect(store.get(id)!.text).toBe('- [x] Ann · Yes')
  })

  it('two new clicks on different rows merge', () => {
    const { a, b, id, sync } = pair('- [ ] Ann\n- [ ] Bob', ['Yes', 'No'])
    togglePick(a, id, 't0', 'Yes', ann)
    togglePick(b, id, 't1', 'No', ada)
    sync()
    for (const s of [a, b]) expect(s.get(id)!.text).toBe('- [x] Ann · Yes\n- [x] Bob · No')
  })

  it('adds, renames and removes rows in the text; who follows a rename', () => {
    const { store, id } = note('### Going\n- [ ] Ann')
    const fresh = addRow(store, id, 't0', '')!
    expect(fresh).toBe('t1')
    setRowLabel(store, id, fresh, 'Ada')
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Ann\n- [ ] Ada')
    togglePick(store, id, 't1', 'Done', ann)
    setRowLabel(store, id, 't1', 'Ada Lovelace')
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Ann\n- [x] Ada Lovelace')
    expect(store.get(id)!.picks!.t1).toMatchObject({ by: 'Ann' })
    removeRow(store, id, 't0')
    expect(store.get(id)!.text).toBe('### Going\n- [x] Ada Lovelace')
    removeRow(store, id, 't0')
    expect(store.get(id)!.text).toBe('### Going')
    expect(store.shapes.get(id)!.has('who:ada lovelace')).toBe(false)
    addRow(store, id, null, 'Bob')
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Bob')
  })

  it('a new card: title then rows from an empty text', () => {
    const { store, id } = note('', ['Yes', 'No'])
    setTitle(store, id, 'G')
    setTitle(store, id, 'Going')
    expect(store.get(id)!.text).toBe('### Going')
    addRow(store, id, null, 'Ann')
    expect(store.get(id)!.text).toBe('### Going\n- [ ] Ann')
  })

  it('columns: rename carries the suffix, removing one clears its picks, one left drops suffixes', () => {
    const { store, id } = note('- [x] Ann · No\n- [x] Bob\n- [x] Cy · Yes', ['Yes', 'No'])
    expect(addColumn(store, id)).toBe(2)
    expect(store.get(id)!.columns).toEqual(['Yes', 'No', 'Maybe'])
    renameColumn(store, id, 1, 'Nope')
    expect(store.get(id)!.text).toBe('- [x] Ann · Nope\n- [x] Bob\n- [x] Cy · Yes')
    removeColumn(store, id, 0)
    expect(store.get(id)!.text).toBe('- [x] Ann · Nope\n- [ ] Bob\n- [ ] Cy')
    removeColumn(store, id, 1)
    expect(store.get(id)!.columns).toEqual(['Nope'])
    expect(store.get(id)!.text).toBe('- [x] Ann\n- [ ] Bob\n- [ ] Cy')
  })

  it('a click is one undo step', () => {
    const { store, id } = note('- [ ] Ann\n- [ ] Bob', ['Yes', 'No'])
    togglePick(store, id, 't0', 'No', ann)
    store.undo.stopCapturing()
    togglePick(store, id, 't1', 'Yes', ann)
    store.undo.undo()
    expect(store.get(id)!.text).toBe('- [x] Ann · No\n- [ ] Bob')
  })

  it('is found by its text, as a checklist', () => {
    const { store } = note('### Going\n- [ ] Ann')
    expect(boardSearchItems(store.getShapes().values())).toMatchObject([{ ref: 'n', kind: 'checklist', text: '### Going\n- [ ] Ann' }])
  })
})
