import { describe, expect, it } from 'vitest'
import * as Y from 'yjs'
import { shiftCaret, textSplice } from '../text-diff'

const apply = (prev: string, next: string) => {
  const { index, remove, insert } = textSplice(prev, next)
  return prev.slice(0, index) + insert + prev.slice(index + remove)
}

describe('textSplice', () => {
  it('finds the single changed span', () => {
    expect(textSplice('hello world', 'hello brave world')).toEqual({ index: 6, remove: 0, insert: 'brave ' })
    expect(textSplice('abcdef', 'abef')).toEqual({ index: 2, remove: 2, insert: '' })
    expect(textSplice('same', 'same')).toEqual({ index: 4, remove: 0, insert: '' })
  })

  it('handles repeated characters without overlapping prefix and suffix', () => {
    for (const [a, b] of [
      ['aaa', 'aa'],
      ['aa', 'aaaa'],
      ['', 'x'],
      ['x', ''],
      ['abab', 'ab'],
    ] as const)
      expect(apply(a, b)).toBe(b)
  })

  it('merges concurrent edits on a Y.Text', () => {
    const one = new Y.Doc()
    const two = new Y.Doc()
    one.getText('t').insert(0, 'buy milk')
    Y.applyUpdate(two, Y.encodeStateAsUpdate(one))
    const edit = (doc: Y.Doc, next: string) => {
      const t = doc.getText('t')
      const { index, remove, insert } = textSplice(t.toString(), next)
      t.delete(index, remove)
      t.insert(index, insert)
    }
    edit(one, 'buy oat milk')
    edit(two, 'buy milk and eggs')
    Y.applyUpdate(two, Y.encodeStateAsUpdate(one))
    Y.applyUpdate(one, Y.encodeStateAsUpdate(two))
    expect(one.getText('t').toString()).toBe('buy oat milk and eggs')
    expect(two.getText('t').toString()).toBe('buy oat milk and eggs')
  })
})

describe('shiftCaret', () => {
  it('keeps a caret before the change, shifts one after it', () => {
    expect(shiftCaret('hello world', 'hello brave world', 3)).toBe(3)
    expect(shiftCaret('hello world', 'hello brave world', 8)).toBe(14)
    expect(shiftCaret('abcdef', 'abef', 5)).toBe(3)
  })

  it('moves a caret inside a replaced span to the end of the insert', () => {
    expect(shiftCaret('abcdef', 'abXYef', 3)).toBe(4)
  })
})
