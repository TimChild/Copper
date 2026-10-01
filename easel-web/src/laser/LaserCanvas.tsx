/**
 * <LaserCanvas>: the screen-space overlay. Put it inside the board's viewport element (the one
 * whose top-left is screen (0, 0) for `view`), above the shape layer. It fills its offset parent,
 * never takes pointer events, and runs a rAF loop only while `drawLaser` says something is still
 * visible. It wakes on any `trails` change and redraws in the same commit when `view` changes, so
 * the laser stays pinned to the board while panning and zooming. It never re-renders React per frame.
 */
import { useLayoutEffect, useRef, type CSSProperties, type JSX } from 'react'
import { drawLaser } from './draw'
import type { LaserTrails } from './trails'
import type { LaserView } from './types'

const STYLE: CSSProperties = {
  position: 'absolute',
  left: 0,
  top: 0,
  width: '100%',
  height: '100%',
  display: 'block',
  pointerEvents: 'none',
}

type Loop = { viewChanged(): void; dispose(): void }

export function LaserCanvas(props: { trails: LaserTrails; view: LaserView }): JSX.Element {
  const { trails, view } = props
  const canvasRef = useRef<HTMLCanvasElement | null>(null)
  const viewRef = useRef<LaserView>(view)
  const loopRef = useRef<Loop | null>(null)

  useLayoutEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const loop = startLoop(canvas, trails, () => viewRef.current)
    loopRef.current = loop
    return () => {
      loop.dispose()
      if (loopRef.current === loop) loopRef.current = null
    }
  }, [trails])

  useLayoutEffect(() => {
    viewRef.current = view
    loopRef.current?.viewChanged()
  }, [view])

  return <canvas ref={canvasRef} className="easel-laser" aria-hidden="true" style={STYLE} />
}

function startLoop(
  canvas: HTMLCanvasElement,
  trails: LaserTrails,
  getView: () => LaserView
): Loop {
  const ctx = canvas.getContext('2d')
  let raf = 0
  let dpr = window.devicePixelRatio || 1
  let painted = false
  let disposed = false

  const draw = (): boolean => {
    if (!ctx || disposed) return false
    painted = drawLaser(ctx, trails, getView(), dpr, Date.now())
    return painted
  }
  const frame = (): void => {
    raf = 0
    // drawLaser may prune and notify, which can schedule a frame itself; never schedule twice.
    if (draw() && !raf && !disposed) raf = requestAnimationFrame(frame)
  }
  const wake = (): void => {
    if (!raf && !disposed) raf = requestAnimationFrame(frame)
  }

  const resize = (cssW: number, cssH: number): void => {
    dpr = window.devicePixelRatio || 1
    const w = Math.max(1, Math.round(cssW * dpr))
    const h = Math.max(1, Math.round(cssH * dpr))
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w // resizing clears, so paint again now
      canvas.height = h
      if (painted || trails.hasVisible()) draw()
      wake()
    }
  }

  const ro =
    typeof ResizeObserver === 'undefined'
      ? null
      : new ResizeObserver((entries) => {
          const r = entries[entries.length - 1]?.contentRect
          if (r) resize(r.width, r.height)
        })
  ro?.observe(canvas)
  resize(canvas.clientWidth, canvas.clientHeight)

  // Moving the window to a display with another scale changes devicePixelRatio but not CSS size.
  let mq: MediaQueryList | null = null
  const onDpr = (): void => {
    resize(canvas.clientWidth, canvas.clientHeight)
    watchDpr()
  }
  const watchDpr = (): void => {
    mq?.removeEventListener('change', onDpr)
    mq = typeof matchMedia === 'function' ? matchMedia(`(resolution: ${dpr}dppx)`) : null
    mq?.addEventListener('change', onDpr)
  }
  watchDpr()

  const unsubscribe = trails.subscribe(wake)
  trails.setZoom(getView().z)
  wake()

  return {
    viewChanged() {
      trails.setZoom(getView().z)
      // Redraw synchronously so the laser moves in the same frame as the board's transform.
      if (painted || trails.hasVisible()) {
        if (draw()) wake()
      }
    },
    dispose() {
      disposed = true
      unsubscribe()
      ro?.disconnect()
      mq?.removeEventListener('change', onDpr)
      if (raf) cancelAnimationFrame(raf)
      raf = 0
    },
  }
}
