import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { Controller } from '../controller'
import { liveAgents, readAgents } from '../canvas/agents'
import { BridgeSocket } from '../bridge-socket'

let c: Controller
beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal('window', {})
  c = new Controller()
  c.init({ docId: 'expiry', me: { id: 'human', name: 'Human' } })
})
afterEach(() => {
  c.session?.destroy()
  vi.unstubAllGlobals()
  vi.useRealTimers()
})
const act = () => c.setAgent({ id: 'a', name: 'Astra', status: 'writing', cursor: { x: 50, y: 50 } })

describe('ephemeral agent presence', () => {
  it('expires after two seconds, including the facepile and tool read', () => {
    act()
    expect(c.presence().some(p => p.id === 'a')).toBe(true)
    vi.advanceTimersByTime(2100)
    expect(c.presence()).toEqual([])
    expect(c.session!.store.agents.has('a')).toBe(false)
    expect(c.session!.awareness.getLocalState()?.user.id).toBe('human')
  })
  it('renews on every operation without an old timer removing the new cursor', () => {
    act()
    vi.advanceTimersByTime(1500)
    act()
    vi.advanceTimersByTime(1000)
    expect(c.presence()).toHaveLength(1)
    vi.advanceTimersByTime(1100)
    expect(c.presence()).toEqual([])
  })
  it('clears owned agents on close without deleting another writer', () => {
    act()
    c.session!.store.agents.set('other', { name: 'Other', updatedAt: Date.now(), status: 'writing' })
    const store = c.session!.store
    c.session!.destroy()
    expect(store.agents.has('a')).toBe(false)
    expect(store.agents.has('other')).toBe(true)
    c.session = null
  })
  it('clears owned leases when the host socket disconnects', () => {
    c.init({ docId: 'shared', online: true, wsURL: 'wss://invalid.test/canvas', me: { id: 'human' } })
    BridgeSocket.setState('open')
    act()
    expect(c.presence()).toHaveLength(1)
    BridgeSocket.setState('closed')
    expect(c.session!.store.agents.has('a')).toBe(false)
  })
  it('does not delete a newer lease written by another client under the same id', () => {
    act()
    vi.advanceTimersByTime(1000)
    c.session!.store.agents.set('a', { name: 'Other writer', status: 'writing', updatedAt: Date.now() })
    vi.advanceTimersByTime(1100)
    expect(c.session!.store.agents.get('a')).toMatchObject({ name: 'Other writer' })
    expect(c.presence()).toHaveLength(1)
  })
  it('hides stale presence replayed from a stored or disconnected peer', () => {
    const map = new Y.Doc().getMap('agents')
    map.set('stale', { name: 'Old', updatedAt: Date.now() - 3000, status: 'writing' })
    expect(liveAgents(readAgents(map), Date.now())).toEqual([])
  })
})
