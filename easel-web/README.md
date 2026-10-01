# easel-web

The canvas page Copper serves at `copper-easel://easel/<id>`: a FigJam-style
board with stickies (live markdown), frames (with pictures), arrows and a
laser pointer. P1 is local-only with no sign-in; the contract with the Swift
side is `docs/plans/2026-10-01-easels-p1-local.md`.

## Dev

```sh
cd easel-web
npm install            # .npmrc sets legacy-peer-deps (npm 11.0.0 chokes on vitest 4's peer set)
npm run dev            # http://127.0.0.1:5291/  (strict port)
npm run typecheck
env -i "HOME=$HOME" "PATH=$PATH" TERM=xterm npx vitest run   # the P3 shell env otherwise crashes tinypool
```

Dependency versions are pinned to what the wiki app runs (react 19.3,
yjs 13.6.33, @tiptap 3.31.3, marked 17.0.6) so the two canvases keep sharing
code.

## Build

```sh
npm run build
```

Writes `../Sources/Search/Fork/Easel/web/` (`index.html` + `assets/`, Vite
`base: '/'`). Copper builds with SwiftPM only, so **commit the output**; native
copies the folder as a resource like `Fork/Backdrop` and the scheme handler
serves `/<id>` → `index.html`, `/assets/<file>` → `assets/`. Nothing is fetched
from the network at runtime (system fonts, inline SVG icons, one chunk).

## Standalone mode

When `window.webkit?.messageHandlers?.easel` is missing (Vite, Playwright) the
page fakes the host (`src/host/standalone.ts`): the easel id comes from `?id=`
(default `00000000-0000-4000-8000-000000000001`), `save` goes to
`localStorage['easel:<id>']`, pictures become object URLs with a data-URL copy
in localStorage so a reload still shows them. The viewer is `You` / `#ff5a36`.

The visual check lives in
`~/Developer/super-charles-personal/research/2026-10-01-copper-easels/web/visual-check.mjs`
(playwright-core, `channel: 'chrome'`, real mouse — synthetic PointerEvents do
not work on this canvas because `setPointerCapture` rejects fake pointer ids).

## Layout

| path | what |
|---|---|
| `src/host/` | `Host` interface, `copperHost` (the bridge), `standaloneHost`, base64 |
| `src/doc/` | `createEaselDoc()` (shapes + meta + undo), `createSaver()` / `wireFlush()` |
| `src/lib/` | pure canvas math, resize, tools, markdown, images, awareness |
| `src/components/` | the board (`easel-page.tsx`), shapes, sticky editor, toolbar, title chip, cursors |
| `src/laser/` | **stub** with the contract's exports; the laser branch replaces it |
| `src/session.ts` | open an easel: `ready` → doc → saver → awareness |
| `src/__tests__/` | vitest (jsdom opt-in per file) |

## How it talks to Copper

- `ready` once on load → `config {easel, viewer, state, mode}`. `state` is applied
  with `Y.applyUpdate` under the origin `easel:load`, which the saver ignores.
- `save {state, title}` ≤ 500 ms after the last change, and at once on
  `visibilitychange` → hidden, `pagehide`, and a native `flush` (forced: it saves
  even with nothing pending). `state` is always the whole doc
  (`Y.encodeStateAsUpdate`), base64.
- `file {reqId, name, mime, data}` for every picture (after client-side
  downscaling to ≤ 2400 px / WebP when it is big or not png/jpeg/gif/webp);
  `file:done {reqId, fileId, url}` → the frame stores `image: file:<fileId>` and
  renders `copper-easel://easel/files/<easelId>/<fileId>`.
- `open {url}` for links clicked in an unfocused sticky (http/https only).
- `log {level, message}` for uncaught errors and failed picture adds.
- `document.title` always equals the easel's title (`meta.title`, default
  "Untitled Easel"); the title chip top-left edits it. A new easel takes
  `config.easel.title` / `createdAt` into `meta` once (that is its first save).

## Lifted from the wiki app

Copied out of `~/Developer/wiki-app/apps/web/src/modules/wiki/` (read-only
there) and adapted: no `@/auth`, `@/data`, React Query, TanStack Router, `@/ui`,
Tailwind `gw-*` tokens or Font Awesome.

| here | from | changes |
|---|---|---|
| `src/doc/easel-doc.ts` | `lib/canvas-doc.ts` | module singleton → `createEaselDoc()` factory; `meta` map; `moveShapes`, `deleteShapes`; no Hocuspocus, no `nodes` |
| `src/lib/canvas-geometry.ts` | `lib/canvas-geometry.ts` | page-card helpers dropped; `fitBoxes`, `zoomTo`, `rectFrom`, intersection added |
| `src/lib/canvas-resize.ts` | `lib/canvas-resize.ts` | as is |
| `src/lib/canvas-tools.ts` | `lib/canvas-tools.ts` | + Hand, Laser; icon names instead of FA classes |
| `src/lib/canvas-images.ts` | `lib/canvas-images.ts` | upload via the host's `file` message; `file:` refs; render URL from the host |
| `src/lib/markdown-lite.ts` | `lib/markdown-lite.ts` | as is |
| `src/lib/sticky-markdown.ts` | `lib/sticky-markdown.ts` | wikilink chip class only |
| `src/lib/text-diff.ts` | `lib/text-diff.ts` | as is |
| `src/components/sticky-editor.tsx` | `components/sticky-editor.tsx` | classes → `app.css`; links open through the host |
| `src/components/canvas-shapes.tsx` | `components/canvas-shapes.tsx` | doc from context; selection bar takes the whole selection; toolbar moved out |
| `src/components/resize-handles.tsx` | `components/resize-handles.tsx` | classes → `app.css` |
| `src/components/markdown-lite.tsx` | `components/markdown-lite.tsx` | classes → `app.css` |
| `src/components/peer-cursors.tsx` | `components/agent-cursors.tsx` + the peers block of `routes/wiki-canvas-page.tsx` | human arrow + name tag |
| `src/components/easel-page.tsx` | `routes/wiki-canvas-page.tsx` | forked: no page cards / drawer / search / comments / closed cards / ring layout / canvas agent; + marquee multi-select, group move, Hand & Space, drag-to-size, double-click note, ⌘0/⌘=/⌘−, pinch, file picker, laser |
| `src/__tests__/setup-tiptap.ts` | `modules/buzz/components/composer/__tests__/setup-tiptap.ts` | as is |
| `src/__tests__/*.test.ts(x)` | `__tests__/canvas-geometry, canvas-resize, canvas-undo, canvas-images, canvas-sticky-markdown, markdown-lite, text-diff` | adapted to the factory/context |

Left out of P1 on purpose: page cards, the wiki drawer, page search, comments,
reactions, closed cards, ring layout and stage, canvas agent chat and hand-off.
