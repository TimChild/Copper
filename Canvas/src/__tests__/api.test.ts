import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApi } from '../api'
import { Controller } from '../controller'

let api: ReturnType<typeof createApi>
let c: Controller
let posted: string[]

beforeEach(() => {
  posted = []
  vi.stubGlobal('window', { webkit: { messageHandlers: { canvas: { postMessage: (s: string) => posted.push(s) } } } })
  c = new Controller()
  api = createApi(c)
})
afterEach(() => {
  c.session?.destroy()
  vi.unstubAllGlobals()
})

describe('window.copperCanvas', () => {
  it('has a version and answers apply/read with JSON strings', () => {
    expect(typeof api.version).toBe('string')
    expect(JSON.parse(api.apply('[]'))).toMatchObject({ applied: 0, errors: [{ error: expect.stringMatching(/init/) }] })
    expect(JSON.parse(api.read())).toMatchObject({ error: expect.stringMatching(/init/) })
    api.init('{"docId":"x","name":"N","kind":"personal","me":{"id":"u","name":"U","color":"#000"},"state":null,"online":false,"readOnly":false}')
    const out = JSON.parse(api.apply('{"ops":[{"op":"add","shape":{"type":"sticky","id":"s","text":"hi"}}]}'))
    expect(out).toEqual({ applied: 1, ids: ['s'], errors: [] })
    const read = JSON.parse(api.read('{"full":true}'))
    expect(read.shapes[0]).toMatchObject({ id: 's', type: 'sticky', text: 'hi' })
  })

  it('takes ids as an array, a JSON string or one id', () => {
    api.init({ docId: 'x' })
    api.apply([
      { op: 'add', shape: { type: 'sticky', id: 'a' } },
      { op: 'add', shape: { type: 'sticky', id: 'b' } },
    ])
    api.select(['a'])
    expect(c.getSelection()).toEqual(['a'])
    api.select('["a","b"]')
    expect(c.getSelection()).toEqual(['a', 'b'])
    api.select('b')
    expect(c.getSelection()).toEqual(['b'])
    // Host-made selections are not reported back.
    expect(posted.map(p => JSON.parse(p).type)).not.toContain('selection')
    expect(() => api.zoomTo(['a'])).not.toThrow()
  })

  it('takes the host status as JSON or a value, and logs bad ones', () => {
    api.setStatus('{"mode":"shared-offline","pending":5}')
    expect(c.getHostStatus()).toEqual({ mode: 'shared-offline', pending: 5 })
    api.setStatus({ mode: 'shared-live' })
    expect(c.getHostStatus()).toEqual({ mode: 'shared-live' })
    expect(() => api.setStatus({ mode: 'sideways' })).not.toThrow()
    expect(c.getHostStatus()).toEqual({ mode: 'shared-live' })
    expect(posted.some(p => /setStatus/.test(JSON.parse(p).msg ?? ''))).toBe(true)
    api.setStatus(null)
    expect(c.getHostStatus()).toBeNull()
  })

  it('never throws into the host', () => {
    expect(() => api.applyUpdate('!!!')).not.toThrow()
    expect(() => api.init(42)).not.toThrow()
    expect(() => api.wsMessage('AAAA')).not.toThrow()
    expect(() => api.wsState('open')).not.toThrow()
    expect(() => api.setAgent('{')).not.toThrow()
    expect(() => api.theme('dark')).not.toThrow()
    expect(api.exportState()).toBe('')
    expect(posted.some(p => JSON.parse(p).level === 'error')).toBe(true)
  })
})
