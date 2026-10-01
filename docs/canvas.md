# Canvas — a whiteboard in a tab

*An infinite board of stickies, text, frames, arrows, images and links that lives in an ordinary
Copper tab at `copper://canvas/<id>`. One **Personal** canvas always exists, works with no
network and no account, and is never shared — it stays on this Mac until you choose **Personal
canvas** in Settings › Cloud › Choose what syncs; with Copper Cloud signed in you can make shared
canvases, invite people, and see each other — and each other's agents — live. The ⌘E agent, MCP
agents and the `copper` CLI all read and write the same boards. Implementation:
`Sources/Search/Fork/Canvas/` (the page itself is built from `Canvas/`).*

## Using it

- **Sidebar › Canvas door** (at the foot, beside Bookmarks and Extensions): Personal, *My
  canvases*, *Shared with me*, *Waiting for you* (invites, with Accept / Decline) and **New
  canvas**. Click a row to open it — an open canvas is switched to, never opened twice. Right-click
  a row: Open, Open in Background, Copy Link, Rename…, Invite…, Members…, Leave… / Delete….
- **View › Canvas ⌘⇧O** opens Personal; **View › New Canvas…**; ⌘K / ⌘T: *Open Personal canvas*,
  *New canvas…*, *Open canvas <name>*. Typing or pasting `copper://canvas/<id>` (or just
  `copper://canvas` for Personal) into the address field works too.
- The tab reads **Canvas › <name>** in the row and the address pill. It restores with the session,
  sleeps and wakes like any tab (the board comes back from disk), and links clicked on the board
  open in a tab of their own — a canvas tab never navigates away by itself.
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
```

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
```

Don't open the card's popover in a headless probe (`canvas ui open`): AppKit can loop on an
off-screen popover's constraints and abort the run — draw it with `ui picture` instead.

Two Coppers sharing a canvas, against a local copper-cloud with `tls.mode = "off"` (Cloud accepts
`http://` for a loopback host): run two probe worlds (`SEARCH_PROBE=canvasE` / `canvasF`, MCP ports
4161 / 4162), sign each in, `canvas_create` + `canvas_invite` on one, `bench canvas accept NAME` on
the other, then `canvas_apply` on either and `canvas_read` on the other.

`docs/fixtures/canvas-fixture.html` is a stand-in page with the same API over a plain map
(updates are base64 JSON) — copy it over `Resources/canvas.html` to exercise the host without the
real bundle.
