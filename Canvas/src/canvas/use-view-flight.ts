/**
 * Animate the board's view to a target, then call `onDone`. Any other view
 * change (a pan, a wheel, a zoom button) mid-flight wins and ends the flight.
 * With reduced motion the view jumps.
 */
import { useCallback, useEffect, useMemo, useRef, type Dispatch, type RefObject, type SetStateAction } from 'react'
import type { View } from './geometry'
import { flightMs, flightView } from './search'

export const prefersReducedMotion = () =>
  typeof window !== 'undefined' && (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false)

export function useViewFlight(view: View, setView: Dispatch<SetStateAction<View>>, viewport: RefObject<HTMLElement | null>) {
  const current = useRef(view)
  useEffect(() => {
    current.current = view
  })
  const frame = useRef(0)

  const cancel = useCallback(() => {
    cancelAnimationFrame(frame.current)
    frame.current = 0
  }, [])

  const fly = useCallback(
    (to: View, onDone?: () => void) => {
      cancel()
      const el = viewport.current
      const from = current.current
      if (!el || prefersReducedMotion() || document.hidden) {
        setView(to)
        onDone?.()
        return
      }
      const w = el.clientWidth
      const h = el.clientHeight
      const ms = flightMs(from, to, w, h)
      const start = performance.now()
      let expected = from
      let stopped = false
      const tick = (now: number) => {
        if (stopped) return
        const t = Math.min(1, (now - start) / ms)
        const next = flightView(from, to, t, w, h)
        const prev = expected
        expected = next
        setView(v => {
          // Someone moved the board since our last frame: leave it there.
          if (v !== prev) {
            stopped = true
            return v
          }
          return next
        })
        if (t < 1) frame.current = requestAnimationFrame(tick)
        else {
          frame.current = 0
          onDone?.()
        }
      }
      frame.current = requestAnimationFrame(tick)
    },
    [cancel, setView, viewport]
  )

  useEffect(() => cancel, [cancel])
  // Stable: the board's actions depend on it, and a new object per render
  // would re-render every shape on every pan.
  return useMemo(() => ({ fly, cancel }), [fly, cancel])
}
