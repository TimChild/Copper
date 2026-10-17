/**
 * What a live frame's picture would show besides its site (`posters.ts`).
 *
 * The host snapshots the board's view at the iframe's box, so whatever the
 * board paints over that box is in the picture too. A frame is asked for only
 * when none of the board's UI paints there — tool bar, zoom bar, title bar,
 * panels, the chat, menus, popovers, toasts, comment pins, cursors, handles,
 * selection and search rings, the laser — found exactly, by walking what is
 * drawn above the page and testing each painted box (with its shadow, outline
 * or ring) against the iframe's box, never by sampling a few points (a sparse
 * grid misses a tool bar between its rows, and takes a thin arrow for a wall).
 *
 * What the board draws over the page may be in the picture when the live
 * drawing lies exactly on its copy wherever the poster is shown: arrows (thin,
 * opaque, the same in board units at every zoom, drawn over every shape) and
 * shapes whose own box is opaque (a note, a card, an image: whatever it draws
 * stays inside its box, and the note drawn there covers its copy at any zoom,
 * simplified or not). Their ids are returned (`over`) so the board can drop the
 * picture the moment one of them, or the frame, changes (`PosterScene`). Not
 * a selected arrow (its halo), not a label being edited, not a shape that
 * shows through (text, a frame's page) or draws outside its box: those keep
 * the frame from being pictured until they are clear. (A shape's own shadow
 * falling on the page is in the picture and drawn again over it: a shade
 * darker, never out of place.)
 *
 * Read-only: rects and computed styles; nothing is changed or hidden, so
 * taking a picture never flickers anything.
 */

export interface ScreenBox {
  left: number
  top: number
  right: number
  bottom: number
}

export interface PosterView {
  /** The first thing found that would be in the picture and must not be, or null. */
  blocker: Element | null
  /** Arrows and shapes (ids) drawn over the page that may be in its picture: the board draws them on their copies. */
  over: string[]
}

export interface PosterViewDeps {
  /** An element's border box on screen (default: `getBoundingClientRect`). */
  rectOf?: (el: Element) => ScreenBox
  /** An element's computed style (default: `getComputedStyle`). */
  styleOf?: (el: Element, pseudo?: string) => CSSStyleDeclaration
}

/** A shadow or outline reaches at most this far (CSS px, times the zoom on the board): nearer than this, an element is looked at. */
const NEAR_PX = 96
/** The host rounds the box it snapshots: what is this close is in it. */
const ROUNDING_PX = 1
/** An arrow's stroke (2 board px) and head reach this far past its path's bounds. */
const ARROW_REACH = 4

const SVG_NS = 'http://www.w3.org/2000/svg'
const NOT_DRAWN = new Set(['head', 'script', 'style', 'template', 'noscript', 'link', 'meta', 'title', 'defs', 'clippath', 'mask', 'marker', 'symbol', 'pattern', 'lineargradient', 'radialgradient', 'filter'])
const REPLACED = new Set(['img', 'video', 'canvas', 'iframe', 'embed', 'object', 'input', 'textarea', 'select', 'progress', 'meter', 'hr'])
const SVG_SHAPES = new Set(['path', 'line', 'polyline', 'polygon', 'rect', 'circle', 'ellipse', 'text', 'image', 'use', 'foreignobject'])
const EVERYWHERE: ScreenBox = { left: -Infinity, top: -Infinity, right: Infinity, bottom: Infinity }

interface Shape {
  id: string
  box: ScreenBox
}

const inside = (r: ScreenBox, b: ScreenBox) => r.left >= b.left && r.top >= b.top && r.right <= b.right && r.bottom <= b.bottom
const overlaps = (a: ScreenBox, b: ScreenBox) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
const grow = (r: ScreenBox, by: number): ScreenBox => ({ left: r.left - by, top: r.top - by, right: r.right + by, bottom: r.bottom + by })
const meet = (a: ScreenBox, b: ScreenBox): ScreenBox => ({
  left: Math.max(a.left, b.left),
  top: Math.max(a.top, b.top),
  right: Math.min(a.right, b.right),
  bottom: Math.min(a.bottom, b.bottom),
})
const px = (v: string | null | undefined) => {
  const n = parseFloat(v ?? '')
  return Number.isFinite(n) ? n : 0
}

/** The alpha of a computed CSS colour: 0 for transparent, 1 when it has none of its own. */
export function alphaOf(color: string | null | undefined): number {
  const c = (color ?? '').trim().toLowerCase()
  if (!c || c === 'transparent' || c === 'none') return 0
  const fn = /^[a-z-]+\((.*)\)$/.exec(c)
  if (fn) {
    const inner = fn[1]!
    const slash = inner.lastIndexOf('/')
    const a = slash >= 0 ? inner.slice(slash + 1) : inner.split(',').length === 4 ? inner.split(',')[3]! : null
    if (a === null) return 1
    const n = parseFloat(a)
    if (!Number.isFinite(n)) return 1
    return a.trim().endsWith('%') ? n / 100 : n
  }
  const hex = /^#([0-9a-f]{4}|[0-9a-f]{8})$/.exec(c)
  if (hex) return parseInt(hex[1]!.length === 4 ? hex[1]!.slice(3).repeat(2) : hex[1]!.slice(6), 16) / 255
  return 1
}

/** Top-level comma-separated parts (commas inside a colour function don't split). */
function layers(value: string): string[] {
  const out: string[] = []
  let depth = 0
  let start = 0
  for (let i = 0; i < value.length; i++) {
    const ch = value[i]
    if (ch === '(') depth++
    else if (ch === ')') depth--
    else if (ch === ',' && depth === 0) {
      out.push(value.slice(start, i))
      start = i + 1
    }
  }
  out.push(value.slice(start))
  return out
}

const COLOR_RE = /[a-z-]+\([^()]*\)|#[0-9a-f]+/gi
const LENGTH_RE = /-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?/g

/** How far something paints past a box, side by side (CSS px; ≤ 0: not past that side). */
export interface Reach {
  top: number
  right: number
  bottom: number
  left: number
}

const NOWHERE: Reach = { top: 0, right: 0, bottom: 0, left: 0 }
const widest = (a: Reach, b: Reach): Reach => ({
  top: Math.max(a.top, b.top),
  right: Math.max(a.right, b.right),
  bottom: Math.max(a.bottom, b.bottom),
  left: Math.max(a.left, b.left),
})
const reaches = (r: Reach) => r.top > 0 || r.right > 0 || r.bottom > 0 || r.left > 0
/** A shadow offset by (x, y), grown by `spread` and blurred by `blur` (its visible tail ends about one blur radius out). */
const cast = (x: number, y: number, blur: number, spread: number): Reach => {
  const k = Math.max(0, blur) + spread
  return { top: k - y, right: k + x, bottom: k + y, left: k - x }
}

/** How far a computed `box-shadow` paints past the border box, side by side, and whether any of it paints inside. */
export function shadowReach(value: string | null | undefined): { reach: Reach; inset: boolean } {
  const v = (value ?? '').trim()
  let reach = NOWHERE
  let inset = false
  if (!v || v === 'none') return { reach, inset }
  for (const part of layers(v)) {
    const color = part.match(COLOR_RE)?.find(c => /^[a-z-]+\(|^#/i.test(c))
    if (color !== undefined && alphaOf(color) <= 0) continue
    if (color === undefined && /\btransparent\b/i.test(part)) continue
    const nums = (part.replace(COLOR_RE, ' ').match(LENGTH_RE) ?? []).map(Number)
    if (nums.length < 2) continue
    const [x = 0, y = 0, blur = 0, spread = 0] = nums
    if (/\binset\b/i.test(part)) {
      inset = true
      continue
    }
    // Box shadows never paint inside their box: a side it doesn't reach past gets none.
    reach = widest(reach, cast(x, y, blur, spread))
  }
  return { reach, inset }
}

/** How far a computed `filter`'s drop shadows paint past the content, side by side. */
function dropReach(value: string | null | undefined): Reach {
  const v = value ?? ''
  let reach = NOWHERE
  if (!v.includes('drop-shadow')) return reach
  for (const m of v.matchAll(/drop-shadow\(((?:[^()]|\([^()]*\))*)\)/g)) {
    const [x = 0, y = 0, blur = 0] = (m[1]!.replace(COLOR_RE, ' ').match(LENGTH_RE) ?? []).map(Number)
    reach = widest(reach, cast(x, y, blur, 0.5))
  }
  return reach
}

const hasOwnText = (el: Element) => {
  for (const n of el.childNodes) if (n.nodeType === 3 && n.nodeValue?.trim()) return true
  return false
}

const generated = (s: CSSStyleDeclaration) => {
  const c = s.content
  return !!c && c !== 'none' && c !== 'normal'
}

type Point = readonly [number, number]

/** Is `p` inside `box` with its corners rounded by `radius`? */
function inRounded(box: ScreenBox, radius: number, [x, y]: Point): boolean {
  if (x < box.left || y < box.top || x > box.right || y > box.bottom) return false
  const r = Math.min(radius, (box.right - box.left) / 2, (box.bottom - box.top) / 2)
  if (r <= 0) return true
  const cx = x < box.left + r ? box.left + r : x > box.right - r ? box.right - r : null
  const cy = y < box.top + r ? box.top + r : y > box.bottom - r ? box.bottom - r : null
  return cx === null || cy === null || (x - cx) ** 2 + (y - cy) ** 2 <= r * r
}

/**
 * The outline of what shows of `box` through a rounded clip (`clip`, corner
 * `radius`): its corners inside the clip, and points along the clip's corner
 * arcs inside it. Both are convex, so a convex shape holds all of it when it
 * holds these.
 */
function outlineOf(box: ScreenBox, clip: ScreenBox | null, radius: number): Point[] {
  const corners: Point[] = [
    [box.left, box.top],
    [box.right, box.top],
    [box.left, box.bottom],
    [box.right, box.bottom],
  ]
  if (!clip || radius <= 0) return corners
  const out = corners.filter(p => inRounded(clip, radius, p))
  const r = Math.min(radius, (clip.right - clip.left) / 2, (clip.bottom - clip.top) / 2)
  for (const [cx, cy, a0] of [
    [clip.left + r, clip.top + r, Math.PI],
    [clip.right - r, clip.top + r, 1.5 * Math.PI],
    [clip.right - r, clip.bottom - r, 0],
    [clip.left + r, clip.bottom - r, 0.5 * Math.PI],
  ] as const)
    for (let k = 0; k <= 8; k++) {
      const a = a0 + (k / 8) * (Math.PI / 2)
      const p: Point = [cx + r * Math.cos(a), cy + r * Math.sin(a)]
      if (p[0] >= box.left && p[0] <= box.right && p[1] >= box.top && p[1] <= box.bottom) out.push(p)
    }
  return out
}

/**
 * What of the board is drawn over `page` (a live frame's iframe, or the box
 * it had — its frame's body — once it is gone) within `area` (the iframe's box
 * on screen). Elements drawn under the page are never looked at: the frame's
 * own ancestors, and the shapes before it in the board's layer (the board
 * draws shapes in their order) unless one is raised over it.
 */
export function posterView(page: Element, area: ScreenBox, deps: PosterViewDeps = {}): PosterView {
  const rectOf = deps.rectOf ?? ((el: Element) => el.getBoundingClientRect())
  const styleOf = deps.styleOf ?? ((el: Element, pseudo?: string) => getComputedStyle(el, pseudo))
  const target = grow(area, ROUNDING_PX)
  const own = page.closest('[data-live]') ?? page
  const layer = own.parentElement
  const body = page.localName === 'iframe' ? page.parentElement : null
  const under = new Set<Element>()
  for (let a = own.parentElement; a; a = a.parentElement) under.add(a)
  // The board's zoom: what shapes and overlays in its layer are scaled by.
  const ownRect = rectOf(own)
  const ownWidth = (own as HTMLElement).offsetWidth ?? 0
  const zoom = ownWidth > 0 && ownRect.right > ownRect.left ? (ownRect.right - ownRect.left) / ownWidth : 1
  const over = new Set<string>()
  // What of the target shows: the frame clips its page to its rounded corners, so whatever lies
  // only in a corner it cuts off never shows (a ring round a selected frame passes there).
  const shows = (() => {
    for (let a = page.parentElement; a && a !== own.parentElement; a = a.parentElement) {
      const s = styleOf(a)
      if (![s.overflowX, s.overflowY, s.overflow].some(o => !!o && !/^visible( visible)?$/.test(o))) continue
      const radius = Math.max(px(s.borderTopLeftRadius), px(s.borderTopRightRadius), px(s.borderBottomLeftRadius), px(s.borderBottomRightRadius))
      if (radius <= 0) continue
      const r = rectOf(a)
      const w = (a as HTMLElement).offsetWidth
      const k = typeof w === 'number' && w > 0 ? (r.right - r.left) / w : zoom
      const b = Math.min(px(s.borderTopWidth), px(s.borderRightWidth), px(s.borderBottomWidth), px(s.borderLeftWidth)) * k
      const clip = { left: r.left + px(s.borderLeftWidth) * k, top: r.top + px(s.borderTopWidth) * k, right: r.right - px(s.borderRightWidth) * k, bottom: r.bottom - px(s.borderBottomWidth) * k }
      // The host's box is rounded out to whole pixels: so is what may show of it.
      return outlineOf(target, grow(clip, ROUNDING_PX), Math.max(0, radius * k - b))
    }
    return outlineOf(target, null, 0)
  })()

  const near = (r: ScreenBox, scale: number) => overlaps(grow(r, NEAR_PX * scale), target)
  /** CSS px → screen px for `el`'s own lengths (its shadow, its border): the zoom on the board, and any scale of its own. */
  const scaleOf = (el: Element, r: ScreenBox, inLayer: boolean) => {
    const w = (el as HTMLElement).offsetWidth
    const k = typeof w === 'number' && w > 0 ? (r.right - r.left) / w : inLayer ? zoom : 1
    return Number.isFinite(k) && k > 0 ? k : 1
  }

  /** Does `el` itself paint over the target (inside `clip`)? */
  const paints = (el: Element, s: CSSStyleDeclaration, r: ScreenBox, clip: ScreenBox, scale: number): boolean => {
    if (s.visibility === 'hidden' || s.visibility === 'collapse') return false
    const svg = el.namespaceURI === SVG_NS
    const tag = el.localName.toLowerCase()
    let fills = false
    if (svg && tag !== 'svg') {
      if (!SVG_SHAPES.has(tag)) return false
      const fill = s.fill || el.getAttribute('fill') || 'black'
      const stroke = s.stroke || el.getAttribute('stroke') || 'none'
      const fillOn = fill !== 'none' && alphaOf(fill) > 0 && px(s.fillOpacity || '1') > 0
      const strokeOn = stroke !== 'none' && alphaOf(stroke) > 0 && px(s.strokeOpacity || '1') > 0 && (s.strokeWidth === '' || px(s.strokeWidth) > 0)
      fills = fillOn || strokeOn || tag === 'image' || tag === 'foreignobject' || tag === 'use' || tag === 'text'
      if (!fills) return false
      return overlaps(meet(grow(r, (strokeOn ? 2 : 0) * scale), clip), target)
    }
    if (REPLACED.has(tag)) fills = !(tag === 'canvas' && el.getAttribute('data-part') === 'laser' && !el.hasAttribute('data-lit'))
    if (!fills)
      fills =
        alphaOf(s.backgroundColor) > 0 ||
        (!!s.backgroundImage && s.backgroundImage !== 'none') ||
        (!!s.backdropFilter && s.backdropFilter !== 'none') ||
        hasOwnText(el)
    const shadow = shadowReach(s.boxShadow)
    if (shadow.inset) fills = true
    const drop = dropReach(s.filter)
    const outline = s.outlineStyle && s.outlineStyle !== 'none' && px(s.outlineWidth) > 0 && alphaOf(s.outlineColor) > 0 ? px(s.outlineOffset) + px(s.outlineWidth) : null
    const side = (w: string, st: string, c: string) => (st && st !== 'none' && st !== 'hidden' && alphaOf(c) > 0 ? px(w) : 0)
    const border = [
      side(s.borderTopWidth, s.borderTopStyle, s.borderTopColor),
      side(s.borderRightWidth, s.borderRightStyle, s.borderRightColor),
      side(s.borderBottomWidth, s.borderBottomStyle, s.borderBottomColor),
      side(s.borderLeftWidth, s.borderLeftStyle, s.borderLeftColor),
    ] as const
    if (!fills && !(reaches(shadow.reach) || reaches(drop) || outline !== null || border.some(w => w > 0))) {
      // Nothing of its own, unless a ::before / ::after draws (taken as drawn in its box, like content).
      if (!generated(styleOf(el, '::before')) && !generated(styleOf(el, '::after'))) return false
      fills = true
    }
    const past = widest(shadow.reach, drop)
    const ring = Math.max(0, outline ?? 0)
    const by = (side: number) => (Math.max(0, side) + ring) * scale
    const outer = meet({ left: r.left - by(past.left), top: r.top - by(past.top), right: r.right + by(past.right), bottom: r.bottom + by(past.bottom) }, clip)
    if (!overlaps(outer, target)) return false
    if (fills || reaches(drop)) return true
    // Only a ring (a border, an outline, a shadow): the inside of the box shows through it.
    const inset = (i: number) => (outline !== null && px(s.outlineOffset) < 0 ? Math.max(border[i]!, -px(s.outlineOffset)) : border[i]!) * scale
    const hole = { left: r.left + inset(3), top: r.top + inset(0), right: r.right - inset(1), bottom: r.bottom - inset(2) }
    const radius =
      Math.max(px(s.borderTopLeftRadius), px(s.borderTopRightRadius), px(s.borderBottomLeftRadius), px(s.borderBottomRightRadius)) * scale -
      Math.min(...border) * scale
    return !shows.every(p => inRounded(hole, Math.max(0, radius), p))
  }

  /** An arrow (or its label) over the page: in the picture, unless it would look wrong there later. */
  const arrow = (el: Element, kind: string, clip: ScreenBox): Element | null => {
    const r = rectOf(el)
    if (!overlaps(meet(grow(r, ARROW_REACH * zoom), clip), target)) return null
    if (el.hasAttribute('data-on')) return el
    if (kind === 'arrow-label' && el.querySelector('input, textarea, [contenteditable]')) return el
    const id = el.getAttribute('data-id')
    if (id) over.add(id)
    return null
  }

  /** A shape whose box is opaque: what it draws over the page may be in the picture if it stays inside that box. */
  const opaqueShape = (el: Element, s: CSSStyleDeclaration): Shape | null => {
    const id = el.getAttribute('data-id')
    if (!id || el.hasAttribute('data-live')) return null
    if (alphaOf(s.backgroundColor) < 0.99 || px(s.opacity || '1') < 1 || (!!s.filter && s.filter !== 'none')) return null
    if (s.visibility === 'hidden' || s.visibility === 'collapse' || (!!s.mixBlendMode && s.mixBlendMode !== 'normal')) return null
    return { id, box: grow(rectOf(el), ROUNDING_PX) }
  }

  const visit = (el: Element, clip: ScreenBox, inLayer: boolean, shape: Shape | null = null): Element | null => {
    const tag = el.localName.toLowerCase()
    if (NOT_DRAWN.has(tag)) return null
    if (el === own) {
      // The frame itself: only what lies over its page in its body (the "use it" hint).
      if (!body) return null
      for (const child of body.children) {
        if (child === page) continue
        const hit = visit(child, clip, true)
        if (hit) return hit
      }
      return null
    }
    const isUnder = under.has(el)
    if (inLayer && !isUnder) {
      const kind = el.getAttribute('data-kind')
      if (kind === 'arrow' || kind === 'arrow-label') return arrow(el, kind, clip)
    }
    const r = rectOf(el)
    let style: CSSStyleDeclaration | undefined
    const st = () => (style ??= styleOf(el))
    const close = !isUnder && near(r, inLayer ? zoom : 1)
    if (close) {
      // Fixed boxes escape their ancestors' clips.
      if (!overlaps(clip, target) && st().position === 'fixed') clip = EVERYWHERE
      if (overlaps(clip, target)) {
        const s = st()
        if (s.display === 'none' || px(s.opacity || '1') <= 0) return null
        if (el.parentElement === layer && !isUnder) shape = opaqueShape(el, s)
        if (paints(el, s, r, clip, scaleOf(el, r, inLayer))) {
          // Inside an opaque shape's box: drawn again, at the same place, over its copy.
          if (!shape || !inside(meet(r, clip), shape.box)) return el
          over.add(shape.id)
        }
      }
    }
    if (!el.firstElementChild) return null
    // A shape (or overlay) in the board's layer keeps its drawing near its box; the layer's
    // SVGs (arrows, low-zoom notes, rings) are 1 px boxes drawing far outside them.
    if (inLayer && el.parentElement === layer && !close && tag !== 'svg') return null
    const s = st()
    if (s.display === 'none' || px(s.opacity || '1') <= 0) return null
    if (s.position === 'fixed') clip = EVERYWHERE
    const clips = s.display !== 'contents' && [s.overflowX, s.overflowY, s.overflow].some(o => !!o && !/^visible( visible)?$/.test(o))
    const inner = clips ? meet(clip, r) : clip
    // What a box clips away can't be in the picture. (A fixed box inside one would escape its
    // clip; the board's UI has none — its menus and popovers are absolute, or portalled.)
    if (!overlaps(inner, target)) return null
    const entering = el === layer
    let below = entering
    for (const child of el.children) {
      if (entering) {
        if (child === own) below = false
        // Drawn before the frame, so under it — unless raised over it.
        else if (below && !raised(child)) continue
      }
      const hit = visit(child, inner, inLayer || entering, shape)
      if (hit) return hit
    }
    return null
  }

  const raised = (child: Element) => {
    if (!near(rectOf(child), zoom)) return false
    const z = parseInt(styleOf(child).zIndex, 10)
    return Number.isFinite(z) && z > 0
  }

  const root = page.ownerDocument.documentElement
  const blocker = visit(root, EVERYWHERE, false)
  return { blocker, over: blocker ? [] : [...over].sort() }
}

export interface PosterPlace {
  /** The iframe's content box on screen. */
  rect: ScreenBox & { width: number; height: number }
  /** Arrows and shapes drawn over it that may be in the picture (`PosterView.over`). */
  over: string[]
}

/**
 * The box to picture `page` (a live frame's iframe) at, when its picture would
 * show its site and nothing else: big enough, all of it inside the board, no
 * pointer over a frame not in use (its "use it" hint), and nothing drawn over
 * it that must not be in its picture (`posterView`). Else null.
 */
export function posterPlace(page: Element, deps: PosterViewDeps = {}): PosterPlace | null {
  const rectOf = deps.rectOf ?? ((el: Element) => el.getBoundingClientRect())
  const r = rectOf(page)
  const width = r.right - r.left
  const height = r.bottom - r.top
  if (!(width >= 48 && height >= 32)) return null
  const appEl = page.closest('[role="application"]')
  if (!appEl) return null
  const app = rectOf(appEl)
  if (r.left < app.left || r.top < app.top || r.right > app.right || r.bottom > app.bottom) return null
  // The pointer on a frame not in use fades its "use it" hint in over the page (before any check could see it).
  const own = page.closest('[data-live]')
  if (own?.querySelector('[data-part="web-shield"]') && own.matches(':hover')) return null
  const seen = posterView(page, r, deps)
  if (seen.blocker) return null
  return { rect: { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width, height }, over: seen.over }
}
