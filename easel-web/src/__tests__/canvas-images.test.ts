// Ported from the wiki app's __tests__/canvas-images.test.ts; `imageSrc` now
// goes through the host and `file:` refs.
import { describe, expect, it } from 'vitest'
import { createEaselDoc } from '../doc/easel-doc'
import {
  FRAME_TITLE_H,
  fileIdOf,
  frameSizeFor,
  imageFile,
  imageSrc,
} from '../lib/canvas-images'
import type { Host } from '../host/types'

const transfer = (files: File[], items: DataTransferItem[] = []) =>
  ({ files, items }) as unknown as DataTransfer

const host = {
  fileUrl: (easelId: string, fileId: string) =>
    `copper-easel://easel/files/${easelId}/${fileId}`,
} as unknown as Host

describe('canvas images', () => {
  it('picks the first image out of a paste, skipping other files', () => {
    const text = new File(['hi'], 'notes.txt', { type: 'text/plain' })
    const png = new File(['png'], 'shot.png', { type: 'image/png' })
    expect(imageFile(transfer([text, png]))).toBe(png)
    expect(imageFile(transfer([text]))).toBeNull()
    expect(imageFile(null)).toBeNull()
  })

  it('falls back to clipboard items when files is empty', () => {
    const jpg = new File(['jpg'], 'photo.jpg', { type: 'image/jpeg' })
    const item = {
      kind: 'file',
      type: 'image/jpeg',
      getAsFile: () => jpg,
    } as unknown as DataTransferItem
    expect(imageFile(transfer([], [item]))).toBe(jpg)
  })

  it('sizes a new frame to the image aspect, capped in width', () => {
    expect(frameSizeFor(1600, 900)).toEqual({ w: 640, h: 360 + FRAME_TITLE_H })
    expect(frameSizeFor(300, 600)).toEqual({ w: 300, h: 600 + FRAME_TITLE_H })
    // Tiny images still get a usable frame.
    expect(frameSizeFor(40, 40).w).toBe(160)
  })

  it('renders file refs through the host and passes data URLs through', () => {
    expect(imageSrc('file:abc.png', host, 'e1')).toBe(
      'copper-easel://easel/files/e1/abc.png'
    )
    expect(imageSrc('data:image/webp;base64,AAAA', host, 'e1')).toBe(
      'data:image/webp;base64,AAAA'
    )
    expect(imageSrc('javascript:alert(1)', host, 'e1')).toBe('')
    expect(fileIdOf('file:abc.png')).toBe('abc.png')
    expect(fileIdOf('img-1')).toBeNull()
  })

  it('keeps a frame image on the doc; removing it is undoable', () => {
    const easel = createEaselDoc()
    const id = easel.createShape({ type: 'frame', image: 'file:img-1.png' })
    expect(easel.getShapesSnapshot().get(id)?.image).toBe('file:img-1.png')
    easel.undo.stopCapturing()

    easel.updateShape(id, { image: '' })
    expect(easel.getShapesSnapshot().get(id)?.image).toBeUndefined()

    easel.undo.undo()
    expect(easel.getShapesSnapshot().get(id)?.image).toBe('file:img-1.png')
  })
})
