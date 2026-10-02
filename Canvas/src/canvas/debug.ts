/**
 * Render counters and a frame sampler for measuring the board. Counting is an
 * integer increment per render, so it ships; `window.__canvasDebug` (seeding
 * a big board, sampling frame times) is only installed by `?dev=1`.
 *
 *   __canvasDebug.seed({ stickies: 120, frames: 12, arrows: 40 })
 *   __canvasDebug.perf.start(); …; __canvasDebug.perf.stop()
 *     → { frames, p50, p95, max, over16, over33, boardRenders, shapeRenders }
 */
export const counters = {
  boardRenders: 0,
  shapeRenders: 0,
}

/** Count one render of `what` (a call, so components never mutate module state in render). */
export function countRender(what: keyof typeof counters) {
  counters[what]++
}

export interface FrameStats {
  frames: number
  p50: number
  p95: number
  max: number
  over16: number
  over33: number
  boardRenders: number
  shapeRenders: number
}

const pct = (sorted: number[], p: number) => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))]! : 0)

/** Frame-to-frame times between `start` and `stop`, plus how much rendered meanwhile. */
export function createFrameSampler() {
  let deltas: number[] = []
  let raf = 0
  let last = 0
  let base = { ...counters }
  const tick = (t: number) => {
    if (last) deltas.push(t - last)
    last = t
    raf = requestAnimationFrame(tick)
  }
  return {
    start() {
      cancelAnimationFrame(raf)
      deltas = []
      last = 0
      base = { ...counters }
      raf = requestAnimationFrame(tick)
    },
    stop(): FrameStats {
      cancelAnimationFrame(raf)
      const sorted = [...deltas].sort((a, b) => a - b)
      const round = (n: number) => Math.round(n * 10) / 10
      return {
        frames: deltas.length,
        p50: round(pct(sorted, 0.5)),
        p95: round(pct(sorted, 0.95)),
        max: round(sorted[sorted.length - 1] ?? 0),
        over16: deltas.filter(d => d > 17.5).length,
        over33: deltas.filter(d => d > 34).length,
        boardRenders: counters.boardRenders - base.boardRenders,
        shapeRenders: counters.shapeRenders - base.shapeRenders,
      }
    },
  }
}

const NOTES = [
  '**Launch** checklist\n- [ ] bridge\n- [x] laser\n- [ ] docs',
  '# Q3 plan\n- ship **canvas**\n- talk to Ada\n  - pricing',
  'Plain thought: keep it fast, keep it *quiet*, link https://example.com/docs',
  '1. sketch\n2. **build**\n3. measure',
  'Short one',
]
const COLORS = ['yellow', 'pink', 'blue', 'green', 'purple', 'white'] as const

/** Ops for a realistic big board: frames in a grid, notes inside, arrows between notes. */
export function seedOps({ stickies = 120, frames = 12, arrows = 40 }: { stickies?: number; frames?: number; arrows?: number } = {}) {
  const ops: Record<string, unknown>[] = []
  const perFrame = Math.max(1, Math.ceil(stickies / Math.max(1, frames)))
  const cols = Math.max(1, Math.ceil(Math.sqrt(frames || 1)))
  for (let f = 0; f < frames; f++) {
    const fx = (f % cols) * 980
    const fy = Math.floor(f / cols) * 760
    ops.push({ op: 'add', shape: { type: 'frame', id: `pf${f}`, x: fx, y: fy, w: 940, h: 700, title: `Area ${f + 1}` } })
  }
  for (let i = 0; i < stickies; i++) {
    const f = Math.floor(i / perFrame)
    const k = i % perFrame
    const fx = (f % cols) * 980
    const fy = Math.floor(f / cols) * 760
    ops.push({
      op: 'add',
      shape: {
        type: 'sticky',
        id: `ps${i}`,
        x: fx + 20 + (k % 4) * 225,
        y: fy + 20 + Math.floor(k / 4) * 225,
        color: COLORS[i % COLORS.length],
        text: `${NOTES[i % NOTES.length]} · ${i + 1}`,
      },
    })
  }
  for (let a = 0; a < arrows && stickies > 1; a++)
    ops.push({ op: 'connect', id: `pa${a}`, from: `ps${(a * 7) % stickies}`, to: `ps${(a * 7 + 1) % stickies}`, ...(a % 3 === 0 ? { label: 'then' } : {}) })
  return ops
}
