/**
 * Live web frames: a link shape with `live: true` shows its site in an
 * <iframe> on the board. Pure parts only — naming, the URL both people
 * share, which frames get a real iframe, and the host's frame reports — so
 * the view (`components/WebFrame.tsx`) stays small and this stays testable.
 *
 * The shared state is the shape's `url` (and `title`, `favicon`): when the
 * person using a frame navigates inside it, the page writes the new URL, and
 * every other client's frame follows. Each person's frame loads the site
 * with their own cookies — what is shared is where the frame is, never who
 * it is signed in as.
 */
import { boxesOverlap, type Box } from './geometry'
export { LIVE_MIN } from './resize'

/** Default size of a new live frame (world px): a laptop-ish page. */
export const LIVE_SIZE = { w: 960, h: 640 } as const
/** Height of the frame's title bar, in world px (it scales with the board). */
export const BAR_H = 36

/**
 * The iframe's sandbox. Scripts, forms and its own origin (a cross-origin
 * frame keeps its cookies and storage only with `allow-same-origin`; it can't
 * reach the board, which is a file:// page of another origin). Popups so a
 * "Sign in with…" window can open (the host turns it into a tab), and
 * top-level navigation only from a click (a `target=_top` link the user
 * pressed, which the host also opens in a tab): never a frame-buster's
 * `top.location = …` on load. No `allow-top-navigation`, no pointer lock.
 */
export const FRAME_SANDBOX = [
  'allow-scripts',
  'allow-same-origin',
  'allow-forms',
  'allow-popups',
  'allow-popups-to-escape-sandbox',
  'allow-modals',
  'allow-downloads',
  'allow-storage-access-by-user-activation',
  'allow-top-navigation-by-user-activation',
].join(' ')

/** Permissions policy: what a page in a tab gets without asking; no camera, mic or location. */
export const FRAME_ALLOW = 'fullscreen; clipboard-write; autoplay; encrypted-media; picture-in-picture'

/** An address a frame may show: http(s) only, normalised; null for anything else. */
export function frameUrl(raw: string | undefined | null): string | null {
  if (!raw) return null
  try {
    const u = new URL(raw)
    return u.protocol === 'http:' || u.protocol === 'https:' ? u.href : null
  } catch {
    return null
  }
}

/** Two spellings of the same page (`https://a.b` and `https://a.b/`). */
export function sameUrl(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a || !b) return a === b
  const na = frameUrl(a) ?? a
  const nb = frameUrl(b) ?? b
  return na === nb
}

// ---- naming -------------------------------------------------------------------

/**
 * Each iframe is named `copper-frame:<shape id>:<nonce>` (its `window.name`,
 * which survives its navigations). The host's subframe script reads it and
 * says which frame went where. The nonce is made per mount and never leaves
 * this page, so a framed page that rewrites its own window.name can't speak
 * for another frame: it doesn't know that frame's nonce.
 */
export const FRAME_PREFIX = 'copper-frame:'

export const frameName = (id: string, nonce: string) => `${FRAME_PREFIX}${id}:${nonce}`

export function parseFrameName(name: unknown): { id: string; nonce: string } | null {
  if (typeof name !== 'string' || !name.startsWith(FRAME_PREFIX)) return null
  const rest = name.slice(FRAME_PREFIX.length)
  const at = rest.lastIndexOf(':')
  if (at <= 0 || at === rest.length - 1) return null
  return { id: rest.slice(0, at), nonce: rest.slice(at + 1) }
}

export function makeNonce(): string {
  const bytes = new Uint8Array(9)
  if (typeof crypto !== 'undefined' && 'getRandomValues' in crypto) crypto.getRandomValues(bytes)
  else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256)
  return [...bytes].map(b => b.toString(16).padStart(2, '0')).join('')
}

// ---- which frames get an iframe ---------------------------------------------------

/** At most this many iframes at once; the rest show their card. */
export const MAX_MOUNTED = 6
/** A frame narrower than this on screen shows its card (and a mounted one keeps its iframe down to KEEP_PX). */
export const MOUNT_PX = 260
export const KEEP_PX = 200

export interface MountInput extends Box {
  id: string
}

/**
 * Which live frames have a real iframe right now: the one in use always;
 * then those on screen and big enough to read, nearest the middle first, up
 * to `max`. Frames already mounted keep theirs a little longer (a margin
 * around the view, a smaller size) so a frame at the edge doesn't reload
 * every time the board moves a pixel.
 */
export function framesToMount(
  frames: readonly MountInput[],
  ctx: { visible: Box; zoom: number; active: string | null; mounted: ReadonlySet<string>; max?: number }
): Set<string> {
  const max = ctx.max ?? MAX_MOUNTED
  const { visible, zoom } = ctx
  const cx = visible.x + visible.w / 2
  const cy = visible.y + visible.h / 2
  const margin = Math.max(visible.w, visible.h) * 0.25
  const wide = { x: visible.x - margin, y: visible.y - margin, w: visible.w + margin * 2, h: visible.h + margin * 2 }
  const out = new Set<string>()
  const candidates: { id: string; d: number; kept: boolean }[] = []
  for (const f of frames) {
    if (f.id === ctx.active) {
      out.add(f.id)
      continue
    }
    const kept = ctx.mounted.has(f.id)
    const onScreen = boxesOverlap(kept ? wide : visible, f)
    const px = f.w * zoom
    if (!onScreen || px < (kept ? KEEP_PX : MOUNT_PX)) continue
    const d = Math.hypot(f.x + f.w / 2 - cx, f.y + f.h / 2 - cy)
    candidates.push({ id: f.id, d, kept })
  }
  candidates.sort((a, b) => Number(b.kept) - Number(a.kept) || a.d - b.d || (a.id < b.id ? -1 : 1))
  for (const c of candidates) {
    if (out.size >= max) break
    out.add(c.id)
  }
  return out
}

// ---- the URL both people share ------------------------------------------------------

/**
 * One frame's navigation, as this client sees it: where its iframe is and
 * the pages it has been (Back/Forward in the title bar walk these, not the
 * board's own history, which every frame on the board shares).
 */
export class FrameNav {
  /** What the iframe shows (its last report, or what it was told to load). */
  current: string
  private history: string[]
  private index = 0
  private version = 0
  private listeners = new Set<() => void>()

  constructor(url: string) {
    this.current = url
    this.history = [url]
  }

  /** For useSyncExternalStore: Back/Forward light up as the frame moves. */
  subscribe = (fn: () => void) => {
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
    }
  }
  getVersion = () => this.version
  private changed() {
    this.version++
    for (const fn of this.listeners) fn()
  }

  /** The shape's url changed in the document. True: the iframe should go there. */
  remote(url: string): boolean {
    if (sameUrl(url, this.current)) return false
    this.current = url
    this.push(url)
    this.changed()
    return true
  }

  /** The frame says it is at `url` now. True when that is somewhere new. */
  report(url: string): boolean {
    if (sameUrl(url, this.current)) return false
    this.current = url
    this.push(url)
    this.changed()
    return true
  }

  get canBack() {
    return this.index > 0
  }
  get canForward() {
    return this.index < this.history.length - 1
  }

  /** Step through the pages this frame showed here; the URL to load, or null. */
  back(): string | null {
    if (!this.canBack) return null
    this.index--
    this.current = this.history[this.index]!
    this.changed()
    return this.current
  }

  forward(): string | null {
    if (!this.canForward) return null
    this.index++
    this.current = this.history[this.index]!
    this.changed()
    return this.current
  }

  private push(url: string) {
    if (sameUrl(this.history[this.index], url)) return
    // A page we stepped back to, reported back again, is not a new step.
    if (this.index > 0 && sameUrl(this.history[this.index - 1], url)) {
      this.index--
      return
    }
    if (this.index < this.history.length - 1 && sameUrl(this.history[this.index + 1], url)) {
      this.index++
      return
    }
    this.history = this.history.slice(0, this.index + 1)
    this.history.push(url)
    if (this.history.length > 50) this.history.shift()
    this.index = this.history.length - 1
  }
}

/**
 * May this client write what its frame reports? Only the person using a
 * frame writes its URL: the frame is active here, or they just pressed one
 * of its buttons. A frame following somebody else, or redirecting on its own
 * right after (a sign-in page, another locale), never writes — so two people
 * whose sites answer one URL differently can't bounce it between them.
 */
export function mayWrite(t: { active: boolean; readOnly: boolean; now: number; chromeUntil: number; quietUntil: number }): boolean {
  if (t.readOnly || t.now < t.quietUntil) return false
  return t.active || t.now < t.chromeUntil
}

// ---- what the host says about frames ------------------------------------------------

/**
 * One report from the host's subframe script (`copperCanvas.frameEvent`):
 * - `nav`: the frame's document is at `url` (on load, and when an app
 *   changes its address without loading), with its `title` and `icon`;
 * - `escape`: Escape was pressed inside it and the site didn't use it;
 * - `blank`: it loaded but shows nothing (a page that hides itself when framed).
 */
export type FrameEvent =
  | { name: string; kind: 'nav'; url: string; title: string; icon?: string }
  | { name: string; kind: 'escape' }
  | { name: string; kind: 'blank'; url: string }

export function parseFrameEvent(raw: unknown): FrameEvent | null {
  let v = raw
  if (typeof v === 'string') {
    try {
      v = JSON.parse(v)
    } catch {
      return null
    }
  }
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null
  const o = v as Record<string, unknown>
  if (!parseFrameName(o.name)) return null
  const name = o.name as string
  if (o.kind === 'escape') return { name, kind: 'escape' }
  const url = frameUrl(typeof o.url === 'string' ? o.url : null)
  if (!url) return null
  if (o.kind === 'blank') return { name, kind: 'blank', url }
  if (o.kind !== 'nav') return null
  const title = typeof o.title === 'string' ? o.title.trim().slice(0, 500) : ''
  const icon = typeof o.icon === 'string' && /^https:\/\/\S+$/i.test(o.icon) && o.icon.length <= 2048 ? o.icon : undefined
  return icon ? { name, kind: 'nav', url, title, icon } : { name, kind: 'nav', url, title }
}

type FrameListener = (e: FrameEvent) => void

/** Frame reports, handed to whichever view owns the frame's name. */
export class FrameBus {
  private listeners = new Map<string, FrameListener>()
  /** The host's subframe script is installed: a frame that never reports didn't load. */
  reports = false

  on(name: string, fn: FrameListener) {
    this.listeners.set(name, fn)
    return () => {
      if (this.listeners.get(name) === fn) this.listeners.delete(name)
    }
  }

  /** True when a view took it. */
  emit(e: FrameEvent): boolean {
    const fn = this.listeners.get(e.name)
    if (!fn) return false
    fn(e)
    return true
  }
}
