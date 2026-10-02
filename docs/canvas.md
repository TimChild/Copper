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
- **Sidebar › Canvas door** (at the foot, beside Bookmarks and Extensions): Personal, *My
  canvases*, *Shared with me*, *Waiting for you* (invites, with Accept / Decline) and **New
  canvas**. Click a row to open it. Right-click a row: Open, Open in Background, Copy Link,
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
  nothing. An invitation row shows the whole name and who sent it above Decline / **Accept**, says
  *Joining…* in the row while the answer is on its way, and stays — with the reason, in the row —
  until the server has said yes.

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
/v1/canvases/:id/members`, invite `POST /v1/canvases/:id/invites {email}`, answer `POST
/v1/invites/:id/accept|decline`.

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
- `copperCanvas.presence() → [{id,name,color,kind,cursor}]` (read, not pushed — used by `bench
  canvas presence` and anything checking live cursors, not just the Share sheet's faces)

`me` is the cloud account (`userId`, display name) when signed in, else this Mac's persona (the
macOS full name, a stable colour). `docId` is the server's canvas id when there is one.

## The tools (⌘E agent, MCP, `copper call`)

All in `CanvasTools.swift`, dispatched from `Tools.call`, so all three surfaces get the same
behaviour; every call shows in the Driver pane and every write is attributed (`by`) to the caller:
the MCP client's name (`Claude Code`, `phi`, `copper CLI`…), **Copper agent** for ⌘E, or `as`.
The agent's presence (`setAgent`, status `writing` → `idle`, cursor on the last shape it touched)
shows on the board.

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
isn't a member gets its own **Invite \<email>** row; every Invite is the email-invite path,
`POST /v1/canvases/:id/invites`), **Members** (owner can remove), and **Reset link** (owner;
`DELETE /v1/canvases/:id/links`, drops the cached token). A local or Personal canvas explains it
can't be shared and offers **New shared canvas** or **Connect to Copper Cloud** instead. The
sheet's state is a `CanvasShareModel` that `CanvasUI.mode` makes and drops, so `bench canvas ui
share state|type TEXT|invite [EMAIL]|copy` reads and drives the same sheet a person sees.

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
canvas no longer there, a cloud that can't be reached), and a success reads *Invited \<email> —
they'll see it in Copper*.

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

**The new-invite banner** (`ContentView.inviteBanner` in `App.swift`) rises the moment
`Canvases.refresh()` sees an invite id it hasn't shown before: *"\<owner> invited you to
“\<name>” · Open"*, with a dismiss × that declines without opening. **Open** accepts and opens
the canvas in one step — it is a shortcut over the sidebar's existing Accept/Decline invite rows,
not a second invite system.

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
./bench --world canvasE canvas invites | accept INVITE | decline INVITE      # INVITE: id or canvas name
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
