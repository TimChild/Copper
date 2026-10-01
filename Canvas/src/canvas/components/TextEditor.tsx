/**
 * In-place editor for sticky and text bodies: a plain textarea over the
 * markdown source (Y.Text), with the few markdown keys people expect —
 * Enter continues a list, Tab nests it, ⌘B / ⌘I wrap the selection. Remote
 * edits arriving mid-typing keep the caret where it was.
 */
import { useEffect, useLayoutEffect, useRef, type CSSProperties, type KeyboardEvent } from 'react'
import { continueList } from '../markdown-lite'
import { shiftCaret } from '../text-diff'
import { cn } from './ui'

export interface TextEditorProps {
  value: string
  onChange: (next: string) => void
  onDone: () => void
  /** ⌘Enter / ⇧⌘Enter. */
  onSibling?: (dir: 'right' | 'down') => void
  placeholder?: string
  className?: string
  style?: CSSProperties
  label: string
  /** Markdown helpers (lists, bold); off for plain fields. */
  markdown?: boolean
  /** Grow with the content instead of scrolling. */
  autoGrow?: boolean
  onHeight?: (px: number) => void
  selectAll?: boolean
}

function wrap(el: HTMLTextAreaElement, mark: string): string {
  const { selectionStart: a, selectionEnd: b, value } = el
  const inner = value.slice(a, b)
  const already = value.slice(a - mark.length, a) === mark && value.slice(b, b + mark.length) === mark
  if (already) {
    const next = value.slice(0, a - mark.length) + inner + value.slice(b + mark.length)
    requestAnimationFrame(() => el.setSelectionRange(a - mark.length, b - mark.length))
    return next
  }
  const next = value.slice(0, a) + mark + inner + mark + value.slice(b)
  requestAnimationFrame(() => el.setSelectionRange(a + mark.length, b + mark.length))
  return next
}

export function TextEditor({
  value,
  onChange,
  onDone,
  onSibling,
  placeholder,
  className,
  style,
  label,
  markdown = true,
  autoGrow = false,
  onHeight,
  selectAll = false,
}: TextEditorProps) {
  const ref = useRef<HTMLTextAreaElement>(null)
  /** What this editor last wrote; a `value` equal to it is our own echo. */
  const mine = useRef(value)
  const shown = useRef(value)

  // Focus once, on mount, and again after the pointer gesture that opened the
  // editor settles (its default action would move focus back to the board).
  useEffect(() => {
    const focus = () => {
      const el = ref.current
      if (!el || document.activeElement === el) return
      el.focus({ preventScroll: true })
      if (selectAll) el.select()
      else el.setSelectionRange(el.value.length, el.value.length)
    }
    focus()
    const frame = requestAnimationFrame(focus)
    const timer = setTimeout(focus, 30)
    return () => {
      cancelAnimationFrame(frame)
      clearTimeout(timer)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // A peer's edit landed: put the caret back where the text it was in went.
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    if (value !== shown.current && value !== mine.current && document.activeElement === el) {
      const a = shiftCaret(shown.current, value, el.selectionStart)
      const b = shiftCaret(shown.current, value, el.selectionEnd)
      el.value = value
      el.setSelectionRange(a, b)
    }
    shown.current = value
  }, [value])

  useLayoutEffect(() => {
    const el = ref.current
    if (!el || !autoGrow) return
    el.style.height = '0px'
    const h = el.scrollHeight
    el.style.height = `${h}px`
    onHeight?.(h)
  })

  const commit = (next: string) => {
    mine.current = next
    shown.current = next
    onChange(next)
  }

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    const el = e.currentTarget
    e.stopPropagation()
    const mod = e.metaKey || e.ctrlKey
    if (e.key === 'Escape') {
      e.preventDefault()
      onDone()
      return
    }
    if (mod && e.key === 'Enter') {
      e.preventDefault()
      if (onSibling) onSibling(e.shiftKey ? 'down' : 'right')
      else onDone()
      return
    }
    if (!markdown) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault()
        onDone()
      }
      return
    }
    if (mod && !e.shiftKey && !e.altKey && (e.key === 'b' || e.key === 'i')) {
      e.preventDefault()
      const next = wrap(el, e.key === 'b' ? '**' : '*')
      el.value = next
      commit(next)
      return
    }
    const { selectionStart: a, selectionEnd: b, value: text } = el
    const lineStart = text.lastIndexOf('\n', a - 1) + 1
    const lineEndRaw = text.indexOf('\n', a)
    const lineEnd = lineEndRaw === -1 ? text.length : lineEndRaw
    const line = text.slice(lineStart, lineEnd)
    if (e.key === 'Enter' && !e.shiftKey && a === b && a === lineEnd) {
      const cont = continueList(line)
      if (!cont) return
      e.preventDefault()
      let next: string
      let caret: number
      if ('clear' in cont) {
        next = text.slice(0, lineStart) + text.slice(lineEnd)
        caret = lineStart
      } else {
        next = text.slice(0, a) + cont.insert + text.slice(b)
        caret = a + cont.insert.length
      }
      el.value = next
      el.setSelectionRange(caret, caret)
      commit(next)
      return
    }
    if (e.key === 'Tab') {
      e.preventDefault()
      const isItem = /^\s*([-*]|\d{1,9}[.)])\s/.test(line)
      if (e.shiftKey) {
        const cut = line.startsWith('  ') ? 2 : line.startsWith('\t') || line.startsWith(' ') ? 1 : 0
        if (!cut) return
        const next = text.slice(0, lineStart) + line.slice(cut) + text.slice(lineEnd)
        el.value = next
        el.setSelectionRange(Math.max(lineStart, a - cut), Math.max(lineStart, b - cut))
        commit(next)
        return
      }
      const next = isItem ? text.slice(0, lineStart) + '  ' + text.slice(lineStart) : text.slice(0, a) + '  ' + text.slice(b)
      el.value = next
      el.setSelectionRange(a + 2, isItem ? b + 2 : a + 2)
      commit(next)
    }
  }

  return (
    <textarea
      ref={ref}
      aria-label={label}
      defaultValue={value}
      placeholder={placeholder}
      spellCheck
      onChange={e => commit(e.currentTarget.value)}
      onKeyDown={onKeyDown}
      onBlur={onDone}
      onPointerDown={e => e.stopPropagation()}
      onDoubleClick={e => e.stopPropagation()}
      onWheel={e => {
        if (!autoGrow) e.stopPropagation()
      }}
      className={cn(
        'block w-full resize-none border-0 bg-transparent p-0 outline-none placeholder:text-current placeholder:opacity-45',
        className
      )}
      style={style}
    />
  )
}
