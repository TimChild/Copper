/**
 * jsdom has no layout engine, and ProseMirror asks for one. Import this at
 * the top of any test that mounts the composer.
 *
 * It also captures the live `EditorView`: ProseMirror keeps no registry and
 * the composer does not expose its editor, so the test drives typing through
 * the view it sees on the first dispatch (the placeholder effect guarantees
 * one right after mount).
 */
import { EditorView } from '@tiptap/pm/view'

type RectLike = {
  bottom: number
  height: number
  left: number
  right: number
  top: number
  width: number
  x: number
  y: number
  toJSON: () => unknown
}

const rect = (): RectLike => ({
  bottom: 0,
  height: 0,
  left: 0,
  right: 0,
  top: 0,
  width: 0,
  x: 0,
  y: 0,
  toJSON: () => ({}),
})

const emptyRectList = Object.assign([] as unknown as DOMRectList, {
  item: () => null,
})

Range.prototype.getBoundingClientRect = () => rect() as DOMRect
Range.prototype.getClientRects = () => emptyRectList
Element.prototype.getClientRects = () => emptyRectList
if (!Element.prototype.scrollIntoView) {
  Element.prototype.scrollIntoView = () => undefined
}
if (typeof globalThis.ResizeObserver === 'undefined') {
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as unknown as typeof ResizeObserver
}

let latestView: EditorView | null = null

function recordView(view: EditorView): void {
  latestView = view
}

const originalDispatch = EditorView.prototype.dispatch
EditorView.prototype.dispatch = function patchedDispatch(
  this: EditorView,
  ...args: Parameters<EditorView['dispatch']>
) {
  recordView(this)
  return originalDispatch.apply(this, args)
}

/** The most recently active ProseMirror view. */
export function currentEditorView(): EditorView {
  if (!latestView) throw new Error('no ProseMirror view has dispatched yet')
  return latestView
}

export function resetEditorView(): void {
  latestView = null
}
