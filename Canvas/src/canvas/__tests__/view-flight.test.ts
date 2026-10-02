// @vitest-environment jsdom
import { act, createElement, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { describe, expect, it } from 'vitest'
import type { View } from '../geometry'
import { useViewFlight } from '../use-view-flight'

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

describe('useViewFlight', () => {
  it('hands out the same object across renders, so the board’s actions stay stable', () => {
    const seen: unknown[] = []
    let pan: (v: View) => void = () => {}
    function Probe() {
      const [view, setView] = useState<View>({ x: 0, y: 0, z: 1 })
      const el = useRef<HTMLDivElement>(null)
      pan = setView
      seen.push(useViewFlight(view, setView, el))
      return createElement('div', { ref: el })
    }
    const host = document.createElement('div')
    const root = createRoot(host)
    act(() => root.render(createElement(Probe)))
    act(() => pan({ x: 10, y: 0, z: 1 }))
    act(() => pan({ x: 20, y: 5, z: 1.5 }))
    expect(seen.length).toBeGreaterThanOrEqual(3)
    expect(new Set(seen).size).toBe(1)
    act(() => root.unmount())
  })
})
