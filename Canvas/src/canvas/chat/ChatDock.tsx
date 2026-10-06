/**
 * The board with the chat panel beside it. Wide windows dock the panel on
 * the right and the board gives up that width (its own resize observer keeps
 * the view honest); narrow ones float it over the board's right edge.
 * The panel's width can be dragged (260–520 px) and is kept for this page.
 */
import { useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from 'react'
import { ChatPanel } from './ChatPanel'
import { chat } from './index'

const MIN_W = 260
const MAX_W = 520
const DEFAULT_W = 320
/** Below this window width the panel floats over the board. */
const DOCK_MIN = 960

let rememberedWidth = DEFAULT_W

export function ChatDock({ children }: { children: ReactNode }) {
  useSyncExternalStore(chat.subscribe, chat.getVersion)
  const open = chat.available && chat.config.open
  const [width, setWidth] = useState(rememberedWidth)
  const [narrow, setNarrow] = useState(() => typeof window !== 'undefined' && window.innerWidth < DOCK_MIN)
  const drag = useRef<{ x: number; w: number } | null>(null)

  // C shows or hides the panel, from the board (never from a field, a dialog or with a modifier).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey || e.repeat) return
      if (e.key !== 'c' && e.key !== 'C') return
      if (!chat.available) return
      const t = e.target
      if (t instanceof HTMLElement && (t.isContentEditable || t.closest('input, textarea, select, [role="dialog"]'))) return
      e.preventDefault()
      chat.toggle()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  useEffect(() => {
    const onResize = () => setNarrow(window.innerWidth < DOCK_MIN)
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [])

  const w = narrow ? Math.min(width, Math.max(MIN_W, (typeof window !== 'undefined' ? window.innerWidth : 800) - 56)) : width

  return (
    <div className="relative flex h-full w-full overflow-hidden">
      <div className="relative h-full min-w-0 flex-1">{children}</div>
      {open && (
        <div
          className={
            narrow
              ? 'absolute bottom-[76px] right-3 top-[60px] z-40 overflow-hidden rounded-[14px] border border-line shadow-lift'
              : 'relative h-full shrink-0 border-l border-line'
          }
          style={{ width: w }}
          // Keys, copy and paste inside the chat are the chat's: the board's
          // window listeners (delete, nudge, ⌘A, shape clipboard) never see them.
          onKeyDown={e => e.stopPropagation()}
          onCopy={e => e.stopPropagation()}
          onCut={e => e.stopPropagation()}
          onPaste={e => e.stopPropagation()}
        >
          {!narrow && (
            <div
              role="separator"
              aria-orientation="vertical"
              aria-label="Resize chat"
              aria-valuemin={MIN_W}
              aria-valuemax={MAX_W}
              aria-valuenow={w}
              tabIndex={0}
              className="group absolute -left-[3px] top-0 z-10 h-full w-[6px] cursor-col-resize outline-none"
              onPointerDown={e => {
                e.preventDefault()
                e.stopPropagation()
                e.currentTarget.setPointerCapture(e.pointerId)
                drag.current = { x: e.clientX, w }
              }}
              onPointerMove={e => {
                if (!drag.current) return
                const next = Math.round(Math.min(MAX_W, Math.max(MIN_W, drag.current.w + (drag.current.x - e.clientX))))
                rememberedWidth = next
                setWidth(next)
              }}
              onPointerUp={() => (drag.current = null)}
              onPointerCancel={() => (drag.current = null)}
              onKeyDown={e => {
                if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return
                e.preventDefault()
                const next = Math.min(MAX_W, Math.max(MIN_W, w + (e.key === 'ArrowLeft' ? 20 : -20)))
                rememberedWidth = next
                setWidth(next)
              }}
            >
              <span className="mx-auto block h-full w-[2px] bg-accent/0 transition-colors group-hover:bg-accent/40 group-focus-visible:bg-accent/60" />
            </div>
          )}
          <ChatPanel hub={chat} />
        </div>
      )}
    </div>
  )
}
