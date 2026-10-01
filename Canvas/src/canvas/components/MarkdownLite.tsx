/** Renders markdown-lite blocks as React elements; no raw HTML anywhere. */
import { Fragment, memo, useMemo, type ReactNode } from 'react'
import { parseInline, parseMarkdownLite, type Block, type Inline } from '../markdown-lite'
import { cn } from './ui'

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

export interface MarkdownHandlers {
  /** A link was clicked: the host opens it (the page never navigates). */
  onOpenUrl?: (url: string) => void
  /** A task box was clicked; `line` is its source line. */
  onToggleTask?: (line: number) => void
}

function renderInline(nodes: Inline[], h: MarkdownHandlers, key = ''): ReactNode[] {
  return nodes.map((n, i) => {
    const k = `${key}${i}`
    switch (n.type) {
      case 'text':
        return <Fragment key={k}>{n.text}</Fragment>
      case 'bold':
        return (
          <strong key={k} className="font-semibold">
            {renderInline(n.children, h, `${k}.`)}
          </strong>
        )
      case 'italic':
        return (
          <em key={k} className="italic">
            {renderInline(n.children, h, `${k}.`)}
          </em>
        )
      case 'strike':
        return (
          <s key={k} className="opacity-70">
            {renderInline(n.children, h, `${k}.`)}
          </s>
        )
      case 'code':
        return (
          <code key={k} className="rounded bg-black/[0.08] px-1 py-px font-mono text-[0.86em] dark:bg-white/15">
            {n.text}
          </code>
        )
      case 'link':
        return (
          <a
            key={k}
            href={n.href}
            className="pointer-events-auto cursor-pointer break-words underline decoration-current/45 underline-offset-2 hover:decoration-current"
            onPointerDown={stop}
            onDoubleClick={stop}
            onClick={e => {
              e.preventDefault()
              e.stopPropagation()
              h.onOpenUrl?.(n.href)
            }}
          >
            {renderInline(n.children, h, `${k}.`)}
          </a>
        )
    }
  })
}

const HEADING_CLASS = {
  1: 'text-[1.35em] font-bold leading-tight tracking-[-0.01em]',
  2: 'text-[1.17em] font-bold leading-tight',
  3: 'text-[1.02em] font-semibold leading-snug',
} as const

function renderLines(lines: Inline[][], h: MarkdownHandlers) {
  return lines.map((line, j) => (
    <Fragment key={j}>
      {j > 0 && <br />}
      {renderInline(line, h, `${j}:`)}
    </Fragment>
  ))
}

function renderBlock(block: Block, i: number, h: MarkdownHandlers): ReactNode {
  switch (block.type) {
    case 'heading': {
      const Tag = `h${block.level}` as const
      return (
        <Tag key={i} className={HEADING_CLASS[block.level]}>
          {renderInline(block.children, h)}
        </Tag>
      )
    }
    case 'paragraph':
      return <p key={i}>{renderLines(block.lines, h)}</p>
    case 'quote':
      return (
        <blockquote key={i} className="border-l-[3px] border-current/30 pl-2 opacity-85">
          {renderLines(block.lines, h)}
        </blockquote>
      )
    case 'list': {
      const items = block.items.map((item, j) => (
        <li
          key={j}
          className={cn(item.checked !== undefined && '-ml-[1.15em] flex list-none items-start gap-[0.4em]')}
          style={item.depth ? { marginLeft: `${Math.min(item.depth, 4) * 1.1 - (item.checked !== undefined ? 1.15 : 0)}em` } : undefined}
        >
          {item.checked !== undefined && (
            <button
              type="button"
              role="checkbox"
              aria-checked={item.checked}
              aria-label={item.checked ? 'Mark as not done' : 'Mark as done'}
              className={cn(
                'pointer-events-auto mt-[0.22em] inline-flex h-[1em] w-[1em] shrink-0 cursor-pointer items-center justify-center rounded-[0.25em] border-[1.5px] border-current/55',
                item.checked && 'border-transparent bg-current/80'
              )}
              onPointerDown={stop}
              onDoubleClick={stop}
              onClick={e => {
                e.stopPropagation()
                h.onToggleTask?.(item.line)
              }}
            >
              {item.checked && (
                <svg viewBox="0 0 12 12" className="h-[0.7em] w-[0.7em]" aria-hidden="true">
                  <path d="M2.5 6.5 5 9l4.5-6" fill="none" stroke="var(--paper-white, #fff)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              )}
            </button>
          )}
          <span className={cn(item.checked && 'line-through opacity-60')}>{renderInline(item.children, h)}</span>
        </li>
      ))
      if (block.ordered)
        return (
          <ol key={i} start={block.start} className="list-decimal pl-[1.3em]">
            {items}
          </ol>
        )
      return (
        <ul key={i} className="list-disc pl-[1.15em]">
          {items}
        </ul>
      )
    }
  }
}

/** A sticky's body: every block, stacked with small gaps. */
export const MarkdownLite = memo(function MarkdownLite({
  source,
  className,
  onOpenUrl,
  onToggleTask,
}: { source: string; className?: string } & MarkdownHandlers) {
  const blocks = useMemo(() => parseMarkdownLite(source), [source])
  const h = { onOpenUrl, onToggleTask }
  return (
    <div className={cn('sticky-md min-w-0 space-y-[0.4em] break-words', className)}>
      {blocks.map((b, i) => renderBlock(b, i, h))}
    </div>
  )
})

/** One line of inline markup (titles). A leading `#` is dropped; only the first line shows. */
export function MarkdownLiteInline({ source, className }: { source: string; className?: string }) {
  const nodes = useMemo(() => {
    const first = source.split(/\r?\n/, 1)[0] ?? ''
    return parseInline(first.replace(/^\s*#{1,3}\s+/, ''))
  }, [source])
  return <span className={cn('block min-w-0 truncate', className)}>{renderInline(nodes, {})}</span>
}
