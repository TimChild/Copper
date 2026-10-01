/**
 * A sticky that is not being edited renders as static HTML, not a TipTap
 * editor: 60 live editors meant 60 ProseMirror views, plugin sets,
 * MutationObservers and selection listeners on a board nobody was typing
 * into. The HTML comes from the same extensions, the same `MarkdownManager`
 * and ProseMirror's own `DOMSerializer`, then gets the few nodes the editor
 * view adds (trailing breaks, atom separators), so a note looks the same in
 * both modes and nothing jumps when it starts or stops editing.
 */
import { getSchema, type JSONContent } from '@tiptap/core'
import { MarkdownManager } from '@tiptap/markdown'
import { DOMSerializer, type Node as PMNode, type Schema } from '@tiptap/pm/model'
import { createStickyMarked, normalizeMarkdown, stickyExtensions } from './sticky-markdown'

interface Kit {
  manager: MarkdownManager
  schema: Schema
  serializer: DOMSerializer
}

let kit: Kit | null = null
function getKit(): Kit {
  if (kit) return kit
  const marked = createStickyMarked()
  const extensions = stickyExtensions(undefined, marked)
  const schema = getSchema(extensions)
  kit = {
    manager: new MarkdownManager({ marked, extensions }),
    schema,
    serializer: DOMSerializer.fromSchema(schema),
  }
  return kit
}

/** The ProseMirror JSON the editor would load for this markdown. */
export function stickyJSON(markdown: string): JSONContent {
  return getKit().manager.parse(markdown)
}

/** Markdown for a document, normalised the way the editor stores it. */
export function stickyMarkdown(json: JSONContent): string {
  const { manager, schema } = getKit()
  // Through the schema first, like editor.getJSON(): defaults filled in.
  return normalizeMarkdown(manager.serialize(schema.nodeFromJSON(json).toJSON()))
}

const TEXTBLOCKS = 'p, h1, h2, h3, h4, h5, h6'

/** TaskItem's node view (extension-list): a visually hidden label for the box. */
const VISUALLY_HIDDEN =
  'position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0'

/**
 * What the editor view draws differently from plain `toDOM`:
 * - prosemirror-view (NodeViewDesc.create, ViewDesc.addTextblockHacks): leaf
 *   nodes are `contenteditable=false`, and a textblock that is empty or ends
 *   in a non-text node gets a trailing <br> (plus a zero-size <img>
 *   separator after an atom, in Safari and Chrome). The <br> is what gives
 *   an empty paragraph its line of height.
 * - TaskItem's node view: `<li data-checked>` without `data-type`, a
 *   non-editable label, and an accessible name on the box ("Task item
 *   checkbox for …"), mirrored in a visually hidden span.
 */
function addEditorHacks(root: HTMLElement, doc: PMNode | null) {
  for (const el of root.querySelectorAll('[data-wikilink]'))
    el.setAttribute('contenteditable', 'false')
  const tasks: PMNode[] = []
  doc?.descendants(node => {
    if (node.type.name === 'taskItem') tasks.push(node)
  })
  root.querySelectorAll('li[data-type="taskItem"]').forEach((li, i) => {
    li.removeAttribute('data-type')
    const label = li.querySelector(':scope > label')
    label?.setAttribute('contenteditable', 'false')
    const name = `Task item checkbox for ${tasks[i]?.textContent || 'empty task item'}`
    label?.querySelector('input')?.setAttribute('aria-label', name)
    const span = label?.querySelector('span')
    if (span) {
      span.setAttribute('style', VISUALLY_HIDDEN)
      span.textContent = name
    }
  })
  for (const block of root.querySelectorAll(TEXTBLOCKS)) {
    let parent: Element = block
    let last = block.lastChild
    // Marks wrap their content; look inside them like ProseMirror does.
    while (
      last instanceof HTMLElement &&
      last.getAttribute('contenteditable') !== 'false' &&
      last.nodeName !== 'BR' &&
      last.lastChild
    ) {
      parent = last
      last = last.lastChild
    }
    const text = last?.nodeType === Node.TEXT_NODE ? (last.textContent ?? '') : null
    if (last && text !== null && !/\n$/.test(text)) continue
    if (last instanceof HTMLElement && last.getAttribute('contenteditable') === 'false') {
      const img = document.createElement('img')
      img.className = 'ProseMirror-separator'
      img.alt = ''
      parent.appendChild(img)
    }
    const br = document.createElement('br')
    br.className = 'ProseMirror-trailingBreak'
    block.appendChild(br)
  }
}

const cache = new Map<string, string>()
const CACHE_MAX = 400

/** Inner HTML of the `.tiptap` element for a sticky, as the editor would draw it unfocused. */
export function stickyStaticHTML(markdown: string, placeholder = 'Type something'): string {
  const key = `${placeholder}\u0000${markdown}`
  const hit = cache.get(key)
  if (hit !== undefined) return hit
  const { schema, serializer } = getKit()
  const container = document.createElement('div')
  const json = markdown.trim() ? safeJSON(markdown) : null
  const doc = json?.content?.length ? schema.nodeFromJSON(json) : null
  if (doc) {
    container.appendChild(serializer.serializeFragment(doc.content))
  } else {
    // The editor's empty state: one paragraph carrying the placeholder.
    const p = document.createElement('p')
    p.className = 'is-empty is-editor-empty'
    p.setAttribute('data-placeholder', placeholder)
    container.appendChild(p)
  }
  addEditorHacks(container, doc)
  const html = container.innerHTML
  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value!)
  cache.set(key, html)
  return html
}

function safeJSON(markdown: string): JSONContent | null {
  try {
    const json = stickyJSON(markdown)
    getKit().schema.nodeFromJSON(json).check()
    return json
  } catch {
    // Never let one odd note blank the board: show it as plain paragraphs.
    return {
      type: 'doc',
      content: markdown.split('\n').map(line => ({
        type: 'paragraph',
        content: line ? [{ type: 'text', text: line }] : [],
      })),
    }
  }
}

/**
 * Tick or untick the `index`-th task box (document order, which is DOM
 * order) without an editor, and return the markdown the editor would store
 * after the same click. Unchanged when there is no such box.
 */
export function toggleTask(markdown: string, index: number): string {
  const json = stickyJSON(markdown)
  let seen = -1
  let hit = false
  const walk = (node: JSONContent) => {
    if (hit) return
    if (node.type === 'taskItem' && ++seen === index) {
      node.attrs = { ...node.attrs, checked: !node.attrs?.checked }
      hit = true
      return
    }
    node.content?.forEach(walk)
  }
  walk(json)
  return hit ? stickyMarkdown(json) : markdown
}
