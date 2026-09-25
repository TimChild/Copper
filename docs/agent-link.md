# Agent link — how Copper lends its tools to your bots

*The implementation behind Settings › Agents › Agent link. For what it does and how to use it, read
[agents.md › Agent link](agents.md#agent-link--your-bots-use-this-browser); for the server side and the
wire contract, the agents service's own docs.*

## The idea in one paragraph

Copper's MCP server listens on `127.0.0.1:4123` and nowhere else — an agent running in the cloud
cannot reach it, and it never should. So Copper turns the arrow around: it registers itself with
the agents service as a **link**, opens one outbound HTTPS stream, and answers the requests the
service relays to it. The service is the hub, this Mac is a spoke, each bot session is a client
whose identity rides on every request. The owner grants the link per bot and can take it back
from Copper, from the agents app's Connect page, or from the shell; every call is announced in the
window and recorded on both sides. Nothing new listens on the Mac, and Copper's own loopback
bearer never leaves it. (A WireGuard hub was considered and rejected: neither Fargate nor the
AgentCore microVMs can hold a tunnel, and the ask is "let this bot use these tools, visibly and
revocably", not raw network reach.)

```text
agent (Claude Code in AgentCore) ─tools/call copper__jev_run─▶ agents service (session MCP gateway)
                                                                  │ LinkRequest row · SSE `request` frame
                                                                  ▼
Copper ── AgentLink.stream() ── LinkWire.events() ── MCP.shared.handle(jsonrpc) ── Tools.call ── the page
   └──────────── POST /v1/me/links/:id/frames {reply} ────────────▶ gateway ──▶ agent
```

## Files

| File | What it holds |
|---|---|
| `Sources/Search/Fork/MCP/Link.swift` | `AgentLink` — `@MainActor final class`, `shared`. Config, status machine, the connect loop, request serving, owner actions (grants, revoke, calls), the CLI/bench control surface. |
| `Sources/Search/Fork/MCP/LinkWire.swift` | `LinkWire` — Foundation-only, no `@MainActor`: byte→line splitter, SSE event parser, frame decoding, lenient DTO readers (`Grant`, `Bot`, `Call`), reply/heartbeat encoders, backoff table, URL guards. Everything in here is a pure function so it can be compiled and tested alone. |
| `MCP.swift` | `Config.agentLink: AgentLink.Config?` (persisted with the rest of `agent.json`); `handle(_:announce:)` so link calls are announced as `agents · @bot · tool`; `start(for:)` starts the link; the loopback method `copper/link` (the CLI's way in); `bench` op `link`. |
| `SettingsFork.swift` | `LinkCard` + `GrantRow` on the Agents page. |
| `CLI.swift` | `copper link status\|on\|off\|token\|api\|grants\|grant\|revoke\|calls` (`--json`). |

No upstream file is touched; there is no PATCHES.md row.

## Configuration

Lives inside the existing `agent.json` (`Store.file("agent.json")`, mode 0600, one writer) as an
optional object:

```json
"agentLink": { "enabled": true, "api": "https://agents.example",
            "token": "fxb_…", "name": "copper", "linkId": "lnk_…", "announces": true }
```

Decoding is lenient on both levels: an older `agent.json` without `agentLink` reads fine and keeps
the MCP token; a malformed `agentLink` value loses only the link settings. No `agentLink` key is written
until one is set. Caveat: an older Copper that re-saves the file drops the key.

`api` must be `https://` (or `http://` on loopback, for a dev stack) or the token is never sent —
`LinkWire.base` enforces it. The token is a **personal token**, minted at Agents › Connect
in the agents app; it is the same credential the service's own CLI uses.

## Lifecycle

```text
off ──(enabled && token)──▶ connecting ──hello──▶ online(label)
                              │  ▲                    │
              error/EOF ──────┘  └── backoff 1,2,4,8,16,30 s ──┘
online ──`revoked` frame or DELETE──▶ revoked (config.enabled = false)
online ──`superseded` frame──▶ offline("another Copper took the link — switch off and on to take it back")
any ──HTTP 401──▶ tokenRejected (no retries until the token changes)
```

- **Turning it on** (or changing token/App URL) is the only time Copper `POST`s
  `/v1/me/links` (`name: copper`, `label: "Copper on <Sharing name>"`, `device`, `clientVersion`).
  That call is idempotent on the server *and un-revokes* a revoked link, which is what you want
  when you flip the switch and exactly what you do not want on a reconnect after sleep — so a
  reconnect only `GET`s `/v1/me/links/:id` and stops if the link is gone or revoked.
- **The stream**: `GET /v1/me/links/:id/frames?device=&clientVersion=`, read with
  `URLSession.bytes(for:)` one byte at a time through `LinkWire.Lines`. `AsyncBytes.lines` is not
  used on purpose: it drops empty lines, and in SSE the empty line is what ends an event.
- **Frames** (`event:` = type, `data:` = JSON; a bare `message` event with a `type` field is read
  the same way): `hello` (link + grants), `request`, `grants` (live updates), `ping`,
  `superseded`, `revoked`.
- **Serving a request**: build `{"jsonrpc":"2.0","id":req.id,"method":…,"params":…}` and hand it
  to `MCP.shared.handle(_:announce:)` — the same code path the loopback port uses, so
  `initialize`, `tools/list` and `tools/call` behave identically and Jev tools appear only when
  Jev mode is on. The result goes back as `POST …/frames {frames:[{type:"reply", requestId,
  result}]}`; a JSON-RPC error goes back as `error:{code,message}`. Any `copper/*` method arriving
  as a link request is refused, so a bot cannot reach the control surface and grant itself access.
- **Heartbeat** `{type:"heartbeat"}` every 15 s while online; the server treats 45 s of silence as
  offline.
- **Generation counter**: every (re)connect bumps `generation`; a stale loop that wakes up after a
  disconnect sees `current(g) == false` and exits, so toggling the switch quickly never leaves two
  loops serving one link.

## The owner's controls

All go straight to the agents API with the personal token (the loopback port is not involved):

| Action | Call |
|---|---|
| list grants | `GET /v1/me/links/:id/grants` (also pushed live as `grants` frames) |
| pick a bot to grant | `GET /v1/bots` (reads `{items}`, a bare array, or `{bots}`) |
| grant / pause | `PUT /v1/me/links/:id/grants/:botId {enabled}` |
| remove | `DELETE /v1/me/links/:id/grants/:botId` |
| recent calls | `GET /v1/me/links/:id/calls?limit=20` (falls back to this run's in-memory list) |
| revoke the link | `DELETE /v1/me/links/:id`, then `enabled = false` locally |

The Settings card shows status (dot + `Status.text`), *Bots with access* (switch per bot, × to
remove, *Grant a bot…*), *Recent calls* (`@bot · tool · 1.2 s · 3 min ago`, red on error), and
*Revoke link*. Every relayed call also counts toward the Agents page's "N tool calls" line.

## CLI and bench

`copper link …` reaches the running app through the loopback server's `copper/link` JSON-RPC
method (`params: {op, arg}`), so it needs *Let agents drive this window* on — the link itself does
not. `./bench agent link on|off|status` mirrors it. `--json` prints `AgentLink.summary`.

## Testing

- **Pure parts** (`LinkWire`): compile the file alone with a small driver —
  `swiftc -swift-version 5 -warnings-as-errors LinkWire.swift test.swift` — and exercise the line
  splitter (CRLF, comments, multi-line `data:`, final event without a trailing newline), the six
  frame types, reply/error/heartbeat encoding, the backoff table and the URL guard. A local Python
  SSE server is enough to prove frames arrive as they are sent (not buffered until EOF).
- **The whole client without touching your real browser**: launch the build in an isolated world —
  `open -n --env SEARCH_PROBE=links build/Copper.app` — whose data lives in
  `~/Library/Application Support/Copper (links)/`. Pre-write that folder's `agent.json` with
  `agentLink: {enabled, api, token}` pointing at a local agents service api
  (`bun run service/src/index.ts` with `SERVICE_KEY`, native Postgres; mint the `fxb_` token with
  `POST /v1/me/tokens` using the service key + `x-user-id`). Grant a bot, then call the session
  gateway yourself: `POST /v1/sessions/:thread/mcp` with the bundle's session token and
  `tools/call copper__browser_tabs` — the probe's tabs come back, the Connect page and
  `copper link calls` show the call. `tools/call` needs a `RUNNING` run on the thread. Kill only the
  probe's PID afterwards; never `pkill Copper`.
- Do not run mutating tools against the browser you use from a test. `browser_tabs`,
  `jev_observe`, `browser_get_text` are safe reads.

## Security notes

- Two credentials, two directions, never crossed: the personal token goes only to the App URL;
  the loopback bearer goes only to `127.0.0.1`.
- A bot sees tools, not the link; grants live on the server, owner-side only; a bot cannot call
  `copper/link`.
- Revocation is immediate on the server (the stream closes, pending calls fail, tools disappear
  from the next `tools/list`) and sticky on the client (no re-registration on reconnect).
- The agent still acts as you, in your sessions. The switch and the per-bot toggles are there to
  be used; turn the link off when you do not need it.
