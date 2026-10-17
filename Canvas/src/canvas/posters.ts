/**
 * Posters: the last picture of a live frame's site, shown in place of its
 * iframe when the frame doesn't have one (off screen a while, too small to
 * read, over the live budget — `frames.ts`). The page can't draw a
 * cross-origin frame itself, so it asks the host:
 *
 *   page → host  {type:'framePoster', name, id, url, rect:{x,y,w,h}, maxWidth}
 *                (`rect`: the iframe's content box, CSS px of the board's viewport)
 *   host → page  copperCanvas.framePoster(name, 'data:image/jpeg;base64,…' | null)
 *
 * Asked while the frame is live, fully on screen, settled (≥ 2 s after a load
 * or navigation) and nothing is drawn over its page that must not be in its
 * picture (`poster-view.ts`: the host's picture is of the board's view, so a
 * tool bar, panel or menu over the page would be in it), at most once per frame
 * per 30 s, and once more right before a deliberate unload when it is still
 * on screen. An answer is kept only if that still holds when it comes (the
 * view hasn't moved, nothing came over the page). A picture with arrows or
 * opaque shapes in it keeps what they were (`PosterScene`), and the board
 * drops it once one of them, or the frame, has changed: what it draws over the
 * poster would no longer hide its copy.
 * Pictures are kept in memory (LRU, ≤ ~40 MB of data URL) by shape id + url:
 * a frame whose url moved on drops its picture. A host that never answers
 * leaves every frame on its card (`components/WebFrame.tsx`), and stops
 * being waited for before an unload after a few unanswered asks.
 */
import { sameUrl } from './frames'

/** Widest picture asked for (CSS px of the snapshot). */
export const POSTER_MAX_WIDTH = 640
/** Total data URL length kept (characters ≈ bytes). */
export const POSTER_BUDGET = 40 * 1024 * 1024
/** Largest single picture accepted. */
export const POSTER_MAX_CHARS = 3 * 1024 * 1024
/** At most one periodic ask per frame this often. */
export const POSTER_EVERY_MS = 30_000
/** A frame's page has to have been still (no load, no navigation) this long. */
export const POSTER_SETTLE_MS = 2_000
/** An ask with no answer after this is given up on. */
export const POSTER_TIMEOUT_MS = 8_000
/** Before an unload, the iframe is kept at most this long for its picture. */
export const POSTER_HOLD_MS = 1_200
/** Unanswered asks (with no answer ever) after which the host is taken not to make posters. */
export const POSTER_SILENT_AFTER = 3

/**
 * What of the board was drawn over a frame's page when its picture was taken
 * (`over`: arrows, opaque shapes — `poster-view.ts`), and `key`: where they and
 * the frame were (`posterSceneKey`). The live drawing lies exactly on its copy
 * in the picture only while that key holds.
 */
export interface PosterScene {
  over: string[]
  key: string
}

/**
 * The frame's box and order, and each of `over` by its signature (null: gone
 * from the board): a picture with them in it is good while this is unchanged.
 */
export function posterSceneKey(
  frame: { x: number; y: number; w: number; h: number; z?: number } | null | undefined,
  over: readonly { id: string; sig?: string | null }[]
): string {
  const parts = [frame ? `${frame.x},${frame.y},${frame.w},${frame.h},${frame.z ?? 0}` : '-']
  for (const o of [...over].sort((p, q) => (p.id < q.id ? -1 : p.id > q.id ? 1 : 0))) parts.push(`${o.id}|${o.sig ?? '-'}`)
  return parts.join('\n')
}

/** A shape's record as a short, stable string: every field, long values (image data) by their length and ends. */
export function shapeSig(shape: object): string {
  const rec = shape as Record<string, unknown>
  return JSON.stringify(
    Object.keys(rec)
      .sort()
      .map(k => {
        const v = rec[k]
        return [k, typeof v === 'string' && v.length > 256 ? `${v.length}:${v.slice(0, 64)}…${v.slice(-64)}` : v]
      })
  )
}

export interface Poster {
  url: string
  /** The shape's own url when it was taken, if the page had moved on from it (a redirect): it matches too. */
  alias?: string
  src: string
  /** Natural size, when the picture's header says (else 0). */
  w: number
  h: number
  at: number
  /** What of the board was drawn over the page in the picture, when anything was. */
  scene?: PosterScene
}

type Listener = () => void

const posterFor = (p: Poster, url: string) => sameUrl(p.url, url) || (!!p.alias && sameUrl(p.alias, url))

/** Pictures by shape id (one each, for one url), least recently used first. */
export class PosterCache {
  private entries = new Map<string, Poster>()
  private listeners = new Map<string, Set<Listener>>()
  private size = 0

  constructor(readonly budget = POSTER_BUDGET) {}

  get bytes() {
    return this.size
  }
  get count() {
    return this.entries.size
  }

  /** The picture of `id` at `url`, made most recently used; a picture of another url is dropped. */
  get(id: string, url: string): Poster | null {
    const p = this.entries.get(id)
    if (!p) return null
    if (!posterFor(p, url)) {
      this.delete(id)
      return null
    }
    this.entries.delete(id)
    this.entries.set(id, p)
    return p
  }

  /** Without touching the LRU order or dropping anything (for render). */
  peek(id: string, url: string): Poster | null {
    const p = this.entries.get(id)
    return p && posterFor(p, url) ? p : null
  }

  set(id: string, poster: Poster) {
    const old = this.entries.get(id)
    if (old) {
      this.size -= old.src.length
      this.entries.delete(id)
    }
    this.entries.set(id, poster)
    this.size += poster.src.length
    const evicted: string[] = []
    for (const [key, p] of this.entries) {
      if (this.size <= this.budget || key === id) break
      this.entries.delete(key)
      this.size -= p.src.length
      evicted.push(key)
    }
    this.notify(id)
    for (const key of evicted) this.notify(key)
  }

  /** Drop every picture with something of the board in it that `fresh` says no longer matches the board. */
  dropStale(fresh: (id: string, scene: PosterScene) => boolean) {
    for (const [id, p] of [...this.entries]) if (p.scene && !fresh(id, p.scene)) this.delete(id)
  }

  delete(id: string) {
    const p = this.entries.get(id)
    if (!p) return
    this.entries.delete(id)
    this.size -= p.src.length
    this.notify(id)
  }

  subscribe(id: string, fn: Listener) {
    let set = this.listeners.get(id)
    if (!set) this.listeners.set(id, (set = new Set()))
    set.add(fn)
    return () => {
      set.delete(fn)
      if (!set.size) this.listeners.delete(id)
    }
  }

  private notify(id: string) {
    for (const fn of this.listeners.get(id) ?? []) fn()
  }
}

export interface PosterRequest {
  name: string
  id: string
  url: string
  /** The shape's url, when it isn't where the page is now (never sent). */
  alias?: string
  rect: { x: number; y: number; w: number; h: number }
  /** What of the board is over the page (never sent): kept with the picture. */
  scene?: PosterScene
  /** Asked when the answer comes (never sent): is the picture still good to keep? */
  verify?: () => boolean
}

export interface PosterMessage extends Omit<PosterRequest, 'alias' | 'scene' | 'verify'> {
  type: 'framePoster'
  maxWidth: number
}

interface Pending {
  id: string
  url: string
  alias?: string
  scene?: PosterScene
  verify?: () => boolean
  at: number
  timer: ReturnType<typeof setTimeout>
  waiters: ((got: boolean) => void)[]
}

const POSTER_HEAD = /^data:image\/(?:jpeg|png|webp);base64,/

/** A data URL the host may answer with (JPEG, PNG or WebP, base64, not huge). */
export function isPosterData(v: unknown): v is string {
  if (typeof v !== 'string' || v.length > POSTER_MAX_CHARS) return false
  const head = POSTER_HEAD.exec(v)
  if (!head || v.length < head[0].length + 16) return false
  return /^[A-Za-z0-9+/=]*$/.test(v.slice(head[0].length, head[0].length + 4096))
}

const still = (verify: (() => boolean) | undefined) => {
  if (!verify) return true
  try {
    return verify()
  } catch {
    return false
  }
}

/**
 * The asks in flight and the answers. One per page (the controller's):
 * `ask` posts the message (through `post`, the host bridge) and resolves when
 * the picture is cached (true) or the host said no / never answered (false).
 */
export class PosterBroker {
  readonly cache: PosterCache
  private pending = new Map<string, Pending>()
  private lastAsked = new Map<string, number>()
  private answered = 0
  private unanswered = 0

  constructor(
    private readonly post: (msg: PosterMessage) => void,
    private readonly sizeOf: (src: string) => { w: number; h: number } | null = () => null,
    cache?: PosterCache
  ) {
    this.cache = cache ?? new PosterCache()
  }

  /** The host has never answered and let several asks go: don't hold pages for it. */
  get silent() {
    return this.answered === 0 && this.unanswered >= POSTER_SILENT_AFTER
  }

  /** May `id` be asked for (periodically) now? */
  due(id: string, now: number) {
    const last = this.lastAsked.get(id)
    return last === undefined || now - last >= POSTER_EVERY_MS
  }

  /** An ask for `name` is in flight. */
  asking(name: string) {
    return this.pending.has(name)
  }

  ask(req: PosterRequest, now: number): Promise<boolean> {
    const open = this.pending.get(req.name)
    if (open) return new Promise(resolve => open.waiters.push(resolve))
    this.lastAsked.set(req.id, now)
    return new Promise(resolve => {
      const entry: Pending = {
        id: req.id,
        url: req.url,
        ...(req.alias && !sameUrl(req.alias, req.url) ? { alias: req.alias } : {}),
        ...(req.scene ? { scene: req.scene } : {}),
        ...(req.verify ? { verify: req.verify } : {}),
        at: now,
        waiters: [resolve],
        timer: setTimeout(() => {
          if (this.pending.get(req.name) !== entry) return
          this.pending.delete(req.name)
          this.unanswered++
          for (const w of entry.waiters) w(false)
        }, POSTER_TIMEOUT_MS),
      }
      this.pending.set(req.name, entry)
      const r = req.rect
      this.post({
        type: 'framePoster',
        name: req.name,
        id: req.id,
        url: req.url,
        rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.w), h: Math.round(r.h) },
        maxWidth: POSTER_MAX_WIDTH,
      })
    })
  }

  /** The host's answer: `copperCanvas.framePoster(name, dataUrl | null)`. True when it was for an ask in flight. */
  answer(name: unknown, data: unknown, now = Date.now()): boolean {
    if (typeof name !== 'string') return false
    const entry = this.pending.get(name)
    if (!entry) return false
    this.pending.delete(name)
    clearTimeout(entry.timer)
    this.answered++
    const ok = isPosterData(data) && still(entry.verify)
    if (ok) {
      const size = this.sizeOf(data) ?? { w: 0, h: 0 }
      this.cache.set(entry.id, {
        url: entry.url,
        ...(entry.alias ? { alias: entry.alias } : {}),
        src: data,
        w: size.w,
        h: size.h,
        at: now,
        ...(entry.scene ? { scene: entry.scene } : {}),
      })
    }
    for (const w of entry.waiters) w(ok)
    return true
  }

  /** Forget everything (a new session). */
  reset() {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer)
      for (const w of p.waiters) w(false)
    }
    this.pending.clear()
    this.lastAsked.clear()
  }
}
