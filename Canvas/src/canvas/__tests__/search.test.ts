import { describe, expect, it } from 'vitest'
import { MIN_ZOOM } from '../geometry'
import {
  READABLE_ZOOM,
  arrowLabelBox,
  boardSearchItems,
  clipSnippet,
  flightView,
  fold,
  indexSearchItems,
  markText,
  matchQuality,
  plainText,
  queryTerms,
  revealView,
  searchIndex,
  searchItems,
  snippetChars,
  stepHit,
  type Highlighted,
  type SearchItem,
} from '../search'
import type { Shape } from '../types'

const sticky = (id: string, text: string, patch: Partial<SearchItem> = {}) =>
  ({ ref: id, kind: 'sticky', text, ...patch }) as SearchItem
const frame = (id: string, title: string) => ({ ref: id, kind: 'frame', text: title }) as SearchItem

/** The marked slices of a highlighted string. */
const marked = (h: Highlighted) => h.marks.map(([a, b]) => h.text.slice(a, b))

describe('plainText', () => {
  it('drops markdown marks and keeps what a reader sees', () => {
    expect(plainText('# Plan\n**Ship** it *soon* with `bun`').text).toBe('Plan Ship it soon with bun')
  })

  it('shows a link by its text and keeps the address as an alias', () => {
    const plain = plainText('see [the plan](https://x.dev/plan) now')
    expect(plain.text).toBe('see the plan now')
    expect(plain.aliases).toEqual([{ start: 4, end: 12, text: 'https://x.dev/plan' }])
  })

  it('reads lists, task boxes, quotes, strikes and escapes as text', () => {
    expect(plainText('- [ ] write \\*docs\\*\n- [x] [ship](https://x.dev) it\n> quoted ~~old~~').text).toBe(
      'write *docs* ship it quoted old'
    )
  })
})

describe('fold and queryTerms', () => {
  it('is case- and accent-insensitive and maps back to the source', () => {
    const f = fold('Crème Brûlée')
    expect(f.text).toBe('creme brulee')
    expect(f.map[f.text.length]).toBe('Crème Brûlée'.length)
  })

  it('folds letters NFD keeps whole', () => {
    expect(fold('Straße Øre').text).toBe('strasse ore')
  })

  it('splits on space and markdown punctuation, deduplicated', () => {
    expect(queryTerms('  [Road|Map]  road  **ÉTÉ** ')).toEqual(['road', 'map', 'ete'])
    expect(queryTerms('   ')).toEqual([])
  })
})

describe('matchQuality', () => {
  it('ranks start over word start over mid-word', () => {
    expect(matchQuality('roadmap review', 'road')).toBe(2)
    expect(matchQuality('the road ahead', 'road')).toBe(1)
    expect(matchQuality('railroad', 'road')).toBe(0)
    expect(matchQuality('railroad', 'sea')).toBe(-1)
  })

  it('finds a word start past an earlier mid-word hit', () => {
    expect(matchQuality('railroad-road', 'road')).toBe(1)
  })
})

describe('searchItems', () => {
  const board = [
    sticky('railroad', 'Railroad crossing'),
    sticky('closures', 'Check the road closures'),
    sticky('review', 'Roadmap review Friday'),
    frame('roadmap', 'Roadmap'),
    frame('offroad', 'Offroad'),
    { ref: 'link', kind: 'link', text: 'Q3 plan', url: 'https://x.dev/q3-roadmap' } as SearchItem,
  ]

  it('puts start matches first, titles before notes, mid-word last', () => {
    expect(searchItems(board, 'road').map(r => r.ref)).toEqual(['roadmap', 'review', 'closures', 'link', 'offroad', 'railroad'])
  })

  it('needs every term (AND), in any field', () => {
    expect(searchItems(board, 'road friday').map(r => r.ref)).toEqual(['review'])
    expect(searchItems(board, 'q3 roadmap').map(r => r.ref)).toEqual(['link'])
    expect(searchItems(board, 'road nowhere')).toEqual([])
  })

  it('returns nothing for an empty query', () => {
    expect(searchItems(board, '  ')).toEqual([])
  })

  it('matches through markdown and accents, and marks the visible text', () => {
    const [hit] = searchItems([sticky('s', '**Café** notes: see [the launch](https://x.dev/plan)')], 'cafe plan')
    expect(hit?.primary.text).toBe('Café notes: see the launch')
    expect(marked(hit!.primary)).toEqual(['Café', 'the launch'])
  })

  it('marks every occurrence, and the address of a link', () => {
    const [hit] = searchItems([{ ref: 'l', kind: 'link', text: 'Plan the plan', url: 'https://x.dev/plan' }], 'plan')
    expect(marked(hit!.primary)).toEqual(['Plan', 'plan'])
    expect(marked(hit!.secondary!)).toEqual(['plan'])
  })

  it('orders ties top to bottom, then left to right', () => {
    const items = [
      sticky('c', 'todo', { at: { x: 0, y: 500 } }),
      sticky('b', 'todo', { at: { x: 400, y: 0 } }),
      sticky('a', 'todo', { at: { x: 0, y: 0 } }),
    ]
    expect(searchItems(items, 'todo').map(r => r.ref)).toEqual(['a', 'b', 'c'])
  })

  it('carries the author through', () => {
    const [hit] = searchItems([{ ...frame('f', 'Runbook'), by: 'Ada' }], 'run')
    expect(hit).toMatchObject({ by: 'Ada', field: 'title' })
  })
})

describe('clipSnippet', () => {
  it('keeps short text whole', () => {
    const h = { text: 'short', marks: [[0, 5]] as [number, number][] }
    expect(clipSnippet(h)).toBe(h)
  })

  it('cuts long text around the first mark on word boundaries', () => {
    const words = Array.from({ length: 40 }, (_, i) => `word${i}`).join(' ')
    const at = words.indexOf('word25')
    const out = clipSnippet({ text: words, marks: [[at, at + 6]] }, 60)
    expect(out.text.startsWith('…word')).toBe(true)
    expect(out.text.endsWith('…')).toBe(true)
    expect(out.text.length).toBeLessThanOrEqual(62)
    expect(marked(out)).toEqual(['word25'])
  })
})

describe('clipSnippet centring', () => {
  const sentence =
    'Ready to review Does the whiteboard preserve my edits while I am offline? Owner: Blair, and a few more words after that'

  it('puts the first match in the middle of the snippet', () => {
    const h = markText(sentence, ['offline'])
    const out = clipSnippet(h, 40)
    const [[a, b]] = out.marks as [[number, number]]
    expect(out.text.slice(a, b)).toBe('offline')
    const middle = (a + b) / 2 / out.text.length
    expect(middle).toBeGreaterThan(0.3)
    expect(middle).toBeLessThan(0.7)
    expect(out.text.startsWith('…')).toBe(true)
    expect(out.text.endsWith('…')).toBe(true)
  })

  it('keeps the match whole in a snippet shorter than the sentence before it', () => {
    for (const max of [24, 30, 50, 70]) {
      const out = clipSnippet(markText(sentence, ['offline']), max)
      expect(marked(out)).toEqual(['offline'])
      expect(out.text.length).toBeLessThanOrEqual(max + 2)
    }
  })

  it('starts at the beginning for an early match and ends at the end for a late one', () => {
    expect(clipSnippet(markText(sentence, ['ready']), 40).text.startsWith('Ready')).toBe(true)
    const late = clipSnippet(markText(sentence, ['that']), 40)
    expect(late.text.endsWith('that')).toBe(true)
    expect(marked(late)).toEqual(['that'])
  })

  it('cuts on word boundaries', () => {
    const out = clipSnippet(markText(sentence, ['offline']), 40)
    const inner = out.text.replace(/^…|…$/g, '')
    for (const w of inner.split(' ')) expect(sentence.split(/\s+/)).toContain(w)
  })
})

describe('snippetChars', () => {
  it('follows the row width, within bounds', () => {
    expect(snippetChars(460)).toBeGreaterThan(snippetChars(300))
    expect(snippetChars(100)).toBe(24)
    expect(snippetChars(5000)).toBe(120)
    expect(snippetChars(Number.NaN)).toBe(90)
  })

  it('centres a match a narrow row would otherwise truncate away', () => {
    const [hit] = searchIndex(
      indexSearchItems([{ ref: 'n', kind: 'sticky', text: '## Ready to review\nDoes the whiteboard preserve my edits while I am offline?' }]),
      'offline',
      { snippet: snippetChars(300) }
    )
    // The whole snippet fits the row, and the match is in it.
    expect(hit!.primary.text.length).toBeLessThanOrEqual(snippetChars(300) + 2)
    expect(marked(hit!.primary)).toEqual(['offline'])
  })
})

describe('boardSearchItems', () => {
  const shape = (patch: Partial<Shape> & Pick<Shape, 'id' | 'type'>): Shape => ({
    x: 0,
    y: 0,
    w: 200,
    h: 140,
    color: 'yellow',
    text: '',
    title: '',
    createdAt: 0,
    updatedAt: 0,
    z: 0,
    ...patch,
  })

  it('takes shapes with text, links, and arrows whose ends are on the board', () => {
    const items = boardSearchItems([
      shape({ id: 's1', type: 'sticky', text: 'hi', by: 'Ada', x: 5, y: 6 }),
      shape({ id: 's2', type: 'sticky', text: '  ' }),
      shape({ id: 't', type: 'text', text: 'Heading', x: 400 }),
      shape({ id: 'f', type: 'frame', title: 'Frame', x: 900 }),
      shape({ id: 'l', type: 'link', url: 'https://x.dev', x: 1300 }),
      shape({ id: 'i', type: 'image', src: 'data:image/png;base64,AA' }),
      shape({ id: 'a1', type: 'arrow', label: 'ok', from: { ref: 's1' }, to: { ref: 't' } }),
      shape({ id: 'a2', type: 'arrow', label: 'dangling', from: { ref: 's1' }, to: { ref: 'gone' } }),
      shape({ id: 'a3', type: 'arrow', label: '', from: { ref: 's1' }, to: { ref: 't' } }),
      shape({ id: 'a4', type: 'arrow', label: 'free', from: { x: 0, y: 0 }, to: { x: 100, y: 100 } }),
    ])
    expect(items).toEqual([
      { ref: 's1', kind: 'sticky', text: 'hi', at: { x: 5, y: 6 }, by: 'Ada' },
      { ref: 't', kind: 'text', text: 'Heading', at: { x: 400, y: 0 } },
      { ref: 'f', kind: 'frame', text: 'Frame', at: { x: 900, y: 0 } },
      { ref: 'l', kind: 'link', text: '', url: 'https://x.dev', at: { x: 1300, y: 0 } },
      { ref: 'a1', kind: 'arrow', text: 'ok' },
      { ref: 'a4', kind: 'arrow', text: 'free' },
    ])
  })
})

describe('stepHit', () => {
  it('lands on the highlighted hit first, then steps and wraps', () => {
    expect(stepHit(3, 1, false, 1)).toBe(1)
    expect(stepHit(3, 1, false, -1)).toBe(1)
    expect(stepHit(3, 1, true, 1)).toBe(2)
    expect(stepHit(3, 2, true, 1)).toBe(0)
    expect(stepHit(3, 0, true, -1)).toBe(2)
    expect(stepHit(0, 0, false, 1)).toBe(-1)
  })
})

describe('revealView', () => {
  const W = 1000
  const H = 600
  const box = { x: 1000, y: 2000, w: 200, h: 140 }
  const centre = (v: { x: number; y: number; z: number }) => ({ x: (W / 2 - v.x) / v.z, y: (H / 2 - v.y) / v.z })

  it('centres the box at a readable zoom', () => {
    const v = revealView(box, { x: 0, y: 0, z: 0.3 }, W, H)
    expect(v.z).toBe(READABLE_ZOOM)
    expect(centre(v)).toEqual({ x: 1100, y: 2070 })
  })

  it('never zooms out when the view is already closer', () => {
    expect(revealView(box, { x: 0, y: 0, z: 1.8 }, W, H).z).toBe(1.8)
  })

  it('fits a big box, and shows the top-left of one that cannot fit', () => {
    const big = { x: 0, y: 0, w: 1744, h: 944 }
    expect(revealView(big, { x: 0, y: 0, z: 0.2 }, W, H).z).toBeCloseTo(0.5)
    expect(revealView(big, { x: 0, y: 0, z: 1 }, W, H)).toEqual({ x: 64, y: 64, z: 1 })
  })

  it('centres in the part the search box leaves free', () => {
    const v = revealView(box, { x: 0, y: 0, z: 1 }, W, H, { top: 200 })
    expect((H / 2 + 100 - v.y) / v.z).toBe(2070)
    const huge = revealView(box, { x: 0, y: 0, z: 1 }, W, H, { top: 5000 })
    expect(huge.y).toBe(revealView(box, huge, W, H, { top: H / 2 }).y)
  })

  it('also leaves the tool bar at the bottom free', () => {
    const v = revealView(box, { x: 0, y: 0, z: 1 }, W, H, { top: 200, bottom: 68 })
    // Centred between 200 and H - 68.
    expect((200 + (H - 200 - 68) / 2 - v.y) / v.z).toBe(2070)
    // A cover too big for the room left is capped, so the box keeps a third.
    const capped = revealView(box, { x: 0, y: 0, z: 1 }, W, H, { top: 200, bottom: 5000 })
    expect(capped.y).toBe(revealView(box, capped, W, H, { top: 200, bottom: (H - 200) / 3 }).y)
  })

  it('centres an arrow on its label', () => {
    const b = arrowLabelBox({ x1: 0, y1: 0, x2: 400, y2: 200 })
    expect(b.x + b.w / 2).toBe(200)
    expect(b.y + b.h / 2).toBe(100)
  })
})

describe('flightView', () => {
  const W = 1000
  const H = 600
  const from = { x: 0, y: 0, z: 0.5 }
  const to = { x: -4000, y: -1000, z: 1 }

  it('starts and ends exactly on the two views', () => {
    expect(flightView(from, to, 0, W, H)).toEqual(from)
    expect(flightView(from, to, 1, W, H)).toEqual(to)
  })

  it('pulls out mid-flight on a long hop, never past the minimum zoom', () => {
    const mid = flightView(from, to, 0.5, W, H)
    expect(mid.z).toBeLessThan(Math.sqrt(from.z * to.z))
    expect(mid.z).toBeGreaterThanOrEqual(MIN_ZOOM)
  })

  it('does not pull out on a short hop', () => {
    const mid = flightView({ x: 0, y: 0, z: 1 }, { x: -100, y: 0, z: 1 }, 0.5, W, H)
    expect(mid.z).toBeCloseTo(1)
  })
})
