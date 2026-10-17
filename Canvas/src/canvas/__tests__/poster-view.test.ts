// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { alphaOf, posterPlace, posterView, shadowReach, type PosterViewDeps, type ScreenBox } from '../poster-view'
import { PosterBroker, type PosterMessage } from '../posters'

/*
 * A board as the page draws it: the viewport (role=application) holding the
 * transformed layer of shapes (a live frame among them, its page an iframe),
 * then the board's own UI (tool bar, panels…) over it, and the chat beside.
 * jsdom lays nothing out: every box on screen is given (`at`).
 */

const SVG = 'http://www.w3.org/2000/svg'
const rects = new Map<Element, ScreenBox>()
const box = (left: number, top: number, right: number, bottom: number): ScreenBox => ({ left, top, right, bottom })
const at = <E extends Element>(el: E, r: ScreenBox) => (rects.set(el, r), el)
const deps: PosterViewDeps = {
  rectOf: el => rects.get(el) ?? box(0, 0, 0, 0),
  // jsdom has no pseudo-element styles.
  styleOf: (el, pseudo) => (pseudo ? ({ content: 'none' } as CSSStyleDeclaration) : getComputedStyle(el)),
}

function div(attrs: Record<string, string> = {}, ...children: (Node | string)[]) {
  const el = document.createElement('div')
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v)
  el.append(...children)
  return el
}
function svg(tag: string, attrs: Record<string, string> = {}, ...children: Element[]) {
  const el = document.createElementNS(SVG, tag)
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v)
  el.append(...children)
  return el
}

/** The page's box: 900 × 600 at (200, 240). Under 3×3 sampling its rows were y = 258, 540, 822. */
const PAGE = box(200, 240, 1100, 840)

let app: HTMLElement
let layer: HTMLElement
let frame: HTMLElement
let body: HTMLElement
let page: HTMLIFrameElement
let arrows: SVGSVGElement

beforeEach(() => {
  rects.clear()
  document.body.innerHTML = ''
  page = at(document.createElement('iframe'), PAGE)
  body = at(div({ 'data-part': 'web-body', style: 'position: relative; background: rgb(244, 244, 245)' }, page), PAGE)
  const bar = at(div({ 'data-part': 'web-bar', style: 'background: white' }, 'Whiteboard · wikipedia.org'), box(200, 204, 1100, 240))
  const inner = at(div({ style: 'overflow: hidden; background: white; border: 1px solid rgb(0 0 0 / 0.1)' }, bar, body), box(199, 203, 1101, 841))
  frame = at(div({ 'data-id': 'wf-0215', 'data-kind': 'link', 'data-live': '1', style: 'position: absolute; box-shadow: 0 3px 8px -2px rgb(0 0 0 / 0.12)' }, inner), box(199, 203, 1101, 841))
  arrows = svg('svg', { width: '1', height: '1', style: 'position: absolute; overflow: visible' }) as SVGSVGElement
  at(arrows, box(0, 0, 1, 1))
  layer = div({ style: 'position: absolute' }, frame, arrows)
  app = at(div({ role: 'application', style: 'position: relative; overflow: hidden' }, layer), box(0, 0, 1440, 900))
  document.body.append(at(div({ style: 'display: flex; overflow: hidden' }, at(div({ style: 'position: relative' }, app), box(0, 0, 1440, 900))), box(0, 0, 1440, 900)))
})

const asked = () => posterPlace(page, deps)

/** An arrow from (x1, y1) to (x2, y2) on screen, drawn as the board draws one (`ArrowView`). */
function arrow(id: string, r: ScreenBox, on = false) {
  const g = svg(
    'g',
    { 'data-id': id, 'data-kind': 'arrow', ...(on ? { 'data-on': '' } : {}) },
    svg('path', { d: 'M0,0 L1,1', fill: 'none', stroke: 'transparent' }),
    svg('path', { d: 'M0,0 L1,1', fill: 'none', stroke: '#1d1d1f', 'stroke-width': '2' }),
    svg('path', { d: 'M1,1 L0,1 Z', fill: '#1d1d1f' })
  )
  arrows.append(at(g, r))
  return g
}

/** A note on the board (a text shape when `clear`: no background), drawn after (over) the frame unless `before`. */
function note(r: ScreenBox, { before = false, style = '', clear = false } = {}) {
  const n = at(
    div({ 'data-id': clear ? 'tx-1' : 'st-1', 'data-kind': clear ? 'text' : 'sticky', style: `position: absolute; ${clear ? '' : 'background: rgb(255, 236, 153);'} ${style}` }, 'Chen — spike: 2 days'),
    r
  )
  if (before) layer.prepend(n)
  else layer.insertBefore(n, arrows)
  return n
}

/** The board's tool bar: centred at the bottom, with its shadow. */
function toolbar(r: ScreenBox) {
  const bar = at(
    div(
      { 'data-part': 'toolbar', style: 'position: absolute; background: white; border-radius: 14px; box-shadow: 0 18px 40px -12px rgb(0 0 0 / 0.28)' },
      at(div({ role: 'button', style: 'background: rgba(0, 0, 0, 0)' }, 'Note'), { ...r, right: r.left + 40 })
    ),
    r
  )
  app.append(bar)
  return bar
}

describe('a live frame crossed by an arrow', () => {
  it('is still asked for its picture, with the arrow kept as part of it', async () => {
    arrow('ar-1399', box(150, 500, 1300, 520))
    arrow('ar-1385', box(600, 100, 640, 900))
    arrow('ar-far', box(1200, 100, 1400, 300))
    const place = asked()
    expect(place).not.toBeNull()
    expect(place!.over).toEqual(['ar-1385', 'ar-1399'])

    const sent: PosterMessage[] = []
    const broker = new PosterBroker(m => sent.push(m))
    const scene = { over: place!.over, key: 'k' }
    const got = broker.ask({ name: 'copper-frame:wf-0215:n', id: 'wf-0215', url: 'https://en.wikipedia.org/wiki/Whiteboard', rect: { x: 200, y: 240, w: 900, h: 600 }, scene }, 0)
    expect(sent).toHaveLength(1)
    broker.answer('copper-frame:wf-0215:n', `data:image/jpeg;base64,${'A'.repeat(64)}`)
    await expect(got).resolves.toBe(true)
    expect(broker.cache.peek('wf-0215', 'https://en.wikipedia.org/wiki/Whiteboard')?.scene).toEqual(scene)
  })

  it('a horizontal arrow (a box with no height) still counts as crossing', () => {
    arrow('ar-flat', box(100, 600, 1300, 600))
    expect(asked()?.over).toEqual(['ar-flat'])
  })

  it('is not asked while that arrow is selected (its halo would be in the picture)', () => {
    arrow('ar-1399', box(150, 500, 1300, 520), true)
    expect(asked()).toBeNull()
  })

  it('a label on the arrow is part of it; one being edited is not', () => {
    const label = at(div({ 'data-id': 'ar-1399', 'data-kind': 'arrow-label', style: 'position: absolute' }, at(div({ style: 'background: white' }, 'flows to'), box(600, 500, 680, 520))), box(600, 500, 680, 520))
    layer.append(label)
    expect(asked()?.over).toEqual(['ar-1399'])
    label.firstElementChild!.append(document.createElement('input'))
    expect(asked()).toBeNull()
  })
})

describe('the board’s UI over a live frame', () => {
  it('a tool bar over any part of the page — even between where 3×3 samples fell — keeps it from being asked', () => {
    // Between the 50 % and 97 % rows (540 and 822), over the middle column.
    toolbar(box(560, 760, 880, 812))
    expect(asked()).toBeNull()
  })

  it('so does one over a corner only, and one whose shadow alone falls on the page', () => {
    const bar = toolbar(box(1080, 830, 1300, 880))
    expect(asked()).toBeNull()
    bar.remove()
    // 20 px right of the page: its shadow (18 px down, 40 px blur, −12 px spread) reaches 28 px sideways.
    toolbar(box(1120, 600, 1400, 650))
    expect(asked()).toBeNull()
  })

  it('a tool bar clear of the page and its shadow doesn’t', () => {
    // 20 px under it: that shadow reaches only 10 px up.
    toolbar(box(560, 860, 880, 910))
    expect(asked()).not.toBeNull()
  })

  it('a panel over the page keeps it from being asked: the comments panel, the chat docked over the board', () => {
    const panel = at(div({ 'data-testid': 'comments-panel', style: 'position: absolute; background: white; border-left: 1px solid rgb(0 0 0 / 0.1)' }), box(1040, 60, 1440, 900))
    app.append(panel)
    expect(asked()).toBeNull()
    panel.remove()
    expect(asked()).not.toBeNull()
    // The chat, outside the board's element: over it when the window is narrow.
    const chat = at(div({ style: 'position: absolute; overflow: hidden; border-radius: 14px; background: white' }, at(div({}, 'Ann: hi'), box(1000, 100, 1400, 140))), box(980, 60, 1428, 824))
    document.body.firstElementChild!.append(chat)
    expect(asked()).toBeNull()
  })

  it('a menu, a popover or a toast over the page keeps it from being asked; hidden ones don’t', () => {
    const menu = at(div({ role: 'menu', style: 'position: absolute; background: white' }, at(div({}, 'Bring to front'), box(400, 400, 560, 430))), box(390, 390, 570, 520))
    app.append(menu)
    expect(asked()).toBeNull()
    menu.style.opacity = '0'
    expect(asked()).not.toBeNull()
    menu.style.opacity = ''
    menu.style.display = 'none'
    expect(asked()).not.toBeNull()
    menu.style.display = ''
    menu.style.visibility = 'hidden'
    for (const el of menu.querySelectorAll('div')) (el as HTMLElement).style.visibility = 'hidden'
    expect(asked()).not.toBeNull()
  })

  it('a transparent box over the page is not in the picture, what it holds is', () => {
    const wrap = at(div({ style: 'position: absolute' }), box(0, 0, 1440, 900))
    app.append(wrap)
    expect(asked()).not.toBeNull()
    wrap.append(at(div({ style: 'background: rgb(29, 29, 31)' }, 'Saved'), box(640, 820, 800, 860)))
    expect(asked()).toBeNull()
  })

  it('what a scroller clips away is not in the picture', () => {
    const list = at(div({ style: 'position: absolute; overflow: auto' }, at(div({ style: 'background: white' }, 'An old comment'), box(1120, 700, 1400, 760))), box(1120, 60, 1400, 400))
    app.append(list)
    expect(asked()).not.toBeNull()
  })

  it('the laser keeps it from being asked only while something is drawn on it', () => {
    const laser = at(document.createElement('canvas'), box(0, 0, 1440, 900))
    laser.setAttribute('data-part', 'laser')
    app.append(laser)
    expect(asked()).not.toBeNull()
    laser.setAttribute('data-lit', '')
    expect(asked()).toBeNull()
  })

  it('a selection outline around the frame is not in the picture; a handle on its corner is', () => {
    // SelectionOutlines: a ring 3 px out, 1.5 px wide: its inside holds the page.
    const ring = at(div({ style: 'position: absolute; border: 1.5px solid rgb(0, 113, 227)' }), box(196, 200, 1104, 844))
    layer.append(ring)
    expect(asked()).not.toBeNull()
    const handles = at(div({ style: 'position: absolute' }, at(div({ style: 'background: white; border: 1.5px solid rgb(0, 113, 227)' }), box(1095.5, 836.5, 1104.5, 845.5))), box(199, 203, 1101, 841))
    layer.append(handles)
    expect(asked()).toBeNull()
  })

  it('a ring whose rounded corner only cuts across the corner the frame clips off its page is not in the picture', () => {
    // A ring 1 px out from the frame, its corners rounded: they cross the page's square corners…
    const r = 'border-top-left-radius: 6px; border-top-right-radius: 6px; border-bottom-left-radius: 6px; border-bottom-right-radius: 6px'
    layer.append(at(div({ style: `position: absolute; border: 1.5px solid rgb(0, 113, 227); ${r}` }), box(196.5, 200.5, 1103.5, 843.5)))
    expect(asked()).toBeNull()
    // …which the frame rounds off (12 px): what shows of the page is clear of it.
    const inner = frame.firstElementChild as HTMLElement
    for (const c of ['top-left', 'top-right', 'bottom-left', 'bottom-right']) inner.style.setProperty(`border-${c}-radius`, '12px')
    expect(asked()).not.toBeNull()
  })

  it('the pointer’s "use it" hint over the page keeps it from being asked while it shows', () => {
    const hint = at(div({ style: 'position: absolute; opacity: 0' }, at(div({ style: 'background: rgb(29 29 31 / 0.85)' }, 'Double-click to use'), box(560, 520, 740, 548))), PAGE)
    body.append(at(div({ 'data-part': 'web-shield', style: 'position: absolute' }, hint), PAGE))
    expect(asked()).not.toBeNull()
    hint.style.opacity = '0.4'
    expect(asked()).toBeNull()
  })
})

describe('shapes over a live frame', () => {
  it('a note on the page — an opaque box, drawn again over its copy — is in its picture, and named', () => {
    // As on the fixture's research wall: a note over a frame's top-right corner.
    note(box(980, 210, 1100, 254), { style: 'box-shadow: 0 3px 8px -2px rgb(0 0 0 / 0.12)' })
    arrow('ar-1399', box(150, 500, 1300, 520))
    expect(asked()?.over).toEqual(['ar-1399', 'st-1'])
  })

  it('a note that draws outside its box over the page keeps it from being asked', () => {
    const n = note(box(980, 210, 1100, 254))
    n.append(at(div({ style: 'background: white' }, 'Show all'), box(1000, 250, 1060, 280)))
    expect(asked()).toBeNull()
  })

  it('text over the page (it shows through) keeps it from being asked until it is clear', () => {
    const t = note(box(1000, 700, 1200, 760), { clear: true })
    expect(asked()).toBeNull()
    rects.set(t, box(1120, 700, 1320, 760))
    expect(asked()).not.toBeNull()
  })

  it('a note’s shadow alone falling on the page is drawn again over its copy: a shade darker, never out of place', () => {
    note(box(1104, 700, 1304, 900), { style: 'box-shadow: 0 3px 8px -2px rgb(0 0 0 / 0.12)' })
    expect(asked()?.over).toEqual(['st-1'])
  })

  it('a shape under the frame (before it in the board’s order) is not in the picture — unless raised over it', () => {
    const t = note(box(1000, 700, 1200, 900), { before: true, clear: true })
    expect(asked()).not.toBeNull()
    expect(asked()?.over).toEqual([])
    t.style.zIndex = '1'
    expect(asked()).toBeNull()
  })

  it('a selected note keeps it from being asked (its outline is over the page)', () => {
    note(box(980, 210, 1100, 254))
    layer.append(at(div({ style: 'position: absolute; border: 1.5px solid rgb(0, 113, 227)' }), box(977, 207, 1103, 257)))
    expect(asked()).toBeNull()
  })

  it('a frame not wholly inside the board, or too small, is not asked', () => {
    rects.set(page, box(-20, 240, 880, 840))
    expect(asked()).toBeNull()
    rects.set(page, box(200, 240, 240, 260))
    expect(asked()).toBeNull()
  })

  it('once its page is gone, what is over its box can still be told (the answer’s check)', () => {
    page.remove()
    expect(posterView(body, PAGE, deps).blocker).toBeNull()
    toolbar(box(560, 760, 880, 812))
    expect(posterView(body, PAGE, deps).blocker).not.toBeNull()
  })
})

describe('reading computed styles', () => {
  it('alpha of a colour', () => {
    expect(alphaOf('rgba(0, 0, 0, 0)')).toBe(0)
    expect(alphaOf('rgb(0 0 0 / 0.12)')).toBe(0.12)
    expect(alphaOf('rgb(255, 255, 255)')).toBe(1)
    expect(alphaOf('transparent')).toBe(0)
    expect(alphaOf('color(srgb 0 0 0 / 50%)')).toBe(0.5)
    expect(alphaOf('#0000')).toBe(0)
    expect(alphaOf('')).toBe(0)
  })

  it('how far a box shadow reaches, side by side, skipping transparent layers', () => {
    expect(shadowReach('none')).toEqual({ reach: { top: 0, right: 0, bottom: 0, left: 0 }, inset: false })
    expect(shadowReach('rgba(0, 0, 0, 0) 0px 0px 0px 0px, rgba(0, 0, 0, 0.12) 0px 3px 8px -2px')).toEqual({ reach: { top: 3, right: 6, bottom: 9, left: 6 }, inset: false })
    // WebKit's form (colour first) and the declared one; the widest of several layers.
    expect(shadowReach('rgba(0, 0, 0, 0.28) 0px 18px 40px -12px, rgba(0, 0, 0, 0.12) 0px 4px 10px -4px').reach).toEqual({ top: 10, right: 28, bottom: 46, left: 28 })
    expect(shadowReach('0 18px 40px -12px rgb(0 0 0 / 0.28), 0 4px 10px -4px rgb(0 0 0 / 0.12)').reach).toEqual({ top: 10, right: 28, bottom: 46, left: 28 })
    expect(shadowReach('rgb(0, 113, 227) 0px 0px 0px 4px').reach).toEqual({ top: 4, right: 4, bottom: 4, left: 4 })
    expect(shadowReach('rgba(0, 0, 0, 0.2) 0px 1px 2px 0px inset').inset).toBe(true)
  })
})

describe('the answer’s check', () => {
  it('drops a picture whose page is no longer clear when it comes', async () => {
    const broker = new PosterBroker(() => {})
    let clear = true
    const got = broker.ask({ name: 'n', id: 'f', url: 'https://a.b/', rect: { x: 0, y: 0, w: 600, h: 400 }, verify: () => clear }, 0)
    clear = false
    broker.answer('n', `data:image/jpeg;base64,${'A'.repeat(64)}`)
    await expect(got).resolves.toBe(false)
    expect(broker.cache.peek('f', 'https://a.b/')).toBeNull()
    // A check that throws keeps nothing either.
    const again = broker.ask({ name: 'n2', id: 'f', url: 'https://a.b/', rect: { x: 0, y: 0, w: 600, h: 400 }, verify: vi.fn(() => { throw new Error('x') }) }, 0)
    broker.answer('n2', `data:image/jpeg;base64,${'A'.repeat(64)}`)
    await expect(again).resolves.toBe(false)
  })
})
