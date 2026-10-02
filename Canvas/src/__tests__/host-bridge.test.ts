import { afterEach, describe, expect, it, vi } from 'vitest'
import { frame, hasNativeHost, hostDouble, hostLog, postToHost } from '../host-bridge'

afterEach(() => vi.unstubAllGlobals())

describe('host bridge framing', () => {
  it('posts one JSON string per message to the native handler', () => {
    const postMessage = vi.fn()
    vi.stubGlobal('window', { webkit: { messageHandlers: { canvas: { postMessage } } } })
    expect(hasNativeHost()).toBe(true)
    postToHost({ type: 'update', b64: 'AAEC' })
    postToHost({ type: 'selection', ids: ['a', 'b'] })
    postToHost({ type: 'openUrl', url: 'https://x.dev' })
    postToHost({ type: 'share' })
    postToHost({ type: 'presence', people: [{ id: 'u2', name: 'Bea', color: '#f00', kind: 'human' }] })
    expect(postMessage.mock.calls.map(c => c[0])).toEqual([
      '{"type":"update","b64":"AAEC"}',
      '{"type":"selection","ids":["a","b"]}',
      '{"type":"openUrl","url":"https://x.dev"}',
      '{"type":"share"}',
      '{"type":"presence","people":[{"id":"u2","name":"Bea","color":"#f00","kind":"human"}]}',
    ])
    for (const [json] of postMessage.mock.calls) expect(typeof json).toBe('string')
  })

  it('frames every message type the contract names', () => {
    for (const msg of [
      { type: 'ready', version: '1' },
      { type: 'ws', b64: 'AA==' },
      { type: 'wsOpen', url: 'ws://bridge/x' },
      { type: 'wsClose' },
      { type: 'share' },
      { type: 'presence', people: [{ id: 'u2', name: 'Bea', color: '#f00', kind: 'human' }] },
      { type: 'log', level: 'warn', msg: 'm' },
    ] as const)
      expect(JSON.parse(frame(msg))).toEqual(msg)
  })

  it('falls back to the recording double outside Copper', () => {
    const seen: string[] = []
    vi.stubGlobal('window', { __copperHost: { messages: [], onMessage: (_m: unknown, json: string) => seen.push(json) } })
    expect(hasNativeHost()).toBe(false)
    postToHost({ type: 'wsClose' })
    expect(hostDouble().messages).toEqual([{ type: 'wsClose' }])
    expect(seen).toEqual(['{"type":"wsClose"}'])
  })

  it('creates the double on first use and caps what it records', () => {
    vi.stubGlobal('window', {})
    for (let i = 0; i < 2100; i++) postToHost({ type: 'wsClose' })
    expect(hostDouble().messages.length).toBe(2000)
  })

  it('never throws when the handler does', () => {
    vi.stubGlobal('window', {
      webkit: {
        messageHandlers: {
          canvas: {
            postMessage: () => {
              throw new Error('gone')
            },
          },
        },
      },
    })
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() => postToHost({ type: 'wsClose' })).not.toThrow()
    spy.mockRestore()
  })

  it('logs to the host as a log message', () => {
    const postMessage = vi.fn()
    vi.stubGlobal('window', { webkit: { messageHandlers: { canvas: { postMessage } } } })
    hostLog('error', 'boom')
    expect(JSON.parse(postMessage.mock.calls[0]![0])).toEqual({ type: 'log', level: 'error', msg: 'boom' })
  })
})
