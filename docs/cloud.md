# Copper Cloud — sync through an instance you run

*Settings › Cloud (or ⌘K › Copper Cloud…). Copper links to **one** self-hosted
[copper-cloud](https://github.com/Exowatt-Labs/copper-cloud) instance at a time,
signs in to an account on it, and syncs the parts of the browser you switch on.
Off until you turn it on; nothing leaves the Mac before that.
Implementation: `Sources/Search/Fork/Cloud/`.*

## Setting it up

Three steps on the page, in order:

1. **Connect.** Paste the link code the server printed — `install.sh` prints it
   when it finishes, and `copper-cloud link-code` prints it again:

   ```text
   copper-cloud://HOST:PORT/#k=<instance key>&fp=<sha256 of the certificate>
   ```

   The page shows the host and the certificate fingerprint before anything is
   sent; compare the fingerprint with `copper-cloud doctor` on the server if
   you want to be sure. **Connect** checks `/healthz` through the pinned
   certificate and that the instance accepts the key, then keeps the link.
   *Enter it by hand* takes the address, key and fingerprint as three fields.
2. **Account.** *Sign in*, or *Create account* (email, a password of at least
   10 characters, the name shown beside your cursor on shared canvases). The
   first account on an instance is its admin; an instance can close sign-up
   after that, and then its admin creates accounts (`copper-cloud admin`).
3. **Sync.** Choose what syncs, press **Turn on sync**. The first sync merges
   this Mac with whatever the cloud already has — nothing on either side is
   thrown away.

After that the page shows the sync switches (each takes effect at once), the
status and **Sync now**, the account (sign out, rename this Mac), the tabs
open on your other devices, the instance (disconnect), and a log.

## What syncs

| Switch | What | Notes |
|---|---|---|
| Spaces and kept tabs | Every space — name, colour, icon, theme, profile *name*, order — and its pinned and Saved tabs | Today's tabs stay on the Mac. A tab is matched across Macs by its space, its section and its site, so browsing inside a pinned tab doesn't resend anything; its address is the one it had when it first synced. Tab groups/folders, the order of pins within a row, and a theme's own picture (a file in `themes/`; the built-in ones work) don't travel. A profile is a name: the cookie jar behind it is never synced. |
| Settings | The allowlist below | Never passwords, passkeys, paths, keys, accounts or agent setup. |
| Bookmarks | The whole tree, ids and folders kept | |
| Open tabs | This Mac's open (non-pinned) tabs, for the others to see under *On your other devices* | One way: another Mac's tabs never open here by themselves — click one to open it. Turning the switch (or sync) off publishes an empty list. |
| History | Places visited | Append-only: pushed in batches of 500 from where the last push stopped; pulled from where the last pull stopped. Clearing history here doesn't clear it on the server or other Macs. |

### The settings allowlist

Only these `Store.settings` keys sync, and only with values of the expected
shape (`CloudSettingsKeys` in `Fork/Cloud/CloudMerge.swift`):

| Key | Setting |
|---|---|
| `look` | Light / Dark / System |
| `sidebar` | Tabs in a sidebar |
| `glyph` | Letters or site icons |
| `tabs.switching` | ⌃Tab: next in the row or most recent |
| `tabs.sleep` | Put idle tabs to sleep |
| `spaces.swipe` | Swipe between spaces direction |
| `shield` | Block ads and trackers |
| `autocorrect` | Correct spelling in pages |
| `sections.archive` | When Today rows are archived |

Deliberately left out: `bench` (the script socket), `passkeys*`,
`passwords.*`, `autofill.everything`, `downloads` and `downloads.ask` (a path,
and where files land), `sidebar.width` (a screen's business), `welcomed`,
`settings.page`, everything in `agent.json`, `intelligence`/model keys,
Bitwarden, extensions and their grants.

## How merging works

`spaces`, `settings` and `bookmarks` are whole documents on the server, each
with a version. Every change here waits two quiet seconds, then the domain's
document is built from the live objects (Spaces, Preferences, Bookmarks) and,
if it differs from the copy last synced, `PUT` with that copy's version as
`base_version`. If another Mac wrote first the server answers 409 with its
copy, and Copper merges **three ways** — the copy last synced (the base),
this Mac's, the server's:

- changed on one side only → that side's;
- changed on both → **the server's** (for settings, key by key);
- missing on one side but in the base → deleted there, stays deleted (unless
  the other side edited it meanwhile — then the edit survives);
- not in the base → new, kept. With no base at all (the first sync) it is a
  plain union, the server winning where both have the same thing.

Bookmarks merge node by node (id, parent folder, title, address); a node whose
folder is gone surfaces at the top level rather than disappearing. Space order
follows the server unless only this Mac reordered.

The merged document is written back here **through the same objects the UI
uses** — `Spaces` edits, `Preferences` properties, `Bookmarks.replace` (one save),
`History.take` — with an `applyingRemote` guard so the write doesn't count as
a change, and is then `PUT` again. Pulls happen at sign-in, at *Turn on sync*,
whenever the event stream (re)connects, and on each `doc`/`history` event
another device's write causes (`GET /v1/sync/events`, server-sent events,
reconnecting after 1, 2, 4 … 30 s with jitter).

History is not a document: new visits go up with `POST /v1/sync/history`
(cursor `pushedThrough`, the newest visit already sent), other devices' come
down with `GET /v1/sync/history?since=…&exclude_device=me` (cursor
`pulledSeq`). A visit already known within one second is skipped; one merged
in from elsewhere is remembered so it isn't sent back up.

The per-domain state — the last-synced copy of each document and the history
cursors — lives in `cloud-sync.json` (0600) beside `cloud.json`; signing in as
another account starts it over.

## Security model

- **Pinning.** A self-signed instance's link code carries the SHA-256 of its
  leaf certificate (DER). Copper accepts the server's TLS certificate **if and
  only if** its fingerprint is that one — the Mac's trust store isn't
  consulted, so a self-signed instance works and nothing else can stand in for
  it, whatever CA signed it. A code without `fp=` (an ACME certificate) uses
  the system's normal validation. Every request, the event stream and canvas
  WebSockets go through the same pinned `URLSession`.
- **The instance key** (`X-Copper-Instance`) is sent with every `/v1` request;
  without it the server answers nothing but `/healthz`.
- **The session token** is a bearer token minted at sign-in. It lives in
  `~/Library/Application Support/Copper/cloud.json`, mode 0600, written
  atomically and private from its first byte — never the macOS keychain, never
  `Store.settings`, never published to the UI, never logged, never in a bench
  or MCP status. A 401 `session` from the server signs this Copper out.
- **Plain HTTP** is accepted only for a loopback host (`127.0.0.1`,
  `localhost`, `::1`) — a development server running with `tls off`. Use
  `http://127.0.0.1:PORT/#k=KEY`, or a link code with `&tls=off`.
- **On the server** every document and history entry is encrypted at rest
  with the account's data key (AES-256-GCM), itself wrapped by the instance's
  master key. The instance's operator can still read them — run your own, or
  use one run by someone you trust.
- **Passwords** go to the server only to sign up or sign in, over the pinned
  connection, and are not kept.

`cloud.json` holds: the device id (minted once per data folder, so each probe
world is its own device) and name, the link (address, key, fingerprint), the
account (user id, email, name, device id), the token, and the sync switches
and history cursors.

## Troubleshooting

- **"The server's certificate doesn't match the link code's fingerprint"** —
  the certificate changed (re-issued, or a different server at that address).
  Get a fresh link code from the server and connect again; if the server
  didn't change, something is in the way.
- **"Nothing is listening there" / "No such host"** — the address or port is
  wrong, or the instance is down: `copper-cloud doctor` on the server.
- **"The instance refused this key"** — the code is from another instance, or
  the key was rotated. Copy the link code again.
- **"This instance isn't taking new accounts"** — sign-up is closed; ask the
  admin to create the account.
- **"Too many tries"** — sign-in is rate-limited per address; wait a minute.
- **Status stays "Can't reach the cloud"** — sync retries on its own once the
  event stream reconnects; **Sync now** tries at once. The log (at the foot of
  the page) has the last 200 lines.
- **Something didn't sync** — check the switch is on for that domain and the
  log says *Pushed …*/*Pulled …*. Remember what doesn't travel (Today tabs,
  groups, pictures, the non-allowlisted settings).

## Driving it from a script

In a probe world (never your own Copper), with *Let a script drive Copper* on:

```sh
./bench --world NAME cloud link 'copper-cloud://127.0.0.1:8443/#k=…&fp=…'
./bench --world NAME cloud signup you@example.com a-long-password Your Name
./bench --world NAME cloud sync on spaces,settings,bookmarks,tabs,history
./bench --world NAME cloud status          # no secrets in it
./bench --world NAME cloud devices         # other devices' tabs
./bench --world NAME cloud doc spaces      # this Mac's document as it would be pushed
./bench --world NAME cloud selftest        # link codes, the allowlist, the merges
./bench --world NAME cloud wstest          # a canvas WebSocket through the pinned session
./bench --world NAME cloud picture /tmp/cloud.png [dark]   # the whole page, drawn off screen
```

Also `cloud signin EMAIL PW`, `signout`, `disconnect`, `sync off|now`,
`sync set DOMAIN on|off`, `log`, and — in test worlds only — `bookmark URL
[TITLE]`, `pin URL` and `open URL` to make something worth syncing. The bench
splits its words on spaces, so a password given there can't contain one (the
page has no such limit). Two probe worlds on one Mac are two devices:

```sh
defaults write com.officecommun.search.test.one bench -bool true   # before launch: the script socket
open -n -g --env SEARCH_PROBE=one --env SEARCH_HEADLESS=1 --env SEARCH_MCP_PORT=4151 build/Copper.app
./bench --world one cloud status
```

## For the canvas and other callers

`Cloud.shared` is the one client: `request`/`requestJSON` (instance key,
bearer token, JSON, 15 s, GETs retried, `Cloud.Failure` from the server's
`{error, message}`), `socket(path:query:)` for a pinned WebSocket
(`CloudSocket`: binary frames, ping every 20 s, reconnecting is the caller's),
`Cloud.didChange` when the link, account or reachability changes, and
`Cloud.event` for each server-sent event (`type`: `doc`, `history`, `canvas`,
plus `open`/`ready`/`resync` when the stream (re)connects).

## TODO

- **Google SSO** — sign in with a Google account on instances that configure
  it, instead of (or beside) email and password.
- Sync a pinned tab's order within its row, tab groups, and theme pictures.
- Device management (list and remove devices) on the Cloud page; the server
  already has `GET/PATCH/DELETE /v1/devices`.
