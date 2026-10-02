import { describe, expect, it } from 'vitest'
import { LaserTrails } from '../laser'

const T0 = 1_700_000_000_000

describe('subscribe', () => {
  it('fires on every change and only on changes', () => {
    const tr = new LaserTrails()
    const log: string[] = []
    let step = ''
    const off = tr.subscribe(() => log.push(step))
    const run = (name: string, fn: () => void) => {
      step = name
      fn()
    }
    run('begin', () => tr.begin({ x: 0, y: 0 }, '#f00', T0))
    run('move', () => tr.move({ x: 10, y: 0 }, T0 + 10))
    run('tiny move', () => tr.move({ x: 10.5, y: 0 }, T0 + 20))
    run('end', () => tr.end(T0 + 30))
    run('end again', () => tr.end(T0 + 40))
    run('prune early', () => tr.prune(T0 + 100))
    run('prune gone', () => tr.prune(T0 + 30 + 3000))
    run('prune again', () => tr.prune(T0 + 9000))
    run('remote', () => tr.setRemote(3, { id: 'r', color: '#0f0', start: 5, end: null, pts: [0, 0, 0] }, T0))
    run('remote null', () => tr.setRemote(3, null, T0 + 10))
    run('remote null again', () => tr.setRemote(3, null, T0 + 20))
    run('cancel nothing', () => tr.cancel())
    run('begin 2', () => tr.begin({ x: 0, y: 0 }, '#f00', T0 + 50))
    run('cancel', () => tr.cancel())
    off()
    run('after off', () => tr.begin({ x: 0, y: 0 }, '#f00', T0 + 60))
    expect(log).toEqual(['begin', 'move', 'end', 'prune gone', 'remote', 'remote null', 'begin 2', 'cancel'])
  })

  it('fires when a stroke being drawn drops its faded tail', () => {
    const tr = new LaserTrails()
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.move({ x: 10, y: 0 }, T0 + 1000)
    let n = 0
    tr.subscribe(() => n++)
    tr.prune(T0 + 4000)
    expect(n).toBe(0)
    tr.prune(T0 + 5000)
    expect(n).toBe(1)
  })

  it('supports several listeners and unsubscribing inside a callback', () => {
    const tr = new LaserTrails()
    let a = 0
    let b = 0
    const offA = tr.subscribe(() => {
      a++
      offA()
    })
    tr.subscribe(() => b++)
    tr.begin({ x: 0, y: 0 }, '#f00', T0)
    tr.end(T0 + 1)
    expect([a, b]).toEqual([1, 2])
  })
})
