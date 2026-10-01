// @vitest-environment jsdom
// Ported from the wiki app's __tests__/canvas-sticky-markdown.test.tsx: the
// doc comes from context (a spy object) instead of a mocked module.
import './setup-tiptap'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Selection } from '@tiptap/pm/state'
import type { EditorView } from '@tiptap/pm/view'
import type { ReactNode } from 'react'
import { currentEditorView } from './setup-tiptap'
import {
  FrameShape,
  SelectionBar,
  StickyShape,
} from '../components/canvas-shapes'
import { EaselContext } from '../components/easel-context'
import { MarkdownLite } from '../components/markdown-lite'
import { SHAPE_COLORS, type EaselDoc, type Shape } from '../doc/easel-doc'
import type { Host } from '../host/types'

const setShapeText = vi.fn()
const updateShape = vi.fn()
const open = vi.fn()
const doc = { setShapeText, updateShape } as unknown as EaselDoc
const host = {
  open,
  fileUrl: (e: string, f: string) => `copper-easel://easel/files/${e}/${f}`,
} as unknown as Host
const viewer = { id: 'me', name: 'Me', color: '#f00' }

const wrap = (ui: ReactNode) =>
  render(
    <EaselContext.Provider value={{ doc, host, easelId: 'e1', viewer }}>
      {ui}
    </EaselContext.Provider>
  )

afterEach(() => {
  cleanup()
  setShapeText.mockClear()
  updateShape.mockClear()
  open.mockClear()
})

const sticky = (text: string, patch: Partial<Shape> = {}): Shape => ({
  id: 's1',
  type: 'sticky',
  x: 0,
  y: 0,
  w: 200,
  h: 140,
  color: 'yellow',
  text,
  ...patch,
})

const props = {
  at: { x: 0, y: 0 },
  selected: false,
  pending: false,
  lifted: false,
}

/** Type like a keyboard would: input rules first, then plain insertion. */
function type(view: EditorView, text: string) {
  for (const ch of text) {
    const { from, to } = view.state.selection
    const handled = view.someProp('handleTextInput', f =>
      f(view, from, to, ch, () => view.state.tr.insertText(ch, from, to))
    )
    if (!handled) view.dispatch(view.state.tr.insertText(ch, from, to))
  }
}

function press(view: EditorView, key: string, init: KeyboardEventInit = {}) {
  view.someProp('handleKeyDown', f =>
    f(view, new KeyboardEvent('keydown', { key, bubbles: true, ...init }))
  )
}

const focusedEditor = () => {
  const el = screen.getByLabelText('Sticky note')
  act(() => el.focus())
  fireEvent.focus(el)
  const view = currentEditorView()
  act(() => view.focus())
  return view
}

describe('MarkdownLite', () => {
  it('renders elements, never raw HTML', () => {
    const { container } = render(
      <MarkdownLite
        source={
          '# Hi <img src=x onerror=alert(1)>\n- **b** [[Wiki]]\n\nsee https://x.dev'
        }
      />
    )
    expect(container.querySelector('h1')?.textContent).toBe(
      'Hi <img src=x onerror=alert(1)>'
    )
    expect(container.querySelector('img')).toBeNull()
    expect(container.querySelector('li strong')?.textContent).toBe('b')
    expect(container.querySelector('[data-wikilink="Wiki"]')?.textContent).toBe(
      'Wiki'
    )
    const a = container.querySelector('a')!
    expect(a.getAttribute('href')).toBe('https://x.dev')
    expect(a.getAttribute('rel')).toContain('noopener')
  })
})

describe('StickyShape live markdown editor', () => {
  it('renders markdown in place, with no separate preview layer', () => {
    wrap(<StickyShape shape={sticky('**bold** move')} {...props} />)
    const view = screen.getByTestId('sticky-editor')
    expect(view.querySelector('strong')?.textContent).toBe('bold')
    const field = screen.getByLabelText('Sticky note')
    expect(field.getAttribute('contenteditable')).toBe('true')
    expect(field.textContent).toBe('bold move')
  })

  it('shows the placeholder when empty', () => {
    wrap(<StickyShape shape={sticky('')} {...props} />)
    const empty = screen
      .getByTestId('sticky-editor')
      .querySelector('p.is-editor-empty')
    expect(empty?.getAttribute('data-placeholder')).toBe('Type something')
  })

  it('renders [[wikilinks]] as chips while keeping the text literal', () => {
    wrap(<StickyShape shape={sticky('see [[Q3 plan|the plan]]')} {...props} />)
    const chip = screen
      .getByTestId('sticky-editor')
      .querySelector('[data-wikilink="Q3 plan"]')
    expect(chip?.textContent).toBe('[[Q3 plan|the plan]]')
  })

  it('never renders raw HTML typed into a note', () => {
    wrap(
      <StickyShape shape={sticky('<img src=x onerror=alert(1)>')} {...props} />
    )
    const view = screen.getByLabelText('Sticky note')
    expect(view.querySelector('img')).toBeNull()
    expect(view.textContent).toContain('<img')
  })

  it('re-renders live when the shape text changes underneath (remote typing)', () => {
    const { rerender } = wrap(<StickyShape shape={sticky('- one')} {...props} />)
    expect(screen.getAllByRole('listitem')).toHaveLength(1)
    rerender(
      <EaselContext.Provider value={{ doc, host, easelId: 'e1', viewer }}>
        <StickyShape shape={sticky('- one\n- two')} {...props} />
      </EaselContext.Provider>
    )
    expect(screen.getAllByRole('listitem').map(li => li.textContent)).toEqual([
      'one',
      'two',
    ])
    // Applying a remote change is not an edit of ours.
    expect(setShapeText).not.toHaveBeenCalled()
  })

  it('turns "- " into a bullet and Enter continues the list, writing markdown back', () => {
    wrap(<StickyShape shape={sticky('')} {...props} />)
    const view = focusedEditor()

    act(() => type(view, '- one'))
    expect(screen.getAllByRole('listitem').map(li => li.textContent)).toEqual([
      'one',
    ])

    act(() => {
      press(view, 'Enter')
      type(view, 'two')
    })
    expect(screen.getAllByRole('listitem').map(li => li.textContent)).toEqual([
      'one',
      'two',
    ])
    expect(setShapeText.mock.lastCall).toEqual(['s1', '- one\n- two'])

    // Enter on an empty item leaves the list.
    act(() => {
      press(view, 'Enter')
      press(view, 'Enter')
      type(view, 'after')
    })
    expect(screen.getAllByRole('listitem')).toHaveLength(2)
    expect(setShapeText.mock.lastCall).toEqual(['s1', '- one\n- two\n\nafter'])
  })

  it('formats **bold** and # headings as they are typed', () => {
    wrap(<StickyShape shape={sticky('')} {...props} />)
    const view = focusedEditor()
    act(() => type(view, '# Title'))
    expect(
      screen.getByTestId('sticky-editor').querySelector('h1')?.textContent
    ).toBe('Title')
    act(() => {
      press(view, 'Enter')
      type(view, 'so **bold**')
    })
    expect(
      screen.getByTestId('sticky-editor').querySelector('p strong')?.textContent
    ).toBe('bold')
    expect(setShapeText.mock.lastCall).toEqual(['s1', '# Title\n\nso **bold**'])
  })

  it('keeps [[wikilinks]] unescaped in the stored markdown', () => {
    wrap(<StickyShape shape={sticky('')} {...props} />)
    const view = focusedEditor()
    act(() => type(view, 'see [[Roadmap]]'))
    expect(setShapeText.mock.lastCall).toEqual(['s1', 'see [[Roadmap]]'])
  })

  it('offers swatches and delete on the selection bar, colouring every selected shape', () => {
    const onDelete = vi.fn()
    wrap(
      <SelectionBar
        shapes={[sticky('x', { color: 'white' }), sticky('y', { id: 's2', color: 'white' })]}
        at={{ x: 100, y: 100 }}
        onDelete={onDelete}
      />
    )
    expect(SHAPE_COLORS).toContain('white')
    const white = screen.getByLabelText('Colour white')
    expect(white.getAttribute('aria-pressed')).toBe('true')
    fireEvent.click(screen.getByLabelText('Colour blue'))
    expect(updateShape).toHaveBeenCalledWith('s1', { color: 'blue' })
    expect(updateShape).toHaveBeenCalledWith('s2', { color: 'blue' })
    fireEvent.click(screen.getByLabelText('Delete 2 items'))
    expect(onDelete).toHaveBeenCalledTimes(1)
  })

  it('offers only delete for an arrow, and remove-image for a pictured frame', () => {
    wrap(
      <SelectionBar
        shapes={[{ ...sticky(''), type: 'arrow', from: 'shape:a', to: 'shape:b' }]}
        at={{ x: 0, y: 0 }}
        onDelete={() => undefined}
      />
    )
    expect(screen.queryByLabelText('Colour yellow')).toBeNull()
    expect(screen.getByLabelText('Delete arrow')).toBeTruthy()
    cleanup()
    wrap(
      <SelectionBar
        shapes={[sticky('', { type: 'frame', image: 'file:p.png' })]}
        at={{ x: 0, y: 0 }}
        onDelete={() => undefined}
      />
    )
    fireEvent.click(screen.getByLabelText('Remove image'))
    expect(updateShape).toHaveBeenCalledWith('s1', { image: '' })
  })
})

describe('FrameShape', () => {
  it('renders inline markdown in the title and swaps to the input on focus', () => {
    wrap(
      <FrameShape
        shape={sticky('## Q3 *plan*', { type: 'frame', w: 480, h: 320 })}
        {...props}
      />
    )
    expect(screen.getByText('plan').tagName).toBe('EM')
    const input = screen.getByLabelText('Frame title')
    fireEvent.focus(input)
    expect(screen.queryByText('plan')).toBeNull()
  })

  it('renders a file: picture through the host', () => {
    wrap(
      <FrameShape
        shape={sticky('Shot', { type: 'frame', w: 480, h: 320, image: 'file:p.png' })}
        {...props}
      />
    )
    expect(screen.getByAltText('Shot').getAttribute('src')).toBe(
      'copper-easel://easel/files/e1/p.png'
    )
  })
})

describe('sticky markdown round-trip (what Yjs sees)', () => {
  const roundTrip = (source: string) => {
    wrap(<StickyShape shape={sticky(source)} {...props} />)
    const view = focusedEditor()
    // Nudge the doc so a local update fires, then undo the nudge.
    const end = Selection.atEnd(view.state.doc).from
    act(() => view.dispatch(view.state.tr.insertText('~', end)))
    act(() => view.dispatch(view.state.tr.delete(end, end + 1)))
    const last = setShapeText.mock.lastCall
    cleanup()
    return last?.[1]
  }

  it('does not escape plain punctuation or emit HTML entities', () => {
    expect(roundTrip('snake_case and 5 * 3 and [brackets]')).toBe(
      'snake_case and 5 * 3 and [brackets]'
    )
    expect(roundTrip('C:\\path and <Component> & co')).toBe(
      'C:\\path and <Component> & co'
    )
  })

  it('keeps task-list boxes', () => {
    wrap(<StickyShape shape={sticky('- [ ] todo\n- [x] done')} {...props} />)
    const boxes = screen
      .getByTestId('sticky-editor')
      .querySelectorAll('input[type="checkbox"]')
    expect(boxes).toHaveLength(2)
    expect((boxes[1] as HTMLInputElement).checked).toBe(true)
    cleanup()
    expect(roundTrip('- [ ] todo\n- [x] done')).toBe('- [ ] todo\n- [x] done')
  })

  it('turns "- [ ] " typed into a bullet into a live task item', () => {
    wrap(<StickyShape shape={sticky('')} {...props} />)
    const view = focusedEditor()
    act(() => type(view, '- [ ] todo'))
    const boxes = screen
      .getByTestId('sticky-editor')
      .querySelectorAll('input[type="checkbox"]')
    expect(boxes).toHaveLength(1)
    expect(setShapeText.mock.lastCall).toEqual(['s1', '- [ ] todo'])
    act(() => {
      press(view, 'Enter')
      type(view, '[x] next')
    })
    expect(setShapeText.mock.lastCall).toEqual(['s1', '- [ ] todo\n- [x] next'])
  })

  it('ticks a task box from the board without entering edit mode', () => {
    wrap(<StickyShape shape={sticky('- [ ] todo\n- [x] done')} {...props} />)
    const box = screen
      .getByTestId('sticky-editor')
      .querySelector('input[type="checkbox"]')!
    fireEvent.pointerDown(box)
    // The browser still fires click after a cancelled pointerdown; it must
    // not toggle a second time or hand focus to the editor.
    fireEvent.click(box)
    expect(setShapeText).toHaveBeenCalledTimes(1)
    expect(setShapeText.mock.lastCall).toEqual(['s1', '- [x] todo\n- [x] done'])
    expect(document.activeElement).toBe(document.body)
  })

  it('opens a link from the board through the host instead of editing', () => {
    wrap(<StickyShape shape={sticky('see https://x.dev/docs')} {...props} />)
    const link = screen.getByTestId('sticky-editor').querySelector('a')!
    fireEvent.pointerDown(link)
    fireEvent.click(link)
    expect(open).toHaveBeenCalledTimes(1)
    expect(open).toHaveBeenCalledWith('https://x.dev/docs')
    expect(document.activeElement).toBe(document.body)
  })

  it('keeps real emphasis escapes so the note reloads unchanged', () => {
    const stored = roundTrip('**bold** and *it* and `code`')
    expect(stored).toBe('**bold** and *it* and `code`')
  })
})
