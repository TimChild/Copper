/**
 * The fake host for the Vite dev server and Playwright: no bridge, so the
 * easel id comes from `?id=` (or a fixed default), `save` goes to
 * localStorage keyed by id, and pictures become object URLs (with a data-URL
 * copy in localStorage so a reload still shows them).
 */
import type { EaselConfig, Host, LogLevel, UploadedFile } from './types'
import { MAX_FILE_BYTES, extensionFor } from './types'
import { blobToDataUrl } from './base64'

export const DEFAULT_EASEL_ID = '00000000-0000-4000-8000-000000000001'
export const STANDALONE_VIEWER = {
  id: 'standalone-viewer',
  name: 'You',
  color: '#ff5a36',
}

/** Where a standalone easel keeps itself. */
export const storageKey = (easelId: string) => `easel:${easelId}`
const fileKey = (easelId: string, fileId: string) =>
  `easel:${easelId}:file:${fileId}`

interface StoredEasel {
  title: string
  createdAt: number
  state: string | null
}

export interface StandaloneOptions {
  /** Defaults to `?id=` in the location, else `DEFAULT_EASEL_ID`. */
  easelId?: string
  storage?: Storage
  /** For tests: a fake URL.createObjectURL. */
  objectUrl?: (blob: Blob) => string
  /** The page's search string, for `?id=`. */
  search?: string
}

/** `?id=<uuid>` from a search string, or null. */
export function easelIdFromSearch(search: string): string | null {
  const id = new URLSearchParams(search).get('id')
  return id && /^[a-z0-9-]{1,80}$/i.test(id) ? id.toLowerCase() : null
}

export function createStandaloneHost(options: StandaloneOptions = {}): Host {
  const storage =
    options.storage ??
    (typeof localStorage !== 'undefined' ? localStorage : undefined)
  const search =
    options.search ??
    (typeof location !== 'undefined' ? location.search : '')
  const easelId =
    options.easelId ?? easelIdFromSearch(search) ?? DEFAULT_EASEL_ID
  const objectUrl =
    options.objectUrl ??
    ((blob: Blob) => URL.createObjectURL(blob))
  const flushers = new Set<() => void>()
  /** Object URLs minted this session, by file id. */
  const urls = new Map<string, string>()

  const read = (): StoredEasel | null => {
    try {
      const raw = storage?.getItem(storageKey(easelId))
      return raw ? (JSON.parse(raw) as StoredEasel) : null
    } catch {
      return null
    }
  }
  const write = (value: StoredEasel) => {
    try {
      storage?.setItem(storageKey(easelId), JSON.stringify(value))
    } catch {
      // quota or private mode: the board lasts for this tab only
    }
  }

  return {
    mode: 'standalone',
    async ready(): Promise<EaselConfig> {
      const stored = read()
      const createdAt = stored?.createdAt ?? Date.now() / 1000
      if (!stored) write({ title: 'Untitled Easel', createdAt, state: null })
      return {
        easel: {
          id: easelId,
          title: stored?.title ?? 'Untitled Easel',
          createdAt,
        },
        viewer: STANDALONE_VIEWER,
        state: stored?.state ?? null,
        mode: 'local',
      }
    },
    save(state, title) {
      const stored = read()
      write({
        title,
        createdAt: stored?.createdAt ?? Date.now() / 1000,
        state,
      })
    },
    async uploadFile(file): Promise<UploadedFile> {
      if (file.size > MAX_FILE_BYTES)
        throw new Error('That picture is over 15 MB.')
      const fileId = `${crypto.randomUUID()}.${extensionFor(file.type)}`
      const url = objectUrl(file)
      urls.set(fileId, url)
      try {
        storage?.setItem(fileKey(easelId, fileId), await blobToDataUrl(file))
      } catch {
        // too big for localStorage: the picture lasts for this session
      }
      return { fileId, url }
    },
    open(url, _background) {
      if (!/^https?:/i.test(url)) return
      window.open(url, '_blank', 'noopener,noreferrer')
    },
    log(level: LogLevel, message: string) {
      const fn = level === 'error' ? console.error : level === 'warn' ? console.warn : console.info
      fn(`easel: ${message}`)
    },
    onFlush(fn) {
      flushers.add(fn)
      return () => flushers.delete(fn)
    },
    // No native side to rename from; the title chip is the only way here.
    onRename() {
      return () => {}
    },
    fileUrl(id, fileId) {
      return urls.get(fileId) ?? storage?.getItem(fileKey(id, fileId)) ?? ''
    },
  }
}
