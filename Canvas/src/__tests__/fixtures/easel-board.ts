/**
 * An Easels board for the `importLegacy` tests. `buildEaselBoard` drove
 * easel-web's own document code (`createEaselDoc` from
 * `easel-web/src/doc/easel-doc.ts`, before that tree was removed — see
 * commit c657455), and `EASEL_BOARD` is its output, frozen:
 * `Y.encodeStateAsUpdate(doc)` as base64, exactly what Easels kept in
 * `doc.yjs`. To rebuild it, check that file out of history and call
 * `buildEaselBoard(createEaselDoc, Y)` with the same copy of yjs it imports.
 */
import type * as YNS from 'yjs'

/** The part of easel-web's `EaselDoc` the builder uses. */
export interface EaselDocLike {
  doc: YNS.Doc
  shapes: YNS.Map<YNS.Map<unknown>>
  meta: YNS.Map<unknown>
  createShape(input: Record<string, unknown> & { type: string }): string
  updateShape(id: string, patch: Record<string, unknown>): void
  setTitle(title: string): void
  ensureMeta(info: { title?: string; createdAt?: number }): void
}

/** A 4 × 3 PNG (red), the picture in the "Mockups" frame. */
export const PICTURE_4X3 =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGO4o6EBRww4OQAa3g4RLYR9sQAAAABJRU5ErkJggg=='

export interface BuiltBoard {
  bytes: Uint8Array
  ids: Record<'note' | 'plain' | 'hex' | 'mockups' | 'empty' | 'lost' | 'then' | 'into' | 'dangling' | 'embed', string>
}

/** Every kind of thing an Easels board held, including the odd ones. */
export function buildEaselBoard(create: () => EaselDocLike, Y: typeof YNS): BuiltBoard {
  const e = create()
  e.ensureMeta({ title: 'Launch plan', createdAt: 1_790_000_000 })
  const note = e.createShape({ type: 'sticky', x: 0, y: 0, w: 200, h: 140, color: 'yellow', text: '**Ship** the beta\n- [ ] docs\n- [x] tests', by: 'Ada' })
  const plain = e.createShape({ type: 'sticky', x: 260, y: 0, w: 220, h: 160, color: 'pink', by: 'Ada' })
  // Another writer stored a plain string body, not a Y.Text.
  e.shapes.get(plain)!.set('text', 'Plain string body')
  const hex = e.createShape({ type: 'sticky', x: 520, y: 0, w: 180, h: 120, text: 'Custom colour', by: 'Ada' })
  e.shapes.get(hex)!.set('color', '#ff8800')
  const mockups = e.createShape({ type: 'frame', x: -40, y: 240, w: 480, h: 320, color: 'gray', text: 'Mockups', image: 'file:pic-1', by: 'Ada' })
  const empty = e.createShape({ type: 'frame', x: 520, y: 240, w: 300, h: 200, color: 'blue', text: 'Empty frame', by: 'Ada' })
  const lost = e.createShape({ type: 'frame', x: 880, y: 240, w: 300, h: 200, color: 'green', text: 'Lost picture', image: 'file:gone-file', by: 'Ada' })
  const then = e.createShape({ type: 'arrow', from: `shape:${note}`, to: `shape:${plain}`, text: 'then', by: 'Ada' })
  const into = e.createShape({ type: 'arrow', from: `shape:${plain}`, to: `shape:${mockups}`, by: 'Ada' })
  const dangling = e.createShape({ type: 'arrow', from: `shape:${note}`, to: 'shape:no-such-shape', by: 'Ada' })
  // A shape type a later Easels version may have written.
  const embed = 'embed-1'
  e.doc.transact(() => {
    const m = new Y.Map<unknown>()
    m.set('type', 'embed')
    m.set('x', 0)
    m.set('y', 700)
    e.shapes.set(embed, m)
  })
  const bytes = Y.encodeStateAsUpdate(e.doc)
  return { bytes, ids: { note, plain, hex, mockups, empty, lost, then, into, dangling, embed } }
}

/** `buildEaselBoard`'s output, frozen (see the file header). */
export const EASEL_BOARD: { doc: string; ids: BuiltBoard['ids'] } = {
  "doc": "AVjPv/H1DQAoAQRtZXRhBXRpdGxlAXcLTGF1bmNoIHBsYW4oAQRtZXRhCWNyZWF0ZWRBdAF9gO6Jqw0nAQZzaGFwZXMkMWE3NGRiM2UtZTRiNC00ZTA2LTllOTAtYjFiMjIwMDI2ZDA1ASgAz7/x9Q0CAXcBfYgDKADPv/H1DQIBaAF9jAIoAM+/8fUNAgVjb2xvcgF3BnllbGxvdygAz7/x9Q0CBHR5cGUBdwZzdGlja3koAM+/8fUNAgF4AX0AKADPv/H1DQIBeQF9ACgAz7/x9Q0CAmJ5AXcDQWRhJwDPv/H1DQIEdGV4dAIEAM+/8fUNCigqKlNoaXAqKiB0aGUgYmV0YQotIFsgXSBkb2NzCi0gW3hdIHRlc3RzJwEGc2hhcGVzJDA1YjhkNGM5LTljZjAtNDNhNS1iNzZkLTA0MjNkZWYwOTA0ZgEoAM+/8fUNMwF3AX2cAygAz7/x9Q0zAWgBfaACKADPv/H1DTMFY29sb3IBdwRwaW5rKADPv/H1DTMEdHlwZQF3BnN0aWNreSgAz7/x9Q0zAXgBfYQEKADPv/H1DTMBeQF9ACgAz7/x9Q0zAmJ5AXcDQWRhJwDPv/H1DTMEdGV4dAKoz7/x9Q07AXcRUGxhaW4gc3RyaW5nIGJvZHknAQZzaGFwZXMkZGY5NTJlMzUtNDgzOS00YjcyLTk1NDctZGI2YWMwZGY0NzljASgAz7/x9Q09AXcBfbQCKADPv/H1DT0BaAF9uAEoAM+/8fUNPQVjb2xvcgF3BnllbGxvdygAz7/x9Q09BHR5cGUBdwZzdGlja3koAM+/8fUNPQF4AX2ICCgAz7/x9Q09AXkBfQAoAM+/8fUNPQJieQF3A0FkYScAz7/x9Q09BHRleHQCBADPv/H1DUUNQ3VzdG9tIGNvbG91cqjPv/H1DUABdwcjZmY4ODAwJwEGc2hhcGVzJDIxOTI4NDRlLTQyMjMtNGY3ZC04NmE1LTIwOTRmMzQxZDk2NwEoAM+/8fUNVAF3AX2gBygAz7/x9Q1UAWgBfYAFKADPv/H1DVQFY29sb3IBdwRncmF5KADPv/H1DVQEdHlwZQF3BWZyYW1lKADPv/H1DVQBeAF9aCgAz7/x9Q1UAXkBfbADKADPv/H1DVQFaW1hZ2UBdwpmaWxlOnBpYy0xKADPv/H1DVQCYnkBdwNBZGEnAM+/8fUNVAR0ZXh0AgQAz7/x9Q1dB01vY2t1cHMnAQZzaGFwZXMkODU0ZWUxYzktMGY3Zi00NDcwLWEzOWUtMzQzOThmY2ZkNTBhASgAz7/x9Q1lAXcBfawEKADPv/H1DWUBaAF9iAMoAM+/8fUNZQVjb2xvcgF3BGJsdWUoAM+/8fUNZQR0eXBlAXcFZnJhbWUoAM+/8fUNZQF4AX2ICCgAz7/x9Q1lAXkBfbADKADPv/H1DWUCYnkBdwNBZGEnAM+/8fUNZQR0ZXh0AgQAz7/x9Q1tC0VtcHR5IGZyYW1lJwEGc2hhcGVzJGEyY2UyZWM4LTFlMWUtNGRiYi1iZDM4LTg2ZGIzMDhhNmM2NgEoAM+/8fUNeQF3AX2sBCgAz7/x9Q15AWgBfYgDKADPv/H1DXkFY29sb3IBdwVncmVlbigAz7/x9Q15BHR5cGUBdwVmcmFtZSgAz7/x9Q15AXgBfbANKADPv/H1DXkBeQF9sAMoAM+/8fUNeQVpbWFnZQF3DmZpbGU6Z29uZS1maWxlKADPv/H1DXkCYnkBdwNBZGEnAM+/8fUNeQR0ZXh0AgQAz7/x9Q2CAQxMb3N0IHBpY3R1cmUnAQZzaGFwZXMkMDJiYTA0MmItMWEyYy00NzVlLTk4NzUtNDFlNDQ3MTM1MWExASgAz7/x9Q2PAQR0eXBlAXcFYXJyb3coAM+/8fUNjwEEZnJvbQF3KnNoYXBlOjFhNzRkYjNlLWU0YjQtNGUwNi05ZTkwLWIxYjIyMDAyNmQwNSgAz7/x9Q2PAQJ0bwF3KnNoYXBlOjA1YjhkNGM5LTljZjAtNDNhNS1iNzZkLTA0MjNkZWYwOTA0ZigAz7/x9Q2PAQJieQF3A0FkYScAz7/x9Q2PAQR0ZXh0AgQAz7/x9Q2UAQR0aGVuJwEGc2hhcGVzJGQ0YjBhMjJkLWI2ZDYtNGI2YS1hNTI0LWJiZGYyYWJkNzFjYgEoAM+/8fUNmQEEdHlwZQF3BWFycm93KADPv/H1DZkBBGZyb20BdypzaGFwZTowNWI4ZDRjOS05Y2YwLTQzYTUtYjc2ZC0wNDIzZGVmMDkwNGYoAM+/8fUNmQECdG8BdypzaGFwZToyMTkyODQ0ZS00MjIzLTRmN2QtODZhNS0yMDk0ZjM0MWQ5NjcoAM+/8fUNmQECYnkBdwNBZGEnAM+/8fUNmQEEdGV4dAInAQZzaGFwZXMkM2IyMjI5YmUtOGU0Yi00YzM0LTkxYzktOWM2OTU1YzRlZTY2ASgAz7/x9Q2fAQR0eXBlAXcFYXJyb3coAM+/8fUNnwEEZnJvbQF3KnNoYXBlOjFhNzRkYjNlLWU0YjQtNGUwNi05ZTkwLWIxYjIyMDAyNmQwNSgAz7/x9Q2fAQJ0bwF3E3NoYXBlOm5vLXN1Y2gtc2hhcGUoAM+/8fUNnwECYnkBdwNBZGEnAM+/8fUNnwEEdGV4dAInAQZzaGFwZXMHZW1iZWQtMQEoAM+/8fUNpQEEdHlwZQF3BWVtYmVkKADPv/H1DaUBAXgBfQAoAM+/8fUNpQEBeQF9vAoBz7/x9Q0COwFAAQ==",
  "ids": {
    "note": "1a74db3e-e4b4-4e06-9e90-b1b220026d05",
    "plain": "05b8d4c9-9cf0-43a5-b76d-0423def0904f",
    "hex": "df952e35-4839-4b72-9547-db6ac0df479c",
    "mockups": "2192844e-4223-4f7d-86a5-2094f341d967",
    "empty": "854ee1c9-0f7f-4470-a39e-34398fcfd50a",
    "lost": "a2ce2ec8-1e1e-4dbb-bd38-86db308a6c66",
    "then": "02ba042b-1a2c-475e-9875-41e4471351a1",
    "into": "d4b0a22d-b6d6-4b6a-a524-bbdf2abd71cb",
    "dangling": "3b2229be-8e4b-4c34-91c9-9c6955c4ee66",
    "embed": "embed-1"
  }
}
