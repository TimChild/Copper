import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { fromBase64, toBase64 } from '../canvas/base64'
import { BridgeSocket, setBridgePoster } from '../bridge-socket'
import type { PageMessage } from '../host-bridge'

let sent: PageMessage[]

beforeEach(() => {
  sent = []
  setBridgePoster(m => sent.push(m))
  BridgeSocket.current = null
})
afterEach(() => setBridgePoster(null))

describe('BridgeSocket', () => {
  it('looks like a WebSocket', () => {
    const ws = new BridgeSocket('ws://bridge/room')
    expect(BridgeSocket.OPEN).toBe(1)
    expect(ws.OPEN).toBe(1)
    expect(ws.CONNECTING).toBe(0)
    expect(ws.CLOSED).toBe(3)
    expect(ws.readyState).toBe(BridgeSocket.CONNECTING)
    expect(ws.binaryType).toBe('arraybuffer')
    expect(ws.url).toBe('ws://bridge/room')
  })

  it('asks the host to connect, and opens when the host says so', () => {
    const ws = new BridgeSocket('ws://bridge/room')
    expect(sent).toEqual([{ type: 'wsOpen', url: 'ws://bridge/room' }])
    let opened = 0
    ws.onopen = () => opened++
    expect(BridgeSocket.setState('open')).toBe(true)
    expect(ws.readyState).toBe(BridgeSocket.OPEN)
    expect(opened).toBe(1)
    BridgeSocket.setState('open')
    expect(opened).toBe(1)
  })

  it('sends frames as base64 and refuses to send while connecting', () => {
    const ws = new BridgeSocket('ws://bridge/room')
    expect(() => ws.send(new Uint8Array([1]))).toThrow(/connecting/)
    BridgeSocket.setState('open')
    ws.send(new Uint8Array([0, 1, 2, 255]))
    ws.send(new Uint8Array([9, 8, 7]).buffer)
    expect(sent.slice(1)).toEqual([
      { type: 'ws', b64: toBase64(new Uint8Array([0, 1, 2, 255])) },
      { type: 'ws', b64: toBase64(new Uint8Array([9, 8, 7])) },
    ])
    expect([...fromBase64((sent[1] as { b64: string }).b64)]).toEqual([0, 1, 2, 255])
  })

  it('delivers host frames as ArrayBuffers', () => {
    const ws = new BridgeSocket('ws://bridge/room')
    BridgeSocket.setState('open')
    const got: ArrayBuffer[] = []
    ws.onmessage = e => got.push(e.data as ArrayBuffer)
    expect(BridgeSocket.deliver(toBase64(new Uint8Array([5, 6, 7])))).toBe(true)
    expect(got[0]).toBeInstanceOf(ArrayBuffer)
    expect([...new Uint8Array(got[0]!)]).toEqual([5, 6, 7])
  })

  it('treats a frame before "open" as an implicit open', () => {
    const ws = new BridgeSocket('ws://bridge/room')
    let opened = false
    ws.onopen = () => (opened = true)
    const got: unknown[] = []
    ws.onmessage = e => got.push(e.data)
    BridgeSocket.deliver(toBase64(new Uint8Array([1])))
    expect(opened).toBe(true)
    expect(got).toHaveLength(1)
  })

  it('closes when the host closes, and drops later frames', () => {
    const ws = new BridgeSocket('ws://bridge/room')
    BridgeSocket.setState('open')
    const events: string[] = []
    ws.onclose = e => events.push(`close:${e.code}`)
    ws.onmessage = () => events.push('message')
    BridgeSocket.setState('closed')
    expect(ws.readyState).toBe(BridgeSocket.CLOSED)
    expect(BridgeSocket.current).toBeNull()
    expect(BridgeSocket.deliver(toBase64(new Uint8Array([1])))).toBe(false)
    expect(events).toEqual(['close:1006'])
  })

  it('tells the host when the page closes it', () => {
    const ws = new BridgeSocket('ws://bridge/room')
    BridgeSocket.setState('open')
    let closed = false
    ws.onclose = () => (closed = true)
    ws.close()
    expect(sent.at(-1)).toEqual({ type: 'wsClose' })
    expect(closed).toBe(true)
    expect(ws.readyState).toBe(BridgeSocket.CLOSED)
    ws.close()
    expect(sent.filter(m => m.type === 'wsClose')).toHaveLength(1)
  })

  it('routes frames to the newest socket only', () => {
    const old = new BridgeSocket('ws://bridge/room')
    const got: string[] = []
    old.onmessage = () => got.push('old')
    const next = new BridgeSocket('ws://bridge/room')
    next.onmessage = () => got.push('new')
    expect(old.readyState).toBe(BridgeSocket.CLOSED)
    BridgeSocket.setState('open')
    BridgeSocket.deliver(toBase64(new Uint8Array([1])))
    expect(got).toEqual(['new'])
  })

  it('supports addEventListener too', () => {
    const ws = new BridgeSocket('ws://bridge/room')
    let n = 0
    const fn = () => n++
    ws.addEventListener('open', fn)
    BridgeSocket.setState('open')
    ws.removeEventListener('open', fn)
    expect(n).toBe(1)
  })
})
