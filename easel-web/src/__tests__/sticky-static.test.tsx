// @vitest-environment jsdom
// The static sticky must look like the editor it replaces: same markdown →
// (nearly) the same DOM under `.tiptap`, so starting or stopping an edit
// never makes a note jump.
import './setup-tiptap'
import { describe, expect, it } from 'vitest'
import { Editor } from '@tiptap/core'
import { createStickyMarked, stickyExtensions } from '../lib/sticky-markdown'
import { stickyStaticHTML, toggleTask } from '../lib/sticky-static'

/** What a mounted, unfocused editor shows for this markdown. */
function editorHTML(markdown: string) {
  const element = document.createElement('div')
  document.body.appendChild(element)
  const editor = new Editor({
    element,
    extensions: stickyExtensions(),
    content: markdown,
    contentType: 'markdown',
  })
  const html = editor.view.dom.innerHTML
  editor.destroy()
  element.remove()
  return html
}

const KEEP = ['class', 'href', 'data-wikilink', 'data-checked', 'checked', 'contenteditable', 'data-placeholder', 'type']

/**
 * A comparable outline of a DOM: tags, text, and the attributes that change
 * how it looks or behaves. Ignored: attribute order, `data-type` (the task
 * node view leaves it off), and the zero-size separator <img> ProseMirror
 * adds only for Safari and Chrome (jsdom is neither).
 */
function outline(html: string) {
  const root = document.createElement('div')
  root.innerHTML = html
  const walk = (node: Node): string => {
    if (node.nodeType === Node.TEXT_NODE) return JSON.stringify(node.textContent)
    const el = node as HTMLElement
    if (el.tagName === 'IMG' && el.classList.contains('ProseMirror-separator')) return ''
    const attrs = KEEP.filter(a => el.hasAttribute(a))
      .map(a => `${a}=${a === 'checked' ? 'on' : el.getAttribute(a)}`)
      .join(' ')
    const kids = [...el.childNodes].map(walk).filter(Boolean).join('')
    return `<${el.tagName.toLowerCase()}${attrs ? ' ' + attrs : ''}>${kids}</>`
  }
  return [...root.childNodes].map(walk).join('')
}

const SAMPLES = [
  '**Launch** checklist\n\n- [ ] bridge messages\n- [x] laser pointer\n- [ ] see [[Roadmap]]',
  '# Q3 plan\n\n- ship **easels**\n- talk to [[Felipe]]\n  - pricing\n  - sharing',
  'Plain thought, keep it *quiet*, and link https://copper.dev/docs',
  '1. sketch\n2. **build**\n3. measure',
  '`setView` per wheel event and *every* sticky [[Perf notes|perf]]',
  '## Open questions\n\n- who owns **sync**?\n- does [[P4]] need accounts?',
  'ends with a link [[Wiki]]',
  'see [a link](https://example.com) and `code`',
  'snake_case and 5 * 3 and [brackets] <Component> & co',
  'one\n\ntwo',
]

describe('static sticky HTML', () => {
  it.each(SAMPLES)('matches what TipTap renders for %j', markdown => {
    expect(outline(stickyStaticHTML(markdown))).toBe(outline(editorHTML(markdown)))
  })

  it('shows the placeholder paragraph for an empty note, like the editor', () => {
    expect(outline(stickyStaticHTML(''))).toBe(outline(editorHTML('')))
    expect(stickyStaticHTML('')).toContain('data-placeholder="Type something"')
  })

  it('never renders raw HTML or a javascript: link', () => {
    const html = stickyStaticHTML('<img src=x onerror=alert(1)> [x](javascript:alert(1))')
    const root = document.createElement('div')
    root.innerHTML = html
    expect(root.querySelector('img:not(.ProseMirror-separator)')).toBeNull()
    expect(root.textContent).toContain('<img src=x onerror=alert(1)>')
    for (const a of root.querySelectorAll('a'))
      expect(a.getAttribute('href') ?? '').not.toMatch(/^javascript:/i)
  })

  it('toggles the n-th task box in the markdown, as the editor would store it', () => {
    const md = '- [ ] one\n- [x] two\n- [ ] three'
    expect(toggleTask(md, 0)).toBe('- [x] one\n- [x] two\n- [ ] three')
    expect(toggleTask(md, 1)).toBe('- [ ] one\n- [ ] two\n- [ ] three')
    expect(toggleTask(md, 7)).toBe(md)
    // Nested task lists count in document order too.
    expect(toggleTask('- [ ] a\n  - [ ] b', 1)).toBe('- [ ] a\n  - [x] b')
  })

  it('gives every extension set its own marked, so tokenizers do not pile up', () => {
    const marked = createStickyMarked()
    const before = (marked.defaults.extensions?.inline ?? []).length
    for (let i = 0; i < 5; i++) {
      const element = document.createElement('div')
      const editor = new Editor({
        element,
        extensions: stickyExtensions(),
        content: '[[x]]',
        contentType: 'markdown',
      })
      editor.destroy()
    }
    expect((marked.defaults.extensions?.inline ?? []).length).toBe(before)
    // And one editor's instance holds one wikilink tokenizer, not one per mount.
    const own = createStickyMarked()
    const element = document.createElement('div')
    const editor = new Editor({
      element,
      extensions: stickyExtensions(undefined, own),
      content: '[[x]]',
      contentType: 'markdown',
    })
    const inline = own.defaults.extensions?.inline?.length ?? 0
    editor.destroy()
    expect(inline).toBeGreaterThan(0)
    expect(inline).toBeLessThanOrEqual(2)
  })
})
