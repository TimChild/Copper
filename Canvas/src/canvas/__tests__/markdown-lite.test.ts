import { describe, expect, it } from 'vitest'
import { continueList, inlineText, parseInline, parseMarkdownLite, toggleTask, type Inline } from '../markdown-lite'

const text = (t: string): Inline => ({ type: 'text', text: t })

describe('parseInline', () => {
  it('leaves plain text as one node', () => {
    expect(parseInline('hello there')).toEqual([text('hello there')])
    expect(parseInline('** spaced **')).toEqual([text('** spaced **')])
  })

  it('returns nothing for an empty string', () => {
    expect(parseInline('')).toEqual([])
  })

  it('parses bold, italic, strike and code', () => {
    expect(parseInline('**b** *i* ~~s~~ `c`')).toEqual([
      { type: 'bold', children: [text('b')] },
      text(' '),
      { type: 'italic', children: [text('i')] },
      text(' '),
      { type: 'strike', children: [text('s')] },
      text(' '),
      { type: 'code', text: 'c' },
    ])
  })

  it('nests italic inside bold', () => {
    expect(parseInline('**a *b* c**')).toEqual([
      { type: 'bold', children: [text('a '), { type: 'italic', children: [text('b')] }, text(' c')] },
    ])
  })

  it('does not parse marks inside code', () => {
    expect(parseInline('`**x**`')).toEqual([{ type: 'code', text: '**x**' }])
  })

  it('keeps unmatched marks literal', () => {
    expect(inlineText(parseInline('a * b ** c `d'))).toBe('a * b ** c `d')
  })

  it('links bare URLs and leaves trailing punctuation outside', () => {
    expect(parseInline('go to https://example.com/a?b=1.')).toEqual([
      text('go to '),
      { type: 'link', href: 'https://example.com/a?b=1', children: [text('https://example.com/a?b=1')] },
      text('.'),
    ])
  })

  it('keeps balanced parentheses in a URL and drops an unbalanced closer', () => {
    const [, link] = parseInline('(see https://example.com/docs/Foo_(bar))')
    expect(link).toMatchObject({ type: 'link', href: 'https://example.com/docs/Foo_(bar)' })
  })

  it('parses [text](url) links with marks in the text, and refuses other schemes', () => {
    expect(parseInline('[**go**](https://x.dev)')).toEqual([
      { type: 'link', href: 'https://x.dev', children: [{ type: 'bold', children: [text('go')] }] },
    ])
    expect(parseInline('[x](javascript:alert(1))')[0]).toMatchObject({ type: 'text' })
  })

  it('does not treat markup-looking HTML specially', () => {
    expect(parseInline('<b>hi</b>')).toEqual([text('<b>hi</b>')])
  })
})

describe('parseMarkdownLite', () => {
  it('returns no blocks for empty or blank text', () => {
    expect(parseMarkdownLite('')).toEqual([])
    expect(parseMarkdownLite('  \n \n')).toEqual([])
  })

  it('parses the three heading levels, and treats four hashes as text', () => {
    expect(parseMarkdownLite('# a\n## b\n### c\n#### d').map(b => b.type)).toEqual(['heading', 'heading', 'heading', 'paragraph'])
  })

  it('keeps single newlines inside a paragraph as separate lines', () => {
    expect(parseMarkdownLite('line one\nline two\n\nnext para')).toEqual([
      { type: 'paragraph', lines: [[text('line one')], [text('line two')]] },
      { type: 'paragraph', lines: [[text('next para')]] },
    ])
  })

  it('parses - and * bullets into one list, with source lines', () => {
    expect(parseMarkdownLite('- one\n* two\n-   three')).toEqual([
      {
        type: 'list',
        ordered: false,
        items: [
          { depth: 0, children: [text('one')], line: 0 },
          { depth: 0, children: [text('two')], line: 1 },
          { depth: 0, children: [text('three')], line: 2 },
        ],
      },
    ])
  })

  it('parses task boxes', () => {
    const [list] = parseMarkdownLite('- [ ] todo\n- [x] done\n- plain')
    expect(list).toMatchObject({
      items: [
        { checked: false, children: [text('todo')] },
        { checked: true, children: [text('done')] },
        { children: [text('plain')] },
      ],
    })
    expect((list as { items: { checked?: boolean }[] }).items[2]!.checked).toBeUndefined()
  })

  it('parses quotes', () => {
    expect(parseMarkdownLite('> a\n> b')).toEqual([{ type: 'quote', lines: [[text('a')], [text('b')]] }])
  })

  it('parses numbered lists with . or ) and keeps the start number', () => {
    expect(parseMarkdownLite('3. a\n4) b')[0]).toMatchObject({ type: 'list', ordered: true, start: 3, items: [{}, {}] })
  })

  it('records nesting depth from indentation', () => {
    expect(parseMarkdownLite('- a\n  - b\n    - c\n\t- d')[0]).toMatchObject({
      items: [{ depth: 0 }, { depth: 1 }, { depth: 2 }, { depth: 1 }],
    })
  })

  it('folds an indented continuation line into the previous item', () => {
    expect(parseMarkdownLite('- first\n  more **here**')[0]).toMatchObject({
      items: [{ children: [text('first more '), { type: 'bold', children: [text('here')] }] }],
    })
  })

  it('handles CRLF line endings', () => {
    expect(parseMarkdownLite('a\r\nb')).toEqual([{ type: 'paragraph', lines: [[text('a')], [text('b')]] }])
  })
})

describe('editing helpers', () => {
  it('toggles the task box on one line only', () => {
    expect(toggleTask('- [ ] a\n- [x] b', 0)).toBe('- [x] a\n- [x] b')
    expect(toggleTask('- [ ] a\n- [x] b', 1)).toBe('- [ ] a\n- [ ] b')
    expect(toggleTask('plain', 0)).toBe('plain')
    expect(toggleTask('x', 9)).toBe('x')
  })

  it('continues bullets, numbers and tasks, and ends an empty item', () => {
    expect(continueList('- one')).toEqual({ insert: '\n- ' })
    expect(continueList('  * nested')).toEqual({ insert: '\n  * ' })
    expect(continueList('9. nine')).toEqual({ insert: '\n10. ' })
    expect(continueList('- [x] done')).toEqual({ insert: '\n- [ ] ' })
    expect(continueList('- ')).toEqual({ clear: true })
    expect(continueList('just text')).toBeNull()
  })
})

describe('inlineText', () => {
  it('flattens inline nodes to their visible text', () => {
    expect(inlineText(parseInline('**a** *b* `c` ~~d~~ [e](https://e.dev)'))).toBe('a b c d e')
  })
})
