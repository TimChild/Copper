---
kind: contract
plan_id: copper-easels-p1
title: Easels P1 — local easels (no sign-in) + laser pointer; the page ⇄ Copper contract
status: in progress
created: 2026-10-01
parent: docs/plans/2026-10-01-easels.md
---

# Easels P1: local, no account

Anyone can make an easel with no sign-in. It lives on this Mac only; sharing (P4) is an upgrade
of a local easel, never a requirement. Three parallel work packages build against this file:

| WP | branch / worktree | owns |
|---|---|---|
| web | `feat/easels-web` · ~/Developer/copper-wt-easels-web | `easel-web/**`, build output `Sources/Search/Fork/Easel/web/**` |
| native | `feat/easels-native` · ~/Developer/copper-wt-easels-native | `Sources/Search/Fork/Easel/*.swift`, one-line hooks in upstream files (+ `PATCHES.md`), `Package.swift`, a throwaway `Fork/Easel/web/index.html` test page |
| laser | `feat/easels-laser` · ~/Developer/copper-wt-easels-laser | `easel-web/src/laser/**` only |

If something here is wrong, change it in your branch *and* say so in your report — the other
packages are building against the same text.

## Addresses

- An easel is `copper-easel://easel/<id>`, `<id>` a lowercase UUID.
- The scheme handler (host `easel`) serves:
  - `/<id>` and `/<id>/` → the bundle's `index.html`
  - `/assets/<file>` → files under the bundle's `assets/` (Vite `base: '/'`)
  - `/files/<easelId>/<fileId>` → a picture the user dropped on that easel; `<fileId>` is
    `<uuid>.<ext>` and the MIME type comes from the extension (png, jpg/jpeg, gif, webp, svg is
    **not** accepted)
  - anything else → 404
- The bundle is the folder `Sources/Search/Fork/Easel/web/` (`index.html` + `assets/`), copied as a
  SwiftPM resource the way `Fork/Backdrop` is. `easel-web`'s `npm run build` writes it there.
- Spike 3 (research/2026-10-01-copper-easels/spike): such a page is a secure context, origin
  `copper-easel://easel`; `<img>` from the same scheme and `wss://` both work.

## On disk (native)

All under `Store.file("easels/…")` so test worlds (`SEARCH_PROBE`) never touch the real profile.

- `easels/index.json` — `{"easels":[{"id","title","createdAt","updatedAt"}]}`, times in Unix
  seconds (Double), newest `updatedAt` first is fine but not required.
- `easels/<id>/doc.yjs` — the whole document, `Y.encodeStateAsUpdate(doc)`, written atomically.
- `easels/<id>/files/<fileId>` — pictures.

## The bridge

Handler name **`easel`** (`webkit.messageHandlers.easel.postMessage(msg)`). Every message is an
object `{ v: 1, type, …payload }`. Native answers by evaluating
`window.__easelHost.receive(<json>)`; the page defines `window.__easelHost` before it sends
`ready`. Native accepts messages **only from the main frame of an easel tab whose security origin
protocol is `copper-easel`** — a framed site on the board must not reach the bridge.

Page → native

| type | payload | native does |
|---|---|---|
| `ready` | — | replies `config` |
| `save` | `state` (base64 Yjs update, the whole doc), `title` | writes `doc.yjs` atomically, updates `title`/`updatedAt` in the index. Page sends it ≤500 ms after the last local change, and at once on `visibilitychange` → hidden and `pagehide` |
| `file` | `reqId`, `name`, `mime`, `data` (base64), ≤ 15 MB | writes the file, replies `file:done {reqId, url, fileId}` or `file:error {reqId, message}` |
| `open` | `url`, `background?` | opens an ordinary Copper tab (http/https only) |
| `log` | `level` (`info`/`warn`/`error`), `message` | NSLog, prefixed `easel:` |

Native → page

| type | payload |
|---|---|
| `config` | `easel {id, title, createdAt}`, `viewer {id, name, color}`, `state` (base64 or `null` for a new easel), `mode: "local"` |
| `file:done` / `file:error` | as above |
| `flush` | page sends `save` now (native sends it before a tab closes or the app quits) |

`viewer` for local mode: `id` = a UUID kept in `easels/viewer.json`, `name` = `NSFullUserName()`,
`color` = one of the board's cursor colours picked from the id.

The tab's title is `document.title`; the page keeps it equal to the easel's title
(default "Untitled Easel").

**Standalone mode (web WP):** when `window.webkit?.messageHandlers?.easel` is missing (Vite dev
server, Playwright), the page fakes the host: config from a fixed id, `save` to localStorage,
`file` to an object URL. Everything except Copper-specific glue must be testable this way.

## The document

A superset of the wiki app's `wiki:canvas` so renderers can be shared later.

- `meta` Y.Map: `title`, `createdAt`.
- `shapes` Y.Map<id, Y.Map>: `type`, `x`, `y`, `w`, `h`, `color`, `text` (Y.Text), `by`, plus
  - `sticky` (markdown in `text`, TipTap live editor), `frame` (title in `text`, optional
    `image`), `arrow` (`from`/`to` = `shape:<id>`, label in `text`)
  - `image` refs are `file:<fileId>`; the page turns them into
    `copper-easel://easel/files/<easelId>/<fileId>` (cloud refs come in P4)
  - `embed` is reserved for P2 (see the parent plan); P1 ignores unknown types like the wiki app does.
- No page cards, comments, reactions, search or canvas agent in P1.

## Presence (awareness), multiplayer-ready from day one

Local mode still runs a `y-protocols/awareness` instance so P4 only adds a provider. Local state:

```ts
{
  user: { id, name, color },
  cursor: { x, y } | null,          // canvas coordinates
  laser: LaserWire | null,          // see below
}
```

## Laser pointer

Tool **Laser** in the toolbar, key **L** (Esc or V returns to Select). Drag to draw a glowing
trail; it is never written to the document.

- While the pointer is down the whole stroke shows; points older than **4 s** fade from the tail
  so a long drag does not pile up.
- On release the stroke **holds 2 s, then fades over 1 s** — enough to circle something and
  talk about it.
- Look: a bright core with a soft glow in the viewer's colour (default Copper red-orange
  `#ff5a36`), round caps, the tail thinning as it fades, a small glowing dot at the head.
- Drawn in a screen-space `<canvas>` overlay (`pointer-events: none`) above the board, from
  canvas coordinates through the camera `{x, y, z}` (the wiki app's model:
  `screen = world * z + (x, y)`), so it stays on what you circled while you pan or zoom.
- Runs a rAF loop only while something is visible.

Module API (`easel-web/src/laser/index.ts`, no dependencies besides React for the component):

```ts
export type LaserPoint = { x: number; y: number; t: number }      // canvas coords, ms epoch
export type LaserStroke = { id: string; color: string; points: LaserPoint[]; endedAt: number | null }
export type LaserWire = { id: string; color: string; start: number; end: number | null; pts: number[] } // flat [x, y, dt, …], dt = ms since start, ≤ 400 points
export type LaserOptions = { holdMs?: number; fadeMs?: number; tailMs?: number }  // 2000, 1000, 4000

export class LaserTrails {
  constructor(opts?: LaserOptions)
  begin(p: { x: number; y: number }, color: string, now?: number): string
  move(p: { x: number; y: number }, now?: number): void
  end(now?: number): void
  cancel(): void
  localWire(): LaserWire | null                         // what to put in awareness
  setRemote(clientId: string | number, wire: LaserWire | null): void
  prune(now?: number): void
  hasVisible(now?: number): boolean
  subscribe(fn: () => void): () => void                 // fires on any change, for the overlay
}
export function drawLaser(ctx: CanvasRenderingContext2D, trails: LaserTrails,
  view: { x: number; y: number; z: number }, dpr: number, now: number): boolean // true = draw again next frame
export function LaserCanvas(props: { trails: LaserTrails; view: { x: number; y: number; z: number } }): JSX.Element
```

The web WP wires it: tool button + `L`, pointer routing (`begin`/`move`/`end` in canvas coords
while the laser tool is active), `localWire()` into awareness at ≤30 Hz, remote wires via
`setRemote`, and `<LaserCanvas>` above the layer. Until the laser branch lands, the web WP keeps
a stub with the same exports.

## Native UI (native WP)

- ⌘K: **New Easel** (creates one and opens it in a new tab), **Open Easel…** rows for each easel
  by title (search matches titles), and easel tabs show up in tab search like any tab.
- Menu: File › New Easel, shortcut ⌃⇧E (Arc's) unless it collides; check `App.swift`/`Arrows.swift`.
- Sidebar row: an easel glyph instead of a favicon; the title from the page.
- Easel tabs restore after relaunch, sleep and wake like any tab (reloading from `doc.yjs`).
- Web pages must not be able to open, navigate to, or frame `copper-easel://` URLs; only Copper
  itself (⌘K, menu, typed in the address field, session restore) opens them.
