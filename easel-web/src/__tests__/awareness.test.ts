import { describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { Awareness } from 'y-protocols/awareness'
import { createAwareness, readPeers } from '../lib/awareness'

const viewer = { id: 'v1', name: 'Collin', color: '#ff5a36' }

describe('awareness', () => {
  it('starts with the contract local state', () => {
    const doc = new Y.Doc()
    const awareness = createAwareness(doc, viewer)
    expect(awareness.getLocalState()).toEqual({
      user: viewer,
      cursor: null,
      laser: null,
    })
    awareness.destroy()
  })

  it('lists remote cursors and never the local client', () => {
    const doc = new Y.Doc()
    const awareness = createAwareness(doc, viewer)
    awareness.setLocalStateField('cursor', { x: 1, y: 2 })
    expect(readPeers(awareness)).toEqual([])

    // Fake what a provider would deliver for another client.
    const remote = new Awareness(new Y.Doc())
    remote.setLocalState({
      user: { id: 'v2', name: 'Felipe', color: '#0af' },
      cursor: { x: 10, y: 20 },
      laser: null,
    })
    awareness.states.set(remote.clientID, remote.getLocalState()!)
    expect(readPeers(awareness)).toEqual([
      { id: remote.clientID, name: 'Felipe', color: '#0af', cursor: { x: 10, y: 20 } },
    ])

    // No cursor = not drawn.
    awareness.states.set(remote.clientID, { user: viewer, cursor: null, laser: null })
    expect(readPeers(awareness)).toEqual([])
    awareness.destroy()
    remote.destroy()
  })

  it('emits change for local field updates (what the page throttles)', () => {
    const doc = new Y.Doc()
    const awareness = createAwareness(doc, viewer)
    const onChange = vi.fn()
    awareness.on('change', onChange)
    awareness.setLocalStateField('laser', { id: 'l', color: '#f00', start: 1, end: null, pts: [] })
    expect(onChange).toHaveBeenCalledTimes(1)
    expect(awareness.getLocalState()?.laser).toMatchObject({ id: 'l' })
    awareness.destroy()
  })
})
