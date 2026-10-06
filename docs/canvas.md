# Canvas — a whiteboard in a tab

*An infinite board of stickies, text, frames, arrows, images and links that lives in an ordinary
Copper tab at `copper://canvas/<id>`. One **Personal** canvas always exists, works with no
network and no account, and is never shared — it stays on this Mac until you choose **Personal
canvas** in Settings › Cloud › Choose what syncs; with Copper Cloud signed in you can make shared
canvases, invite people, and see each other — and each other's agents — live. The ⌘E agent, MCP
agents and the `copper` CLI all read and write the same boards. Implementation:
`Sources/Search/Fork/Canvas/` (the page itself is built from `Canvas/`).*

## Using it

Canvas is Copper's one board. (It used to have two: Easels, a local-only board with a format of
its own, was folded into Canvas on 2026-10-01 — see [What happened to easels](#what-happened-to-easels).)

### Opening one

- **⌘K › New Canvas** (or ⌘T, typing "canvas"), or **File › New Canvas** (⌃⇧E, Arc's): a canvas
  in a new tab in front. A blank tab in front takes it instead, the way ⌘T reuses one. A canvas
  made this way is **local** — on this Mac, called *Untitled canvas* — whether or not you are
  signed in; sharing stays an upgrade, from the door's **New canvas** (signed in, it makes a shared
  one; ⌘K says **New Shared Canvas…** for it) and the invite flow.
- **From the sidebar**, where Arc keeps its new things: right-click the **New Tab** row (New Tab /
  New Canvas), right-click the **plus** at the foot (New Space / New Canvas; a click on it still
  makes a space), or **New Canvas in Space** on a space's menu (its header, its chip, ⌘K's space
  rows).
- **Sidebar › Canvas door** (at the foot, beside Bookmarks and Extensions): Personal,
  *Invitations* (invites waiting for your answer, with Decline / **Join**), *My canvases*, *Shared
  with me* and **New canvas**. While an invite waits the door wears a small dot in the space's ink
  (green when someone is live on a canvas) and its help says *1 invitation*. Click a row to open it. Right-click a row: Open, Open in Background, Copy Link,
  Rename…, Share…, Members…, Leave… / Delete….
- **⌘K / ⌘T**, typing a canvas's name: an **Open Canvas · <name>** row for each match, three at
  most. `canvas` alone (or `canvases`, or `canv`) lists them all, newest first; `canvas plan`
  narrows to names with "plan" in them. An open canvas also shows up in tab search like any tab,
  wearing the Canvas mark. **View › Canvas ⌘⇧O** opens Personal.
- Its address, `copper://canvas/<id>` (or just `copper://canvas` for Personal), typed or pasted
  into the field or the ⌘T card. An easel's old address, `copper-easel://easel/<id>`, opens the
  canvas that easel became.

However it is opened, a canvas's tab — the first time it loads — joins the current space's
**Saved** block at the bottom and is selected, the way Arc pins a board. Today's archive never
takes it, and the sweep passes over a canvas even when somebody drags it down into Today. A canvas
whose tab is already in the sidebar stays where it is (opening it goes to it). Session restore puts
each canvas tab back in its space and its block.

A canvas has **one tab**. Opening one that is already open — in this space, another space, or
another window — goes to that tab (the other window comes forward, the other space is switched
to). Only the bench's own tabs are exempt. This is `CanvasTabs.show`, and `CanvasTabs.already`
(`Browser.open`) and `CanvasTabs.reroute` (`Tab.go`) send every other way of opening one there.

### Its tab

An ordinary tab in every other way. The sidebar row (and a favourite's square, and ⌘K's row) wears
the **Canvas mark** (`CanvasPage.icon`) where a site wears its icon; the title is the canvas's
name — a sleeping or restored row says the registry's name, so a rename made while it slept shows
at once. The address pill says **Canvas · <name>**. It sleeps after half an hour and wakes from
disk, comes back after a relaunch, sits in split view, and moves between spaces. Links clicked on
the board open in a tab of their own; an address typed into a canvas tab's field opens beside it —
a canvas tab only ever shows its board.

### Its row

Right-click a canvas's row (or its square, if it is a favourite, or its pill in the top bar): the
canvas's own items come first, then Copper's tab items as for any tab. Personal has neither.

- **Rename Canvas…** opens a name field on the row, as a folder's Rename… does (a sheet where there
  is no row: a favourite's square, the top bar). Return keeps it, Escape or a click away leaves
  it. It is `Canvases.rename`, the door's Rename: a shared canvas is renamed on the cloud (and so
  needs it signed in — the item is greyed out without), every tab holding the canvas retitles, and
  an open board is told the new name (`copperCanvas.rename` when the page has it; otherwise the
  page is checkpointed and reloaded under the new name).
- **Delete Canvas…** asks first, in a sheet that says what happens: a local canvas — *Permanently
  deletes this canvas and everything on it from this Mac* —, a shared one you own — *…for every
  member* —, or, for a shared canvas somebody else owns, **Leave Canvas…** — *It stays for everyone
  else. Someone will have to invite you again.* Cancel is the default; Return confirms nothing. It
  is `Canvases.delete` / `Canvases.leave`, the door's: every tab showing the canvas closes — this
  row, a favourite, a row in another space or window — and its history on this Mac goes.

### What a canvas tab is spared

Every tab is built for the open web; a canvas is Copper's own page, so its tab is built lean
(`CanvasLean.swift`; `defaults write <domain> canvas.lean -bool NO` builds it like any tab, for
the bench's before-and-after). Only what the bridge does not need goes:

| every tab gets | on a canvas tab |
|---|---|
| back/forward swipe in `PageView.scrollWheel` (the sideways tracker, the page asked, the disc, `onTouch` per event) | **off**: the event goes to WebKit and nothing else; `onTouch` once per gesture |
| `Swipe.watch` / `Swipe.calm` scripts in every frame | off |
| `ScrollRelay`, `VeilRelay` (hide something), `ImageRelay` (Copper's image menu), `StoreRelay` (Web Store mender), the passkey shim | **off**, handlers too |
| `FormRelay`'s sign-in watcher (a `MutationObserver` over the document, capture listeners) | off; a 20-line script reports focus changes only, so Tab still goes to a sticky or a title |
| the ad blocker's rule list | off |
| WebKit's pinch magnification | off (the board zooms itself) |
| the `canvas` message handler, `callAsyncJavaScript`, the first-frame fade, the sleep picture, sleep after half an hour, the title/address/progress observers, the audio watch | **kept** |

`bench canvas lean` reads the page back: the bridge is there, the page's API is there, the host is
ready, and the web-page scripts are not. A canvas tab has no Chrome extensions (its configuration
is CanvasHost's, made for it, never an extension's).

- Signed out, everything cloud-shaped is hidden and the card says, in one line, that sharing lives
  at **Settings › Cloud**. New canvases are then local to this Mac. Shared canvases already kept
  here stay listed under **Signed out** with a line saying what that means: they open offline and
  keep your changes until you sign in again. With *another* account signed in they are only
  counted ("2 shared canvases are kept on this Mac for another account"), never named or opened.
- Row subtitles say what is true now: Personal is *Private · on this Mac* while its sync is off,
  *Private · connecting…* (its tab is up, the room hasn't answered) or *Private · sync on* (no tab open) while it is on, and *Private · synced* only once its
  room has answered with the server's side of the document; a shared board with no room reads
  *Offline · changes saved on this Mac*. The tab in front has a tinted row and a ✓; one open behind
  has a window mark ("Open in a tab"); the green dot's help says "1 collaborator live".
- Rename, Invite, Members and Delete open with a short title ("Rename canvas", "Invite to
  canvas", "Delete canvas") over the canvas's whole name, wrapped. Delete is a red **Delete
  canvas** that says what it does — *Permanently deletes this canvas and everything on it, for
  every member. This can't be undone.* — with Cancel first: Escape cancels and Return confirms
  nothing. An invitation row shows the whole name and who sent it (*From Felipe · reminded you* once
  its sender has reminded you) above Decline / **Join**, says *Joining…* in the row while the
  answer is on its way, and stays — with the reason, in the row — until the server has said yes.
  **Join** accepts and opens the canvas in front.

## Live web frames

A link on the board can show the site itself instead of its card: an `<iframe>` under a slim title
bar, which you and everyone else on the board can use at the same time.

- **Making one.** The link prompt (the link tool, or `L`) has **Live** (⌥↵) beside Add; a link you
  paste or drop lands as a card with a *Link added · Show live* toast; any link card's selection bar
  has **Show live** (and a live one **Show as card**). Agents add `{type:'web', url}` (or a link
  with `live:true`; `embed` and `iframe` are accepted spellings); it is 960×640 by default and
  never smaller than 320×200. A live link is still a `link` in the document — a page from before
  frames shows it as a card and keeps the flag.
- **Using one.** Until it is in use a frame is a shape like any other: a transparent shield lies
  over the page, so it selects, drags, resizes, marquees and zooms with the board. Click the
  selected frame (or double-click it, or ↵) and the shield comes off: the page scrolls, takes
  clicks and the keyboard. **Esc** (when the site didn't use it), a click on the board or another
  shape gives the board back. The bar has Back / Forward (this frame's own pages, not the board's
  history), Reload, the address (editable while in use), **Sign in**, **Open in a tab** and **Show
  as card**.
- **Together.** Where a frame is — its `url`, `title` and `favicon` — is the shape's, so it syncs
  like any edit: when the person using a frame follows a link, everyone else's frame goes there
  too. Only the person using a frame writes its address (a frame that is following someone, or
  redirecting on its own — to a sign-in page, another locale — never writes it), and browsing is
  never an undo step. Whoever is using a frame shows on it: a ring and a name tag in their colour.
  Scroll position, what is typed into the page and the page's own state are each person's.
- **Cheap when idle.** At most six frames have a real iframe at once: the one in use, then the
  ones on screen and at least 260 px wide, nearest the middle first; the rest show a placeholder
  (favicon, title, host) until you come closer.

### Privacy: one address, your own cookies

What a live frame shares is **where it is, never who it is signed in as.** Each person's Copper
loads the site with their own cookie jar — the board's view uses the store of the space it was
opened in (its profile's, if the space wears one), the same one a tab there uses. Nobody's
cookies, storage or page contents travel through the board; the board only carries the address
and title, which everyone on it can read (the same as a link card). So a private page — a doc,
an inbox — shows each person their own view of it, or a sign-in page if they have no access.

### Which sites stay signed out, and why

The board is a local file (`file://`), so to the browser every site in a frame is a
**third-party, cross-site** frame. WebKit then sends a frame only the cookies marked
`SameSite=None` (and unmarked ones); `SameSite=Lax` and `Strict` cookies — which most sign-ins
use now — are never sent to a frame, whatever the board does, and storage (localStorage,
IndexedDB) is partitioned, so the frame doesn't see what the site stored in a tab. Measured on
macOS 26 with WebKit's own settings:

- Public pages (Wikipedia, docs, news, dashboards with public links) work fully.
- Sites whose session cookie is `SameSite=None` (apps made to be embedded often are) are signed
  in as you, once you have signed in to them in a tab.
- Sites with Lax/Strict session cookies (GitHub and Google among them) show signed out in a
  frame however you sign in. **Sign in** in the bar opens the frame's page in a tab — where it is
  the site itself, with every cookie, your passwords and passkeys — and the frame reloads when you
  come back to the board, picking up whatever of that sign-in a frame may carry. For the rest,
  **Open in a tab**. Passwords and passkeys are not offered inside a frame (Copper's passkeys
  answer only the site you are on, and the board is not that site).
- Sites that refuse to be framed (`X-Frame-Options`, `frame-ancestors`) load anyway in the board —
  the board's view, and only it, turns on WebKit's `IgnoreIframeEmbeddingProtectionsEnabled`. A
  page that still shows nothing — one that hides itself when framed, a load that never arrives —
  gets a card: *\<host> doesn't allow embedding · Open in tab · Try again · Show as card*.

What would change it, and why Copper doesn't: turning off WebKit's third-party cookie blocking
(`_setThirdPartyCookieBlockingMode:` on the store) works, but for the whole store — every tab of
the space, every tracker on every page — so it stays off. Serving the board from a custom scheme
instead of `file://` changes nothing: the board would still be cross-site to every site.
`_setShouldRelaxThirdPartyCookieBlocking:` is Safari's alone (WebKit throws for anyone else), and
the `IsThirdPartyCookieBlockingDisabled` feature has no effect for an app.

### How it works

- **Page** (`Canvas/src/canvas/frames.ts`, `components/WebFrame.tsx`): the iframe is sandboxed
  (`allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox
  allow-modals allow-downloads allow-storage-access-by-user-activation
  allow-top-navigation-by-user-activation` — never `allow-top-navigation`, so a frame-buster can't
  take the tab), `allow="fullscreen; clipboard-write; autoplay; encrypted-media;
  picture-in-picture"` (no camera, mic or location), and named `copper-frame:<shape id>:<nonce>`;
  the nonce is made per mount and never leaves the page. The page's CSP allows `frame-src https:
  http:` and still `connect-src 'none'`.
- **Host** (`Sources/Search/Fork/Canvas/CanvasFrames.swift`): a user script in every subframe of
  the board, in a content world of its own (`CopperCanvasFrames`, out of the site's reach), reads
  the frame's name at document start — before the site's scripts can change it — and, only in a
  frame directly on the board with a `copper-frame:` name, reports to its own handler
  (`copperFrame`): `nav` (address, title, https icon; on load, history changes, and a 1 s check
  while visible), `escape` (Esc the site didn't use) and `blank` (the page hid itself). The
  handler drops anything from the main frame or another web view, an address not on the origin
  WebKit says the frame is on, or a name that isn't the board's, and hands the rest to the page:
  `copperCanvas.frameEvent({name, kind, url?, title?, icon?})`. After `init` the host says
  `copperCanvas.frameHost({reports: true})`; from then on a frame that loads without reporting
  shows the "doesn't allow embedding" card. The `canvas` handler still answers the main frame
  only, so a framed site can't speak for the board.
- **Popups.** A window a frame opens (`window.open`, "Sign in with…") and a `target=_blank` or
  `_top` link are ordinary tabs in front (`CanvasHost.popup`, `CanvasHost.decide`), never a view
  built from the board's configuration; the opener link is lost, so a popup sign-in finishes in
  the tab.
- **Not in a frame:** the ad blocker (a board's view carries no content rules), Copper's password
  and passkey helpers, extensions, and the hide-something picker — a frame is the site as WebKit
  shows it. A frame that is a PDF or another document no script runs in may show the "doesn't
  allow embedding" card; Open in tab shows it.
- `./bench canvas frames [ID]` shows what the host passed on, whether the embedding preference is
  on, and the board's cookie store.

## Where things are kept

`Application Support/Copper/canvas/` (a probe world's own folder under `SEARCH_PROBE`):

| file | what |
|---|---|
| `canvases.json` | the registry: `[{id, name, kind: personal\|shared\|local, remoteId?, createdAt, updatedAt, role?, owner?, members?, account?}]` |
| `me.json` | this Mac's persona (stable id + colour, shown when signed out) and which account the local Personal history was first bound to |
| `<id>/updates.log` | every Yjs update the page reported **and every update the room handed the page** (a sync message's SyncStep2 / update payload, kept as it is delivered), in order: 4-byte big-endian length + bytes |
| `<id>/snapshot.bin` | the whole document as one update, written when the log passes 2 MB or 500 entries (the page's `exportState()`), after which the log keeps only what came after |

Opening a canvas hands the page `snapshot.bin` as `init.state`, then every logged update through
`applyUpdate`. Yjs makes a repeated update harmless, so compaction only ever errs on the side of
keeping too much (it drops the entries that existed when the export was *asked for*). A record cut
short by a crash is trimmed on the next read.

Personal belongs to one account: the first account it is relayed to is remembered, and a
*different* account signing in on the same Mac gets a fresh local Personal history
(`personal-<userId>/`) so two people's private boards never merge.

**Personal syncs only when chosen.** Its room is a sync domain like the others —
`CloudSync.Domain.canvas`, "Personal canvas" in Settings › Cloud › Choose what syncs, included in
`cloud sync on all`, off until picked, paused by *Turn off* and by signing out. The switch is kept
in `cloud-sync.json` (`canvas`, beside the sync bases; `Cloud.SyncPrefs` in cloud.json has no
field for it yet). `Canvases.room(for:)` gives Personal a room only when
`CloudSync.shared.syncs(.canvas)` and the row's `account` is the account signed in; with every
switch off nothing on the Personal board leaves the Mac. Shared canvases are cloud documents by
definition and keep their room whenever their account is signed in.

## What happened to easels

Copper had a second board, **Easels** (local only, its own Yjs schema, served from a
`copper-easel://` scheme of its own). It was folded into Canvas: Canvas is the engine — it syncs,
shares, invites and has the agent tools — and Easels gave it its ways in, its row and its lean tab
(the sections above). The Easel engine, its scheme and its web bundle are gone; what is left is
`CanvasImport.swift`, which brings each easel a Mac still has into a canvas the first time a
build with Canvas-only starts:

1. **Before the session is restored**, every easel in `easels/index.json` that
   `easels/migrated.json` doesn't list gets a **local canvas with the same name and dates** (an
   easel still called *Untitled Easel* becomes *Untitled canvas*), and the mapping is written down.
   From then on an easel's old address — in the session file, a favourite, a bookmark, a link, the
   address field — is that canvas's; one whose easel never became a canvas is dropped from the
   session ("That easel isn't in Canvas yet" when opened by hand).
2. **A moment after the window is up**, each easel not yet done is loaded into its canvas's page
   in a view nobody sees (the same configuration, bridge and `CanvasHost` a canvas tab uses, so
   every update goes to the canvas's history the ordinary way), and the page is handed the old
   document and its pictures: `copperCanvas.importLegacy({doc: <base64 of doc.yjs>, files:
   {<fileId>: <data: URL>}, title})`, which turns stickies, frames (title and picture), arrows
   (`from`/`to` = `shape:<id>`, the label) into canvas shapes in one transaction and answers
   `{imported, skipped, error?, already?}`. The page is then checkpointed (its whole document
   written as `snapshot.bin`) and let go. Fifteen seconds an easel at most; one at a time.
3. An easel is **done** when its board came over — wholly, or as far as it ever will (a picture
   that can't be read is said in `error`, not retried). A failure (a corrupt `doc.yjs`, a page
   that didn't come up) is logged (`canvas` category, "easel import: …"), stays not done, and is
   tried again on the next launch into the same canvas. The page remembers which documents it has
   imported (`meta.importedLegacy`), so a retry never puts a board's shapes on twice. A canvas
   deleted after its easel was done is never brought back.

**The easel folders are never deleted.** `easels/` (index, `viewer.json`, every `<id>/doc.yjs` and
`files/`) stays where it was, beside `migrated.json`:

```
easels/migrated.json   {"easels": {<easel id>: {canvas, done, imported, skipped, error?, tries, at}}}
```

Removing an entry (or the file) and relaunching runs that easel's import again — into its old
canvas if it still exists, else a new one. `bench canvas import` shows the records;
`bench canvas import run` runs whatever is not done, now.

## The cloud

With a cloud linked and signed in (`Fork/Cloud/`), `GET /v1/canvases` fills the list (Personal is
matched to the server's `kind=personal` canvas) and `GET /v1/invites` the invites — refreshed when
the card opens and on every `canvas` event from `/v1/sync/events`. A canvas with a room is relayed
over a pinned `CloudSocket` to `wss://<host>/v1/canvases/<id>/ws` (backoff 1 → 30 s, ±30 % jitter).
The page runs y-websocket's provider over a bridge socket; Copper only moves frames, and holds the
server's greeting (its SyncStep1 + awareness) until the page's socket is open — the SyncStep1 is
what makes the page send what the room is missing, which is how an offline Personal history or an
edit made while the server was down reaches it. A new page socket (`wsOpen`) gets a fresh
connection, so it always gets a greeting of its own; `wsClose` drops the room. Live collaborators
are counted from the awareness frames on the wire (a frame may hold several y-protocol messages),
**by person** — the state's `user.id` — so you in a second tab or on another Mac are not a
collaborator; a state not renewed for 45 s has gone. Sign-in or sign-out reloads open canvas pages
so their provider starts or stops. After a couple of connections that never open (a revoked
member, a deleted canvas — `CloudSocket` doesn't surface the 4403/4404 close codes) the list is
read again, and a canvas gone from it closes its tabs.

**Which room, for whom.** A page is told its room once, in `init`; the host remembers that room id
(`roomId`). Signing in or out, another account, the Personal switch (`CloudSync.didChange`) and
every list read (`Canvases.refresh`) compare it with what `room(for:)` says now; a page whose room
is no longer the right one — or whose history is another account's (`storeKey`) — is
**checkpointed and reloaded** (`restartPage`), so its provider starts, stops or moves rooms. The
list is keyed to the account it was read for: a different account signing in starts with no list
(the first page open waits up to 1.5 s for it) and an answer that arrives after a switch is
dropped and asked for again. The 20 s sweeper repeats the comparison (a notice missed) and gives a
live page that lost its room a new one, so a page never stays on "online, no room".

**Nothing a collaborator wrote is lost to a disconnect.** The page reports only its own changes;
what its provider applied from the room it never reports. So the host keeps those itself, as it
hands them over (`CanvasHost.hand` → `CanvasStore.appendRemote`, deduplicated across two tabs on
one canvas, and handed to the sibling tab too): a sync message's SyncStep2 or update payload is a
whole v1 Yjs update, the same as the page's own. Frames for a socket that never opened are not
kept (the page never had them; the next sync brings them). Before a page is let go for a room
change, the whole document is exported (`exportState`) and written as `snapshot.bin` by atomic
rename (`checkpoint`, two seconds at most) and the store's queue is flushed; closing a tab,
navigating it away and quitting (⌘Q, SIGTERM in a probe, an update's relaunch:
`NSApplication.willTerminateNotification` → `CanvasStore.flushAll`) flush too. Compaction stays
safe because every update counted in the log was *posted* to the page before the export is asked
for (`post` issues the call at once, and WebKit runs one view's calls in order). While a room has
brought anything in the host still folds the log into a fresh snapshot every two minutes.

**The page's status line** is told with `copperCanvas.setStatus({mode, pending})` whenever it
changes (when the page has the function): `local` (Personal or a local canvas, on this Mac by
design), `personal-synced`, `shared-live` (room open and the server's SyncStep2 received) or
`shared-offline` (a shared board with no room: signed out, disconnected, the server away), and
`pending` — changes made here since the room last confirmed a sync.

Create `POST /v1/canvases {name}`, rename `PATCH /v1/canvases/:id`, delete `DELETE
/v1/canvases/:id` (owner), leave `DELETE /v1/canvases/:id/members/<me>`, members `GET
/v1/canvases/:id/members`, invite `POST /v1/canvases/:id/invites {email}` (on 0.5.0 a second one
for the same address is a reminder: `200` with `nudged`), the invites waiting on a canvas `GET
/v1/canvases/:id/invites`, withdraw one `DELETE /v1/canvases/:id/invites/:invite_id` (0.5.0), answer
`POST /v1/invites/:id/accept|decline`.

## The page ↔ host bridge

The page is one self-contained file, `Sources/Search/Fork/Canvas/Resources/canvas.html`
(`build.sh` copies a newer `Canvas/dist/canvas.html` over it), loaded with
`loadFileURL(…canvas.html?id=<id>, allowingReadAccessTo: <its folder>)`. There is no URL scheme
handler: `copper://canvas/…` is caught in the browser's navigation delegate
(`CanvasHost.decide`) and the tab keeps the copper:// address. Canvas tabs opened through
`Browser.open` or the session get their own `WKWebViewConfiguration` with the `canvas` handler on
it before the view exists and no extensions attached; any other tab told to go to a canvas gets
the handler when the page is loaded into it. The handler answers only the bundled page's main
frame in a web view that is a canvas host's.

Page → host, `window.webkit.messageHandlers.canvas.postMessage({...})`:

| message | host does |
|---|---|
| `{type:"ready"}` | `init(...)`, then `applyUpdate` for each logged update, `theme(...)`, `document.title`, then opens the room if there is one |
| `{type:"update", b64}` | appends to `updates.log`, hands it to any other tab on the same canvas; compacts when due |
| `{type:"selection", ids}` | kept for the tools |
| `{type:"share"}` | the page's own Share button was clicked — opens the native Share sheet |
| `{type:"presence", people:[{id,name,color,kind}]}` | debounced (≤500 ms) on every change; kept per canvas for the Share sheet's "N here now" faces |
| `{type:"ws", b64}` | sent on the room's socket |
| `{type:"wsOpen"}` / `{type:"wsClose"}` | the page's socket wants / no longer wants the room — answered with `wsState("open")` when the room is up |
| `{type:"openUrl", url}` | http(s) in a new tab in front; `copper://canvas/…` switches to that canvas |
| `{type:"log", level, msg}` | os_log (subsystem `com.collinrijock.copper`, category `canvas`) |

Host → page, always with `callAsyncJavaScript(arguments:)` in the page world (values travel as
arguments, never pasted into source), so a function may return a value or a promise:

- `copperCanvas.init({docId, name, kind, me:{id,name,color}, state: b64|null, online, readOnly})`
- `copperCanvas.applyUpdate(b64)`, `wsMessage(b64)`, `wsState("open"|"closed")`
- `copperCanvas.apply(opsJsonString, who) → resultJson` — `who` is `{id, name, color}`
- `copperCanvas.read('{"full":false}') → json`
- `copperCanvas.select(ids)`, `zoomTo(ids)`, `setAgent({id,name,color,cursor,status})`,
  `theme("light"|"dark")` (pushed again whenever the view's appearance changes)
- `copperCanvas.exportState() → b64` (optional; without it the log is simply never compacted)
- `copperCanvas.setStatus({mode: "local"|"personal-synced"|"shared-live"|"shared-offline", pending})`
  (optional; called only when `typeof setStatus === 'function'`)
- `copperCanvas.setShare({canShare, members?, reason?})` — shows/enables the page's own Share
  button; called after `ready` and whenever the entry, its membership or the cloud link changes
  (guarded: `typeof setShare === 'function'`, for a bundled page older than this)
- `copperCanvas.frameEvent({name, kind:"nav"|"escape"|"blank", url?, title?, icon?}) → bool` and
  `frameHost({reports})` — live web frames' reports ([Live web frames](#live-web-frames)); from
  the `copperFrame` handler, in its own content world, never the `canvas` one
- `copperCanvas.presence() → [{id,name,color,kind,cursor}]` (read, not pushed — used by `bench
  canvas presence` and anything checking live cursors, not just the Share sheet's faces)

`me` is the cloud account (`userId`, display name) when signed in, else this Mac's persona (the
macOS full name, a stable colour). `docId` is the server's canvas id when there is one.

## The tools (⌘E agent, MCP, `copper call`)

All in `CanvasTools.swift`, dispatched from `Tools.call`, so all three surfaces get the same
behaviour; every call shows in the Driver pane and every write is attributed (`by`) to the caller:
the MCP client's name (`Claude Code`, `phi`, `copper CLI`…), **Copper agent** for ⌘E, or `as`.
The agent's presence (`setAgent`, cursor on the last shape it touched) is a two-second lease:
each operation renews it, then the cursor fades and its face leaves the collaborator list.
Closing the page or disconnecting releases that page's agent leases; stale leases from a lost
peer are hidden on expiry too. Human collaborators and the shapes' author attribution stay.

| tool | arguments | answer |
|---|---|---|
| `canvas_list` | — | `{canvases:[{id,name,kind,open,live,collaborators,url,updatedAt,role?,members?}], cloud}` |
| `canvas_open` | `id` (or name) \| `name`, `foreground?` | the canvas's summary, once its page is up (background by default) |
| `canvas_read` | `id?`, `full?` | `{canvas:{id,name,kind}, viewport, shapes:[{id,type,x,y,w,h,color,text\|title\|label\|url,by}], agents, selection}` |
| `canvas_apply` | `id?`, `ops` (required), `as?` | `{applied, ids, errors}` |
| `canvas_select` | `id?`, `shapeIds` | — |
| `canvas_focus` | `id?`, `shapeIds` | — (zooms the view to them) |
| `canvas_create` | `name` | the new canvas's summary (shared when signed in, local otherwise) |
| `canvas_invite` | `id`, `email` | — (cloud only; Personal and local canvases refuse with a reason) |
| `canvas_share_link` | `id` | `{link, webLink}` — makes the canvas's invite link once, then reuses it |
| `canvas_join` | `link` | opens a `copper://canvas/join/...` or `https://<cloud>/join/...` link in this window, as if it had been clicked |
| `canvas_screenshot` | `id?` | PNG of the canvas tab |

`id?` omitted means the canvas tab in front, else Personal. Every schema also takes `reason`.
Each call leaves its one line in `Tools.summary` — *220 operations applied on Roadmap*, *Read 7
shapes on Personal*, *Invited ada@example.com to Roadmap*, *Selected 2 shapes…*, *Created …* —
which rides as `_meta.summary` and is what the Driver pane's row says after the arrow (MCP and the
⌘E agent alike). Canvas tools never report "page changed / no change": they change a board, not
the page.
Ops: `add {shape:{type, x?, y?, w?, h?, color?, …}}` (no x/y → free space near the view),
`update {id, patch}`, `move {id, dx, dy}`, `resize {id, w, h}`, `delete {id}`, `connect {from, to,
label?}`, `clear {confirm:true}`. Colours: yellow, pink, blue, green, purple, gray, white, `#hex`.

```sh
copper tools | grep canvas_
copper call canvas_apply '{"reason":"jot it down","ops":[{"op":"add","shape":{"type":"sticky","text":"hello"}}]}'
copper call canvas_read '{"reason":"what is on the board"}'
copper call canvas_share_link '{"reason":"invite a teammate","id":"Roadmap"}'
```

## Sharing a canvas (invite links, Share sheet, join flow)

*Native Swift: `Sources/Search/Fork/Canvas/CanvasShare.swift`. Server:
`copper-cloud`'s `/v1/canvases/:id/links`, `/v1/canvas-links/:token`, `/join/:token` (not under
`/v1`, no instance-key gate — a tiny static landing page), `/v1/people`.*

**Link formats.** Copy invite link gives `copper://canvas/join/<token>?cloud=<host[:port]>&n=<url-encoded
name>`; Copy web link gives `https://<host[:port]>/join/<token>`. `copper` is registered as its own
macOS URL scheme (`build.sh`'s Info.plist — a second `CFBundleURLTypes` entry, "Copper link",
separate from the "Web address" http/https one, `CFBundleTypeRole` Viewer) alongside http/https, so
mail clients, Slack, anywhere a link can be clicked, hands it to Copper. Canvas ids are UUIDs or
`personal`, so `copper://canvas/join/...` can never collide with `copper://canvas/<id>`.

**The Share sheet** (`CanvasShareSheet`) opens from the page's own Share button (the `share`
bridge message), the sidebar canvas row's **Share…** (replacing the old **Invite…**), and the
command bar's **Share Canvas**. It shows who is live right now (the canvas's `presence`
messages: *Only you here* with the canvas open and nobody else in it, *N here now* counting you,
nothing when it isn't open here and nobody is in it), **Copy invite link** / **Copy web link** (the
token is made once through `POST /v1/canvases/:id/links` and cached per canvas in
`canvas/share-links.json`, 0600, never the keychain — later copies reuse it), **People on this
cloud** (*Search people or type an email*: debounced `GET /v1/people?q=`; a typed address that
isn't a member gets its own row; every Invite is the email-invite path, `POST
/v1/canvases/:id/invites`), **Members** (owner can remove), **Invited** (the invites waiting on
this canvas, `GET /v1/canvases/:id/invites`, read with the members when the sheet opens and on
every list refresh — someone accepting or declining shows while it is open), and **Reset link**
(owner; `DELETE /v1/canvases/:id/links`, drops the cached token). A local or Personal canvas
explains it can't be shared and offers **New shared canvas** or **Connect to Copper Cloud**
instead. The sheet's state is a `CanvasShareModel` that `CanvasUI.mode` makes and drops, so
`bench canvas ui share state|type TEXT|invite [EMAIL] [--instant]|resend EMAIL|withdraw
EMAIL|reload|copy` reads and drives the same sheet a person sees.

**Where each person stands.** Every person's row — a directory row, the typed address's row, an
Invited row — says one of: **You**; **Owner** / **Member** (with the role on hover); **Invited**
(· **Resend** · **×**); or an **Invite** button. Clicking Invite flips the row to *Invited* at once
(a stand-in invite until the server's copy arrives; it goes back, with the reason, if the server
says no) and the line right under the field — above the rows, so a long list never pushes it out
of the card — says what happened: *Invited Tim Child — it's waiting for them in Copper*, or
*Invited dana@example.com — waiting for them to make an account on \<host>* when no account has
that address yet. The rows, Members and Invited scroll together below that line (360 pt at most),
vertically only.

- **Resend** invites the same address again. On copper-cloud 0.5.0 that is a reminder: the server
  stamps the invite's `nudged_at`, answers `"nudged": true` and sends the invitee a `canvas` event,
  so the pill comes back up in their Copper — *Reminded Tim Child*. It reminds someone at most every
  30 s, counting from the invite itself (*Invited Tim Child moments ago — you can remind them in a
  minute*). It is not offered for an address with no account yet (there is no Copper to bring it
  up in; the row's second line says *No account on \<host> yet*). Any member may resend.
- **×** withdraws the invite (`DELETE /v1/canvases/:id/invites/:invite_id`, 0.5.0): the row goes at
  once, the sheet says *Withdrew the invite to Tim Child*, and the invitee's pill and Invitations
  row go on the `invite_revoked` event. Only the canvas's owner, or whoever sent that invite, sees
  it. A refusal is a sentence (*That invite was already answered or withdrawn.*).
- **On a cloud before 0.5.0** (`Cloud.Feature.inviteReminders`, by `/v1/info`'s version) there is
  no Resend and no ×: inviting again reminds nobody there and an invite can't be taken back, so
  the row only says *Invited* (its help: *Waiting for them to join — it's in their Copper*) and
  the Invited list still shows every invite waiting. The confirmation reads the same; whether an
  address has an account is known only from the directory (an address it looked up and didn't
  find: *…waiting for them to make an account on \<host>*).

`canvas_invite` answers in the same words, naming the canvas: *Invited Tim Child to Roadmap*,
*Reminded Tim Child about Roadmap*, *Tim Child was invited to Roadmap moments ago — too soon to
remind them*, or on an older cloud *tim@example.com was already invited to Roadmap*. `canvas_list`
adds `invitations: [{canvas, from}]` while any invite waits for the user's answer.

**Older clouds.** Share links and the people directory arrived in copper-cloud 0.3.0. Copper
reads the instance's version from `GET /v1/info` (`Cloud.serverVersion`, once per link and again
whenever the event stream reconnects; `Cloud.supports(.shareLinks)`), and with the version
unknown takes a bare route-level `404 not_found` from `/v1/people` or a links route as "this
instance hasn't got it" (`Cloud.lacks`). Against an older instance the sheet hides Copy invite
link, Copy web link and Reset link, never calls `/v1/people`, and says one quiet line — *Invite
links need Copper Cloud 0.3.0 — \<host> runs \<version>. You can still invite people by email.* —
with the field titled **Invite by email**. Email invites work on every version. No failure in
the sheet shows the server's own short text ("not found", "conflict"): `Canvases.plain` turns
each refusal into a sentence (an address that isn't one, yourself, someone already a member, a
canvas no longer there, a cloud that can't be reached), and a success reads *Invited \<name> —
it's waiting for them in Copper*.

**The join flow** (`CanvasJoinLink.parse` + `CanvasJoinFlow`) is one parser and one actor reached
from four places: LaunchServices/AppleEvents (`Links.swift`), the address bar (`Browser.arrive` /
`Browser.go`), an in-page link click (`Browser`'s `WKNavigationDelegate`, which cancels the
navigation), and any tab navigating to the `https://.../join/<token>` form when its host\[:port]
is the cloud this Copper is linked to (a different cloud's landing page is left to load as an
ordinary page, which is where its own "Open in Copper" button lives). Not linked, or linked to a
different cloud: Settings › Cloud opens with *"This canvas is on \<host>. Connect to that Copper
Cloud to open it."* Not signed in: the link is remembered (`canvas/pending-join.json`, 0600) and
resumed the moment sign-in completes. Otherwise: `GET /v1/canvas-links/:token` (already a member
→ just open it), else `POST /v1/canvas-links/:token/join`, upsert the returned row, refresh, then
open it in the **key window** (so an external open lands somewhere sane), in front. A 404
`link_not_found` says *"This invite link no longer works — ask for a new one."*; an instance
before 0.3.0 (by its version, or by a bare `not_found` for the route) says *"This Copper Cloud
doesn't support invite links yet (runs \<version>)."* `canvas_join` waits for the outcome and
answers with it.

**Being invited** (`Fork/Canvas/CanvasInvites.swift`). Three places say an invite is waiting, all
reading `Canvases.invites` (`GET /v1/invites`, read again on every `canvas` event — `invited`,
`invite_revoked`, `invite_declined`, `member_added` — and whenever the event stream comes back):

- **The pill** at the window's foot: *"\<sender> invited you to “\<name>” · Open ×"*. It rises
  for every invite waiting the first time the list is read after a launch or a sign-in, for each
  new one after that, and again whenever its sender reminds you (the invite's `nudged_at` moved —
  it then reads *"\<sender> reminded you about “\<name>”"*). **Open** joins and opens the canvas
  in front; **×** is *Not now* — the pill goes, the invite stays under Invitations, and a reminder
  or the next launch brings the pill back. An invite withdrawn or answered on another Mac takes
  its pill with it. The pill is drawn **over the panels** — Settings, History, Downloads,
  Passwords — so signing up in Settings › Cloud no longer hides the invite that was waiting for
  the new account (`CanvasInviteBar`, overlaid after `panels` in `App.swift`; `CanvasInviteSlot`
  keeps its place in `bars`, so the other lines there stack above it).
- **Invitations** in the Canvas card (above), with Decline / **Join**, for as long as it waits,
  and the dot on the door.
- **⌘K**: *Join Canvas · \<name>* for each invite waiting (type *join* or the canvas's name) —
  the way in when the sidebar is off.

## Testing it

Only in a probe world — never the windowed Copper on 4123:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=-; ./build.sh
defaults write com.officecommun.search.test.canvase bench -bool true     # the bench socket for this world
open -n -g --stderr /tmp/copper-canvas.log --env SEARCH_PROBE=canvasE --env SEARCH_HEADLESS=1 \
  --env SEARCH_MCP_PORT=4161 --env SEARCH_HEADLESS_SIZE=1440x1000 build/Copper.app
export SEARCH_PROBE=canvasE SEARCH_MCP_PORT=4161
C=build/Copper.app/Contents/Resources/bin/copper
$C health; $C tools | grep canvas_
$C call canvas_open '{"reason":"t","id":"personal","foreground":true}'
$C call canvas_apply '{"reason":"t","ops":[{"op":"add","shape":{"type":"sticky","text":"hello"}}]}'
$C call canvas_read '{"reason":"t"}'
$C shot /tmp/canvas.png
./bench --world canvasE canvas hosts      # each open canvas: ready, online, roomId, room, synced, status{mode,pending}, clients, collaborators, store
./bench --world canvasE canvas list | open ID | read [ID] | apply JSON | create NAME
./bench --world canvasE canvas invites | accept INVITE | decline INVITE      # INVITE: id or canvas name; invites also says the pill's
./bench --world canvasE canvas pill [dismiss|open]                          # the invite pill: what it shows; its × (Not now) and Open
./bench --world canvasE canvas pending ID                                   # the invites waiting on canvas ID, as its members see them
./bench --world canvasE canvas remind ID EMAIL | withdraw ID EMAIL          # invite again (a reminder on 0.5.0) / take an invite back
./bench --world canvasE canvas ui share resend EMAIL | withdraw EMAIL       # the Share sheet's Resend and × (after ui mode share ID)
./bench --world canvasE canvas rename ID -> NAME | delete ID | leave ID | members ID
./bench --world canvasE canvas ui mode new | picture /tmp/card.png [dark]  # the card, drawn off screen
./bench --world canvasE canvas new | tabs [ID] | menu [press] | flush ID    # ⌘K's New Canvas; every canvas's tabs (window, space, section, row, asleep, lean, mark, pill)
./bench --world canvasE canvas click X Y [N] | draw X,Y X,Y …               # real mouse input on the board in front, page CSS px
./bench --world canvasE canvas scroll DX DY [STEPS] [--zoom] [--app] | scroll stats   # a trackpad gesture (CGEvent, phased, 8 ms apart)
./bench --world canvasE canvas perf start | stop | lean                     # rAF frame times + wheel lag; what the tab was spared
./bench --world canvasE canvas ask-rename ID | ask-delete ID | answer rename NAME|delete|leave|cancel | sheet
./bench --world canvasE canvas rowmenu ID /tmp/menu.png | picture /tmp/window.png   # the row's menu; the window with its popover/sheet
./bench --world canvasE canvas import [status|run]                          # the easel migration
./bench --world canvasE canvas link [ID]                                    # make/reuse the invite link for ID (default: the front canvas): {link, webLink}
./bench --world canvasE canvas join LINK                                    # open an invite link the way clicking it would
./bench --world canvasE canvas presence [ID]                                # copperCanvas.presence() for ID right now: who's in the room, with cursors
./bench --world canvasE canvas parsetest                                    # self-test of the join-link parser (pure, no network, no window)
```

`canvas scroll` makes each event with CGEvent and gives it the board's window, so it is what a
trackpad's is to AppKit and WebKit; `--app` sends it through `NSApp.sendEvent` so the app's
monitors (the space swipe) see it first. Headless, the row's sheets are held open for `canvas
answer` instead of being declined (every other alert is), and `canvas picture` draws a held sheet
where it would hang; `canvas rowmenu` reads the real menu, puts it away at once, and draws its items
over the row (a parked window's menu would otherwise open on somebody else's screen).

Don't open the card's popover in a headless probe (`canvas ui open`): AppKit can loop on an
off-screen popover's constraints and abort the run — draw it with `ui picture` instead.

Two Coppers sharing a canvas, against a local copper-cloud with `tls.mode = "off"` (Cloud accepts
`http://` for a loopback host): run two probe worlds (`SEARCH_PROBE=canvasE` / `canvasF`, MCP ports
4161 / 4162), sign each in, `canvas_create` + `canvas_invite` on one, `bench canvas accept NAME` on
the other, then `canvas_apply` on either and `canvas_read` on the other.

`docs/fixtures/canvas-fixture.html` is a stand-in page with the same API over a plain map
(updates are base64 JSON) — copy it over `Resources/canvas.html` to exercise the host without the
real bundle.
