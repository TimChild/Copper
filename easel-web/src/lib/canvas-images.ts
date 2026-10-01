/**
 * Pictures pasted, dropped or picked onto the easel. A frame holds one: the
 * shape stores only a reference (`image: file:<fileId>`), never the bytes,
 * because the whole board doc is loaded by every client.
 *
 * Lifted from the wiki app's apps/web/src/modules/wiki/lib/canvas-images.ts;
 * the upload goes through the host's `file` message instead of a REST call,
 * and the render URL comes from the host (`copper-easel://easel/files/…` in
 * Copper, an object URL standalone).
 */
import type { Host } from '../host/types'
import { ACCEPTED_IMAGE_TYPES, MAX_FILE_BYTES } from '../host/types'

/** Longest edge kept; bigger pictures are downscaled before upload. */
const MAX_EDGE = 2400
/** Re-encode above this even if the type is accepted: it is a board, not a gallery. */
const MAX_AS_IS_BYTES = 8 * 1024 * 1024

/** Height of a frame's title bar; the image fills the body below it. */
export const FRAME_TITLE_H = 32
/** Widest a new frame gets when it is sized to fit a pasted image. */
const FRAME_MAX_W = 640
const FRAME_MIN_W = 160

/** The first image file in a paste or drop, if any. */
export function imageFile(data: DataTransfer | null): File | null {
  if (!data) return null
  for (const file of Array.from(data.files))
    if (file.type.startsWith('image/')) return file
  for (const item of Array.from(data.items ?? [])) {
    if (item.kind !== 'file' || !item.type.startsWith('image/')) continue
    const file = item.getAsFile()
    if (file) return file
  }
  return null
}

/** The file id in a `file:<fileId>` ref, or null for anything else. */
export const fileIdOf = (image: string) =>
  image.startsWith('file:') ? image.slice(5) : null

/**
 * `<img src>` for a shape's `image`. `file:` refs go through the host;
 * `data:`/`http(s):` (wiki-app-style refs) pass through untouched.
 */
export function imageSrc(image: string, host: Host, easelId: string): string {
  const fileId = fileIdOf(image)
  if (fileId) return host.fileUrl(easelId, fileId)
  return /^(data|https?|blob):/.test(image) ? image : ''
}

/** A new frame's size for an image: its aspect, at most `FRAME_MAX_W` wide. */
export function frameSizeFor(width: number, height: number) {
  const w = Math.round(Math.min(Math.max(width, FRAME_MIN_W), FRAME_MAX_W))
  const body = height > 0 && width > 0 ? (w * height) / width : w * 0.75
  return { w, h: Math.round(body) + FRAME_TITLE_H }
}

/** Downscale through a canvas; Safari may hand back PNG instead of WebP. */
async function reencode(bitmap: ImageBitmap, maxEdge: number): Promise<File> {
  const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(bitmap.width * scale))
  canvas.height = Math.max(1, Math.round(bitmap.height * scale))
  canvas.getContext('2d')!.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  const blob = await new Promise<Blob>((resolve, reject) =>
    canvas.toBlob(
      b => (b ? resolve(b) : reject(new Error('The image did not encode.'))),
      'image/webp',
      0.85
    )
  )
  const ext = blob.type === 'image/png' ? 'png' : 'webp'
  return new File([blob], `image.${ext}`, { type: blob.type })
}

/**
 * Store a picture for the board and return its reference plus its natural
 * size. Small pictures in an accepted type go up untouched (a GIF keeps its
 * animation); big or exotic ones (svg, bmp, heic) are downscaled to WebP.
 */
export async function saveEaselImage(
  file: File,
  host: Host
): Promise<{ image: string; width: number; height: number }> {
  const bitmap = await createImageBitmap(file).catch(() => {
    throw new Error('That file is not an image the browser can read.')
  })
  const { width, height } = bitmap
  try {
    const asIs =
      (ACCEPTED_IMAGE_TYPES as readonly string[]).includes(file.type) &&
      file.size <= Math.min(MAX_AS_IS_BYTES, MAX_FILE_BYTES) &&
      Math.max(width, height) <= MAX_EDGE
    const upload = asIs ? file : await reencode(bitmap, MAX_EDGE)
    const { fileId } = await host.uploadFile(upload)
    return { image: `file:${fileId}`, width, height }
  } finally {
    bitmap.close()
  }
}
