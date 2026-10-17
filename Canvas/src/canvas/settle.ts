/**
 * `copperCanvas.settled(timeoutMs)`: resolves once what is on screen is drawn
 * — every picture mounted in the view has decoded (a downscaled copy still
 * being made counts as not yet: `thumbs.ts` draws nothing until it is ready)
 * and every live web frame in the view is either loaded or showing its
 * poster or card, not a blank loading page — plus two animation frames; or
 * when `timeoutMs` (default 2500, 0–10000) is up, with what was still
 * pending. Never rejects. The host waits on it before it takes the board's
 * picture (`canvas_screenshot`): `ready` comes as soon as the doc is applied,
 * long before a cold board's pictures are.
 *
 * What is pending is read from the DOM: a view still waiting marks itself
 * `data-pending="image" | "frame"` (`Shapes.tsx`, `WebFrame.tsx`), and every
 * `<img>` on screen must be complete and decoded.
 */

export interface Pending {
  images: number
  frames: number
}

export interface Settled {
  settled: boolean
  waitedMs: number
  pending: Pending
}

export const SETTLE_DEFAULT_MS = 2500
export const SETTLE_MAX_MS = 10000
/** A decode that hasn't answered in this long is taken as done (the image is complete; WebKit may sit on it). */
const DECODE_GRACE_MS = 1500

export interface SettleDeps {
  /** What is still pending on screen right now. */
  scan(): Pending
  /** The next animation frame (or a short timer, where frames don't come). */
  frame(): Promise<void>
  /** Resolves after `ms`. */
  sleep(ms: number): Promise<void>
  now(): number
}

export function clampTimeout(raw: unknown): number {
  const n = typeof raw === 'string' && raw.trim() ? Number(raw) : raw
  if (typeof n !== 'number' || !Number.isFinite(n)) return SETTLE_DEFAULT_MS
  return Math.min(SETTLE_MAX_MS, Math.max(0, Math.round(n)))
}

const none = (): Pending => ({ images: 0, frames: 0 })

export async function settled(timeoutMs?: unknown, deps: SettleDeps = domDeps()): Promise<Settled> {
  const limit = clampTimeout(timeoutMs)
  let start = 0
  try {
    start = deps.now()
  } catch {
    // keep 0
  }
  const elapsed = () => {
    try {
      return Math.max(0, deps.now() - start)
    } catch {
      return limit
    }
  }
  /** Scans in a row that found nothing pending. */
  let quiet = 0
  for (;;) {
    let pending: Pending
    try {
      pending = deps.scan()
    } catch {
      pending = none()
    }
    const total = pending.images + pending.frames
    quiet = total ? 0 : quiet + 1
    // Nothing pending now and for the two frames before: drawn.
    if (quiet >= 3) return { settled: true, waitedMs: Math.round(elapsed()), pending }
    const spent = elapsed()
    if (spent >= limit) return { settled: total === 0, waitedMs: Math.round(spent), pending }
    try {
      await Promise.race([deps.frame(), deps.sleep(Math.min(limit - spent, 100))])
    } catch {
      await new Promise<void>(resolve => setTimeout(resolve, 16))
    }
  }
}

// ---- the DOM ------------------------------------------------------------------------

type Box = { left: number; top: number; right: number; bottom: number }

const onScreen = (r: DOMRect, view: Box) =>
  r.width > 0 && r.height > 0 && r.right > view.left && r.bottom > view.top && r.left < view.right && r.top < view.bottom

/** Decodes asked for, by image: the source asked for, when, and whether it answered. */
const decodes = new WeakMap<HTMLImageElement, { src: string; at: number; done: boolean }>()

/** Pending pictures and frames in the board's view right now. */
export function scanDom(doc: Document = document, now: () => number = () => performance.now()): Pending {
  const out = none()
  const win = doc.defaultView
  const board = doc.querySelector('[role=application]')
  const area = board?.getBoundingClientRect()
  const w = win?.innerWidth ?? 0
  const h = win?.innerHeight ?? 0
  const view: Box =
    area && area.width > 0 && area.height > 0
      ? { left: Math.max(0, area.left), top: Math.max(0, area.top), right: Math.min(w || area.right, area.right), bottom: Math.min(h || area.bottom, area.bottom) }
      : { left: 0, top: 0, right: w, bottom: h }
  const root: ParentNode = board ?? doc
  for (const el of root.querySelectorAll<HTMLElement>('[data-pending]')) {
    if (!onScreen(el.getBoundingClientRect(), view)) continue
    if (el.dataset.pending === 'frame') out.frames++
    else out.images++
  }
  for (const img of root.querySelectorAll<HTMLImageElement>('[data-id] img')) {
    if (img.style.visibility === 'hidden' || !img.getAttribute('src')) continue
    if (!onScreen(img.getBoundingClientRect(), view)) continue
    if (!img.complete) {
      out.images++
      continue
    }
    // Complete with no size: broken. It draws as it ever will.
    if (!img.naturalWidth) continue
    const src = img.currentSrc || img.src
    const seen = decodes.get(img)
    if (seen && seen.src === src && (seen.done || now() - seen.at > DECODE_GRACE_MS)) continue
    if (!seen || seen.src !== src) {
      const entry = { src, at: now(), done: false }
      decodes.set(img, entry)
      const finish = () => void (entry.done = true)
      try {
        if (typeof img.decode === 'function') img.decode().then(finish, finish)
        else finish()
      } catch {
        finish()
      }
      if (entry.done) continue
    }
    out.images++
  }
  return out
}

/** The next animation frame, or 100 ms where a hidden view gets none. */
function nextFrame(): Promise<void> {
  return new Promise(resolve => {
    let done = false
    const go = () => {
      if (done) return
      done = true
      resolve()
    }
    const timer = setTimeout(go, 100)
    if (typeof requestAnimationFrame === 'function')
      requestAnimationFrame(() => {
        clearTimeout(timer)
        go()
      })
  })
}

export function domDeps(): SettleDeps {
  return {
    scan: () => (typeof document === 'undefined' ? none() : scanDom(document)),
    frame: nextFrame,
    sleep: ms => new Promise(resolve => setTimeout(resolve, ms)),
    now: () => (typeof performance !== 'undefined' ? performance.now() : Date.now()),
  }
}
