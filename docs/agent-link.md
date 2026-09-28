# Agent links — let your agents use this browser

Copper can lend the tools in its open window to bots in one or more agents apps. Each app is an
outbound connection: Copper registers the browser, holds an HTTPS event stream, and sends each
request through the same MCP server used by the local CLI. Nothing new listens on the Mac and the
loopback bearer never leaves it.

```text
bot ── tools/call ──▶ agents app ── request (SSE) ──▶ Copper
Copper ── reply / progress / heartbeat ─────────────▶ agents app ──▶ bot
```

A bot sees no tools until you grant it. Calls are announced in the window as
`@bot · app · tool` and appear under Recent calls. Revoke removes every grant immediately.

## Settings

Open **Settings › Agents**. The **Your agents — let them use this browser** section has one card
per configured app:

- **Connect this browser** turns that app's connection on or off.
- **App address** is the address shown at **Agents › Connect** in your agents app.
- **Personal token** is the `fxb_…` token minted there; Copper stores it only in the 0600
  `agent.json` file.
- **Status**, grants, recent calls and **Revoke link** are per app.
- **Remove this app** forgets the entry and best-effort revokes it on the service.

**Add an agents app** creates an empty, disabled card. Paste an address and token, then switch it
on. An address must be `https://`; `http://` is accepted only for loopback development.

## Configuration

The file is `Store.file("agent.json")` (normally
`~/Library/Application Support/Copper/agent.json`) and remains mode 0600. Copper only re-encodes
its own fields; malformed entries are skipped rather than making the file unreadable:

```json
{
  "links": [
    {
      "id": "8E0…",
      "enabled": true,
      "api": "https://agents.example",
      "token": "fxb_…",
      "name": "copper-exomac-fa",
      "linkId": "lnk_…",
      "announces": true,
      "label": "production"
    }
  ]
}
```

`links` may be absent (it means an empty list). `id` is a UUID for new entries. `label` is an
optional nickname used in announcements; when it is empty, the app host is used. Link identity is
separate from that nickname: a windowed Copper defaults to `copper`, while a headless Copper uses
`copper-<device-slug>` (lowercase, punctuation collapsed to `-`, at most 40 characters). The
service record also carries `placement` (`local` or `remote`) and `headless`; Copper displays the
current `servedBy` object (`device`, `streamId`, `since`) and whether that device is this Mac.

Existing installations may contain the legacy single-app object because an external installer may
write it:

```json
"agentLink": {
  "enabled": true,
  "api": "https://agents.example",
  "token": "fxb_…",
  "name": "copper",
  "linkId": "lnk_…",
  "announces": true
}
```

On read, that object becomes (or overwrites) the `links` entry whose id is `legacy`; its fields win
because an installer may JSON-merge only that key and restart Copper. On write, a non-empty `links`
array is written. If it contains `legacy`, Copper mirrors the entry back to the legacy key with
exactly the fields shown above. The legacy key is never written for any other entry. An existing
installation with only the legacy object comes up connected unchanged, while newer and older Copper
versions can open one another's files.

## Connection lifecycle

Each card has its own stream and retry state:

```text
off ──(enabled, address, token)──▶ connecting ──hello──▶ online
                                      ▲                       │
                         error/EOF ──┘  backoff 1,2,4,8,16,30 s
online ── revoke or revoked frame ──▶ revoked
HTTP 401 ──────────────────────────▶ token rejected
```

Switching on (or changing address/token) creates a link with `POST /v1/me/links`. The create body
includes `placement` (`remote` for `--headless`, otherwise `local`) and `headless`; the frames
query repeats those fields alongside `device` and `clientVersion`. Reconnects check the saved link
with `GET /v1/me/links/:id` and never silently recreate a revoked link. A heartbeat is posted every
15 seconds. A generation counter prevents a stale stream from writing over a newer connection.
When the service returns 409 `LINK_NAME_TAKEN` or `LINK_DEVICE_MISMATCH`, or a superseded stream
refreshes to a different `servedBy.device`, Copper clears the old id, chooses its device name (then
`-2`, etc.), persists it in `agent.json`, and retries (at most three renames). It reports
`Renamed to <name>: another Copper owns "<old>"` while reconnecting. Progress frames for
`jev_run` and `jev_step` are scoped to their own request and carry the final trace before the reply;
a cancel frame stops only that request.

A request whose method starts with `copper/` is refused before it reaches the MCP control methods.
This prevents a bot from calling `copper/link`, changing grants, or changing another connection.

## CLI

The CLI reaches the running Copper through the authenticated loopback `copper/link` method. The
link itself can run without the local MCP listener, but a CLI invocation needs the listener and a
window:

```text
copper [--json] link [--app SELECTOR] <command>
```

`SELECTOR` is an app address, host, nickname, or id (case-insensitive). It is optional when one
app is configured. With several apps, operations other than an unqualified `status` require a
selector; error messages list the available choices.

```text
copper link status                         # every app
copper link --app production on
copper link add https://agents.example fxb_… --label production
copper link --app agents.example remove
copper link --app production token fxb_…
copper link --app production api https://agents.example
copper link --app production grants
copper link --app production grant @bot
copper link --app production revoke [@bot|BOT_ID]
copper link --app production calls
```

`add URL [fxb_…] [--label NAME]` appends an entry, enabling it when both values are present, waits for its first
status, and prints that status. `remove` forgets the selected app and best-effort deletes its
server link. `--json status` returns `{"apps":[summary…]}` and also puts the legacy entry's
summary fields at the top level (or the first app when there is no legacy entry). In addition to the
legacy keys (`enabled`, `api`, `name`, `linkId`, `tokenSet`, `announces`, `status`, `statusText`,
`online`, `label`, `grants`, `recentCalls`, and `lastError`), status includes `placement`, `headless`,
`device`, `servedBy` (or `null`), and `servingHere`. Human-readable status prints the placement and
device too. Tokens are never printed, including with `--dry-run`.

Exit status remains 0 for success, 1 when the app refuses a request, and 2 for usage errors or an
unreachable Copper. `./bench agent link on|off|status` operates on the first configured app.

## Owner controls and wire

The service routes `request` frames over `GET /v1/me/links/:id/frames`; Copper answers with
`POST /v1/me/links/:id/frames` and `{frames:[…]}`. The create request is shaped as
`{name,label,kind:"mcp",device,clientVersion,placement,headless}`; the frames query is
`?device=…&clientVersion=…&placement=local|remote&headless=true|false`. It also uses the service
routes for grants, bots, calls and revoke. The same `MCP.shared.handle` serves local and linked `initialize`,
`tools/list`, and `tools/call` requests, so Jev tools appear consistently. `LinkWire.swift` owns
SSE parsing and lenient frame readers and can be compiled without the app.

The personal token goes only to the configured app address. Copper's own loopback token goes only
to `127.0.0.1`. Keep the link off when it is not needed: linked agents act as you in the tabs and
accounts already open in Copper.
