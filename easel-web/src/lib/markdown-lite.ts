/**
 * Lifted as-is from the wiki app's apps/web/src/modules/wiki/lib/markdown-lite.ts.
 *
 * A tiny markdown subset for canvas stickies and frame titles. Pure data out,
 * no HTML strings, so the renderer builds React elements and nothing a peer
 * types can inject markup.
 *
 * Blocks: `#`/`##`/`###` headings, `-`/`*` bullets, `1.`/`1)` numbered items
 * (indent two spaces per level), paragraphs whose single newlines are kept.
 * Inlines: `**bold**`, `*italic*`, `` `code` ``, `[[Page]]` / `[[Page|label]]`,
 * `[text](https://…)` and bare `http(s)://` URLs.
 */

export type Inline =
  | { type: 'text'; text: string }
  | { type: 'bold'; children: Inline[] }
  | { type: 'italic'; children: Inline[] }
  | { type: 'code'; text: string }
  | { type: 'wikilink'; target: string; label: string }
  | { type: 'link'; href: string; children: Inline[] }

export interface ListItem {
  /** Nesting level from leading indent, 0-based. */
  depth: number
  children: Inline[]
}

export type Block =
  | { type: 'heading'; level: 1 | 2 | 3; children: Inline[] }
  | { type: 'paragraph'; lines: Inline[][] }
  | { type: 'list'; ordered: false; items: ListItem[] }
  | { type: 'list'; ordered: true; start: number; items: ListItem[] }

const HEADING = /^(#{1,3})\s+(.*?)\s*#*\s*$/
const BULLET = /^(\s*)[-*]\s+(.*)$/
const NUMBERED = /^(\s*)(\d{1,9})[.)]\s+(.*)$/
const URL_START = /^https?:\/\/[^\s<>]+/
const TRAILING_PUNCT = /[.,;:!?'"]+$/

const depthOf = (indent: string) =>
  Math.floor(indent.replace(/\t/g, '  ').length / 2)

/** Cut trailing punctuation and unbalanced `)` off a bare URL. */
function trimUrl(raw: string): string {
  let url = raw
  for (;;) {
    const before = url
    url = url.replace(TRAILING_PUNCT, '')
    if (url.endsWith(')')) {
      const open = url.split('(').length - 1
      const close = url.split(')').length - 1
      if (close > open) url = url.slice(0, -1)
    }
    if (url === before) return url
  }
}

const isWordChar = (c: string | undefined) => !!c && /[\p{L}\p{N}_]/u.test(c)

function pushText(out: Inline[], text: string) {
  if (!text) return
  const last = out[out.length - 1]
  if (last?.type === 'text') last.text += text
  else out.push({ type: 'text', text })
}

/** Index of the closing `*` for an italic opened just before `from`, or -1. */
function italicClose(s: string, from: number): number {
  for (let i = from; i < s.length; i++) {
    if (s[i] === '`') {
      const end = s.indexOf('`', i + 1)
      if (end !== -1) i = end
      continue
    }
    if (s[i] !== '*') continue
    if (s[i + 1] === '*') {
      // a nested **bold** inside the italic: skip past its closer
      const end = s.indexOf('**', i + 2)
      if (end === -1) return -1
      i = end + 1
      continue
    }
    if (s[i - 1] !== ' ' && i > from) return i
  }
  return -1
}

/** Parse inline markup in one line of text. Never throws; unmatched marks stay literal. */
export function parseInline(s: string): Inline[] {
  const out: Inline[] = []
  let i = 0
  while (i < s.length) {
    const c = s[i]
    const rest = s.slice(i)

    if (c === '`') {
      const end = s.indexOf('`', i + 1)
      if (end > i + 1) {
        out.push({ type: 'code', text: s.slice(i + 1, end) })
        i = end + 1
        continue
      }
    }

    if (rest.startsWith('[[')) {
      const end = s.indexOf(']]', i + 2)
      const inner = end === -1 ? '' : s.slice(i + 2, end)
      if (inner.trim() && !inner.includes('[') && !inner.includes('\n')) {
        const bar = inner.indexOf('|')
        const target = (bar === -1 ? inner : inner.slice(0, bar)).trim()
        const label = bar === -1 ? target : inner.slice(bar + 1).trim()
        if (target) {
          out.push({ type: 'wikilink', target, label: label || target })
          i = end + 2
          continue
        }
      }
    }

    if (c === '[') {
      const m =
        /^\[([^\]\n]+)\]\((https?:\/\/[^\s()<>]+(?:\([^\s()<>]*\))?[^\s()<>]*)\)/.exec(
          rest
        )
      if (m) {
        out.push({
          type: 'link',
          href: m[2] ?? '',
          children: parseInline(m[1] ?? ''),
        })
        i += m[0].length
        continue
      }
    }

    if (rest.startsWith('**')) {
      const end = s.indexOf('**', i + 2)
      if (end > i + 2 && s[i + 2] !== ' ' && s[end - 1] !== ' ') {
        out.push({ type: 'bold', children: parseInline(s.slice(i + 2, end)) })
        i = end + 2
        continue
      }
    }

    if (c === '*' && s[i + 1] !== '*' && s[i + 1] !== ' ' && s[i + 1]) {
      const end = italicClose(s, i + 1)
      if (end !== -1) {
        out.push({
          type: 'italic',
          children: parseInline(s.slice(i + 1, end)),
        })
        i = end + 1
        continue
      }
    }

    if ((c === 'h' || c === 'H') && !isWordChar(s[i - 1])) {
      const m = URL_START.exec(rest)
      if (m) {
        const href = trimUrl(m[0])
        if (/^https?:\/\/[^/?#\s]+/.test(href)) {
          out.push({
            type: 'link',
            href,
            children: [{ type: 'text', text: href }],
          })
          i += href.length
          continue
        }
      }
    }

    // Plain run up to the next character that could open markup.
    let j = i + 1
    while (j < s.length && !'`[*hH'.includes(s[j] ?? '')) j++
    pushText(out, s.slice(i, j))
    i = j
  }
  return out
}

/** Parse a whole sticky's text into blocks. */
export function parseMarkdownLite(source: string): Block[] {
  const blocks: Block[] = []
  let para: Inline[][] | null = null
  let list: Extract<Block, { type: 'list' }> | null = null

  const flush = () => {
    para = null
    list = null
  }

  for (const line of source.replace(/\r\n?/g, '\n').split('\n')) {
    if (!line.trim()) {
      flush()
      continue
    }

    const heading = HEADING.exec(line)
    if (heading) {
      flush()
      blocks.push({
        type: 'heading',
        level: (heading[1] ?? '#').length as 1 | 2 | 3,
        children: parseInline(heading[2] ?? ''),
      })
      continue
    }

    const bullet = BULLET.exec(line)
    const numbered = bullet ? null : NUMBERED.exec(line)
    if (bullet || numbered) {
      const ordered = !!numbered
      const item: ListItem = bullet
        ? {
            depth: depthOf(bullet[1] ?? ''),
            children: parseInline(bullet[2] ?? ''),
          }
        : {
            depth: depthOf(numbered?.[1] ?? ''),
            children: parseInline(numbered?.[3] ?? ''),
          }
      const current = list as Extract<Block, { type: 'list' }> | null
      if (current && current.ordered === ordered) {
        current.items.push(item)
      } else {
        para = null
        list = ordered
          ? {
              type: 'list',
              ordered,
              start: Number(numbered![2]),
              items: [item],
            }
          : { type: 'list', ordered, items: [item] }
        blocks.push(list)
      }
      continue
    }

    // An indented line under a list item continues that item.
    const current = list as Extract<Block, { type: 'list' }> | null
    if (current && /^\s/.test(line)) {
      const last = current.items[current.items.length - 1]
      if (!last) continue
      pushText(last.children, ' ')
      for (const node of parseInline(line.trim())) {
        if (node.type === 'text') pushText(last.children, node.text)
        else last.children.push(node)
      }
      continue
    }

    list = null
    const lineInlines = parseInline(line)
    if (para) (para as Inline[][]).push(lineInlines)
    else {
      para = [lineInlines]
      blocks.push({ type: 'paragraph', lines: para })
    }
  }
  return blocks
}

/** Plain text of inlines, for titles and accessible labels. */
export function inlineText(nodes: Inline[]): string {
  return nodes
    .map(n =>
      n.type === 'text' || n.type === 'code'
        ? n.text
        : n.type === 'wikilink'
          ? n.label
          : inlineText(n.children)
    )
    .join('')
}
