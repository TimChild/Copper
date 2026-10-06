/**
 * The checklist (RSVP) shape: a title, 1–4 columns ("Yes", "No") and up to
 * 60 rows (people, tasks). Each row has at most one pick; one column makes
 * plain to-do boxes.
 *
 * Stored on the shape's own `Y.Map`, beside the usual box props:
 *
 *   title    string
 *   columns  string[]                   whole value, last writer wins
 *   rows     {id, label}[]              whole value, last writer wins
 *   pick:<rowId>  {col, by, byId, at}   one key per row
 *
 * A pick lives under its row's own key, so two people clicking different rows
 * at the same moment both stick: neither rewrites the other's. `col` is the
 * column's label; renaming a column rewrites the picks that name it, removing
 * one drops them. A pick naming no current column (or no current row) reads
 * as no pick.
 *
 * Pure apart from Yjs: the board, the ops (`ops.ts`) and the cloud's mirror
 * (`crates/canvas/src/checklist.rs`) share these rules.
 */
import * as Y from 'yjs'
import type { CanvasStore, Origin } from './doc'
import type { ChecklistPick, ChecklistRow } from './types'

export const PICK_PREFIX = 'pick:'
export const MAX_COLUMNS = 4
export const MAX_ROWS = 60
/** Labels are cut to these many characters (UTF-16 units, as JavaScript counts). */
export const MAX_COLUMN_LABEL = 40
export const MAX_ROW_LABEL = 200
export const DEFAULT_COLUMNS: readonly string[] = ['Yes', 'No']
/** Ids a caller may give a row. */
export const ROW_ID = /^[A-Za-z0-9_-]{1,32}$/

export const pickKey = (rowId: string) => PICK_PREFIX + rowId

export function newRowId(): string {
  let id = 'r'
  for (let i = 0; i < 8; i++) id += Math.floor(Math.random() * 36).toString(36)
  return id
}

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)
const plain = (v: unknown): Record<string, unknown> | null => {
  if (v instanceof Y.Map) return v.toJSON() as Record<string, unknown>
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}
const list = (v: unknown): unknown[] | null => (v instanceof Y.Array ? v.toArray() : Array.isArray(v) ? v : null)
const fold = (s: string) => s.trim().toLowerCase()

// ---- tolerant reads -------------------------------------------------------------

/** Columns as stored: strings, deduplicated, at most four; none → Yes / No. */
export function readColumns(v: unknown): string[] {
  const out: string[] = []
  for (const c of list(v) ?? []) {
    if (typeof c !== 'string' || !c.trim()) continue
    if (out.some(o => fold(o) === fold(c))) continue
    out.push(c)
    if (out.length === MAX_COLUMNS) break
  }
  return out.length ? out : [...DEFAULT_COLUMNS]
}

/** Rows as stored: `{id, label}` with unique ids, at most sixty. */
export function readRows(v: unknown): ChecklistRow[] {
  const out: ChecklistRow[] = []
  const seen = new Set<string>()
  for (const r of list(v) ?? []) {
    const o = plain(r)
    if (!o || typeof o.id !== 'string' || !o.id || seen.has(o.id)) continue
    seen.add(o.id)
    out.push({ id: o.id, label: typeof o.label === 'string' ? o.label : '' })
    if (out.length === MAX_ROWS) break
  }
  return out
}

export function readPick(v: unknown): ChecklistPick | null {
  const o = plain(v)
  if (!o || typeof o.col !== 'string' || !o.col) return null
  return {
    col: o.col,
    by: typeof o.by === 'string' ? o.by : '',
    byId: typeof o.byId === 'string' ? o.byId : '',
    at: finite(o.at) ? o.at : 0,
  }
}

/** Each row's pick, when it names a current column. */
export function readPicks(m: Y.Map<unknown>, rows: readonly ChecklistRow[], columns: readonly string[]): Record<string, ChecklistPick> {
  const out: Record<string, ChecklistPick> = {}
  for (const row of rows) {
    const pick = readPick(m.get(pickKey(row.id)))
    if (pick && columns.includes(pick.col)) out[row.id] = pick
  }
  return out
}

/** How many rows picked each column, in column order. */
export function tally(columns: readonly string[], rows: readonly ChecklistRow[], picks: Readonly<Record<string, ChecklistPick>>) {
  const out: Record<string, number> = {}
  for (const c of columns) out[c] = 0
  for (const row of rows) {
    const p = picks[row.id]
    if (p && p.col in out) out[p.col]!++
  }
  return out
}

// ---- size -------------------------------------------------------------------------

/** Layout numbers shared with ChecklistView (world px). */
export const CHECKLIST_LAYOUT = {
  /** Title band, its padding and its rule. */
  head: 49,
  /** Column header band (several columns only). */
  columnsHead: 28,
  row: 34,
  /** Padding around the rows and the card's border. */
  foot: 14,
  /** One choice column. */
  col: 64,
  /** The label column's room in a fresh card. */
  label: 168,
  pad: 14,
} as const

export const CHECKLIST_MIN = { w: 200, h: 72 } as const

/** A fresh card's width for this many columns. */
export function checklistWidth(columns: number): number {
  const L = CHECKLIST_LAYOUT
  return columns <= 1 ? 280 : L.pad * 2 + L.label + L.col * columns
}

/** The height a card needs before anyone has measured it (one line per label). */
export function checklistHeight(columns: number, rows: number): number {
  const L = CHECKLIST_LAYOUT
  return L.head + (columns > 1 ? L.columnsHead : 0) + L.row * Math.max(rows, 1) + L.foot
}

// ---- writes (inside a transaction) -----------------------------------------------

export interface Picker {
  name: string
  id: string
}

/** Set (or with `col` null, clear) one row's pick. Touches no other row. */
export function writePick(m: Y.Map<unknown>, rowId: string, col: string | null, by: Picker, at = Date.now()) {
  const key = pickKey(rowId)
  if (col === null) {
    if (m.has(key)) m.delete(key)
    return
  }
  m.set(key, { col, by: by.name, byId: by.id, at })
}

/**
 * New columns. Picks follow a rename (`renames[old] = new`) or a column whose
 * label is unchanged but for case; a pick naming a column that has gone is
 * dropped.
 */
export function writeColumns(m: Y.Map<unknown>, next: readonly string[], renames: Readonly<Record<string, string>> = {}) {
  m.set('columns', [...next])
  const byFold = new Map(next.map(c => [fold(c), c] as const))
  for (const key of [...m.keys()]) {
    if (!key.startsWith(PICK_PREFIX)) continue
    const pick = readPick(m.get(key))
    if (!pick) {
      m.delete(key)
      continue
    }
    const to = renames[pick.col] ?? byFold.get(fold(pick.col))
    if (!to || !next.includes(to)) m.delete(key)
    else if (to !== pick.col) m.set(key, { ...pick, col: to })
  }
}

/** New rows; the picks of rows that are gone go with them. */
export function writeRows(m: Y.Map<unknown>, next: readonly ChecklistRow[]) {
  m.set(
    'rows',
    next.map(r => ({ id: r.id, label: r.label }))
  )
  const keep = new Set(next.map(r => pickKey(r.id)))
  for (const key of [...m.keys()]) if (key.startsWith(PICK_PREFIX) && !keep.has(key)) m.delete(key)
}

// ---- what the board does ---------------------------------------------------------

/** The live map and its rows and columns (inside a transaction the snapshot lags). */
function current(store: CanvasStore, id: string) {
  const m = store.shapes.get(id)
  if (!m || m.get('type') !== 'checklist') return null
  return { m, rows: readRows(m.get('rows')), columns: readColumns(m.get('columns')) }
}

function touch(m: Y.Map<unknown>) {
  m.set('updatedAt', Date.now())
}

/** One click on a cell: pick it, or clear it when it is already the pick. */
export function togglePick(store: CanvasStore, id: string, rowId: string, col: string, by: Picker, origin: Origin = 'local') {
  store.transact(() => {
    const c = current(store, id)
    if (!c || !c.rows.some(r => r.id === rowId) || !c.columns.includes(col)) return
    const now = readPick(c.m.get(pickKey(rowId)))
    writePick(c.m, rowId, now?.col === col ? null : col, by)
    touch(c.m)
  }, origin)
}

export function setRowLabel(store: CanvasStore, id: string, rowId: string, label: string, origin: Origin = 'local') {
  store.transact(() => {
    const c = current(store, id)
    if (!c) return
    const clean = label.slice(0, MAX_ROW_LABEL)
    if (!c.rows.some(r => r.id === rowId && r.label !== clean)) return
    writeRows(
      c.m,
      c.rows.map(r => (r.id === rowId ? { ...r, label: clean } : r))
    )
    touch(c.m)
  }, origin)
}

/** A new row after `after` (or at the end); its id, or null when the list is full. */
export function addRow(store: CanvasStore, id: string, after: string | null = null, label = '', origin: Origin = 'local'): string | null {
  let made: string | null = null
  store.transact(() => {
    const c = current(store, id)
    if (!c || c.rows.length >= MAX_ROWS) return
    const row = { id: newRowId(), label: label.slice(0, MAX_ROW_LABEL) }
    const at = after ? c.rows.findIndex(r => r.id === after) + 1 : c.rows.length
    const next = [...c.rows]
    next.splice(at > 0 ? at : c.rows.length, 0, row)
    writeRows(c.m, next)
    touch(c.m)
    made = row.id
  }, origin)
  return made
}

export function removeRow(store: CanvasStore, id: string, rowId: string, origin: Origin = 'local') {
  store.transact(() => {
    const c = current(store, id)
    if (!c || !c.rows.some(r => r.id === rowId)) return
    writeRows(
      c.m,
      c.rows.filter(r => r.id !== rowId)
    )
    touch(c.m)
  }, origin)
}

/** A label for a new column: Maybe after Yes / No, else Option N. */
export function nextColumnLabel(columns: readonly string[]): string {
  const taken = new Set(columns.map(fold))
  if (taken.has('yes') && taken.has('no') && !taken.has('maybe')) return 'Maybe'
  for (let n = columns.length + 1; ; n++) if (!taken.has(`option ${n}`)) return `Option ${n}`
}

/** Add a column at the end; its index, or -1 when there are four already. */
export function addColumn(store: CanvasStore, id: string, label?: string, origin: Origin = 'local'): number {
  let index = -1
  store.transact(() => {
    const c = current(store, id)
    if (!c || c.columns.length >= MAX_COLUMNS) return
    const clean = (label ?? nextColumnLabel(c.columns)).trim().slice(0, MAX_COLUMN_LABEL)
    if (!clean || c.columns.some(o => fold(o) === fold(clean))) return
    writeColumns(c.m, [...c.columns, clean])
    touch(c.m)
    index = c.columns.length
  }, origin)
  return index
}

/**
 * Rename column `index`; its picks follow. An empty or duplicate name changes
 * nothing (false).
 */
export function renameColumn(store: CanvasStore, id: string, index: number, label: string, origin: Origin = 'local'): boolean {
  let done = false
  store.transact(() => {
    const c = current(store, id)
    const old = c?.columns[index]
    if (!c || old === undefined) return
    const clean = label.trim().slice(0, MAX_COLUMN_LABEL)
    if (!clean || clean === old) return
    if (c.columns.some((o, i) => i !== index && fold(o) === fold(clean))) return
    writeColumns(
      c.m,
      c.columns.map((o, i) => (i === index ? clean : o)),
      { [old]: clean }
    )
    touch(c.m)
    done = true
  }, origin)
  return done
}

/** Remove column `index` and its picks; the last column stays. */
export function removeColumn(store: CanvasStore, id: string, index: number, origin: Origin = 'local') {
  store.transact(() => {
    const c = current(store, id)
    if (!c || c.columns.length <= 1 || index < 0 || index >= c.columns.length) return
    writeColumns(
      c.m,
      c.columns.filter((_, i) => i !== index)
    )
    touch(c.m)
  }, origin)
}

// ---- agent input (ops.ts; mirrored by the cloud) ----------------------------------

/** A checklist value an op got wrong: the message names it, as the page reports it. */
export class ChecklistInputError extends Error {}
const bad = (message: string): never => {
  throw new ChecklistInputError(message)
}

/** `columns`: 1–4 distinct non-empty strings, each cut to 40 characters. */
export function cleanColumns(v: unknown): string[] {
  if (!Array.isArray(v) || v.length < 1 || v.length > MAX_COLUMNS) bad('`columns` must be a list of 1 to 4 names')
  const out: string[] = []
  for (const c of v as unknown[]) {
    if (typeof c !== 'string' || !c.trim()) bad('`columns` names must be non-empty strings')
    const name = (c as string).trim().slice(0, MAX_COLUMN_LABEL)
    if (out.some(o => fold(o) === fold(name))) bad(`\`columns\` has ${JSON.stringify(name)} twice`)
    out.push(name)
  }
  return out
}

/**
 * `rows`: up to 60 labels (`"Ann"`) or `{label, id?}`. A row keeps its id —
 * and so its pick — when it names an existing row's id, or failing that has
 * the same label as an existing row not yet taken.
 */
export function cleanRows(v: unknown, existing: readonly ChecklistRow[] = []): ChecklistRow[] {
  if (!Array.isArray(v)) return bad('`rows` must be a list of labels or {label, id?}')
  if (v.length > MAX_ROWS) bad(`\`rows\`: at most ${MAX_ROWS} rows`)
  const given = (v as unknown[]).map(r => {
    if (typeof r === 'string') return { label: r.trim().slice(0, MAX_ROW_LABEL), id: null as string | null }
    const o = plain(r)
    if (!o) return bad('`rows` must be a list of labels or {label, id?}')
    const label = o.label ?? o.text ?? o.title ?? ''
    if (typeof label !== 'string') bad('`rows`: a label must be a string')
    let id: string | null = null
    if (o.id !== undefined && o.id !== null) {
      if (typeof o.id !== 'string' || !ROW_ID.test(o.id)) bad('`rows`: an id must be 1–32 of A–Z a–z 0–9 _ -')
      id = o.id as string
    }
    return { label: (label as string).trim().slice(0, MAX_ROW_LABEL), id }
  })
  const taken = new Set<string>()
  for (const g of given) {
    if (!g.id) continue
    if (taken.has(g.id)) bad(`\`rows\`: id ${g.id} is used twice`)
    taken.add(g.id)
  }
  const out: ChecklistRow[] = []
  for (const g of given) {
    let id = g.id
    if (!id) {
      const same = existing.find(r => r.label === g.label && !taken.has(r.id))
      id = same ? same.id : null
      while (!id || taken.has(id)) id = newRowId()
      taken.add(id)
    }
    out.push({ id, label: g.label })
  }
  return out
}

/** The row `ref` names: its id, its label, or its label in any case. */
export function findRow(rows: readonly ChecklistRow[], ref: string): ChecklistRow {
  const byId = rows.find(r => r.id === ref)
  if (byId) return byId
  for (const same of [(r: ChecklistRow) => r.label === ref, (r: ChecklistRow) => fold(r.label) === fold(ref)]) {
    const hits = rows.filter(same)
    if (hits.length === 1) return hits[0]!
    if (hits.length > 1) return bad(`\`picks\`: more than one row is called ${JSON.stringify(ref)} — use its id`)
  }
  return bad(`\`picks\`: no row ${JSON.stringify(ref)}`)
}

/**
 * `picks`: `{rowIdOrLabel: column | true | null}` → `[rowId, column | null]`.
 * A column is named in any case; `true` is the first column; null, false or
 * "" clears the row.
 */
export function cleanPicks(v: unknown, rows: readonly ChecklistRow[], columns: readonly string[]): [string, string | null][] {
  const o = plain(v)
  if (!o) return bad('`picks` must be an object like {"Ann": "Yes"}')
  const out = new Map<string, string | null>()
  for (const [ref, value] of Object.entries(o)) {
    const row = findRow(rows, ref)
    let col: string | null
    if (value === null || value === false || value === '') col = null
    else if (value === true) col = columns[0]!
    else if (typeof value === 'string') {
      const hit = columns.find(c => fold(c) === fold(value))
      col = hit ?? bad(`\`picks\`: no column ${JSON.stringify(value)} (${columns.join(', ')})`)
    } else return bad('`picks` values must be a column name, true or null')
    out.set(row.id, col)
  }
  return [...out]
}

/** The checklist as an agent reads it (`canvas_read`). */
export function summarizeChecklist(columns: readonly string[], rows: readonly ChecklistRow[], picks: Readonly<Record<string, ChecklistPick>>) {
  return {
    columns: [...columns],
    rows: rows.map(r => {
      const p = picks[r.id]
      return p ? { id: r.id, label: r.label, pick: p.col, by: p.by, at: p.at } : { id: r.id, label: r.label, pick: null }
    }),
    tally: tally(columns, rows, picks),
  }
}

/** "just now", "4 min ago", "3 h ago", "yesterday", "Oct 4". */
export function ago(at: number, now = Date.now()): string {
  if (!at) return ''
  const s = Math.max(0, Math.round((now - at) / 1000))
  if (s < 45) return 'just now'
  const m = Math.round(s / 60)
  if (m < 60) return `${m} min ago`
  const h = Math.round(m / 60)
  if (h < 24) return `${h} h ago`
  const d = Math.round(h / 24)
  if (d === 1) return 'yesterday'
  if (d < 7) return `${d} days ago`
  return new Date(at).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

/** Who made a pick and when: "Ann · 4 min ago". */
export const pickedBy = (p: ChecklistPick, now = Date.now()) => [p.by, ago(p.at, now)].filter(Boolean).join(' · ')

/** Plain text for copy and search: the title, then one line per row. */
export function checklistText(title: string, rows: readonly ChecklistRow[], picks: Readonly<Record<string, ChecklistPick>> = {}, columns: readonly string[] = []) {
  const one = columns.length === 1
  const lines = rows.map(r => {
    const p = picks[r.id]
    if (one) return `- [${p ? 'x' : ' '}] ${r.label}`
    return p ? `- ${r.label}: ${p.col}` : `- ${r.label}`
  })
  return [title.trim(), ...lines].filter(Boolean).join('\n')
}
