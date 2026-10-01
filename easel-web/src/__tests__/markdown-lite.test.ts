import { describe, expect, it } from 'vitest'
import {
  inlineText,
  parseInline,
  parseMarkdownLite,
  type Inline,
} from '../lib/markdown-lite'

const text = (t: string): Inline => ({ type: 'text', text: t })

describe('parseInline', () => {
  it('leaves plain text as one node', () => {
    expect(parseInline('just words, no marks')).toEqual([
      text('just words, no marks'),
    ])
  })

  it('returns nothing for an empty string', () => {
    expect(parseInline('')).toEqual([])
  })

  it('parses bold', () => {
    expect(parseInline('a **b** c')).toEqual([
      text('a '),
      { type: 'bold', children: [text('b')] },
      text(' c'),
    ])
  })

  it('parses italic', () => {
    expect(parseInline('an *aside* here')).toEqual([
      text('an '),
      { type: 'italic', children: [text('aside')] },
      text(' here'),
    ])
  })

  it('nests italic inside bold and bold inside italic', () => {
    expect(parseInline('**big *and* bold**')).toEqual([
      {
        type: 'bold',
        children: [
          text('big '),
          { type: 'italic', children: [text('and')] },
          text(' bold'),
        ],
      },
    ])
    expect(parseInline('*soft **loud** soft*')).toEqual([
      {
        type: 'italic',
        children: [
          text('soft '),
          { type: 'bold', children: [text('loud')] },
          text(' soft'),
        ],
      },
    ])
  })

  it('parses inline code without parsing marks inside it', () => {
    expect(parseInline('run `a **b** [[c]]` now')).toEqual([
      text('run '),
      { type: 'code', text: 'a **b** [[c]]' },
      text(' now'),
    ])
  })

  it('keeps unmatched marks literal', () => {
    expect(parseInline('2 * 3 = 6')).toEqual([text('2 * 3 = 6')])
    expect(parseInline('**open bold')).toEqual([text('**open bold')])
    expect(parseInline('*open italic')).toEqual([text('*open italic')])
    expect(parseInline('a ` tick')).toEqual([text('a ` tick')])
    expect(parseInline('``')).toEqual([text('``')])
    expect(parseInline('[[unclosed')).toEqual([text('[[unclosed')])
    expect(parseInline('[[]]')).toEqual([text('[[]]')])
    expect(parseInline('** spaced **')).toEqual([text('** spaced **')])
  })

  it('parses wikilinks, with and without a label', () => {
    expect(parseInline('see [[Roadmap]]')).toEqual([
      text('see '),
      { type: 'wikilink', target: 'Roadmap', label: 'Roadmap' },
    ])
    expect(parseInline('[[Invoice policy|the policy]]!')).toEqual([
      { type: 'wikilink', target: 'Invoice policy', label: 'the policy' },
      text('!'),
    ])
  })

  it('trims wikilink whitespace and falls back to the target for an empty label', () => {
    expect(parseInline('[[ Q3 plan | ]]')).toEqual([
      { type: 'wikilink', target: 'Q3 plan', label: 'Q3 plan' },
    ])
  })

  it('links bare URLs and leaves trailing punctuation outside', () => {
    expect(parseInline('go to https://example.com/a?b=1.')).toEqual([
      text('go to '),
      {
        type: 'link',
        href: 'https://example.com/a?b=1',
        children: [text('https://example.com/a?b=1')],
      },
      text('.'),
    ])
  })

  it('keeps balanced parentheses in a URL and drops an unbalanced closer', () => {
    const [, wiki] = parseInline(
      'see https://en.wikipedia.org/wiki/Foo_(bar) ok'
    )
    expect(wiki).toMatchObject({
      type: 'link',
      href: 'https://en.wikipedia.org/wiki/Foo_(bar)',
    })
    expect(parseInline('(https://example.com)')).toEqual([
      text('('),
      {
        type: 'link',
        href: 'https://example.com',
        children: [text('https://example.com')],
      },
      text(')'),
    ])
  })

  it('does not link a scheme glued to a word or a bare scheme', () => {
    expect(parseInline('xhttps://example.com')).toEqual([
      text('xhttps://example.com'),
    ])
    expect(parseInline('http:// nothing')).toEqual([text('http:// nothing')])
    expect(parseInline('javascript:alert(1)')).toEqual([
      text('javascript:alert(1)'),
    ])
  })

  it('parses [text](url) links with inline marks in the text', () => {
    expect(parseInline('[the **docs**](https://x.dev/docs) here')).toEqual([
      {
        type: 'link',
        href: 'https://x.dev/docs',
        children: [text('the '), { type: 'bold', children: [text('docs')] }],
      },
      text(' here'),
    ])
  })

  it('refuses non-http link targets', () => {
    expect(parseInline('[x](javascript:alert(1))')).toEqual([
      text('[x](javascript:alert(1))'),
    ])
  })

  it('does not treat markup-looking HTML specially', () => {
    expect(parseInline('<b>hi</b>')).toEqual([text('<b>hi</b>')])
  })
})

describe('parseMarkdownLite', () => {
  it('returns no blocks for empty or blank text', () => {
    expect(parseMarkdownLite('')).toEqual([])
    expect(parseMarkdownLite('  \n\n  ')).toEqual([])
  })

  it('parses the three heading levels, and treats four hashes as text', () => {
    expect(parseMarkdownLite('# One\n## Two\n### Three\n#### Four')).toEqual([
      { type: 'heading', level: 1, children: [text('One')] },
      { type: 'heading', level: 2, children: [text('Two')] },
      { type: 'heading', level: 3, children: [text('Three')] },
      { type: 'paragraph', lines: [[text('#### Four')]] },
    ])
  })

  it('needs a space after the hash and strips closing hashes', () => {
    expect(parseMarkdownLite('#hashtag')).toEqual([
      { type: 'paragraph', lines: [[text('#hashtag')]] },
    ])
    expect(parseMarkdownLite('## Title ##')).toEqual([
      { type: 'heading', level: 2, children: [text('Title')] },
    ])
  })

  it('parses inline marks inside headings', () => {
    expect(parseMarkdownLite('# Ship **v2**')).toEqual([
      {
        type: 'heading',
        level: 1,
        children: [text('Ship '), { type: 'bold', children: [text('v2')] }],
      },
    ])
  })

  it('keeps single newlines inside a paragraph as separate lines', () => {
    expect(parseMarkdownLite('line one\nline two\n\nnext para')).toEqual([
      { type: 'paragraph', lines: [[text('line one')], [text('line two')]] },
      { type: 'paragraph', lines: [[text('next para')]] },
    ])
  })

  it('parses - and * bullets into one list', () => {
    expect(parseMarkdownLite('- one\n* two\n-   three')).toEqual([
      {
        type: 'list',
        ordered: false,
        items: [
          { depth: 0, children: [text('one')] },
          { depth: 0, children: [text('two')] },
          { depth: 0, children: [text('three')] },
        ],
      },
    ])
  })

  it('does not mistake italic or bold at line start for a bullet', () => {
    expect(parseMarkdownLite('*note* this')).toEqual([
      {
        type: 'paragraph',
        lines: [[{ type: 'italic', children: [text('note')] }, text(' this')]],
      },
    ])
    expect(parseMarkdownLite('**bold** start')[0]).toMatchObject({
      type: 'paragraph',
    })
    expect(parseMarkdownLite('---')[0]).toMatchObject({ type: 'paragraph' })
  })

  it('parses numbered lists with . or ) and keeps the start number', () => {
    expect(parseMarkdownLite('3. c\n4) d')).toEqual([
      {
        type: 'list',
        ordered: true,
        start: 3,
        items: [
          { depth: 0, children: [text('c')] },
          { depth: 0, children: [text('d')] },
        ],
      },
    ])
  })

  it('records nesting depth from indentation', () => {
    const [list] = parseMarkdownLite('- a\n  - b\n    - c\n\t- d')
    expect(list).toMatchObject({
      type: 'list',
      items: [{ depth: 0 }, { depth: 1 }, { depth: 2 }, { depth: 1 }],
    })
  })

  it('starts a new list when switching between bullets and numbers', () => {
    const blocks = parseMarkdownLite('- a\n1. b')
    expect(blocks.map(b => b.type === 'list' && b.ordered)).toEqual([
      false,
      true,
    ])
  })

  it('folds an indented continuation line into the previous item', () => {
    expect(parseMarkdownLite('- first\n  more **here**')).toEqual([
      {
        type: 'list',
        ordered: false,
        items: [
          {
            depth: 0,
            children: [
              text('first more '),
              { type: 'bold', children: [text('here')] },
            ],
          },
        ],
      },
    ])
  })

  it('ends a list at an unindented line', () => {
    expect(parseMarkdownLite('- a\nafter').map(b => b.type)).toEqual([
      'list',
      'paragraph',
    ])
  })

  it('handles CRLF line endings', () => {
    expect(parseMarkdownLite('# T\r\n- x\r\n')).toEqual([
      { type: 'heading', level: 1, children: [text('T')] },
      {
        type: 'list',
        ordered: false,
        items: [{ depth: 0, children: [text('x')] }],
      },
    ])
  })

  it('parses a realistic sticky', () => {
    const blocks = parseMarkdownLite(
      [
        '## Launch checklist',
        '- [[Pricing]] signed off',
        '- ship `v2.1` *today*',
        '',
        'Notes: https://example.com/notes',
      ].join('\n')
    )
    expect(blocks.map(b => b.type)).toEqual(['heading', 'list', 'paragraph'])
    expect(blocks[1]).toMatchObject({
      items: [
        {
          children: [
            { type: 'wikilink', target: 'Pricing' },
            text(' signed off'),
          ],
        },
        {
          children: [
            text('ship '),
            { type: 'code', text: 'v2.1' },
            text(' '),
            { type: 'italic' },
          ],
        },
      ],
    })
    expect(blocks[2]).toMatchObject({
      lines: [
        [
          text('Notes: '),
          { type: 'link', href: 'https://example.com/notes' },
        ],
      ],
    })
  })
})

describe('inlineText', () => {
  it('flattens inline nodes to their visible text', () => {
    expect(
      inlineText(parseInline('**a** *b* `c` [[D|dee]] [e](https://e.dev)'))
    ).toBe('a b c dee e')
  })
})
