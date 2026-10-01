// @vitest-environment jsdom
import { describe, expect, it } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import * as Y from 'yjs'
import { Awareness } from 'y-protocols/awareness'
import {
  createAwareness,
  involvesOthers,
  samePeers,
  usePeers,
  type Peer,
} from '../lib/awareness'

const viewer = { id: 'v1', name: 'Collin', color: '#ff5a36' }

/** What a provider does when another client's state arrives. */
function deliver(local: Awareness, remote: Awareness) {
  local.states.set(remote.clientID, remote.getLocalState()!)
  local.emit('change', [{ added: [], updated: [remote.clientID], removed: [] }, 'remote'])
}

describe('awareness change filter', () => {
  it('involvesOthers is false for changes that only touch the local client', () => {
    expect(involvesOthers({ added: [], updated: [7], removed: [] }, 7)).toBe(false)
    expect(involvesOthers({ added: [7], updated: [], removed: [] }, 7)).toBe(false)
    expect(involvesOthers({ added: [], updated: [7, 9], removed: [] }, 7)).toBe(true)
    expect(involvesOthers({ added: [], updated: [], removed: [9] }, 7)).toBe(true)
  })

  it('samePeers compares id, name, colour and spot in order', () => {
    const a: Peer = { id: 1, name: 'A', color: '#000', cursor: { x: 1, y: 2 } }
    expect(samePeers([a], [{ ...a, cursor: { x: 1, y: 2 } }])).toBe(true)
    expect(samePeers([a], [{ ...a, cursor: { x: 1, y: 3 } }])).toBe(false)
    expect(samePeers([a], [])).toBe(false)
    expect(samePeers([a], [{ ...a, name: 'B' }])).toBe(false)
  })

  it('usePeers does not re-render for local cursor or laser updates', () => {
    const awareness = createAwareness(new Y.Doc(), viewer)
    let renders = 0
    const { result } = renderHook(() => {
      renders++
      return usePeers(awareness)
    })
    const base = renders
    act(() => {
      for (let i = 0; i < 30; i++) awareness.setLocalStateField('cursor', { x: i, y: i })
      awareness.setLocalStateField('laser', { id: 'l', color: '#f00', start: 1, end: null, pts: [] })
    })
    expect(renders).toBe(base)
    expect(result.current).toEqual([])
    awareness.destroy()
  })

  it('usePeers re-renders when a peer moves, and not when a peer re-sends the same spot', () => {
    const awareness = createAwareness(new Y.Doc(), viewer)
    const remote = new Awareness(new Y.Doc())
    remote.setLocalState({
      user: { id: 'v2', name: 'Felipe', color: '#0af' },
      cursor: { x: 10, y: 20 },
      laser: null,
    })
    let renders = 0
    const { result } = renderHook(() => {
      renders++
      return usePeers(awareness)
    })
    act(() => deliver(awareness, remote))
    expect(result.current.map(p => p.cursor)).toEqual([{ x: 10, y: 20 }])
    const before = renders
    const peers = result.current
    // Same spot again (e.g. their laser changed): same array, no render.
    act(() => deliver(awareness, remote))
    expect(renders).toBe(before)
    expect(result.current).toBe(peers)
    act(() => {
      remote.setLocalStateField('cursor', { x: 11, y: 20 })
      deliver(awareness, remote)
    })
    expect(renders).toBe(before + 1)
    expect(result.current[0]?.cursor).toEqual({ x: 11, y: 20 })
    awareness.destroy()
    remote.destroy()
  })
})
