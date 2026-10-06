/**
 * The checklist (RSVP) card: a title, column headers with live counts, and
 * one row per person or task with a box per column. One click on a box picks
 * it (or clears it) for anyone who can edit — selected or not, no edit mode;
 * the title, labels and edges still drag the card. Double-click a title,
 * label or column to rename it; while one is open, a click on another moves
 * the editor there. Model and rules: `../checklist.ts` — the same card for a
 * note in the checklist view (its text is the list) and the legacy shape.
 */
import { memo, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent, type PointerEvent } from 'react'
import { Plus, Trash2, X } from 'lucide-react'
import {
  CHECKLIST_MIN,
  MAX_COLUMNS,
  MAX_ROWS,
  MAX_COLUMN_LABEL,
  MAX_ROW_LABEL,
  addColumn,
  addRow,
  pickedBy,
  removeColumn,
  removeRow,
  renameColumn,
  setRowLabel,
  setTitle,
  tally,
  togglePick,
} from '../checklist'
import { contrastInk, inkOn, paperOf, strokeOf } from '../colors'
import { countRender } from '../debug'
import { INIT } from '../doc'
import { isNamedColor, type ChecklistPick, type ChecklistRow, type Shape } from '../types'
import { useBoard } from './context'
import { cn, useMountFocus } from './ui'
import './checklist.css'

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

/** One-line field over a title, label or column name; keys are the caller's. */
function Field({
  label,
  value,
  placeholder,
  max,
  onChange,
  onKey,
  onDone,
  onLeave,
  className,
  style,
}: {
  label: string
  value: string
  placeholder: string
  max: number
  onChange: (next: string) => void
  onKey: (e: KeyboardEvent<HTMLInputElement>, value: string) => boolean
  onDone: (value: string) => void
  /** The editor moved elsewhere without finishing here (no blur arrives). */
  onLeave?: (value: string) => void
  className?: string
  style?: CSSProperties
}) {
  const ref = useRef<HTMLInputElement>(null)
  const done = useRef(false)
  const latest = useRef(value)
  const leave = useRef(onLeave)
  useLayoutEffect(() => {
    leave.current = onLeave
  })
  useMountFocus(ref)
  useEffect(() => {
    // The press that opened the field may hand focus back to the board as
    // its default action; take it back once that has settled.
    const timer = setTimeout(() => {
      if (!done.current && document.activeElement !== ref.current) ref.current?.focus({ preventScroll: true })
    }, 30)
    return () => {
      clearTimeout(timer)
      if (!done.current) leave.current?.(latest.current)
      done.current = true
    }
  }, [])
  const finish = () => {
    if (done.current) return
    done.current = true
    onDone(ref.current?.value ?? value)
  }
  /** A blur that lasts: the field is left (not the opening press settling). */
  const blurred = () =>
    setTimeout(() => {
      if (!done.current && document.activeElement !== ref.current) finish()
    }, 80)
  return (
    <input
      ref={ref}
      aria-label={label}
      defaultValue={value}
      placeholder={placeholder}
      maxLength={max}
      spellCheck={false}
      onChange={e => {
        latest.current = e.currentTarget.value
        onChange(e.currentTarget.value)
      }}
      onBlur={blurred}
      onKeyDown={e => {
        e.stopPropagation()
        if (onKey(e, e.currentTarget.value)) {
          e.preventDefault()
          done.current = true
          return
        }
        if (e.key === 'Enter' || e.key === 'Escape') {
          e.preventDefault()
          finish()
        }
      }}
      onPointerDown={stop}
      onDoubleClick={stop}
      className={cn('cl-field', className)}
      style={style}
    />
  )
}

/** The box itself: crisp, with a short check animation when it turns on. */
function Box({ on }: { on: boolean }) {
  return (
    <span className="cl-box" data-on={on || undefined} aria-hidden="true">
      {on && (
        <svg viewBox="0 0 16 16" className="cl-check">
          <path d="M3.6 8.4 6.6 11.3 12.4 4.9" />
        </svg>
      )}
    </span>
  )
}

interface CellProps {
  row: ChecklistRow
  col: string
  pick: ChecklistPick | undefined
  readOnly: boolean
  onToggle: () => void
  onKey: (e: KeyboardEvent<HTMLButtonElement>) => void
}

function Cell({ row, col, pick, readOnly, onToggle, onKey }: CellProps) {
  const on = pick?.col === col
  const [tip, setTip] = useState<string | null>(null)
  const name = row.label.trim() || 'Untitled row'
  return (
    <span className="cl-cell" role="cell">
      <button
        type="button"
        role="checkbox"
        aria-checked={on}
        aria-disabled={readOnly || undefined}
        aria-label={`${name}: ${col}${on && pick?.by ? ` (${pickedBy(pick)})` : ''}`}
        data-cell=""
        data-row={row.id}
        data-col={col}
        className="cl-hit"
        tabIndex={0}
        onPointerDown={readOnly ? undefined : stop}
        onDoubleClick={stop}
        onPointerEnter={() => setTip(on && pick ? pickedBy(pick) : null)}
        onPointerLeave={() => setTip(null)}
        onClick={e => {
          // The second click of a double-click is not a second toggle.
          if (readOnly || e.detail > 1) return
          e.stopPropagation()
          setTip(null)
          onToggle()
        }}
        onKeyDown={onKey}
      >
        <Box on={on} />
      </button>
      {tip && (
        <span className="cl-tip" role="presentation">
          {tip}
        </span>
      )}
    </span>
  )
}

/** Where the editor is: `part:cl-title`, `part:cl-row:<id>`, `part:cl-col:<index>`. */
function editTarget(field: string | null) {
  if (!field?.startsWith('part:cl-')) return null
  const part = field.slice(5)
  if (part === 'cl-title') return { kind: 'title' as const }
  if (part.startsWith('cl-row:')) return { kind: 'row' as const, id: part.slice(7) }
  if (part.startsWith('cl-col:')) return { kind: 'col' as const, index: Number(part.slice(7)) }
  return null
}

export const ChecklistView = memo(function ChecklistView({
  shape,
  editing,
  selected,
}: {
  shape: Shape
  /** The board's edit field when this card is being edited, else null. */
  editing: string | null
  selected: boolean
}) {
  countRender('shapeRenders')
  const board = useBoard()
  const { store, me, readOnly } = board
  const columns = shape.columns ?? []
  const rows = shape.rows ?? []
  const picks = shape.picks ?? {}
  const counts = tally(columns, rows, picks)
  const single = columns.length === 1
  const target = editTarget(editing)
  const accent = strokeOf(shape.color)
  const check = isNamedColor(shape.color) ? 'var(--surface)' : contrastInk(shape.color)
  const band = shape.color === 'white' ? 'var(--surface-2)' : paperOf(shape.color)
  const bandInk = shape.color === 'white' ? 'var(--ink)' : inkOn(shape.color)
  const grid = single ? '28px minmax(0, 1fr)' : `minmax(0, 1fr) repeat(${columns.length}, var(--cl-col))`
  const done = Object.keys(picks).length

  // ---- height follows the content (written by editors, outside undo) ----------
  const card = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    const el = card.current
    if (!el || readOnly || typeof ResizeObserver === 'undefined') return
    let timer: ReturnType<typeof setTimeout> | null = null
    const measure = () => {
      if (timer) clearTimeout(timer)
      timer = setTimeout(() => {
        const h = Math.max(CHECKLIST_MIN.h, Math.ceil(el.offsetHeight))
        const stored = store.get(shape.id)?.h
        if (stored !== undefined && Math.abs(h - stored) > 1) store.update(shape.id, { h }, INIT, false)
      }, 120)
    }
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    return () => {
      ro.disconnect()
      if (timer) clearTimeout(timer)
    }
  }, [store, shape.id, readOnly])

  // ---- editing -----------------------------------------------------------------
  /** A row this card added and is naming: left empty, it goes again. */
  const fresh = useRef<string | null>(null)
  const leaveFresh = (unless?: string) => {
    const id = fresh.current
    if (!id || id === unless) return
    fresh.current = null
    const row = store.live(shape.id)?.rows?.find(r => r.id === id)
    if (row && !row.label.trim()) removeRow(store, shape.id, id)
  }
  const edit = (part: string | null) => {
    leaveFresh(part?.startsWith('cl-row:') ? part.slice(7) : undefined)
    board.editPart(shape.id, part)
  }
  const finishRow = () => leaveFresh()
  const newRowAfter = (after: string | null) => {
    const id = addRow(store, shape.id, after)
    if (!id) return
    fresh.current = id
    board.editPart(shape.id, `cl-row:${id}`)
  }
  // A double-click on an empty card starts its first row.
  const startEmpty = editing === 'part:cl-new'
  useEffect(() => {
    if (startEmpty && !readOnly) newRowAfter(rows[rows.length - 1]?.id ?? null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [startEmpty])
  /** While the card is open, one click on another name moves the editor there. */
  const onCardDown = (e: PointerEvent) => {
    if (readOnly || !editing || e.button !== 0) return
    const part = (e.target as Element).closest('[data-part]')?.getAttribute('data-part')
    if (!part || !/^cl-(title|row:|col:)/.test(part) || `part:${part}` === editing) return
    e.stopPropagation()
    e.preventDefault()
    edit(part)
  }

  // ---- keyboard between boxes ----------------------------------------------------
  const cellKey = (ri: number, ci: number) => (e: KeyboardEvent<HTMLButtonElement>) => {
    const move = (r: number, c: number) => {
      const el = e.currentTarget.closest('[data-kind="checklist"]')?.querySelector<HTMLButtonElement>(
        `[data-row="${CSS.escape(rows[r]?.id ?? '')}"][data-col="${CSS.escape(columns[c] ?? '')}"]`
      )
      if (el) el.focus({ preventScroll: true })
    }
    if (e.key === ' ' || e.key === 'Enter') {
      // The button's own activation (a click) toggles it; the board must not
      // also take the key (Space pans, Enter edits).
      e.stopPropagation()
      return
    }
    const step: Record<string, [number, number]> = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] }
    const d = step[e.key]
    if (d) {
      e.preventDefault()
      e.stopPropagation()
      move(Math.min(rows.length - 1, Math.max(0, ri + d[0])), Math.min(columns.length - 1, Math.max(0, ci + d[1])))
    }
    if (e.key === 'Escape') {
      e.stopPropagation()
      ;(e.currentTarget.closest('[role="application"]') as HTMLElement | null)?.focus({ preventScroll: true })
    }
  }

  const titleText = shape.title.trim()
  return (
    <div
      ref={card}
      data-id={shape.id}
      data-kind="checklist"
      role="table"
      aria-label={titleText ? `Checklist: ${titleText}` : 'Checklist'}
      aria-readonly={readOnly || undefined}
      onPointerDown={onCardDown}
      className={cn('cl-card absolute left-0 top-0', single && 'cl-single', selected && 'cl-selected')}
      style={
        {
          width: shape.w,
          minHeight: CHECKLIST_MIN.h,
          transform: `translate(${shape.x}px, ${shape.y}px)`,
          '--cl-accent': accent,
          '--cl-check': check,
          '--cl-band': band,
          '--cl-band-ink': bandInk,
          '--cl-grid': grid,
        } as CSSProperties
      }
    >
      <div>
        <div className="cl-band">
          <div className="cl-title-row" data-part="cl-title">
            {target?.kind === 'title' ? (
              <Field
                label="Checklist title"
                value={shape.title}
                placeholder="Title"
                max={500}
                onChange={title => setTitle(store, shape.id, title)}
                onKey={e => {
                  if (e.key !== 'Enter' && e.key !== 'Tab') return false
                  // Enter goes on to the first row: naming people in one go.
                  if (rows[0]) edit(`cl-row:${rows[0].id}`)
                  else newRowAfter(null)
                  return true
                }}
                onDone={() => board.endEdit(shape.id)}
                className="cl-title-field"
              />
            ) : (
              <span className={cn('cl-title', !titleText && 'cl-muted')}>{titleText || 'Untitled'}</span>
            )}
            {single && rows.length > 0 && (
              <span className="cl-count" aria-label={`${done} of ${rows.length} done`}>
                {done}/{rows.length}
              </span>
            )}
          </div>
          {!single && (
            <div className="cl-grid cl-heads" role="row">
              <span role="columnheader" className="cl-head-spacer">
                <span className="sr-only">Name</span>
              </span>
              {columns.map((c, i) => (
                <span
                  key={`${i}:${c}`}
                  role="columnheader"
                  className="cl-head"
                  data-part={`cl-col:${i}`}
                  aria-label={`${c}, ${counts[c] ?? 0}`}
                >
                  <span className="cl-head-label">{c}</span>
                  <span className={cn('cl-head-count', (counts[c] ?? 0) > 0 && 'cl-head-count-on')}>{counts[c] ?? 0}</span>
                  {target?.kind === 'col' && target.index === i && (
                    <span className="cl-col-edit" onPointerDown={stop} onDoubleClick={stop}>
                      <Field
                        label={`Rename column ${c}`}
                        value={c}
                        placeholder="Column"
                        max={MAX_COLUMN_LABEL}
                        onChange={() => {}}
                        onKey={(e, value) => {
                          if (e.key !== 'Enter' && e.key !== 'Tab') return false
                          renameColumn(store, shape.id, i, value)
                          if (e.key === 'Tab' && columns[i + 1] !== undefined) edit(`cl-col:${i + 1}`)
                          else board.endEdit(shape.id)
                          return true
                        }}
                        onDone={value => {
                          renameColumn(store, shape.id, i, value)
                          board.endEdit(shape.id)
                        }}
                        onLeave={value => renameColumn(store, shape.id, i, value)}
                        className="cl-col-field"
                      />
                      {columns.length > 1 && (
                        <button
                          type="button"
                          aria-label={`Remove column ${c}`}
                          className="cl-icon-btn"
                          onPointerDown={e => {
                            // Before the field's blur ends the edit.
                            e.preventDefault()
                            e.stopPropagation()
                            removeColumn(store, shape.id, i)
                            board.endEdit(shape.id)
                          }}
                        >
                          <Trash2 className="h-3.5 w-3.5" aria-hidden="true" />
                        </button>
                      )}
                    </span>
                  )}
                </span>
              ))}
            </div>
          )}
        </div>
        <div role="rowgroup" className="cl-rows">
          {rows.map((row, ri) => {
            const pick = picks[row.id]
            const editingRow = target?.kind === 'row' && target.id === row.id
            const label = (
              <span
                role="rowheader"
                className="cl-label"
                data-part={`cl-row:${row.id}`}
              >
                {editingRow ? (
                  <Field
                    label="Row label"
                    value={row.label}
                    placeholder={single ? 'To do' : 'Name'}
                    max={MAX_ROW_LABEL}
                    onChange={next => setRowLabel(store, shape.id, row.id, next)}
                    onKey={(e, value) => {
                      if (e.key === 'Enter') {
                        if (!value.trim()) {
                          if (fresh.current !== row.id) fresh.current = row.id
                          finishRow()
                          board.endEdit(shape.id)
                        } else {
                          fresh.current = null
                          newRowAfter(row.id)
                        }
                        return true
                      }
                      if (e.key === 'Backspace' && !value) {
                        const prev = rows[ri - 1]
                        removeRow(store, shape.id, row.id)
                        fresh.current = null
                        edit(prev ? `cl-row:${prev.id}` : 'cl-title')
                        return true
                      }
                      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
                        const next = rows[ri + (e.key === 'ArrowUp' ? -1 : 1)]
                        if (next) edit(`cl-row:${next.id}`)
                        else if (e.key === 'ArrowUp') edit('cl-title')
                        else return false
                        return true
                      }
                      return false
                    }}
                    onDone={() => {
                      finishRow()
                      board.endEdit(shape.id)
                    }}
                    className="cl-label-field"
                  />
                ) : (
                  <>
                    <span className={cn('cl-label-text', !row.label.trim() && 'cl-muted')}>{row.label.trim() || 'Untitled'}</span>
                    {selected && !readOnly && (
                      <button
                        type="button"
                        aria-label={`Remove ${row.label.trim() || 'this row'}`}
                        className="cl-icon-btn cl-row-remove"
                        onPointerDown={stop}
                        onDoubleClick={stop}
                        onClick={e => {
                          e.stopPropagation()
                          removeRow(store, shape.id, row.id)
                        }}
                      >
                        <X className="h-3 w-3" aria-hidden="true" />
                      </button>
                    )}
                  </>
                )}
              </span>
            )
            const cells = columns.map((col, ci) => (
              <Cell
                key={`${ci}:${col}`}
                row={row}
                col={col}
                pick={pick}
                readOnly={readOnly}
                onToggle={() => togglePick(store, shape.id, row.id, col, me, 'local', row.label)}
                onKey={cellKey(ri, ci)}
              />
            ))
            return (
              <div key={row.id} role="row" className={cn('cl-grid cl-row', pick && 'cl-row-picked')}>
                {single ? (
                  <>
                    {cells}
                    {label}
                  </>
                ) : (
                  <>
                    {label}
                    {cells}
                  </>
                )}
              </div>
            )
          })}
          {rows.length === 0 && (
            <p className="cl-empty" data-part="cl-empty">
              {readOnly ? 'Nothing here yet.' : 'Double-click to add names.'}
            </p>
          )}
        </div>
        {!readOnly && (
          <div className="cl-foot" aria-label="Checklist actions">
            {rows.length < MAX_ROWS && (
              <button
                type="button"
                className="cl-add"
                onPointerDown={stop}
                onDoubleClick={stop}
                onClick={e => {
                  e.stopPropagation()
                  newRowAfter(rows[rows.length - 1]?.id ?? null)
                }}
              >
                <Plus className="h-3.5 w-3.5" aria-hidden="true" />
                {single ? 'Add item' : 'Add row'}
              </button>
            )}
            {columns.length < MAX_COLUMNS && (
              <button
                type="button"
                className="cl-add cl-add-col"
                onPointerDown={stop}
                onDoubleClick={stop}
                onClick={e => {
                  e.stopPropagation()
                  const i = addColumn(store, shape.id)
                  if (i >= 0) edit(`cl-col:${i}`)
                }}
              >
                <Plus className="h-3.5 w-3.5" aria-hidden="true" />
                Column
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  )
})

/** The edit field a double-click on part of a checklist opens. */
export function checklistEditField(part: string | null): `part:${string}` {
  if (part === 'cl-empty') return 'part:cl-new'
  return `part:${part && part.startsWith('cl-') ? part : 'cl-title'}`
}
