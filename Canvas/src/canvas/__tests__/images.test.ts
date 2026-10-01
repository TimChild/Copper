import { describe, expect, it } from 'vitest'
import { MAX_DATA_URL, frameSizeFor, imageFile, imageSizeFor, isUrlText, looksLikeImageUrl, urlFrom } from '../images'

/** Just enough of a DataTransfer for the readers. */
function transfer(data: Record<string, string>, files: { type: string }[] = []): DataTransfer {
  return {
    files: files as unknown as FileList,
    items: [] as unknown as DataTransferItemList,
    getData: (type: string) => data[type] ?? '',
  } as unknown as DataTransfer
}

describe('image sizes', () => {
  it('sizes a frame to the image aspect, clamped in width', () => {
    expect(frameSizeFor(1280, 720)).toEqual({ w: 640, h: 360 })
    expect(frameSizeFor(100, 100)).toEqual({ w: 160, h: 160 })
    expect(frameSizeFor(0, 0)).toEqual({ w: 160, h: 120 })
  })

  it('sizes an image shape at natural size, at most 480 wide', () => {
    expect(imageSizeFor(200, 100)).toEqual({ w: 200, h: 100 })
    expect(imageSizeFor(1920, 1080)).toEqual({ w: 480, h: 270 })
  })

  it('caps data URLs at 2 MB', () => {
    expect(MAX_DATA_URL).toBe(2 * 1024 * 1024)
  })
})

describe('reading drops and pastes', () => {
  it('takes the first image file', () => {
    const png = { type: 'image/png' }
    expect(imageFile(transfer({}, [{ type: 'text/plain' }, png]))).toBe(png)
    expect(imageFile(transfer({}, [{ type: 'text/plain' }]))).toBeNull()
    expect(imageFile(null)).toBeNull()
  })

  it('reads a dragged URL, skipping uri-list comments', () => {
    expect(urlFrom(transfer({ 'text/uri-list': '# comment\nhttps://a.dev/x\n' }))).toEqual({ url: 'https://a.dev/x' })
    expect(urlFrom(transfer({ 'text/plain': ' https://b.dev ' }))).toEqual({ url: 'https://b.dev' })
    expect(urlFrom(transfer({ 'text/plain': 'not a url' }))).toBeNull()
  })

  it('tells URLs and image URLs apart', () => {
    expect(isUrlText('https://x.dev/a b')).toBe(false)
    expect(isUrlText('http://x.dev')).toBe(true)
    expect(looksLikeImageUrl('https://x.dev/a.png?w=2')).toBe(true)
    expect(looksLikeImageUrl('http://x.dev/a.png')).toBe(false)
    expect(looksLikeImageUrl('https://x.dev/page')).toBe(false)
  })
})
