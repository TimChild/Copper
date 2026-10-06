/**
 * A checklist kept in a note's own text: a `type:"sticky"` with
 * `view:"checklist"`, whose body is the markdown every Copper already draws as
 * a note with clickable task boxes.
 *
 *   ### Going            the title: the first #, ## or ### heading
 *   - [ ] Ann            a row with no pick
 *   - [x] Ada Lovelace   one column: ticked is the pick
 *   - [x] Bob · No       several columns (`columns` on the shape): the suffix names the pick
 *
 * The text is the truth. A ticked line with no suffix, or with one naming no
 * column, picks the first column (an older Copper ticked it); an unticked line
 * has no pick. Who picked a row, and when, sit beside it on the shape
 * (`who:<label key>` → `{col, by, byId, at}`) and count only while they agree
 * with the text. Every write changes only the characters of its own line —
 * the box, the label or the suffix — so ticks on different rows from any two
 * Coppers, old or new, merge.
 */
import * as Y from 'yjs'
import { textSplice } from './text-diff'

export const VIEW_CHECKLIST = 'checklist'
export const WHO_PREFIX = 'who:'
/** The one column of a note shown as a checklist without columns of its own. */
export const TICK_COLUMN = 'Done'

const HEADING = /^(#{1,3})(\s+)(.*?)\s*#*\s*$/
/** `- [ ] label`, `* [x] label`, `1. [ ] label`; a doubled box (`[xx]`, two ticks merged) still reads. */
const TASK_LINE = /^(\s*(?:[-*]|\d{1,9}[.)])\s+)\[([ xX]{1,3})\](?:([ \t]+)(.*))?$/
const SUFFIX = /\s+·\s+([^·]+?)\s*$/

const fold = (s: string) => s.trim().toLowerCase()

/** The key of a row's who-picked entry: its label, trimmed, any case, single spaces. */
export const rowKey = (label: string) => label.trim().toLowerCase().replace(/\s+/g, ' ')
export const whoKey = (label: string) => WHO_PREFIX + rowKey(label)

/** One line, as a label or a title can only be. */
export const oneLine = (s: string) => s.replace(/[\r\n]+/g, ' ')

export interface TextRow {
  /** Order among the task lines, from 0. */
  index: number
  label: string
  /** The box has a tick in it. */
  ticked: boolean
  /** The column a ` · Column` suffix names, if it names one. */
  suffix: string | null
  /** The row's pick: the suffix, or the first column when ticked without one; null unticked. */
  pick: string | null
  /** Offsets in the whole text. */
  lineStart: number
  lineEnd: number
  /** Inside the brackets. */
  boxStart: number
  boxEnd: number
  labelStart: number
  /** Where the label ends and the suffix (or trailing space) begins. */
  labelEnd: number
  /** Something (a space at least) follows the box. */
  hasBody: boolean
}

export interface ParsedChecklist {
  title: string
  /** The title's heading: where its words sit and where its line ends. */
  heading: { start: number; end: number; lineEnd: number } | null
  rows: TextRow[]
}

/** Read the title and the rows out of a note's text. Never throws. */
export function parseChecklistText(text: string, columns: readonly string[]): ParsedChecklist {
  const out: ParsedChecklist = { title: '', heading: null, rows: [] }
  const byFold = new Map(columns.map(c => [fold(c), c] as const))
  let at = 0
  for (const line of text.split('\n')) {
    const start = at
    const end = start + line.length
    at = end + 1
    const task = TASK_LINE.exec(line)
    if (task) {
      const lead = task[1] ?? ''
      const box = task[2] ?? ' '
      const space = task[3] ?? ''
      const body = (task[4] ?? '').trimEnd()
      const boxStart = start + lead.length + 1
      const boxEnd = boxStart + box.length
      const labelStart = boxEnd + 1 + space.length
      let label = body
      let suffix: string | null = null
      const m = SUFFIX.exec(body)
      const named = m ? byFold.get(fold(m[1] ?? '')) : undefined
      if (m && named !== undefined) {
        label = body.slice(0, m.index)
        suffix = named
      }
      const ticked = /x/i.test(box)
      out.rows.push({
        index: out.rows.length,
        label,
        ticked,
        suffix,
        pick: ticked ? (suffix ?? columns[0] ?? null) : null,
        lineStart: start,
        lineEnd: end,
        boxStart,
        boxEnd,
        labelStart,
        labelEnd: labelStart + label.length,
        hasBody: task[3] !== undefined,
      })
      continue
    }
    if (!out.heading) {
      const h = HEADING.exec(line)
      if (h) {
        const titleStart = start + (h[1] ?? '').length + (h[2] ?? '').length
        out.title = h[3] ?? ''
        out.heading = { start: titleStart, end: titleStart + out.title.length, lineEnd: end }
      }
    }
  }
  return out
}

/** A row's line as this page writes it. */
export function rowLine(label: string, pick: string | null, columns: readonly string[]): string {
  const tail = pick && columns.length > 1 ? ` · ${pick}` : ''
  return `- [${pick ? 'x' : ' '}] ${oneLine(label)}${tail}`
}

/** A whole checklist note: the title as a heading, then one line per row. */
export function checklistMarkdown(title: string, rows: readonly { label: string; pick: string | null }[], columns: readonly string[]): string {
  const lines = rows.map(r => rowLine(r.label, r.pick, columns))
  if (title.trim()) lines.unshift(`### ${oneLine(title).trim()}`)
  return lines.join('\n')
}

// ---- writes on the note's Y.Text (inside a transaction) -------------------------

/** The note's body as a Y.Text (a plain string body becomes one). */
export function noteText(m: Y.Map<unknown>): Y.Text {
  const v = m.get('text')
  if (v instanceof Y.Text) return v
  const t = new Y.Text(typeof v === 'string' ? v : '')
  m.set('text', t)
  return t
}

function splice(t: Y.Text, index: number, remove: number, insert: string) {
  if (remove) t.delete(index, remove)
  if (insert) t.insert(index, insert)
}

/** Replace `prev` (at `index`) by `next`, touching only the characters that differ. */
function spliceWithin(t: Y.Text, index: number, prev: string, next: string) {
  const d = textSplice(prev, next)
  splice(t, index + d.index, d.remove, d.insert)
}

/**
 * Set (or with null clear) one row's pick: its box and its suffix change,
 * nothing else on the board's text does. `row` is from a parse of the text as
 * it is now.
 */
export function writeRowPick(t: Y.Text, row: TextRow, col: string | null, columns: readonly string[]) {
  const text = t.toString()
  const wantTail = col && columns.length > 1 ? ` · ${col}` : ''
  const tail = text.slice(row.labelEnd, row.lineEnd)
  // Right to left, so the box's offset still holds after the tail changes.
  if (tail.trimEnd() !== wantTail) splice(t, row.labelEnd, tail.length, wantTail)
  const wantBox = col ? 'x' : ' '
  if (text.slice(row.boxStart, row.boxEnd) !== wantBox) splice(t, row.boxStart, row.boxEnd - row.boxStart, wantBox)
}

/** Rename one row in place: its box and suffix stay. */
export function writeRowLabel(t: Y.Text, row: TextRow, label: string) {
  const next = oneLine(label)
  if (next === row.label) return
  if (!row.hasBody) {
    if (next) t.insert(row.boxEnd + 1, ` ${next}`)
    return
  }
  spliceWithin(t, row.labelStart, row.label, next)
}

/**
 * A new row's line after row `after` (null: after the last row, else under the
 * title, else at the end). Its index among the rows.
 */
export function insertRowLine(t: Y.Text, parsed: ParsedChecklist, after: number | null, line: string): number {
  const ref = after !== null ? parsed.rows[after] : parsed.rows[parsed.rows.length - 1]
  if (ref) {
    t.insert(ref.lineEnd, `\n${line}`)
    return ref.index + 1
  }
  if (parsed.heading) {
    t.insert(parsed.heading.lineEnd, `\n${line}`)
    return 0
  }
  const text = t.toString()
  if (!text) t.insert(0, line)
  else t.insert(text.length, text.endsWith('\n') ? line : `\n${line}`)
  return 0
}

/** Remove a row's line (and one line break with it). */
export function removeRowLine(t: Y.Text, row: TextRow) {
  const length = t.toString().length
  if (row.lineEnd < length) t.delete(row.lineStart, row.lineEnd - row.lineStart + 1)
  else if (row.lineStart > 0) t.delete(row.lineStart - 1, row.lineEnd - row.lineStart + 1)
  else if (row.lineEnd > 0) t.delete(0, row.lineEnd)
}

/** The title: the first heading's words, or a new `###` heading on top. */
export function writeTitle(t: Y.Text, parsed: ParsedChecklist, title: string) {
  const next = oneLine(title)
  if (parsed.heading) {
    spliceWithin(t, parsed.heading.start, parsed.title, next)
    return
  }
  if (!next.trim()) return
  t.insert(0, t.length ? `### ${next}\n` : `### ${next}`)
}

/** Replace every row with `next` (one line each), where the rows were (or under the title). */
export function replaceRows(t: Y.Text, parsed: ParsedChecklist, next: readonly string[]) {
  const before = t.toString()
  const lines = before.split('\n')
  const isRow = new Set<number>()
  let firstRowLine = -1
  let headingLine = -1
  let n = 0
  for (let i = 0, at = 0; i < lines.length; i++) {
    const start = at
    at += (lines[i] ?? '').length + 1
    if (parsed.rows[n]?.lineStart === start) {
      isRow.add(i)
      if (firstRowLine < 0) firstRowLine = i
      n++
    } else if (parsed.heading && start <= parsed.heading.start && parsed.heading.lineEnd <= at) headingLine = i
  }
  const out: string[] = []
  const insertAt = firstRowLine >= 0 ? firstRowLine : headingLine >= 0 ? headingLine + 1 : lines.length
  for (let i = 0; i <= lines.length; i++) {
    if (i === insertAt) out.push(...next)
    if (i < lines.length && !isRow.has(i)) out.push(lines[i] ?? '')
  }
  // A note that was empty (or only rows) does not keep a blank first line.
  while (out.length > 1 && out[0] === '' && before === '') out.shift()
  const after = out.join('\n')
  spliceWithin(t, 0, before, after)
}
