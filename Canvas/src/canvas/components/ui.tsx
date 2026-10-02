/** Small hand-made primitives: class merging, icon buttons, tooltips, keycaps. */
import { forwardRef, useEffect, type ButtonHTMLAttributes, type ReactNode, type RefObject } from 'react'

export function cn(...parts: (string | false | null | undefined)[]) {
  return parts.filter(Boolean).join(' ')
}

export const isMac = () =>
  typeof navigator !== 'undefined' && /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent)

/** The in-place editor's "how to finish" hint, which describes it to assistive tech. */
export const EDIT_HINT_ID = 'canvas-edit-hint'

/** "⌘" on the Mac, "Ctrl" elsewhere. */
export const MOD = isMac() ? '⌘' : 'Ctrl+'

export function Kbd({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <kbd
      className={cn(
        'inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-[5px] border border-line-2 bg-surface-2 px-1 font-sans text-[10.5px] font-medium leading-none text-ink-3',
        className
      )}
    >
      {children}
    </kbd>
  )
}

export function Tip({ label, keys, below }: { label: string; keys?: string; below?: boolean }) {
  return (
    <span
      role="presentation"
      className={cn(
        'tip flex items-center gap-1.5 rounded-lg bg-[#1d1d1f] px-2 py-1 text-[11.5px] font-medium text-white shadow-2 dark:bg-[#f2f2ef] dark:text-[#1d1d1f]',
        below && 'tip-below'
      )}
    >
      {label}
      {keys && (
        <span className="rounded bg-white/15 px-1 text-[10.5px] text-white/80 dark:bg-black/10 dark:text-black/60">
          {keys}
        </span>
      )}
    </span>
  )
}

export interface IconButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  label: string
  keys?: string
  active?: boolean
  tipBelow?: boolean
  /** Anchor the tooltip to the button's right edge (buttons near the window's right). */
  tipEnd?: boolean
  size?: 'sm' | 'md'
}

/** A square icon button with an accessible name and a hover tooltip. */
export const IconButton = forwardRef<HTMLButtonElement, IconButtonProps>(function IconButton(
  { label, keys, active, tipBelow, tipEnd, size = 'md', className, children, ...rest },
  ref
) {
  return (
    <button
      ref={ref}
      type="button"
      aria-label={keys ? `${label} (${keys})` : label}
      aria-pressed={active === undefined ? undefined : active}
      className={cn(
        'tip-host inline-flex shrink-0 items-center justify-center rounded-[10px] text-ink-2 outline-none transition-colors duration-100',
        'hover:bg-surface-2 hover:text-ink focus-visible:ring-2 focus-visible:ring-accent/60 disabled:pointer-events-none disabled:opacity-35',
        size === 'md' ? 'h-9 w-9' : 'h-7 w-7 rounded-lg',
        active && 'bg-accent-soft text-accent hover:bg-accent-soft hover:text-accent',
        tipBelow && 'tip-below',
        tipEnd && 'tip-end',
        className
      )}
      {...rest}
    >
      {children}
      <Tip label={label} keys={keys} below={tipBelow} />
    </button>
  )
})

export function Divider({ vertical = true, className }: { vertical?: boolean; className?: string }) {
  return vertical ? (
    <span className={cn('mx-1 h-5 w-px shrink-0 bg-line-2', className)} aria-hidden="true" />
  ) : (
    <span className="my-1 h-px w-full bg-line" aria-hidden="true" />
  )
}

/** Floating surface used by every toolbar and panel. */
export function Panel({
  className,
  children,
  ...rest
}: { className?: string; children: ReactNode } & React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn('rounded-[14px] border border-line bg-surface shadow-2', className)}
      onPointerDown={e => e.stopPropagation()}
      onDoubleClick={e => e.stopPropagation()}
      {...rest}
    >
      {children}
    </div>
  )
}

/** Focus (and select) a field on mount, again once the opening gesture settles. */
export function useMountFocus(ref: RefObject<HTMLInputElement | HTMLTextAreaElement | null>, select = true) {
  useEffect(() => {
    const focus = () => {
      const el = ref.current
      if (!el || document.activeElement === el) return
      el.focus({ preventScroll: true })
      if (select) el.select()
    }
    focus()
    const frame = requestAnimationFrame(focus)
    return () => cancelAnimationFrame(frame)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])
}
