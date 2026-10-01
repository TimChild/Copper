/**
 * `window.__easelDebug`: always present, inert until called. The perf
 * harness (research/2026-10-01-copper-easels/perf) uses it to build a
 * realistic board in one transaction and to measure frame times and how
 * often the board re-renders. Counting is two integer increments per page
 * render, so it is safe to ship.
 *
 *   __easelDebug.seed({ stickies: 60, frames: 10, arrows: 20, images: 2 })
 *   __easelDebug.perf.start(); …; __easelDebug.perf.stop()
 *     → { frames, p50, p95, max, over16, over33, pageRenders, pageCommits, … }
 */
import { SHAPE_COLORS, type ShapeColor } from './doc/easel-doc'
import type { View } from './lib/canvas-geometry'
import type { EaselSession } from './session'

/** Render counters. Plain numbers so the hot path is an increment. */
export const counters = {
  pageRenders: 0,
  pageCommits: 0,
  shapeRenders: 0,
  /** TipTap editors alive right now (a gauge, not a counter). */
  editors: 0,
}

/** `performance.now()` at named moments of opening a board. */
const marks: Record<string, number> = {}
export function mark(name: string) {
  if (!(name in marks)) marks[name] = performance.now()
}

/** What the page lends the hook so the harness can set the camera. */
export interface BoardHandle {
  getView(): View
  setView(view: View): void
  fit(): void
}
let board: BoardHandle | null = null
export function registerBoard(handle: BoardHandle | null) {
  board = handle
}

export interface SeedOptions {
  stickies?: number
  frames?: number
  arrows?: number
  images?: number
}

/** Mixed markdown, the way people actually write stickies. */
const NOTES = [
  '**Launch** checklist\n\n- [ ] bridge messages\n- [x] laser pointer\n- [ ] see [[Roadmap]]',
  '# Q3 plan\n\n- ship **easels**\n- talk to [[Felipe]]\n  - pricing\n  - sharing',
  'Plain thought about the board: keep it fast, keep it *quiet*, and link https://copper.dev/docs',
  '1. sketch\n2. **build**\n3. measure\n4. repeat',
  '`setView` per wheel event and *every* sticky re-renders [[Perf notes|perf]]',
  '- [ ] check WebKit\n- [ ] check Chrome\n- [x] write the harness',
  '## Open questions\n\n- who owns **sync**?\n- does [[P4]] need accounts?',
  'Short one',
  'Remember: **bold**, *italic*, `code`, [[Wiki]] and [a link](https://example.com) all render live.',
  '- one\n- two\n  - two and a half\n- three',
]
const LABELS = ['then', 'depends on', 'feeds', 'blocks']

/** A small picture as a File, drawn on a canvas (no network, no fixtures). */
async function makePicture(i: number): Promise<File> {
  const canvas = document.createElement('canvas')
  canvas.width = 640
  canvas.height = 400
  const ctx = canvas.getContext('2d')!
  const g = ctx.createLinearGradient(0, 0, 640, 400)
  g.addColorStop(0, i % 2 ? '#ffd6a8' : '#bcd8ff')
  g.addColorStop(1, i % 2 ? '#ff5a36' : '#3b82f6')
  ctx.fillStyle = g
  ctx.fillRect(0, 0, 640, 400)
  ctx.fillStyle = 'rgba(255,255,255,0.85)'
  ctx.beginPath()
  ctx.arc(440, 180, 80, 0, Math.PI * 2)
  ctx.fill()
  const blob = await new Promise<Blob>((resolve, reject) =>
    canvas.toBlob(b => (b ? resolve(b) : reject(new Error('toBlob'))), 'image/png')
  )
  return new File([blob], `seed-${i}.png`, { type: 'image/png' })
}

const FRAME = { w: 680, h: 400 }
const STICKY = { w: 200, h: 140 }
const GAP = 80

async function seed(session: EaselSession, opts: SeedOptions = {}) {
  const { stickies = 60, frames = 10, arrows = 20, images = 2 } = opts
  const { doc, host, config } = session
  const pictures: string[] = []
  for (let i = 0; i < Math.min(images, frames); i++) {
    const { fileId } = await host.uploadFile(await makePicture(i))
    pictures.push(`file:${fileId}`)
  }
  const stickyIds: string[] = []
  const colors = SHAPE_COLORS.filter(c => c !== 'gray') as ShapeColor[]
  doc.doc.transact(() => {
    let placed = 0
    const cols = 5
    for (let f = 0; f < frames; f++) {
      const fx = (f % cols) * (FRAME.w + GAP)
      const fy = Math.floor(f / cols) * (FRAME.h + GAP)
      const image = pictures[f]
      doc.createShape({
        type: 'frame',
        x: fx,
        y: fy,
        ...FRAME,
        color: f % 3 === 0 ? 'white' : 'gray',
        text: image ? `Screenshot ${f + 1}` : `**Area ${f + 1}** · ideas`,
        image,
        by: config.viewer.name,
      })
      if (image) continue
      // Six notes per text frame, 3 × 2, under the 32 px title bar.
      for (let k = 0; k < 6 && placed < stickies; k++, placed++) {
        stickyIds.push(
          doc.createShape({
            type: 'sticky',
            x: fx + 20 + (k % 3) * (STICKY.w + 20),
            y: fy + 52 + Math.floor(k / 3) * (STICKY.h + 24),
            ...STICKY,
            color: colors[placed % colors.length],
            text: NOTES[placed % NOTES.length],
            by: config.viewer.name,
          })
        )
      }
    }
    // Whatever did not fit in a frame goes in rows under them.
    const rowsTop = Math.ceil(frames / cols) * (FRAME.h + GAP)
    for (let k = 0; placed < stickies; k++, placed++) {
      stickyIds.push(
        doc.createShape({
          type: 'sticky',
          x: (k % 14) * (STICKY.w + 40),
          y: rowsTop + Math.floor(k / 14) * (STICKY.h + 40),
          ...STICKY,
          color: colors[placed % colors.length],
          text: NOTES[placed % NOTES.length],
          by: config.viewer.name,
        })
      )
    }
    // Pairs of neighbours: across a row, or diagonally down to the next row.
    let made = 0
    for (let i = 0; i + 1 < stickyIds.length && made < arrows; i += 2, made++) {
      doc.createShape({
        type: 'arrow',
        from: `shape:${stickyIds[i]}`,
        to: `shape:${stickyIds[i + 1]}`,
        text: made % 3 === 0 ? LABELS[made % LABELS.length] : '',
        by: config.viewer.name,
      })
    }
  })
  // Seeding is setup, not an edit: start undo history clean.
  doc.undo.clear()
  session.saver.flush(true)
  return {
    shapes: doc.getShapesSnapshot().size,
    stickies: stickyIds.length,
  }
}

const percentile = (sorted: number[], p: number) =>
  sorted.length
    ? sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!
    : 0
const round = (n: number) => Math.round(n * 10) / 10

export interface PerfResult {
  frames: number
  p50: number
  p95: number
  max: number
  /** Frames longer than one 60 Hz vsync (> 17.5 ms): at least one dropped. */
  over16: number
  /** Frames longer than two vsyncs (> 34 ms). */
  over33: number
  pageRenders: number
  pageCommits: number
  shapeRenders: number
  ms: number
}

function createPerf() {
  let raf = 0
  let last: number | null = null
  let deltas: number[] = []
  let base = { ...counters }
  let began = 0
  const loop = (t: number) => {
    if (last !== null) deltas.push(t - last)
    last = t
    raf = requestAnimationFrame(loop)
  }
  return {
    start() {
      cancelAnimationFrame(raf)
      deltas = []
      last = null
      base = { ...counters }
      began = performance.now()
      raf = requestAnimationFrame(loop)
    },
    stop(): PerfResult {
      cancelAnimationFrame(raf)
      raf = 0
      const sorted = [...deltas].sort((a, b) => a - b)
      return {
        frames: deltas.length,
        p50: round(percentile(sorted, 50)),
        p95: round(percentile(sorted, 95)),
        max: round(sorted[sorted.length - 1] ?? 0),
        over16: deltas.filter(d => d > 17.5).length,
        over33: deltas.filter(d => d > 34).length,
        pageRenders: counters.pageRenders - base.pageRenders,
        pageCommits: counters.pageCommits - base.pageCommits,
        shapeRenders: counters.shapeRenders - base.shapeRenders,
        ms: Math.round(performance.now() - began),
      }
    },
  }
}

declare global {
  interface Window {
    __easelDebug?: ReturnType<typeof createDebug>
  }
}

function createDebug() {
  let session: EaselSession | null = null
  return {
    counters,
    marks,
    perf: createPerf(),
    attach(s: EaselSession | null) {
      session = s
    },
    seed(opts?: SeedOptions) {
      if (!session) throw new Error('no easel open yet')
      return seed(session, opts)
    },
    view: () => board?.getView() ?? null,
    setView: (view: View) => board?.setView(view),
    fit: () => board?.fit(),
  }
}

export const debug = createDebug()
if (typeof window !== 'undefined') window.__easelDebug = debug
