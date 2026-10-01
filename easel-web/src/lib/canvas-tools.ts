/**
 * Drawing tools and their keyboard shortcuts. Lifted from the wiki app's
 * apps/web/src/modules/wiki/lib/canvas-tools.ts, plus Hand and Laser; icons
 * are inline SVG (components/icons.tsx) instead of Font Awesome names.
 */
export type Tool = 'select' | 'hand' | 'sticky' | 'frame' | 'arrow' | 'laser'

export type IconName =
  | 'select'
  | 'hand'
  | 'sticky'
  | 'frame'
  | 'arrow'
  | 'image'
  | 'laser'

export const TOOLS: {
  tool: Tool
  key: string
  label: string
  icon: IconName
}[] = [
  { tool: 'select', key: 'v', label: 'Select', icon: 'select' },
  { tool: 'hand', key: 'h', label: 'Hand', icon: 'hand' },
  { tool: 'sticky', key: 's', label: 'Sticky', icon: 'sticky' },
  { tool: 'frame', key: 'f', label: 'Frame', icon: 'frame' },
  { tool: 'arrow', key: 'a', label: 'Arrow', icon: 'arrow' },
  { tool: 'laser', key: 'l', label: 'Laser', icon: 'laser' },
]

/** Focus a shape's text field after the current pointer gesture settles. */
export function focusShapeText(id: string) {
  requestAnimationFrame(() => {
    const root = `[data-ref="shape:${id}"]`
    const el = document.querySelector<HTMLElement>(
      `${root} [contenteditable="true"], ${root} textarea, ${root} input`
    )
    if (!el) return
    el.focus()
    // Land the caret at the end of a sticky, where typing continues.
    if (el.isContentEditable) {
      const sel = window.getSelection()
      if (!sel) return
      const range = document.createRange()
      range.selectNodeContents(el)
      range.collapse(false)
      sel.removeAllRanges()
      sel.addRange(range)
    }
  })
}
