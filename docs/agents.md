# Agents — driving Copper from Claude Code, phi, Cursor, Claude Desktop

Copper is an MCP server. Turn it on and an agent gets the window you have
open — your tabs, your sign-ins, your extensions — through the same tool
names Playwright MCP uses, so a skill written for that works here unchanged.

## Turn it on

Settings › Agents › **Let agents drive this window**. That starts a
Streamable-HTTP MCP endpoint at `http://127.0.0.1:4123/mcp`, loopback only,
guarded by a bearer token that lives in `agent.json` beside your session
(0600). Every request must carry it; anything with a foreign `Origin` header
is refused, so a page in another browser can't reach in.

## Connect a client

**Claude Code / phi / Cursor (HTTP)** — Settings › Agents › *Copy config*,
paste into `~/.claude.json` (or `~/.pi/agent/mcp.json`, or the editor's MCP
settings):

```json
{
  "mcpServers": {
    "copper": {
      "type": "http",
      "url": "http://127.0.0.1:4123/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

Or the one-liner: `claude mcp add --transport http copper http://127.0.0.1:4123/mcp --header "Authorization: Bearer <token>"`.

**Claude Desktop and other stdio-only clients** — the second *Copy config*.
It runs the app binary with `--mcp-stdio`, which is a pipe to the running
window (and launches Copper if it isn't up):

```json
{
  "mcpServers": {
    "copper": {
      "type": "stdio",
      "command": "/Applications/Copper.app/Contents/MacOS/Copper",
      "args": ["--mcp-stdio"]
    }
  }
}
```

**Rotate** the token from Settings whenever you like; every client config
goes stale at once, on purpose.

## Tools

Playwright MCP's names and argument shapes. `ref`s come from
`browser_snapshot` and are remembered on the element until the page changes.

| tool | does |
|---|---|
| `browser_tabs` | `list` / `new {url}` / `close {index}` / `select {index}` — the real row, groups and pins shown |
| `browser_navigate`, `browser_navigate_back`, `browser_navigate_forward` | the current tab; waits for the load to settle |
| `browser_snapshot` | accessibility tree with `[ref=e12]` on interactive nodes; `interactive: true` for a smaller one, `selector` for a subtree |
| `browser_click` | `ref` or `selector`; `doubleClick`, `button`, `modifiers` — a real `NSEvent` at the element's centre |
| `browser_type` | `text`, `submit`, `slowly` (real key events) — sets the value through the native setter so React/Vue notice |
| `browser_fill_form` | `[{ref, type, value}]` for textbox / checkbox / radio / combobox / slider |
| `browser_press_key` | `Enter`, `Escape`, `ArrowDown`, `Meta+a`, `a` … as real key events (⌘ shortcuts go to the window first) |
| `browser_hover`, `browser_drag`, `browser_select_option`, `browser_scroll` | as named |
| `browser_take_screenshot` | PNG/JPEG at 1×, so image pixels are CSS pixels; `ref` for one element, `fullPage`, `filename` |
| `browser_evaluate` | `function: "() => …"` or `(element) => …` with `ref` |
| `browser_wait_for` | `text`, `textGone`, `time` |
| `browser_get_text`, `browser_find`, `browser_console_messages` | reading without a snapshot; refs for text you name; console since load |
| `browser_resize`, `browser_close` | the window; the tab |
| `browser_groups` | Copper's tab groups: `list`, `assign {group}`, `remove`, `suggest` |
| `browser_perf_probe` | Samples the current tab for rAF loops, DOM churn, animations, filters, canvases, timers, long tasks, and slow resources (`seconds`, `top`, `format`) |

### Saved sign-in (no-secret contract)

`browser_sign_in` fills a saved account on the current tab in-process. Its
arguments are `account` (optional username), `what` (`password` by default or
`otp`), and `submit` (true by default). With more than one shared match, omit
`account` to get a username-only `candidates` list, or name the username. The
result reports only `filled`, `account`, `host`, `source` (for password fills),
`what` (for OTP), and `submitted`; the password, one-time code, and Bitwarden
session key never appear in the MCP result, CLI output, or Jev trace.
`copper signin [--account USER] [--otp] [--no-submit] [--json]` is the CLI
equivalent (`--json` may be placed with the command).

Jev's fast path exposes a `SIGN_IN` control labelled “Sign in with the saved
account for this site” only when the current tab has a password field and at
least one permitted candidate. It routes through the same password fill and
submit path. OTP fills use `browser_sign_in` with `what: "otp"` (or `copper
signin --otp`); Jev `SIGN_IN` does not guess an OTP. Unshared credentials,
missing fields, locked Bitwarden, and private (`shy`) tabs return an error;
there is no agent prompt or audit record in this flattened lane. When a
credential exists but is not shared, the error points to Settings › Passwords ›
Agent access. The operation is not a page sandbox: with `--no-submit`, the
password intentionally remains in the page, so do not use ordinary
page-reading/evaluate tools on that tab.

Sharing is controlled by Settings › Passwords › **Agent access**. The user can
turn on the share-everything switch or enable individual per-item toggles. A
Bitwarden item in the `Agents` folder is shared automatically; a custom field
`copper-agent: deny` always means never shared, even when the broad switch is
on. The policy is local to Copper and never editable through MCP or the CLI.

### Why is this tab hot?
`browser_perf_probe` samples the tab in one call instead of requiring a chain of evaluations: it groups frame loops and DOM mutations, inspects running animations and filters, and records canvases, timers, long tasks, and resources.
Its findings are deliberately WebKit-specific. The three traps it calls out are a filtered SVG under an animated transform, off-screen `requestAnimationFrame` loops, and animations of properties other than `transform`/`opacity`.

Input goes in as real events when the tab is on screen (trusted `isTrusted`
clicks, key repeat, focus, default actions); when it is not, the DOM gets an
event of the same shape. Screenshots and snapshot coordinates are in the
tab's CSS pixels; the server converts to points for the click.

Each tool call is announced in the line at the bottom of the window (turn
that off in Settings › Agents). `./bench agent` reports status; `./bench
agent on|off|rotate`.

## Jev mode — hand over a goal

Settings › Agents › **Let the agent hand Copper a goal**. Three more tools
appear, and the server's instructions tell the agent to reach for them
first:

| tool | does |
|---|---|
| `jev_run` | `goal` (+ `url`, `newTab`, `maxSteps`, `elements`) — runs [browser-use's jev-ultrafast](https://github.com/browser-use/jev-ultrafast) loop in the current tab until DONE, BLOCKED or the budget (60 actions, 120 decisions, 3 minutes); answers with the trace, the page, and the indexed element table |
| `jev_step` | one decision and its action; same `goal` continues the session |
| `jev_observe` | what Jev sees: `[3] combobox  Where to? · London` for every visible control, plus the visible text |
| `jev_extract` | `instruction` (+ `schema`, `full`) — one JSON object drawn from the page by the text model: values, not a tree |

The loop is theirs, in Swift (`Fork/MCP/Ultrafast.swift`): one script reads
the visible controls into an indexed table with a semantic marker; **one**
TypeSafe System One request asks for the operation and, speculatively, a
target for every operation that has candidates — only the head the chosen
operation names is consumed; freshness (the marker, or for a click the form
state plus the target's own guard) and occlusion are checked again before the
input goes in as real events. `TYPE_TEXT` asks the router (Settings ›
Intelligence) for the value and types only what came back as `{"text": …}`.
Model output never becomes a selector, a coordinate or JavaScript.

Needs a TypeSafe key (shared with Intelligence — the Agents page has the
field too) and, for anything that types or extracts, the router key. **Text
model** on the Agents page names the small model used for typing and
`jev_extract`; empty means the router model. Small and fast is the point:
Sonnet spends ~2.5 s writing a search string, a mercury-class model well under
a second. DONE is the model's
claim; the tool says so and the agent is told to check.

**Copy prompt** on the Agents page gives you one paragraph to paste into the
chat with your agent — endpoint, token, how to add the server, what it can
do. There is one for the Playwright-shaped tools and one for Jev mode.
`./bench agent jev on|off`.

## The agent in the window — ⌘E

The other direction: Copper as an MCP **client**. ⌘E opens a pane beside
the page with a chat; ⌘⇧E (or ⌘K › *Ask About This Page*) opens it with the
page in front of the question. The model is whatever the router serves
(Settings › Intelligence; the Agents page has a *Model* field for this pane
alone — it needs tool calling). Nothing is configured out of the box.

What it has in hand:

- **Copper's own tools, bound locally** — the same `Tools.call` the MCP
  server runs, no HTTP in between: `browser_*`, and `jev_run` /
  `jev_extract` / `jev_observe` when Jev mode is on. Screenshots go back
  to the model as pictures.
- **Your other MCP servers**, from `mcp.json` beside the session
  (Application Support/Copper/mcp.json — *Open mcp.json* on the Agents
  page writes an empty one). Same shape Claude Code and phi read:

  ```json
  {
    "mcpServers": {
      "feads": { "type": "http", "url": "https://feads.mcp.exowatt.com/mcp", "headers": { "Authorization": "Bearer ${FEADS_TOKEN}" } },
      "time":  { "command": "uvx", "args": ["mcp-server-time"] }
    }
  }
  ```

  Streamable HTTP (JSON or SSE replies, `Mcp-Session-Id` honoured) and
  stdio (run through your login shell, so `npx` / `uvx` resolve). `${VAR}`
  fills from the environment. Each server's tools appear to the model as
  `server__tool` and are routed back by that prefix. Connected at launch
  and on *Reload*; the row under the card says which answered.

Tool calls are chips in the transcript — name, the arguments that matter,
the first line of the answer, the time it took — so you can see the
agent's hands. Stop with the square; clear with the bin. Every question
carries the current tab's address, title and first 3000 characters unless
*Page in front of every question* is off. `./bench agent ask TEXT`,
`./bench agent chat`, `./bench agent servers`.

Files: `Fork/Agent/Agent.swift` (the loop), `Fork/Agent/Servers.swift`
(the client), `Fork/Agent/AgentPane.swift` (the pane). The pane rides in
`SplitStage`; no upstream file changed.

## Agent link — your bots use this browser

Settings › Agents › **Connect this browser to an agents app**. The loopback server
can't be reached from a bot running in the cloud, so this side dials out:
Copper registers itself with the agents service as a *link*
(`POST /v1/me/links`, name `copper`, label "Copper on <this Mac>"), holds one
server-sent-events stream (`GET /v1/me/links/:id/frames`), and answers each
`request` frame by handing its JSON-RPC message to the same server the
loopback port uses, then posting the reply (`POST /v1/me/links/:id/frames`,
`{frames:[{type:"reply", requestId, result|error}]}`, plus a heartbeat every
15 s). Bots see the tools as `copper__<tool>` — `copper__jev_run`,
`copper__browser_snapshot` and the rest, Jev tools only when Jev mode is on.

- **Credential**: a personal token (`fxb_…`, minted at Agents › Connect
  in the agents app), kept in `agent.json` under `agentLink` (0600), sent only to the
  **App** address (https, default `https://agents.example`).
  Copper's loopback token never leaves the Mac.
- **Grants**: a bot sees nothing until you grant it — from the card (*Grant a
  bot…*, a switch per bot to pause it, × to remove), from the agents app's Connect
  page, or `copper link grant @bot`. Grant changes arrive live over the stream.
- **Calls**: each call is said in the bottom line as `agents · @bot · tool`
  and listed under *Recent calls* (this run, last 20); the agents app keeps the full
  record (`copper link calls`).
- **Revoke**: *Revoke link* (or `copper link revoke`, or the agents app's Connect page)
  and every bot loses the tools at once; Copper disconnects and switches the
  card off. A revoke made while the Mac slept holds — a reconnect never
  re-creates a link, only switching it on again does. A second Copper that
  links with the same token takes the link over; the first stops and says so.
- **Reconnects** with backoff (1 s → 30 s) while on; a rejected token stops
  retrying until the token changes.

It works whether or not *Let agents drive this window* is on (the link does
not use the port); it needs a window, like every tool call. `copper link …`
does go through the port. `./bench agent link on|off|status`. How it is built and
tested: [agent-link.md](agent-link.md). On a Mac nobody sits at (the bot Mac mini), Copper runs
as a background service with no window: [headless.md](headless.md).

## What it is not

Not a sandbox. The agent acts as you, in your sessions. Turn it off when you
don't need it. There is no server→client event stream (GET on `/mcp` answers
405); tools are synchronous and answer in the POST.

## Where it lives

`Sources/Search/Fork/MCP/`: `MCP.swift` (listener, HTTP, JSON-RPC),
`Tools.swift` (the catalogue and dispatch), `Page.swift` (the injected
helper: snapshot, refs, setters), `Input.swift` (NSEvent synthesis),
`Bridge.swift` (`--mcp-stdio`), `Link.swift` + `LinkWire.swift` (the agent
link and its wire). Hooks: `Browser.init` starts it,
`SearchApp.init` runs the bridge. See `PATCHES.md` › `mcp-hooks`.
