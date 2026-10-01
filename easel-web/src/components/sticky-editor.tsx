/**
 * Typora-style sticky body: markdown renders as you type, the source stays a
 * markdown string in Yjs (`shape.text`). `- ` starts a bullet, Enter continues
 * it, Tab nests, `**bold**`, `# heading` and `[[Page]]` convert as the closing
 * mark lands. There is no separate preview layer.
 *
 * Lifted from the wiki app's apps/web/src/modules/wiki/components/sticky-editor.tsx;
 * the Tailwind class list became `.sticky-editor` rules in app.css and links
 * open through the host instead of `window.open`.
 */
import {
  useEffect,
  useRef,
  useState,
  type MouseEvent,
  type PointerEvent,
} from 'react'
import { EditorContent, useEditor, type Editor } from '@tiptap/react'
import { normalizeMarkdown, stickyExtensions } from '../lib/sticky-markdown'
import { counters } from '../debug'

export interface StickyEditorProps {
  /** Markdown source, shared through Yjs. */
  value: string
  /** Called with normalised markdown after every local edit. */
  onChange: (markdown: string) => void
  /** A link in an unfocused note was clicked. */
  onOpenLink?: (href: string) => void
  onFocus?: () => void
  onBlur?: () => void
  placeholder?: string
  className?: string
  /** Aria label of the editable region. */
  label?: string
}

/** Replace the doc from markdown without polluting undo or echoing an update. */
function loadMarkdown(editor: Editor, markdown: string) {
  const { from, to } = editor.state.selection
  editor
    .chain()
    .setMeta('addToHistory', false)
    .setContent(markdown, { contentType: 'markdown', emitUpdate: false })
    .run()
  // Keep the caret roughly where it was when a peer edits under us.
  const max = editor.state.doc.content.size
  if (editor.isFocused && from <= max) {
    editor.commands.setTextSelection({
      from: Math.min(from, max),
      to: Math.min(to, max),
    })
  }
}

export function StickyEditor({
  value,
  onChange,
  onOpenLink,
  onFocus,
  onBlur,
  placeholder = 'Type something',
  className,
  label = 'Sticky note',
}: StickyEditorProps) {
  const [focused, setFocused] = useState(false)
  // What we last wrote or loaded; a `value` equal to this is our own echo.
  const known = useRef(normalizeMarkdown(value))
  const onChangeRef = useRef(onChange)
  onChangeRef.current = onChange
  const onOpenLinkRef = useRef(onOpenLink)
  onOpenLinkRef.current = onOpenLink

  const editor = useEditor({
    extensions: stickyExtensions(placeholder),
    content: value,
    contentType: 'markdown',
    // Canvas is client-only; skip the SSR hydration path.
    immediatelyRender: true,
    editorProps: {
      attributes: {
        'aria-label': label,
        role: 'textbox',
        'aria-multiline': 'true',
        class: 'sticky-editor-doc',
      },
    },
    onUpdate: ({ editor }) => {
      const md = normalizeMarkdown(editor.getMarkdown())
      if (md === known.current) return
      known.current = md
      onChangeRef.current(md)
    },
    onFocus: () => {
      setFocused(true)
      onFocus?.()
    },
    onBlur: () => {
      setFocused(false)
      onBlur?.()
    },
  })

  useEffect(() => {
    counters.editors++
    return () => {
      counters.editors--
    }
  }, [])

  // Remote (or programmatic) change: reload unless it is our own echo.
  useEffect(() => {
    if (!editor) return
    const next = normalizeMarkdown(value)
    if (next === known.current) return
    known.current = next
    loadMarkdown(editor, next)
  }, [editor, value])

  /**
   * The canvas cancels pointerdown to run its own gestures, which also
   * suppresses the browser's click. So the unfocused note handles its two
   * clickable things right here, before the canvas sees the event: links
   * open in a tab and task boxes toggle, neither of which enters edit mode.
   * While editing, every pointer event belongs to the text.
   */
  const onPointerDown = (e: PointerEvent<HTMLDivElement>) => {
    if (focused) {
      e.stopPropagation()
      return
    }
    if (!editor) return
    const target = e.target as HTMLElement
    const link = target.closest('a')
    if (link) {
      e.preventDefault()
      e.stopPropagation()
      const href = link.getAttribute('href') ?? ''
      if (/^https?:/i.test(href)) {
        if (onOpenLinkRef.current) onOpenLinkRef.current(href)
        else window.open(href, '_blank', 'noopener,noreferrer')
      }
      return
    }
    if (target instanceof HTMLInputElement && target.type === 'checkbox') {
      e.preventDefault()
      e.stopPropagation()
      // The task item's node view is a bare <li data-checked>.
      const item = target.closest('li')
      if (!item) return
      // Find the task item whose node view is this <li>.
      let pos = -1
      editor.state.doc.descendants((node, p) => {
        if (pos !== -1) return false
        if (node.type.name === 'taskItem' && editor.view.nodeDOM(p) === item)
          pos = p
        return pos === -1
      })
      const node = pos === -1 ? null : editor.state.doc.nodeAt(pos)
      if (!node) return
      editor.view.dispatch(
        editor.state.tr.setNodeMarkup(pos, undefined, {
          ...node.attrs,
          checked: !node.attrs.checked,
        })
      )
    }
  }

  /**
   * A cancelled pointerdown still produces a click, and the click is what
   * toggles the native checkbox (firing TipTap's own handler, which focuses
   * the editor) and follows the anchor. Swallow it while unfocused; the
   * pointerdown above already did the work.
   */
  const onClickCapture = (e: MouseEvent<HTMLDivElement>) => {
    if (focused) return
    const target = e.target as HTMLElement
    if (
      target.closest('a') ||
      (target instanceof HTMLInputElement && target.type === 'checkbox')
    ) {
      e.preventDefault()
      e.stopPropagation()
    }
  }

  return (
    <EditorContent
      editor={editor}
      data-testid="sticky-editor"
      data-focused={focused || undefined}
      onPointerDown={onPointerDown}
      onClickCapture={onClickCapture}
      className={['sticky-editor', className].filter(Boolean).join(' ')}
    />
  )
}
