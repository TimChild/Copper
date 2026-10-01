/**
 * Renders `markdown-lite` blocks as React elements, no raw HTML anywhere.
 * Lifted from the wiki app's apps/web/src/modules/wiki/components/markdown-lite.tsx
 * with class names moved to app.css. Frame titles use `MarkdownLiteInline`.
 */
import { Fragment, useMemo, type ReactNode } from 'react'
import {
  parseInline,
  parseMarkdownLite,
  type Block,
  type Inline,
} from '../lib/markdown-lite'

const stop = (e: { stopPropagation: () => void }) => e.stopPropagation()

function renderInline(nodes: Inline[], key = ''): ReactNode[] {
  return nodes.map((n, i) => {
    const k = `${key}${i}`
    switch (n.type) {
      case 'text':
        return <Fragment key={k}>{n.text}</Fragment>
      case 'bold':
        return <strong key={k}>{renderInline(n.children, `${k}.`)}</strong>
      case 'italic':
        return <em key={k}>{renderInline(n.children, `${k}.`)}</em>
      case 'code':
        return <code key={k}>{n.text}</code>
      case 'wikilink':
        return (
          <span
            key={k}
            data-wikilink={n.target}
            title={n.target}
            className="easel-wikilink"
          >
            {n.label}
          </span>
        )
      case 'link':
        return (
          <a
            key={k}
            href={n.href}
            target="_blank"
            rel="noopener noreferrer"
            // Links stay clickable while the rest of the view lets pointer
            // gestures fall through to the shape underneath.
            className="easel-link"
            onPointerDown={stop}
          >
            {renderInline(n.children, `${k}.`)}
          </a>
        )
    }
  })
}

function renderBlock(block: Block, i: number): ReactNode {
  switch (block.type) {
    case 'heading': {
      const Tag = `h${block.level}` as const
      return <Tag key={i}>{renderInline(block.children)}</Tag>
    }
    case 'paragraph':
      return (
        <p key={i}>
          {block.lines.map((line, j) => (
            <Fragment key={j}>
              {j > 0 && <br />}
              {renderInline(line, `${j}:`)}
            </Fragment>
          ))}
        </p>
      )
    case 'list': {
      const items = block.items.map((item, j) => (
        <li
          key={j}
          style={
            item.depth ? { marginLeft: `${Math.min(item.depth, 4)}em` } : {}
          }
        >
          {renderInline(item.children)}
        </li>
      ))
      return block.ordered ? (
        <ol key={i} start={block.start}>
          {items}
        </ol>
      ) : (
        <ul key={i}>{items}</ul>
      )
    }
  }
}

/** A note's body: every block, stacked with small gaps. */
export function MarkdownLite({
  source,
  className,
}: {
  source: string
  className?: string
}) {
  const blocks = useMemo(() => parseMarkdownLite(source), [source])
  return (
    <div className={['markdown-lite', className].filter(Boolean).join(' ')}>
      {blocks.map(renderBlock)}
    </div>
  )
}

/**
 * One line of inline markup, for frame titles. A leading `#` marker is
 * dropped (the title is already bold) and only the first line shows.
 */
export function MarkdownLiteInline({
  source,
  className,
}: {
  source: string
  className?: string
}) {
  const nodes = useMemo(() => {
    const first = source.split(/\r?\n/, 1)[0] ?? ''
    return parseInline(first.replace(/^\s*#{1,3}\s+/, ''))
  }, [source])
  return (
    <span
      className={['markdown-lite-inline', className].filter(Boolean).join(' ')}
    >
      {renderInline(nodes)}
    </span>
  )
}
