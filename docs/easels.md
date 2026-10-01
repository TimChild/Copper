# Easels

An easel is a board in a Copper tab: stickies, frames, arrows and pictures on a canvas you pan
and zoom, FigJam-style. Anyone can make one. P1 is local: no account, nobody signs in, and nothing
leaves the Mac. Sharing (P4) will be an upgrade of a board that already works here, never a
condition of having one. The plan is [plans/2026-10-01-easels.md](plans/2026-10-01-easels.md); the
contract the two halves build against is
[plans/2026-10-01-easels-p1-local.md](plans/2026-10-01-easels-p1-local.md).

The board is a web app (`easel-web/`, built into `Sources/Search/Fork/Easel/web/`) that Copper
serves from its own scheme. The native half is `Sources/Search/Fork/Easel/`:

| file | what it is |
|---|---|
| `Easels.swift` | `EaselStore`: the index, the documents, the pictures, the viewer |
| `EaselScheme.swift` | the `copper-easel://` handler: the bundle and the pictures |
| `EaselBridge.swift` | the `easel` message handler: page ⇄ Copper |
| `EaselTabs.swift` | easel tabs: their configuration, the navigation guard, ⌘K, flushing, the mark, `bench easels` |

## Opening one

- **⌘K › New Easel**, or **File › New Easel** (⌃⇧E, Arc's): a board in a new tab in front. A
  blank tab in front takes it instead, the way ⌘T reuses one.
- **⌘K**, typing a board's title: an **Open Easel** row for each match, three at most. `easel`
  alone lists them all, newest first; `easel plan` narrows to titles with "plan" in them. An open
  board also shows up in tab search like any tab.
- Its address, `copper-easel://easel/<id>`, typed into the field or the ⌘T card.

A board has **one tab**. Opening one that is already open, in this space, another space or
another window, goes to that tab. Two pages saving the whole of one document would each write over
the other.

The tab is an ordinary tab in every other way. The sidebar row wears Copper's mark, an orange
square with a white scribble, where a site wears its icon, and the title is the page's
`document.title`. The address pill says **Easel · <title>**. It sleeps after half an hour and
wakes from the file, comes back after a relaunch, sits in split view, and moves between spaces.

## Where it lives

Under the world's own folder, `Store.file("easels")`. That is
`~/Library/Application Support/Copper/easels/` for the real browser, and
`Copper (<world>)/easels/` for a `SEARCH_PROBE` run, so a test can never touch a real board:

```
easels/index.json            {"easels":[{id,title,createdAt,updatedAt}]}   newest change first
easels/viewer.json           {"id": <uuid>}   who "you" are on every board
easels/<id>/doc.yjs          the whole document, Y.encodeStateAsUpdate(doc)
easels/<id>/files/<fileId>   pictures dropped on that board, <uuid>.<png|jpg|gif|webp>
```

Every write is atomic, on one serial queue, so a save and the read that answers the next `ready`
never pass each other. A board whose id is not in the index (an address typed by hand, an index
lost) opens empty and joins the index with its first save. Deleting is `bench easels delete` only,
until there is an undo to put beside it.

## The scheme

`copper-easel://easel/…` is served by a handler that **only easel tabs have**, and each one is
bound to its own board:

| path | answer |
|---|---|
| `/<id>`, `/<id>/` | the bundle's `index.html`, for this tab's board only |
| `/assets/<file>` | the bundle's `assets/`, by extension: html js mjs css svg png jpg webp gif woff2 woff ttf json wasm map |
| `/files/<id>/<fileId>` | a picture of this tab's board; png, jpeg, gif, webp, never svg |
| anything else | 404 |

Every path part is decoded and checked: nothing empty, no `.`/`..`, nothing hidden, no `/` or `\`
smuggled in as `%2F`, and the file must still be inside its folder once links are resolved.
Answers carry `X-Content-Type-Options: nosniff` and `Cross-Origin-Resource-Policy: same-origin`;
`index.html` also carries `Content-Security-Policy: frame-ancestors 'none'` and
`X-Frame-Options: DENY`. The page is a secure context with origin `copper-easel://easel`.

The bundle is the SwiftPM resource `Fork/Easel/web` (`Package.swift`), found the way the
backdrop's scene is: in `Search_Search.bundle` beside the binary for a run from `.build`, and in
`Copper.app/Contents/Resources/Search_Search.bundle` for the app, which `build.sh` already copies
in whole.

## The bridge

`webkit.messageHandlers.easel.postMessage({ v: 1, type, … })` from the page; Copper answers with
`window.__easelHost.receive(<json>)`, every answer carrying `v: 1` as well.

| page → Copper | Copper does |
|---|---|
| `ready` | answers `config`: `easel {id, title, createdAt}`, `viewer {id, name, color}`, `state` (base64 of `doc.yjs`, or `null`), `mode: "local"` |
| `save {state, title}` | writes `doc.yjs`, updates the title and `updatedAt` in the index. 64 MB at most |
| `file {reqId, name, mime, data}` | checks the bytes themselves (PNG, JPEG, GIF or WebP, 15 MB at most; a `mime` that is given must match), writes the picture, answers `file:done {reqId, url, fileId}` or `file:error {reqId, message}` |
| `open {url, background?}` | an ordinary tab, http and https only |
| `log {level, message}` | NSLog, `easel: [level] <id> message` |

Copper sends `flush` when a board's tab closes and when the app quits; the page answers with a
`save`. Quitting waits 300 ms at most for every awake board, then for the disk. A closing tab's
view is kept up to a second to answer, without holding anything up.

The viewer's `id` is made once and kept in `viewer.json`; `name` is `NSFullUserName()`; `color` is
one of eight cursor colours (`EaselStore.cursorColors`, Copper's `#ff5a36` first) picked by a hash of
the id.

## What a page can't do

Easels are Copper's own. Web pages can't reach them, and boards can't reach anything else:

- **No other tab has the scheme.** An ordinary tab's configuration has no `copper-easel` handler,
  so a link, a redirect, an `<iframe>`, an `<img>` or a `fetch()` from a website loads nothing.
  The navigation policy cancels a website's navigation to an easel too, before upstream's would
  hand the unknown scheme to the system. `window.open` of an easel opens nothing.
- **No other tab has the bridge.** `easel` is in an easel tab's configuration only. There, a
  message is heard only from the main frame, with origin `copper-easel://easel`, of a view built
  for that board and showing it. Easel tabs have no Chrome extensions, as private tabs have none,
  so no content script can put a script into the page's world.
- **A board's tab shows that board and nothing else.** A navigation in it that leads anywhere
  else (a link, a redirect, a frame setting `top.location`, another board's address) is
  cancelled. An http(s) one opens in an ordinary tab instead. A frame on a board never loads an
  easel, and a window a board opens is an ordinary tab, never one sharing its configuration. So
  the only document in an easel tab's main frame is its own board's page.
- **Only Copper opens a board**: ⌘K, the menu, an address typed into the field or the ⌘T card,
  session restore. Each ends in `Tab.go(to:)` or a tab made with `Easels.configuration(for:)`, and
  `Easels.reroute` gives an easel address handed to an ordinary tab a tab of its own. The policy
  never has to tell Copper's loads from a page's. An agent driving Copper (MCP `browser_tabs` new,
  `browser_navigate`) goes the same way as a typed address.

## For the web bundle

- Keep the path `/<id>`. Use `?query`, or `history.replaceState` rather than hash history: a
  reload asks the handler for the path, and a back entry turns a two-finger pan into Copper's
  back swipe.
- Never navigate the main frame. Links go through `open`. `window.open` opens an ordinary tab
  and returns `null`.
- Exports go through `<a download>` (Copper's downloads), not `window.open(blob:)`.
- Every tab lets WebKit magnify on a pinch (`allowsMagnification`). A canvas that zooms itself
  should `preventDefault()` WebKit's `gesturestart`/`gesturechange`, as it would in Safari; not yet
  tried on a trackpad. ⌘+/⌘−/⌘0 are Copper's page zoom.
- Tab belongs to Copper (it walks the tabs) unless the caret is in a field or a contenteditable.
  A page keeps ⌘K only if it calls `preventDefault()` on it, so leave ⌘K, ⌘T, ⌘L and ⌘W alone.
- Call `preventDefault()` on file `dragover`/`drop`. A dropped file WebKit would open is a
  navigation, and the board's tab refuses it.
- `localStorage` and IndexedDB belong to the one origin every board shares, and to the space's
  profile. Key anything kept there by board id, or better, keep it in the document.

## The bench

```
./bench --world NAME easels                  every board, its tabs, the folder and the bundle in use
./bench --world NAME easels new              a board, opened the way ⌘K's New Easel opens one
./bench --world NAME easels open ID          by id prefix
./bench --world NAME easels check ID         doc.yjs (bytes, first bytes), the index entry, the pictures
./bench --world NAME easels flush ID         ask its page to save now
./bench --world NAME easels delete ID        close its tab and remove it, files and all
./bench --world NAME easels menu [press]     File › New Easel as the menu bar holds it
```

A test world, headless, off the real Copper's MCP port:

```sh
swift build
defaults write com.officecommun.search.test.easels bench -bool YES
SEARCH_PROBE=easels SEARCH_MCP_PORT=4199 SEARCH_HEADLESS=1 .build/debug/Search &
./bench --world easels bar "New Easel" --go
./bench --world easels easels
```
