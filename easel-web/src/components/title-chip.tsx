/**
 * The easel's title, top left, editable in place. The chip sizes itself to
 * the text with a hidden mirror span (no `field-sizing` in WebKit yet).
 */
import { useLayoutEffect, useRef, useState } from 'react'
import { DEFAULT_TITLE } from '../doc/easel-doc'

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

export function TitleChip({
  title,
  onChange,
}: {
  title: string
  onChange: (title: string) => void
}) {
  const [draft, setDraft] = useState<string | null>(null)
  const input = useRef<HTMLInputElement>(null)
  const mirror = useRef<HTMLSpanElement>(null)
  const shown = draft ?? title

  useLayoutEffect(() => {
    const el = input.current
    const m = mirror.current
    if (!el || !m) return
    m.textContent = shown || DEFAULT_TITLE
    el.style.width = `${Math.min(420, m.offsetWidth + 2)}px`
  }, [shown])

  const commit = () => {
    if (draft !== null) onChange(draft.trim() || DEFAULT_TITLE)
    setDraft(null)
  }

  return (
    <div className="easel-card easel-title" onPointerDown={stop}>
      <input
        ref={input}
        aria-label="Easel title"
        value={shown}
        placeholder={DEFAULT_TITLE}
        spellCheck={false}
        onChange={e => setDraft(e.target.value)}
        onFocus={() => setDraft(title)}
        onBlur={commit}
        onKeyDown={e => {
          if (e.key === 'Enter') e.currentTarget.blur()
          if (e.key === 'Escape') {
            setDraft(null)
            e.currentTarget.blur()
          }
        }}
        className="easel-title-input"
      />
      <span ref={mirror} className="easel-title-mirror" aria-hidden="true" />
    </div>
  )
}
