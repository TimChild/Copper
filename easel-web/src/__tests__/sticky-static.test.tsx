// @vitest-environment jsdom
// The static sticky must look like the editor it replaces: same markdown →
// (nearly) the same DOM under `.tiptap`, so starting or stopping an edit
// never makes a note jump.
import './setup-tiptap'
import { describe, expect, it } from 'vitest'
import { Editor } from '@tiptap/core'
import { createStickyMarked, stickyExtensions } from '../lib/sticky-markdown'
import { stickyStaticHTML, toggleTask } from '../lib/sticky-static'

/** Outline of what a mounted, unfocused editor shows for this markdown. */
function editorOutline(markdown: string) {
  const element = document.createElement('div')
  document.body.appendChild(element)
  const editor = new Editor({
    element,
    extensions: stickyExtensions(),
    content: markdown,
    contentType: 'markdown',
  })
  // The live DOM, not innerHTML: the task node view sets `checked` as a property.
  const out = outline(editor.view.dom)
  editor.destroy()
  element.remove()
  return out
}

function staticOutline(markdown: string) {
  const root = document.createElement('div')
  root.innerHTML = stickyStaticHTML(markdown)
  return outline(root)
}

const KEEP = ['class', 'href', 'data-wikilink', 'data-checked', 'data-placeholder', 'type', 'aria-label', 'style']

/**
 * A comparable outline of a DOM: tags, text, the attributes that change how
 * it looks, reads or behaves, and each box's checked state. Ignored:
 * attribute order, how an inline style is spelled (only whether there is
 * one), and `contenteditable` (ProseMirror sets the property, which browsers
 * reflect to the attribute and jsdom does not; checked on its own below).
 */
function outline(root: Element) {
  const walk = (node: Node): string => {
    if (node.nodeType === Node.TEXT_NODE) return JSON.stringify(node.textContent)
    const el = node as HTMLElement
    const attrs = KEEP.filter(a => el.hasAttribute(a)).map(a =>
      a === 'style' ? 'style' : `${a}=${el.getAttribute(a)}`
    )
    if (el instanceof HTMLInputElement) attrs.push(`checked=${el.checked}`)
    const kids = [...el.childNodes].map(walk).join('')
    return `<${el.tagName.toLowerCase()}${attrs.length ? ' ' + attrs.join(' ') : ''}>${kids}</>`
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
    expect(staticOutline(markdown)).toBe(editorOutline(markdown))
  })

  it('marks wikilink atoms contenteditable=false, as the editor view does in a browser', () => {
    const root = document.createElement('div')
    root.innerHTML = stickyStaticHTML('see [[Roadmap]] and **[[Q3|plan]]**')
    const chips = [...root.querySelectorAll('[data-wikilink]')]
    expect(chips.map(c => c.getAttribute('contenteditable'))).toEqual(['false', 'false'])
    // An atom at the end of a line gets the separator + trailing break.
    expect(root.querySelector('p')?.lastElementChild?.className).toBe('ProseMirror-trailingBreak')
  })

  it('shows the placeholder paragraph for an empty note, like the editor', () => {
    expect(staticOutline('')).toBe(editorOutline(''))
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
