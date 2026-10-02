/**
 * Images pasted or dropped on the board. They live in the doc as a data URL
 * (at most 2 MB, re-encoded smaller when needed) or as an https URL; the page
 * never uploads anything.
 */
/** Longest a stored `data:` URL may be, in characters. */
export const MAX_DATA_URL = 2 * 1024 * 1024
/** Longest edge kept when an image has to be re-encoded. */
const MAX_EDGE = 2400
/** Formats kept as they are when they already fit. */
const KEEP_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/svg+xml']

/** Widest a new image (or a frame sized for one) starts out. */
const IMAGE_MAX_W = 480
const FRAME_MAX_W = 640
const FRAME_MIN_W = 160

/** The first image file in a paste or drop, if any. */
export function imageFile(data: DataTransfer | null): File | null {
  if (!data) return null
  for (const file of Array.from(data.files ?? [])) if (file.type.startsWith('image/')) return file
  for (const item of Array.from(data.items ?? [])) {
    if (item.kind !== 'file' || !item.type.startsWith('image/')) continue
    const file = item.getAsFile()
    if (file) return file
  }
  return null
}

/** A frame's size for an image: its aspect, at most `FRAME_MAX_W` wide. */
export function frameSizeFor(width: number, height: number) {
  const w = Math.round(Math.min(Math.max(width, FRAME_MIN_W), FRAME_MAX_W))
  const body = height > 0 && width > 0 ? (w * height) / width : w * 0.75
  return { w, h: Math.max(120, Math.round(body)) }
}

/** An image shape's starting size: natural size, at most `IMAGE_MAX_W` wide. */
export function imageSizeFor(width: number, height: number) {
  const nw = width > 0 ? width : 320
  const nh = height > 0 ? height : 240
  const w = Math.round(Math.min(nw, IMAGE_MAX_W))
  return { w: Math.max(16, w), h: Math.max(16, Math.round((w * nh) / nw)) }
}

const readAsDataUrl = (blob: Blob) =>
  new Promise<string>((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = () => reject(reader.error ?? new Error('The image could not be read.'))
    reader.readAsDataURL(blob)
  })

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = () => reject(new Error('That file is not an image this page can read.'))
    img.src = src
  })
}

/** Draw into a canvas at `scale` and encode; Safari may answer PNG for WebP. */
function encode(img: HTMLImageElement, scale: number, type: string, quality: number): Promise<string> {
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(img.naturalWidth * scale))
  canvas.height = Math.max(1, Math.round(img.naturalHeight * scale))
  const g = canvas.getContext('2d')
  if (!g) return Promise.reject(new Error('The image could not be drawn.'))
  if (type === 'image/jpeg') {
    g.fillStyle = '#fff'
    g.fillRect(0, 0, canvas.width, canvas.height)
  }
  g.drawImage(img, 0, 0, canvas.width, canvas.height)
  return Promise.resolve(canvas.toDataURL(type, quality))
}

export interface StoredImage {
  src: string
  naturalW: number
  naturalH: number
}

/**
 * An image file as a data URL that fits the doc: kept as it is when it is
 * small enough, otherwise downscaled and re-encoded until it is under 2 MB.
 */
export async function imageFromFile(file: Blob): Promise<StoredImage> {
  const original = await readAsDataUrl(file)
  const img = await loadImage(original)
  const naturalW = img.naturalWidth || 320
  const naturalH = img.naturalHeight || 240
  const longest = Math.max(naturalW, naturalH)
  if (KEEP_TYPES.includes(file.type) && original.length <= MAX_DATA_URL && longest <= MAX_EDGE * 2)
    return { src: original, naturalW, naturalH }
  // Photos go to JPEG/WebP; images that may carry alpha try WebP, then PNG.
  const opaque = file.type === 'image/jpeg'
  let scale = Math.min(1, MAX_EDGE / longest)
  for (let attempt = 0; attempt < 8; attempt++) {
    const webp = await encode(img, scale, 'image/webp', 0.86)
    if (webp.startsWith('data:image/webp') && webp.length <= MAX_DATA_URL) return { src: webp, naturalW, naturalH }
    const fallback = await encode(img, scale, opaque ? 'image/jpeg' : 'image/png', 0.85)
    if (fallback.length <= MAX_DATA_URL) return { src: fallback, naturalW, naturalH }
    if (!opaque) {
      const jpeg = await encode(img, scale, 'image/jpeg', 0.82)
      if (jpeg.length <= MAX_DATA_URL) return { src: jpeg, naturalW, naturalH }
    }
    scale *= 0.72
  }
  throw new Error('The image is too large to put on the board.')
}

/** The natural size of an image at `src` (https or data). */
export async function imageFromUrl(src: string): Promise<StoredImage> {
  const img = await loadImage(src)
  return { src, naturalW: img.naturalWidth || 320, naturalH: img.naturalHeight || 240 }
}

/** A `data:` URL as a Blob (for re-encoding one that is too big). */
export function dataUrlBlob(src: string): Blob {
  const comma = src.indexOf(',')
  const head = src.slice(5, comma)
  const type = head.split(';')[0] || 'application/octet-stream'
  const body = src.slice(comma + 1)
  if (/;base64$/i.test(head)) {
    const bin = atob(body.replace(/\s/g, ''))
    const bytes = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
    return new Blob([bytes], { type })
  }
  return new Blob([decodeURIComponent(body)], { type })
}

/**
 * A picture handed over by the host (an Easels file) made ready for the doc:
 * re-encoded when it is over the data-URL limit, with its natural size read
 * from the header, else by decoding it (0 × 0 when neither works in time).
 * Null when it cannot be used.
 */
export async function pictureForImport(
  value: string,
  sniff: (src: string) => { w: number; h: number } | null,
  toSrc: (value: string) => string | null,
  timeoutMs = 4000
): Promise<StoredImage | null> {
  const src = toSrc(value)
  if (!src) return null
  if (src.startsWith('data:') && src.length > MAX_DATA_URL) {
    try {
      return await imageFromFile(dataUrlBlob(src))
    } catch {
      return null
    }
  }
  const sniffed = sniff(src)
  if (sniffed) return { src, naturalW: sniffed.w, naturalH: sniffed.h }
  if (typeof Image === 'undefined') return { src, naturalW: 0, naturalH: 0 }
  const timeout = new Promise<null>(resolve => setTimeout(() => resolve(null), timeoutMs))
  const decoded = await Promise.race([loadImage(src).catch(() => null), timeout])
  return decoded
    ? { src, naturalW: decoded.naturalWidth || 0, naturalH: decoded.naturalHeight || 0 }
    : { src, naturalW: 0, naturalH: 0 }
}

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|avif|svg)(\?.*)?$/i
export const looksLikeImageUrl = (url: string) => /^https:\/\//i.test(url) && IMAGE_EXT.test(url)

/** A URL dragged or pasted in (a tab, a link, a bookmark), if any. */
export function urlFrom(data: DataTransfer | null): { url: string; title?: string } | null {
  if (!data) return null
  const list = data.getData('text/uri-list')
  if (list) {
    const url = list
      .split(/\r?\n/)
      .map(s => s.trim())
      .find(s => s && !s.startsWith('#'))
    if (url && /^(https?|mailto|copper):/i.test(url)) {
      const title = titleFromHtml(data.getData('text/html')) ?? data.getData('text/x-moz-url').split('\n')[1]
      return title ? { url, title: title.trim() } : { url }
    }
  }
  const text = data.getData('text/plain').trim()
  return isUrlText(text) ? { url: text } : null
}

/** A whole string that is one http(s) URL. */
export const isUrlText = (text: string) => /^https?:\/\/[^\s]+$/i.test(text.trim())

function titleFromHtml(html: string): string | undefined {
  if (!html) return undefined
  try {
    const doc = new DOMParser().parseFromString(html, 'text/html')
    const text = doc.querySelector('a')?.textContent?.trim()
    return text || undefined
  } catch {
    return undefined
  }
}
