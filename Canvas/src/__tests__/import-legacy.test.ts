import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as Y from 'yjs'
import { createApi } from '../api'
import { fromBase64, toBase64 } from '../canvas/base64'
import { CanvasStore, readShape } from '../canvas/doc'
import { containsBox } from '../canvas/geometry'
import {
  containIn,
  decodeLegacyDoc,
  legacyColor,
  parseLegacyPayload,
  pictureSrc,
  planLegacyImport,
  readLegacyShapes,
  sniffImageSize,
  splitLengthPrefixed,
} from '../canvas/legacy'
import { Controller, IMPORTED_KEY } from '../controller'
import type { PageMessage } from '../host-bridge'
import { EASEL_BOARD, PICTURE_4X3 } from './fixtures/easel-board'

let messages: PageMessage[]
let c: Controller

const init = (extra: Record<string, unknown> = {}) =>
  c.init({ docId: 'd1', name: 'Untitled canvas', kind: 'personal', me: { id: 'u1', name: 'Ada', color: '#f00' }, state: null, online: false, readOnly: false, ...extra })

const payload = (extra: Record<string, unknown> = {}) => ({ doc: EASEL_BOARD.doc, files: { 'pic-1': PICTURE_4X3 }, title: 'Launch plan', ...extra })

beforeEach(() => {
  messages = []
  vi.stubGlobal('window', { __copperHost: { messages: [], onMessage: (m: PageMessage) => messages.push(m) } })
  vi.spyOn(console, 'debug').mockImplementation(() => {})
  c = new Controller()
})

afterEach(() => {
  c.session?.destroy()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

const ids = EASEL_BOARD.ids

describe('reading an Easels document', () => {
  it('reads the frozen board written by easel-web’s own doc code', () => {
    const doc = decodeLegacyDoc(EASEL_BOARD.doc)
    const read = readLegacyShapes(doc)
    expect(read.title).toBe('Launch plan')
    expect(read.skipped).toBe(1) // the `embed`
    const byId = new Map(read.shapes.map(s => [s.id, s]))
    expect(read.shapes).toHaveLength(9)
    expect(byId.get(ids.note)).toMatchObject({ type: 'sticky', x: 0, y: 0, w: 200, h: 140, color: 'yellow', text: '**Ship** the beta\n- [ ] docs\n- [x] tests' })
    expect(byId.get(ids.plain)).toMatchObject({ text: 'Plain string body', color: 'pink' })
    expect(byId.get(ids.hex)?.color).toBe('#ff8800')
    expect(byId.get(ids.mockups)).toMatchObject({ type: 'frame', text: 'Mockups', fileId: 'pic-1' })
    expect(byId.get(ids.empty)?.fileId).toBeUndefined()
    expect(byId.get(ids.then)).toMatchObject({ type: 'arrow', from: ids.note, to: ids.plain, text: 'then' })
  })

  it('reads an update stream: a list, 4-byte length records, or varuint records', () => {
    const src = new Y.Doc()
    const updates: Uint8Array[] = []
    src.on('update', (u: Uint8Array) => updates.push(u))
    const shapes = src.getMap<Y.Map<unknown>>('shapes')
    const a = new Y.Map<unknown>()
    src.transact(() => {
      a.set('type', 'sticky')
      a.set('text', new Y.Text('first'))
      shapes.set('a', a)
    })
    src.transact(() => {
      const b = new Y.Map<unknown>()
      b.set('type', 'frame')
      b.set('text', 'Second')
      shapes.set('b', b)
    })
    ;(a.get('text') as Y.Text).insert(5, ' edit')
    expect(updates).toHaveLength(3)
    const check = (doc: Y.Doc) => {
      const read = readLegacyShapes(doc)
      expect(read.shapes.map(s => [s.id, s.type, s.text])).toEqual([
        ['a', 'sticky', 'first edit'],
        ['b', 'frame', 'Second'],
      ])
    }
    check(decodeLegacyDoc(updates.map(toBase64)))
    const framed = (lens: (n: number) => number[]) => {
      const parts: number[] = []
      for (const u of updates) parts.push(...lens(u.length), ...u)
      return toBase64(new Uint8Array(parts))
    }
    check(decodeLegacyDoc(framed(n => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255])))
    const varuint = (n: number) => {
      const out: number[] = []
      while (n > 127) {
        out.push((n & 127) | 128)
        n >>>= 7
      }
      out.push(n)
      return out
    }
    check(decodeLegacyDoc(framed(varuint)))
    expect(splitLengthPrefixed(new Uint8Array([0, 0, 0, 9, 1]))).toBeNull()
    expect(() => decodeLegacyDoc(toBase64(new Uint8Array([255, 1, 2, 3, 4, 5])))).toThrow()
  })

  it('parses the payload as JSON or an object', () => {
    expect(parseLegacyPayload(JSON.stringify(payload()))).toMatchObject({ title: 'Launch plan', files: { 'pic-1': PICTURE_4X3 } })
    expect(() => parseLegacyPayload('{nope')).toThrow(/JSON/)
    expect(() => parseLegacyPayload({ files: {} })).toThrow(/doc/)
    expect(parseLegacyPayload({ doc: 'AAA=', files: { a: 1, b: 'data:image/png;base64,AA' } }).files).toEqual({ b: 'data:image/png;base64,AA' })
  })
})

describe('legacy colours, pictures and placement', () => {
  it('maps colours to the palette or passes #hex through', () => {
    expect(legacyColor('pink', 'sticky')).toBe('pink')
    expect(legacyColor('Grey', 'frame')).toBe('gray')
    expect(legacyColor('#FF8800', 'sticky')).toBe('#ff8800')
    expect(legacyColor('rgb(250, 210, 60)', 'sticky')).toBe('yellow')
    expect(legacyColor('rgba(120,180,250,1)', 'sticky')).toBe('blue')
    expect(legacyColor('red', 'sticky')).toBe('pink')
    expect(legacyColor('chartreuse-ish', 'sticky')).toBeUndefined()
    expect(legacyColor(42, 'sticky')).toBeUndefined()
    // Easels drew every arrow in one colour.
    expect(legacyColor('pink', 'arrow')).toBeUndefined()
  })

  it('reads natural sizes from image headers', () => {
    expect(sniffImageSize(PICTURE_4X3)).toEqual({ w: 4, h: 3 })
    const b64 = (bytes: number[]) => `base64,${toBase64(new Uint8Array([...bytes, ...new Array(40).fill(0)]))}`
    expect(sniffImageSize(`data:image/gif;${b64([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x20, 0x01, 0x10, 0x00])}`)).toEqual({ w: 288, h: 16 })
    // JPEG: SOI, an APP0 segment, then SOF0 with 600 × 800.
    const jpeg = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x03, 0x20, 0x02, 0x58, 0x03]
    expect(sniffImageSize(`data:image/jpeg;${b64(jpeg)}`)).toEqual({ w: 600, h: 800 })
    // WebP VP8X: canvas 1024 × 512 stored minus one, 24-bit little-endian.
    const webp = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x58, 10, 0, 0, 0, 0, 0, 0, 0, 0xff, 0x03, 0x00, 0xff, 0x01, 0x00]
    expect(sniffImageSize(`data:image/webp;${b64(webp)}`)).toEqual({ w: 1024, h: 512 })
    expect(sniffImageSize(`data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"></svg>')}`)).toEqual({ w: 120, h: 80 })
    expect(sniffImageSize(`data:image/svg+xml;base64,${btoa('<svg viewBox="0 0 300 150"></svg>')}`)).toEqual({ w: 300, h: 150 })
    expect(sniffImageSize('data:image/png;base64,AAAA')).toBeNull()
  })

  it('accepts data URLs, https and bare base64 pictures', () => {
    expect(pictureSrc(PICTURE_4X3)).toBe(PICTURE_4X3)
    expect(pictureSrc('https://example.com/a.png')).toBe('https://example.com/a.png')
    expect(pictureSrc(PICTURE_4X3.slice(PICTURE_4X3.indexOf(',') + 1))).toBe(PICTURE_4X3)
    expect(pictureSrc('copper-easel://easel/files/x/y')).toBeNull()
    expect(pictureSrc('not a picture at all')).toBeNull()
  })

  it('fits a picture inside its frame like object-fit: contain', () => {
    const frame = { x: -40, y: 240, w: 480, h: 320 }
    const at = containIn(frame, { w: 4, h: 3 })
    expect(at).toEqual({ x: -2, y: 248, w: 405, h: 304 })
    expect(containsBox(frame, at)).toBe(true)
    // Unknown size: the frame's own, less the inset.
    expect(containIn(frame, { w: 0, h: 0 })).toEqual({ x: -32, y: 248, w: 464, h: 304 })
  })

  it('moves an import that would land on existing shapes beside them', () => {
    const shapes = readLegacyShapes(decodeLegacyDoc(EASEL_BOARD.doc)).shapes
    const plan = planLegacyImport(shapes, {
      taken: () => false,
      existing: [{ x: -100, y: -100, w: 400, h: 400 }],
      zBase: 7,
      pictures: new Map(),
      newId: () => 'fresh',
    })
    expect(plan.offset.x).toBeGreaterThan(0)
    const boxes = plan.inputs.filter(i => i.type !== 'arrow')
    for (const b of boxes) expect(b.x!).toBeGreaterThanOrEqual(300)
    expect(plan.inputs.map(i => i.z)).toEqual(plan.inputs.map((_, i) => 7 + i))
    // Frames first, then notes, then arrows: frames stay under what sits in them.
    expect(plan.inputs.map(i => i.type)).toEqual(['frame', 'frame', 'frame', 'sticky', 'sticky', 'sticky', 'arrow', 'arrow'])
    expect(plan.missingPictures.sort()).toEqual(['gone-file', 'pic-1'])
  })
})

describe('copperCanvas.importLegacy', () => {
  it('brings the whole board over in one transaction the host stores', async () => {
    init()
    const store = c.session!.store
    const before = messages.filter(m => m.type === 'update').length
    const out = await c.importLegacy(payload())
    // 3 notes + 3 frames + 1 picture + 2 arrows; skipped: the embed, the dangling arrow, the lost picture.
    expect(out).toMatchObject({ imported: 9, skipped: 3 })
    expect(out.error).toMatch(/1 picture could not be imported \(gone-file\)/)

    const note = store.get(ids.note)!
    expect(note).toMatchObject({ type: 'sticky', x: 0, y: 0, w: 200, h: 140, color: 'yellow', fontSize: 14 })
    expect(note.text).toBe('**Ship** the beta\n- [ ] docs\n- [x] tests')
    expect(note.by).toBeUndefined()
    expect(store.shapes.get(ids.note)!.get('text')).toBeInstanceOf(Y.Text)
    expect(store.shapes.get(ids.plain)!.get('text')).toBeInstanceOf(Y.Text)
    expect(store.get(ids.plain)?.text).toBe('Plain string body')
    expect(store.get(ids.hex)?.color).toBe('#ff8800')

    const mockups = store.get(ids.mockups)!
    expect(mockups).toMatchObject({ type: 'frame', title: 'Mockups', color: 'gray', x: -40, y: 240, w: 480, h: 320 })
    expect(mockups.image).toBeUndefined()
    expect(store.get(ids.empty)).toMatchObject({ type: 'frame', title: 'Empty frame', color: 'blue' })
    expect(store.get(ids.lost)).toMatchObject({ type: 'frame', title: 'Lost picture', color: 'green' })
    const pictures = store.liveAll().filter(s => s.type === 'image')
    expect(pictures).toHaveLength(1)
    expect(pictures[0]).toMatchObject({ src: PICTURE_4X3, naturalW: 4, naturalH: 3, x: -2, y: 248, w: 405, h: 304 })
    expect(containsBox(mockups, pictures[0]!)).toBe(true)
    expect(pictures[0]!.z).toBeGreaterThan(mockups.z)
    expect(note.z).toBeGreaterThan(mockups.z)

    expect(store.get(ids.then)).toMatchObject({ type: 'arrow', from: { ref: ids.note }, to: { ref: ids.plain }, label: 'then', color: 'gray' })
    expect(store.get(ids.into)).toMatchObject({ from: { ref: ids.plain }, to: { ref: ids.mockups } })
    expect(store.get(ids.dangling)).toBeUndefined()
    expect(store.get(ids.embed)).toBeUndefined()

    // Named from the title; one update to the host; not on the undo stack.
    expect(store.meta.get('name')).toBe('Launch plan')
    const sent = messages.filter((m): m is Extract<PageMessage, { type: 'update' }> => m.type === 'update')
    expect(sent.length).toBe(before + 1)
    expect(store.undo.canUndo()).toBe(false)
    const replay = new Y.Doc()
    for (const m of sent) Y.applyUpdate(replay, fromBase64(m.b64))
    const copy = new CanvasStore(replay)
    expect(copy.liveAll()).toHaveLength(9)
    expect(readShape(ids.then, replay.getMap<Y.Map<unknown>>('shapes').get(ids.then))?.label).toBe('then')
  })

  it('does it again only once, and keeps a name someone chose', async () => {
    init({ name: 'Roadmap' })
    const store = c.session!.store
    expect(await c.importLegacy(JSON.stringify(payload()))).toMatchObject({ imported: 9 })
    expect(store.meta.get('name')).toBe('Roadmap')
    expect(store.meta.get(IMPORTED_KEY)).toHaveLength(1)
    expect(await c.importLegacy(payload())).toEqual({ imported: 0, skipped: 0, already: true })
    expect(store.liveAll()).toHaveLength(9)
  })

  it('gives colliding ids fresh ones and rewires the arrows', async () => {
    init()
    const store = c.session!.store
    store.create({ type: 'sticky', id: ids.note, text: 'already here', x: 0, y: 0 })
    const out = await c.importLegacy(payload())
    expect(out.imported).toBe(9)
    expect(store.get(ids.note)?.text).toBe('already here')
    const imported = store.liveAll().find(s => s.type === 'sticky' && s.text.startsWith('**Ship**'))!
    expect(imported.id).not.toBe(ids.note)
    const then = store.get(ids.then)!
    expect(then.from).toEqual({ ref: imported.id })
    // It landed beside what was there rather than on it.
    expect(imported.x).toBeGreaterThan(200)
  })

  it('finds pictures keyed with or without their extension', async () => {
    init()
    const doc = new Y.Doc()
    const frame = new Y.Map<unknown>()
    doc.transact(() => {
      frame.set('type', 'frame')
      frame.set('text', new Y.Text('Shot'))
      frame.set('image', 'file:3f2a.png')
      doc.getMap<Y.Map<unknown>>('shapes').set('f', frame)
    })
    const out = await c.importLegacy({ doc: toBase64(Y.encodeStateAsUpdate(doc)), files: { '3f2a': PICTURE_4X3 } })
    expect(out).toEqual({ imported: 2, skipped: 0 })
    expect(c.session!.store.liveAll().find(s => s.type === 'image')?.naturalW).toBe(4)
  })

    it('reports what it cannot do, and never throws', async () => {
    expect(await c.importLegacy(payload())).toMatchObject({ imported: 0, error: expect.stringMatching(/init/) })
    init({ readOnly: true })
    expect(await c.importLegacy(payload())).toMatchObject({ imported: 0, error: expect.stringMatching(/read-only/) })
    init()
    expect(await c.importLegacy('{oops')).toMatchObject({ imported: 0, error: expect.stringMatching(/JSON/) })
    expect(await c.importLegacy({ doc: toBase64(new Uint8Array([255, 9, 9, 9])), files: {} })).toMatchObject({
      imported: 0,
      error: expect.stringMatching(/not a Yjs update/),
    })
    const api = createApi(c)
    await expect(api.importLegacy(payload({ files: {} }))).resolves.toMatchObject({
      imported: 8,
      skipped: 4,
      error: expect.stringMatching(/2 pictures/),
    })
  })
})
