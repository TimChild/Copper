/**
 * TipTap extensions for the live-markdown sticky editor. Lifted from
 * the wiki app's apps/web/src/modules/wiki/lib/sticky-markdown.ts; only the
 * wikilink chip's class name changed (plain CSS instead of Tailwind).
 *
 * The sticky's source of truth stays a markdown string in Yjs (`shape.text`),
 * so anything here has to round-trip: `[[wikilinks]]` become an inline node
 * that serialises back to the same `[[Page|label]]` text.
 *
 * The first local keystroke re-serialises the whole note, so legacy text is
 * normalised once: `* x` → `- x`, `1) x` → `1. x`, a blank line lands after
 * headings, bare URLs become `[url](url)`. `normalizeMarkdown` then strips
 * the escapes and entities the serializer adds that no other reader of the
 * note would understand.
 */
import {
  Extension,
  InputRule,
  Node,
  mergeAttributes,
  nodeInputRule,
} from '@tiptap/core'
import Placeholder from '@tiptap/extension-placeholder'
import { Markdown } from '@tiptap/markdown'
import { TaskItem, TaskList } from '@tiptap/extension-list'
import StarterKit from '@tiptap/starter-kit'
import { Marked, type marked } from 'marked'

const WIKILINK_TEXT = /^\[\[([^[\]\n|]+?)(?:\|([^[\]\n]+?))?\]\]/
/**
 * Input rule variant: fires as the closing `]]` is typed. `nodeInputRule`
 * replaces capture group 1 with the node, so the whole link is group 1.
 */
const WIKILINK_INPUT = /(\[\[([^[\]\n|]+?)(?:\|([^[\]\n]+?))?\]\])$/

export interface WikilinkAttrs {
  target: string
  label: string
}

/** Inline atom for `[[Page]]` / `[[Page|label]]`. */
export const Wikilink = Node.create({
  name: 'wikilink',
  group: 'inline',
  inline: true,
  atom: true,
  selectable: true,

  addAttributes() {
    // Rendered by hand below (`data-wikilink`), never as bare attributes.
    return {
      target: { default: '', renderHTML: () => ({}) },
      label: { default: '', renderHTML: () => ({}) },
    }
  },

  parseHTML() {
    return [
      {
        tag: 'span[data-wikilink]',
        getAttrs: el => {
          const target = (el as HTMLElement).getAttribute('data-wikilink')
          if (!target) return false
          return { target, label: (el as HTMLElement).textContent || target }
        },
      },
    ]
  },

  renderHTML({ node, HTMLAttributes }) {
    const { target, label } = node.attrs as WikilinkAttrs
    return [
      'span',
      mergeAttributes(HTMLAttributes, {
        'data-wikilink': target,
        title: target,
        class: 'easel-wikilink',
      }),
      // Shown literally, like Obsidian's live preview: the chip *is* the
      // source text, so nothing hides behind it while editing.
      serializeWikilink({ target, label }),
    ]
  },

  renderText({ node }) {
    return serializeWikilink(node.attrs as WikilinkAttrs)
  },

  addInputRules() {
    return [
      nodeInputRule({
        find: WIKILINK_INPUT,
        type: this.type,
        getAttributes: match => ({
          target: (match[2] ?? '').trim(),
          label: (match[3] ?? match[2] ?? '').trim(),
        }),
      }),
    ]
  },

  // ---- @tiptap/markdown round-trip ----
  markdownTokenName: 'wikilink',
  markdownTokenizer: {
    name: 'wikilink',
    level: 'inline',
    start: src => src.indexOf('[['),
    tokenize: src => {
      const m = WIKILINK_TEXT.exec(src)
      if (!m) return undefined
      const target = (m[1] ?? '').trim()
      if (!target) return undefined
      return {
        type: 'wikilink',
        raw: m[0],
        target,
        label: (m[2] ?? '').trim() || target,
      }
    },
  },
  parseMarkdown: (token, helpers) =>
    helpers.createNode('wikilink', {
      target: token.target as string,
      label: token.label as string,
    }),
  renderMarkdown: node => serializeWikilink(node.attrs as WikilinkAttrs),
})

export function serializeWikilink({ target, label }: WikilinkAttrs): string {
  return !label || label === target ? `[[${target}]]` : `[[${target}|${label}]]`
}

/**
 * List ergonomics: Tab / Shift-Tab nest and un-nest items like every
 * outliner, and the GitHub habit of typing `- [ ] ` (or `[x] `) at the start
 * of a bullet turns that list into a task list live, not only on reload.
 */
const TASK_IN_BULLET = /^\[( |x|X)?\]\s$/
const ListTweaks = Extension.create({
  name: 'stickyListTweaks',
  addKeyboardShortcuts() {
    return {
      Tab: () => this.editor.commands.sinkListItem('listItem'),
      'Shift-Tab': () => this.editor.commands.liftListItem('listItem'),
    }
  },
  addInputRules() {
    return [
      new InputRule({
        find: TASK_IN_BULLET,
        handler: ({ state, range, match, chain }) => {
          const parent = state.selection.$from.node(-1).type.name
          if (parent !== 'listItem' && parent !== 'taskItem') return null
          const checked = (match[1] ?? ' ').toLowerCase() === 'x'
          const c = chain().deleteRange(range)
          if (parent === 'listItem') c.toggleTaskList()
          c.updateAttributes('taskItem', { checked }).run()
          return undefined
        },
      }),
    ]
  },
})

/**
 * Our own marked instance, not the shared singleton: a sticky is plain text
 * with markdown sugar, so anything that looks like HTML stays literal
 * (`<Component>` is a word, not a tag). The default parser would drop it.
 */
const stickyMarked = new Marked({
  tokenizer: {
    html: () => undefined,
    tag: () => undefined,
  },
  // The option is typed as the singleton; an instance has the same surface
  // minus static defaults, which the parser never calls.
}) as unknown as typeof marked

/** The extension set for one sticky. */
export function stickyExtensions(placeholder = 'Type something') {
  return [
    StarterKit.configure({
      // A trailing empty paragraph would round-trip as a stray blank line.
      trailingNode: false,
      // Stickies are one-liners with lists; drop the block furniture.
      horizontalRule: false,
      codeBlock: false,
      blockquote: false,
      dropcursor: false,
      gapcursor: false,
      link: { openOnClick: false },
    }),
    // `- [ ] todo` / `- [x] done` keep their boxes instead of flattening.
    TaskList,
    TaskItem.configure({ nested: true }),
    Placeholder.configure({ placeholder }),
    Markdown.configure({ marked: stickyMarked }),
    Wikilink,
    ListTweaks,
  ]
}

/**
 * The markdown we store for what the editor holds. Strips what the serializer
 * adds defensively but every other reader of a sticky would show literally:
 * a trailing newline after lists, `&lt;`-style entities, and backslash
 * escapes on characters that cannot open markup where they sit (`\_`, `\[`,
 * `\]`, `\\`, a `\*` next to whitespace). Idempotent, so a note reloads to
 * the same document and never ping-pongs with a peer.
 */
export function normalizeMarkdown(s: string): string {
  return s
    .replace(/\r\n?/g, '\n')
    .replace(/\\([_[\]\\])/g, '$1')
    .replace(/(^|\s)\\\*/g, '$1*')
    .replace(/\\\*(?=\s|$)/gm, '*')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/\s+$/, '')
}
