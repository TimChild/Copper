// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { SETTLE_DEFAULT_MS, clampTimeout, scanDom, settled, type Pending, type SettleDeps } from '../settle'

/*
 * jsdom lays nothing out and loads no pictures: every box on screen is given
 * (`at`), and an image's `complete` / `naturalWidth` / `decode` are set by hand.
 */

const VIEW = { w: 1440, h: 900 }
const rect = (left: number, top: number, w: number, h: number) =>
  ({ left, top, right: left + w, bottom: top + h, width: w, height: h, x: left, y: top, toJSON: () => ({}) }) as DOMRect
const at = <E extends Element>(el: E, r: DOMRect) => {
  el.getBoundingClientRect = () => r
  return el
}

let board: HTMLElement

beforeEach(() => {
  document.body.innerHTML = ''
  board = at(document.createElement('div'), rect(0, 0, VIEW.w, VIEW.h))
  board.setAttribute('role', 'application')
  document.body.append(board)
  Object.defineProperty(window, 'innerWidth', { value: VIEW.w, configurable: true })
  Object.defineProperty(window, 'innerHeight', { value: VIEW.h, configurable: true })
})
afterEach(() => {
  document.body.innerHTML = ''
})

function shape(id: string, r: DOMRect, pending?: 'image' | 'frame') {
  const el = at(document.createElement('div'), r)
  el.dataset.id = id
  if (pending) el.dataset.pending = pending
  board.append(el)
  return el
}

function picture(parent: HTMLElement, r: DOMRect, state: { complete: boolean; naturalWidth?: number; decode?: () => Promise<void> }) {
  const img = at(document.createElement('img'), r)
  img.setAttribute('src', `https://example.test/${Math.random()}.png`)
  Object.defineProperty(img, 'complete', { get: () => state.complete, configurable: true })
  Object.defineProperty(img, 'naturalWidth', { get: () => state.naturalWidth ?? 0, configurable: true })
  img.decode = state.decode ?? (() => Promise.resolve())
  parent.append(img)
  return img
}

const tick = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms))

/** The page's deps, with frames every 5 ms and the clock counted. */
function deps(scan: () => Pending = () => scanDom(document)) {
  const counts = { frames: 0, scans: 0 }
  const d: SettleDeps = {
    scan: () => {
      counts.scans++
      return scan()
    },
    frame: async () => {
      counts.frames++
      await tick(5)
    },
    sleep: ms => tick(ms),
    now: () => performance.now(),
  }
  return { d, counts }
}

describe('settled', () => {
  it('resolves within two frames when nothing is pending', async () => {
    shape('s1', rect(10, 10, 100, 100))
    const { d, counts } = deps()
    const out = await settled(2500, d)
    expect(out).toEqual({ settled: true, waitedMs: expect.any(Number), pending: { images: 0, frames: 0 } })
    expect(counts.frames).toBe(2)
    expect(out.waitedMs).toBeLessThan(200)
  })

  it('waits for an image on screen to decode', async () => {
    const host = shape('img-1', rect(100, 100, 200, 150))
    let decoded: () => void = () => {}
    const img = picture(host, rect(100, 100, 200, 150), {
      complete: true,
      naturalWidth: 640,
      decode: () => new Promise<void>(resolve => (decoded = resolve)),
    })
    expect(img.isConnected).toBe(true)
    const { d } = deps()
    const run = settled(2500, d)
    await tick(60)
    expect(scanDom(document).images).toBe(1)
    decoded()
    const out = await run
    expect(out.settled).toBe(true)
    expect(out.waitedMs).toBeGreaterThanOrEqual(50)
    expect(out.pending).toEqual({ images: 0, frames: 0 })
  })

  it('waits for an image still loading, and for a small copy still being made', async () => {
    const state = { complete: false, naturalWidth: 0 }
    picture(shape('img-1', rect(0, 0, 50, 50)), rect(0, 0, 50, 50), state)
    const thumbless = shape('img-2', rect(60, 0, 50, 50), 'image')
    expect(scanDom(document)).toEqual({ images: 2, frames: 0 })
    const { d } = deps()
    const run = settled(2500, d)
    await tick(30)
    state.complete = true
    state.naturalWidth = 300
    await tick(30)
    delete thumbless.dataset.pending
    const out = await run
    expect(out).toMatchObject({ settled: true, pending: { images: 0, frames: 0 } })
    expect(out.waitedMs).toBeGreaterThanOrEqual(50)
  })

  it('times out with what is still pending on screen, never rejecting', async () => {
    shape('frame-1', rect(200, 200, 400, 300), 'frame')
    shape('img-1', rect(700, 200, 100, 100), 'image')
    picture(shape('img-2', rect(800, 200, 100, 100)), rect(800, 200, 100, 100), { complete: false })
    // Off screen: not waited for.
    shape('img-off', rect(VIEW.w + 400, 0, 100, 100), 'image')
    shape('frame-off', rect(0, -900, 400, 300), 'frame')
    const { d } = deps()
    const out = await settled(120, d)
    expect(out.settled).toBe(false)
    expect(out.pending).toEqual({ images: 2, frames: 1 })
    expect(out.waitedMs).toBeGreaterThanOrEqual(115)
    expect(out.waitedMs).toBeLessThan(600)
  })

  it('a broken image, a hidden poster and an empty source are not waited for', async () => {
    picture(shape('img-1', rect(0, 0, 50, 50)), rect(0, 0, 50, 50), { complete: true, naturalWidth: 0 })
    const hidden = picture(shape('wf-1', rect(60, 0, 50, 50)), rect(60, 0, 50, 50), { complete: false })
    hidden.style.visibility = 'hidden'
    const empty = picture(shape('img-3', rect(120, 0, 50, 50)), rect(120, 0, 50, 50), { complete: false })
    empty.removeAttribute('src')
    expect(scanDom(document)).toEqual({ images: 0, frames: 0 })
  })

  it('a scan that throws counts as nothing pending; timeout 0 answers at once', async () => {
    const { d } = deps(() => {
      throw new Error('boom')
    })
    await expect(settled(1000, d)).resolves.toMatchObject({ settled: true })
    const pending = deps(() => ({ images: 3, frames: 0 }))
    await expect(settled(0, pending.d)).resolves.toEqual({ settled: false, waitedMs: expect.any(Number), pending: { images: 3, frames: 0 } })
    expect(pending.counts.frames).toBe(0)
  })

  it('clamps the timeout to 0–10000, default 2500', () => {
    expect(clampTimeout(undefined)).toBe(SETTLE_DEFAULT_MS)
    expect(clampTimeout('nope')).toBe(SETTLE_DEFAULT_MS)
    expect(clampTimeout(-5)).toBe(0)
    expect(clampTimeout(99999)).toBe(10000)
    expect(clampTimeout('1200')).toBe(1200)
  })
})
