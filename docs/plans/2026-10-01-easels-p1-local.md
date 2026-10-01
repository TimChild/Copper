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
| `rename` | `title` (string). *Added for sidebar rename.* The page sets `meta.title`, so `document.title` follows, and saves as usual (`save` ≤ 500 ms later, carrying the new title). Surrounding spaces are trimmed; an empty title reads as "Untitled Easel". Native needs no reply. |

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

## As built (native WP, `feat/easels-native`)

What the native half does beyond, or more strictly than, the text above. The web and laser
packages need none of it except where marked **web**.

- **Native → page messages carry `v: 1` too** (**web**: `host/types.ts` already expects it).
- **Bound to one board.** Each easel tab's scheme handler and bridge are made for its board:
  `/<id>` serves `index.html` only for the tab's own id, and `/files/<easelId>/…` only for its own
  easel id. Another board's id is a 404. A board renders only its own pictures (**web**: the
  `file:<fileId>` → URL rule above already does that).
- **An easel tab never leaves its board.** Main-frame navigations elsewhere are cancelled, and
  http(s) ones open in an ordinary tab. `window.open` from a board opens an ordinary tab and returns
  `null` (**web**: use `open`). An http(s) address typed into an easel tab's field opens beside it.
- **One tab per board.** Opening a board that is already open (⌘K, the menu, the field, ⌘T, ⌘D,
  an agent) goes to its tab.
- **Unknown ids open empty**, and join the index with their first save. A deleted board's late
  `save` (from its closing tab) is ignored.
- **`file`** sniffs the bytes (PNG/JPEG/GIF/WebP). An empty `mime` or `application/octet-stream` is
  taken from the bytes, a `mime` that is given must match, and `image/jpg` is accepted as
  `image/jpeg`. `save` is capped at 64 MB.
- **`flush`**: quitting waits ≤ 300 ms for every awake board, as specified. A closing tab's view is
  kept up to 1 s to answer, but nothing waits on it (the row goes at once), so this is not a
  slower close.
- **Headers**: every answer has `nosniff` and `Cross-Origin-Resource-Policy: same-origin`, and
  `index.html` also has `frame-ancestors 'none'` + `X-Frame-Options: DENY`. The MIME list also
  takes `gif`, `jpeg`, `woff`, `ttf`.
- **No Chrome extensions in easel tabs** (as in private tabs), so no content script can reach the
  bridge from the page's world.
- **Viewer colour** comes from `EaselStore.cursorColors`: `#ff5a36 #3b82f6 #10b981 #a855f7
  #f59e0b #ec4899 #14b8a6 #6366f1`, picked by an FNV-1a hash of the viewer id.
- **Menu**: File › New Easel ⌃⇧E sits after New Private Tab in `App.swift`'s File group, not in
  `ForkCommands`.
- `docs/easels.md` has the rest, including a list of WKWebView quirks for the web bundle.

## As built (web perf, `feat/easels-perf`)

What the page does now that the other packages, and P4, should know.

- **`rename`** (native → page) is in the table above: added for sidebar rename.
- **Moves and resizes write the doc once, on release**, between `undo.stopCapturing()` calls, so a
  drag is exactly one undo step (it used to write every 50 ms and split into several steps on a
  pause). A drawn new box still writes every 200 ms. P4 peers would see a drag land rather than
  glide; a live drag for peers belongs in awareness, not the doc.
- **Stickies are static HTML until edited.** Only the note being edited mounts TipTap (double-click,
  or a new note); it goes back on blur, but not on a window blur. Links and task boxes on an
  unfocused note still work. Anything that scripts the page (bench, agents) should look for
  `[contenteditable]` only inside the note being edited; the others carry `[data-static]`.
- **The camera is not React state.** The layer `transform` and the grid's
  `background-position/size` are written straight to the DOM, once per frame. While it moves, the
  layer has `data-moving` (and `will-change: transform`) until 150 ms after it rests.
- **`window.__easelDebug`** is always defined and inert until called: `seed({stickies, frames,
  arrows, images})`, `perf.start({busy?})` / `perf.stop()`, `view()` / `setView(v)` / `fit()`,
  `marks` (`config`, `firstCommit`, `painted`), `counters`. Harness and numbers:
  `~/Developer/super-charles-personal/research/2026-10-01-copper-easels/perf/`.

## As built (Arc tab + native lag, `feat/easels-arc`)

Collin: easels must be a tab in Copper the way an Arc easel is, and the board felt laggy.

- **Where a board lives.** A board's tab joins its space's **Saved** block (bottom) the first time
  it loads, however it was opened, and is selected; the archive sweep never takes a board. New
  Easel is also on the New Tab row's and the foot plus's right-click and on each space's menu.
- **Its row** starts with **Rename Easel…** and **Delete Easel…** (which asks first), then Copper's
  tab items.
- **Native → page `rename {title}`** (**web**): sent when the board is renamed from its row while
  its page is up, and right after `config` when it was renamed while the page was not. The page
  sets `meta.title` (and so `document.title`) to `title`. It must not drop a `rename` that arrives
  straight after `config`, before the board is drawn.
- **`config.easel.renamed: true`** (**web**): present only when Copper renamed the board since the
  page last saved; `config.easel.title` is then newer than the document's `meta.title` and wins
  (copy it into `meta`, not only for a new board). Absent otherwise; `config.easel.title` is still
  Copper's name for the board.
- **The index holds the name.** `index.json` entries may carry `renamedFrom` (the name the
  document still has) until the page saves under the new name; meanwhile a `save` whose `title` is
  exactly `renamedFrom` keeps Copper's title, any other title replaces it and clears the marker.
- **A deleted board's address opens nothing** for the rest of the session ("That easel was
  deleted"); its late `save` was already ignored.
- **An easel tab is lean** (**web**: nothing to do, but don't rely on Copper's page scripts): no
  `Swipe.watch`/`Swipe.calm`, no sign-in watcher (`__officeForms`), no picker, no image menu
  script, no store mender, no passkey shim, no ad-block rule list, and no back/forward swipe
  tracking in the view. One script stays: on focus changes it tells Copper whether the caret is in
  something that takes typing (Tab then goes to the page). `docs/easels.md` has the table.
