# Canvas

The infinite whiteboard Copper shows at `copper://canvas/<id>`: stickies (markdown), text, frames
(optionally holding an image), arrows that attach to shapes or their sides, images, and link cards;
select, multi-select, marquee, move, resize, undo/redo, search, live cursors and agent presence.

It is a Vite + React 19 + TypeScript + Tailwind v4 page, built with **bun** into one self-contained
file, **`dist/canvas.html`** (≈ 500 KB; every script and style inlined, no fonts or other requests).
That file is committed and copied into the app bundle; the app does not need bun to build.

The page never talks to the network. Copper hosts it in a `WKWebView`, persists its Yjs updates,
and relays the sync socket over the bridge described below.

## Develop

```sh
cd Canvas
bun install
bun run dev            # then open http://localhost:5173/?dev=1
```

`?dev=1` (only outside Copper) stands in for the host: it records page → host messages on
`window.__copperHost.messages`, initialises a demo canvas from a stored state, and accepts:

| Param | Effect |
|---|---|
| `empty=1` | start from a blank board |
| `peers=1` | a simulated collaborator's cursor and selection (awareness) |
| `agent=1` | a simulated agent that thinks, then writes notes through `apply` |
| `online=1` | the relayed sync socket against an in-page server (`src/dev-relay.ts`) |
| `theme=dark\|light` | force a theme (otherwise `prefers-color-scheme`) |
| `status=…&pending=N` | what the host would say through `setStatus` (e.g. `status=shared-offline&pending=3`) |
| `readonly=1`, `name=…`, `kind=personal\|shared` | init options |

Checks (all must pass):

```sh
bun run test        # vitest (4 workers, from vitest.config.ts)
bun run typecheck   # tsc --noEmit
bun run lint        # eslint (typescript-eslint, react-hooks)
bun run build       # → dist/canvas.html
./build.sh          # bun install --frozen-lockfile && bun run build (no-op without bun)
```

## Embedding (host side)

1. Load `canvas.html` (e.g. `loadFileURL`) in a `WKWebView` with a script message handler named
   **`canvas`**. Keep `allowsMagnification = false`: the page handles pinch and ⌘-scroll itself.
2. Wait for `{"type":"ready","version":"1.0.0"}`, then call `copperCanvas.init({...})`.
3. Store every `{"type":"update","b64"}` in order (append-only log); replay them, or a snapshot
   from `copperCanvas.exportState()`, as `init.state` next time. Updates only depend on earlier
   updates from the same page, so keep the whole log (or compact it with `exportState`).
4. Online canvases: answer `{"type":"wsOpen","url"}` by opening the pinned, authenticated socket to
   `/v1/canvases/:id/ws`, then call `copperCanvas.wsState("open")`; forward every binary server frame
   with `copperCanvas.wsMessage(b64)` and every `{"type":"ws","b64"}` to the server; on a drop call
   `copperCanvas.wsState("closed")` (the provider reconnects by sending `wsOpen` again, with backoff);
   on `{"type":"wsClose"}` close the socket.
5. The page captures ⌘F for its own search; let that key reach the web view on canvas tabs.

The y-websocket provider closes a connection that has received nothing for 30 s. Like the
reference server, the sync server should broadcast awareness to every peer including the sender
(each client renews its awareness every 15 s), or otherwise send something at least every 30 s.

## Window API — host → page

Every function accepts a JSON string or a plain value and never throws into the host (failures are
reported as `{"type":"log","level":"error"}`). `apply` and `read` return JSON strings.

```js
copperCanvas.version                       // "1.0.0"

copperCanvas.init({
  docId: "8f1c…",                          // room name for the sync socket
  name: "Personal", kind: "personal",      // "personal" | "shared"
  me: { id: "u-123", name: "Ada", color: "#2f6fdf" },
  state: "AQL…" | null,                    // base64 Yjs update, applied before anything else
  online: false,                           // true → connect the relayed provider
  readOnly: false,
})                                          // a second init replaces the session

copperCanvas.applyUpdate("AQL…")            // a stored or relayed update (not echoed back)
copperCanvas.wsMessage("AAEC…")             // one binary frame from the server
copperCanvas.wsState("open" | "closed")
copperCanvas.exportState()                  // → base64 of the whole doc

copperCanvas.apply(JSON.stringify({
  as: { id: "agent:scout", name: "Scout", color: "#2b9348" },   // optional; default "Agent"
  ops: [
    { op: "add", shape: { type: "sticky", id: "n1", text: "**Ship** it", color: "yellow" } }, // no x/y → free space near the viewport centre
    { op: "add", shape: { type: "frame", x: 0, y: 0, w: 640, h: 400, title: "Ideas" } },
    { op: "add", shape: { type: "link", url: "https://example.com", title: "Example" } },
    { op: "add", shape: { type: "image", src: "https://…/a.png", naturalW: 800, naturalH: 600 } },
    { op: "update", id: "n1", patch: { color: "pink", text: "Shipped" } },
    { op: "move", id: "n1", dx: 40, dy: 0 },
    { op: "resize", id: "n1", w: 260, h: 220 },
    { op: "connect", from: "n1", to: "n2", label: "then", fromSide: "right", toSide: "left" },
    { op: "delete", id: "n2" },
    { op: "clear" },
  ],
}))
// → '{"applied":8,"ids":["n1","…","…","…","n1","n1","n1",null,null,null],
//     "errors":[{"index":7,"op":"connect","error":"`to`: no shape n2"},{"index":8,"op":"delete","error":"no shape n2"}]}'

copperCanvas.read('{"full":false, "ids":["n1"], "types":["sticky"], "inView":true}')  // all optional
// → '{"canvas":{"id","name","kind"},"viewport":{"x","y","w","h","zoom"},
//     "shapes":[{"id","type","x","y","w","h","color","z","by","text"|"title"|"label"|"url",…}],
//     "agents":[{"id","name","color","cursor","status","updatedAt"}],"selection":["n1"],"count":12}'

copperCanvas.select(["n1", "n2"])           // also '["n1"]' or "n1"; not reported back as a selection message
copperCanvas.zoomTo(["n1"])                 // animated flight to the shapes' bounds
copperCanvas.setAgent({ id: "agent:scout", name: "Scout", color: "#2b9348",
                        cursor: { x: 120, y: 40 }, status: "thinking" })   // partial patches merge
copperCanvas.setAgent({ id: "agent:scout", remove: true })
copperCanvas.setStatus({ mode: "shared-offline", pending: 3 })  // what the title pill says; see below
copperCanvas.theme("dark")                  // "light" | "dark" | "system" (default: system)
```

### Connection status

`setStatus({mode, pending?})` tells the page how the host sees the board's connection, for the
title pill (top left). It is idempotent, survives `init` (so it may come before or after one), and
`setStatus(null)` clears it. `mode`:

| Mode | Pill | Use when |
|---|---|---|
| `local` | gray dot, "On this Mac" | the board never leaves this Mac |
| `personal-synced` | green dot, "Synced" | Personal, syncing to the account |
| `shared-live` | green dot, "Live", collaborators' avatars | a shared board with its room connected |
| `shared-offline` | amber dot, "Offline · changes saved on this Mac · N pending" | a shared board whose room is not connected (signed out, disconnected, no network) |

`pending` (optional, ≥ 0) is the number of local changes not yet handed to the cloud; it shows only
while offline. "Synced" and "Live" show only once the page's own socket has synced — before that the
pill says "Connecting" (or "Offline" if the socket dropped). Narrow windows keep a short text
("Offline · 3 pending"), never just a dot; the full sentence is in the pill's tooltip.

Without `setStatus` the page derives the pill as before from `init` and the socket — "On this Mac",
"Connecting", "Live", "Offline" — except that a `kind: "shared"` board initialised with
`online: false` reads "Offline · changes saved on this Mac" rather than "On this Mac".

### Ops semantics

- One transaction per call, ops in order; a bad op is skipped and reported, the rest apply.
  `ids[i]` is the id op `i` created or touched (`null` when it failed, and for `clear`).
  At most 500 ops per call. Agent ops are undoable by the user (one step per call).
- `add` defaults: sticky 200×200 yellow, text 240×36, frame 480×320 gray, link 300×84 white,
  image at natural size (≤ 480 wide), arrow needs `from`/`to`. Unknown props are errors.
  Friendly aliases: `text` on a frame/link is its `title`, on an arrow its `label`.
- Arrow ends: a shape id (`"n1"` or `"shape:n1"`), `{ref, side?}` with side `top|right|bottom|left`,
  or a free point `{x, y}`. Arrows have no box of their own.
- `move` on a frame carries the shapes lying wholly inside it; on an arrow it moves free ends.
- `delete` also deletes the arrows that end on the shape. `clear` keeps `meta` and `agents`.
- Images: `src` is a `data:image/…` URL (≤ 2 MB) or an `https:` URL. Link `url`: http(s), mailto,
  copper. `color`: yellow, pink, blue, green, purple, gray, white or `#hex`.
- A call with `as` marks that agent `writing` (cursor at the last thing it touched), then `idle`
  1.5 s later.

## Page → host messages

`window.webkit.messageHandlers.canvas.postMessage(JSON.stringify(msg))`:

| Message | When |
|---|---|
| `{"type":"ready","version"}` | the API is installed; call `init` |
| `{"type":"update","b64"}` | after every local transaction (user, agent ops, presence, meta) — not for `init.state`, `applyUpdate` or server frames |
| `{"type":"selection","ids"}` | the user's selection changed |
| `{"type":"ws","b64"}` | a frame for the relayed socket |
| `{"type":"wsOpen","url"}` / `{"type":"wsClose"}` | open / close the relayed socket |
| `{"type":"openUrl","url"}` | a link card was opened or a link in a note clicked (the page never navigates) |
| `{"type":"log","level","msg"}` | diagnostics |

## Document schema

One Y.Doc per canvas (see `src/canvas/types.ts`):

- `shapes: Y.Map<id, Y.Map<prop>>` — per-property last-writer-wins. Every shape: `id, type, x, y, w,
  h, color, by, createdAt, updatedAt, z`. `sticky {text, fontSize?}`, `text {text, fontSize?,
  align?}` — `text` is a **Y.Text** (plain strings written by other writers are read too and
  upgraded on the next edit); `frame {title, image?:{src, naturalW, naturalH}}`; `arrow {from, to,
  label?}`; `image {src, naturalW, naturalH}`; `link {url, title, favicon?}`. Titles, labels and
  urls are plain strings.
- `agents: Y.Map<agentId, {name, color, cursor:{x,y}|null, status:'idle'|'thinking'|'writing',
  updatedAt}>` — whole values; entries older than 2 minutes are hidden, never deleted.
- `meta: Y.Map` — `name`, `createdBy` (written once by the page that made the canvas).
- Awareness (human cursors): `{user:{id,name,color}, name, color, cursor:{x,y}|null, selection:[ids]}`.

Undo is a `Y.UndoManager` on `shapes` tracking the page's own origins (`local`, `agent`); stored
and relayed updates are never undone.

Sticky text is never shrunk to fit. A note whose markdown is taller than its box shows a fade and a
**Show all** pill that grows it to fit (one undo step, up to 960 px; a longer note opens in its
editor, which scrolls). While you type, a note grows the same way. Read-only boards show it all
locally without writing.

## Layout

```
src/
  main.tsx          mounts the board, installs window.copperCanvas, posts ready (or starts ?dev=1)
  api.ts            the window API (JSON in/out, never throws)
  controller.ts     the session: Y.Doc, store, awareness, provider, selection, agents, viewport
  host-bridge.ts    page → host framing (webkit handler, or the __copperHost double)
  bridge-socket.ts  BridgeSocket, the WebSocketPolyfill for y-websocket
  ops.ts            apply + read (the agent contract)
  placement.ts      free-slot placement near the viewport centre
  theme.ts          light / dark / system
  dev.ts, dev-relay.ts   ?dev=1 host double and in-page sync server
  canvas/           doc model, geometry, arrows, search, markdown, images, presence, and the UI
```

Not in this version: comments/reactions (the `comments` map is left alone), multi-shape resize,
alignment guides.
