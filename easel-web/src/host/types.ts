/**
 * The page ⇄ Copper contract (docs/plans/2026-10-01-easels-p1-local.md,
 * "The bridge"). Every message is `{ v: 1, type, …payload }`. The page posts
 * to `webkit.messageHandlers.easel`; native answers by evaluating
 * `window.__easelHost.receive(<json>)`.
 *
 * Nothing here knows about Yjs or React: the host is a thin typed pipe and
 * the two implementations (`copperHost`, `standaloneHost`) are swappable.
 */

export type LogLevel = 'info' | 'warn' | 'error'

/** Who is looking at the board, from native (`easels/viewer.json`). */
export interface Viewer {
  id: string
  name: string
  color: string
}

export interface EaselInfo {
  id: string
  title: string
  /** Unix seconds (Double), as native keeps it in `easels/index.json`. */
  createdAt: number
}

/** Native → page `config`, the reply to `ready`. */
export interface EaselConfig {
  easel: EaselInfo
  viewer: Viewer
  /** Base64 Yjs update of the whole doc, or null for a new easel. */
  state: string | null
  mode: 'local'
}

// ---- Page → native ----

export type PageMessage =
  | { v: 1; type: 'ready' }
  | { v: 1; type: 'save'; state: string; title: string }
  | { v: 1; type: 'file'; reqId: string; name: string; mime: string; data: string }
  | { v: 1; type: 'open'; url: string; background?: boolean }
  | { v: 1; type: 'log'; level: LogLevel; message: string }

// ---- Native → page ----

export type HostMessage =
  | ({ v: 1; type: 'config' } & EaselConfig)
  | { v: 1; type: 'file:done'; reqId: string; url: string; fileId: string }
  | { v: 1; type: 'file:error'; reqId: string; message: string }
  | { v: 1; type: 'flush' }
  /** Added for sidebar rename: native renamed the easel; adopt the title and save. */
  | { v: 1; type: 'rename'; title: string }

export interface UploadedFile {
  /** `<uuid>.<ext>`; the doc stores `file:<fileId>`. */
  fileId: string
  /** Where the picture renders from right now. */
  url: string
}

/** Pictures the scheme handler serves; svg is deliberately not one of them. */
export const ACCEPTED_IMAGE_TYPES = [
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
] as const

/** The bridge's file ceiling. */
export const MAX_FILE_BYTES = 15 * 1024 * 1024

/**
 * What the canvas needs from whatever is hosting it. `copperHost` speaks the
 * bridge; `standaloneHost` fakes it for the Vite dev server and Playwright.
 */
export interface Host {
  readonly mode: 'copper' | 'standalone'
  /** Send `ready`; resolves with the `config` reply. */
  ready(): Promise<EaselConfig>
  /** The whole doc as a base64 update, plus the title for the index. */
  save(stateB64: string, title: string): void
  /** Store a picture; resolves with its id and a URL to render it from. */
  uploadFile(file: File): Promise<UploadedFile>
  /** Open an ordinary tab (http/https only). */
  open(url: string, background?: boolean): void
  log(level: LogLevel, message: string): void
  /** Native asks for a `save` now (tab closing, app quitting). */
  onFlush(fn: () => void): () => void
  /** Native renamed the easel (sidebar rename); the page takes the title. */
  onRename(fn: (title: string) => void): () => void
  /** Render URL for a stored picture (`file:<fileId>` in the doc). */
  fileUrl(easelId: string, fileId: string): string
}

/** The extension native derives the MIME type from. */
export function extensionFor(mime: string): string {
  switch (mime) {
    case 'image/png':
      return 'png'
    case 'image/jpeg':
      return 'jpg'
    case 'image/gif':
      return 'gif'
    case 'image/webp':
      return 'webp'
    default:
      return 'bin'
  }
}
