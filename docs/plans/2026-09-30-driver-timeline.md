---
kind: implementation-record
plan_id: copper-driver-timeline
title: Who is driving — the pill, the ring, the trail and the timeline for every driver, not only Jev
status: shipped
created: 2026-09-30
shipped: 2026-09-30 (fork 0045d7a → Copper 1.0.20260930.35)
repository: collinrijock/Copper (branch `fork`; built in worktree ~/src/copper-agentview, branch agent-view-bw-email)
base_revision: 44ec5a3 (origin/fork, 2026-09-30)
owners: [felipe]
predecessor: the Jev visibility layer of 2026-09-25 (Trace.swift / JevPane.swift / Trail.swift)
---

# Who is driving

## The problem

Copper had two ways for an agent to drive the page, and only one of them showed itself.

- **Jev mode** (`jev_run` / `jev_step`) wrote every cycle to `JevTrace`: the "Jev is driving"
  pill in the page's corner, the warm ring around the page, the trail drawn on the page
  (outline, glide, press dot, typed plate) and the timeline pane beside the page (⌥⌘J).
- **The Playwright-shaped tools** (`browser_snapshot`, `browser_click`, `browser_type`, …)
  — what phi, Claude Code, the `copper` CLI, a bot through an agent link, and the
  agent in Copper's own pane actually call most of the time — put one word in the status
  line ("Agent · browser_click") and nothing else. No pill, no ring, no trail, no rows, no
  idea what the agent was trying to do or whether it had let go.

Felipe's ask: the same agent view for both, always — what the latest reasoning turn is,
what the agent is doing right now, and an unmistakable signal that something other than
the user has the wheel.

## What was built

### One model: `Drive` (`Sources/Search/Fork/MCP/Drive.swift`, was `Trace.swift`)

`JevTrace` became `Drive` (renamed everywhere; no typealias left behind). Its `Run` now
carries a **driver**:

| `Drive.Driver` | Who | Name on the pill |
|---|---|---|
| `.jev` | the Jev loop, on a goal | Jev |
| `.agent(name)` | an MCP client on the loopback server, by the name it gave at `initialize` (`MCP.pretty`: `pi`/`phi` → phi, `claude-code` → Claude Code, `copper-cli` → copper CLI, else the raw name) | phi / Claude Code / … |
| `.bot(handle)` | a bot through an agent link | @dev-s · agents |
| `.pane` | the agent in Copper's own pane (⌘E) | Copper's agent |

A **Jev run** is what it was: `begin(goal:tab:)`, cycles of read → ask → act → settle,
`finish(status:note:)`. Untouched by design, because `LinkProgress` / `JevProgress` stream
exactly that run to a linked app and key on its id.

An **agent's run** is made of tool calls. `began(call:args:by:tab:)` opens the driver's run
when none is live (or another driver's is), adds the call as a cycle with one timed phase —
title and detail in plain words (`Drive.words`: "Clicking Search button", "Typing into Email
field, then Enter", "Opening localhost", "Reading the page's controls", "Waiting for “Done”",
…) — and returns a ticket. `ended(ticket, error:, tab:)` closes the phase and writes the
outcome: a chip (`CLICK`, `TYPE`, `GO`, `READ`, `SCROLL`, `KEY`, `SELECT`, `DRAG`, `SHOT`,
`SCRIPT`, `WAIT`, `TABS`, `SIGN_IN`, `AUTOFILL`, `PROBE`), the target as the agent named
it, the typed text (masked through `JevProgress.looksSecret` when the field sounds like a
password, a code, a card number), whether the page moved (URL/title compared before and
after, only for calls that can move it), and the error when the call failed.

`jev_run` and `jev_step` get no ticket — they own their run through `Ultrafast`. A live Jev
run is never replaced by a stray call from another client: it is the story being told.

**Reasoning.** `Run.thought` is the latest thing the driver said about what it is doing:
an agent's `reason` argument on a call, or — for the pane — what the model wrote before
reaching for a tool (`Agent.execute` hands it over).

**Liveness.** An agent has no natural "end of run"; it calls, thinks, calls again. So a run
stays `live` through `Drive.grace` = 30 s after each call (agents routinely think for ten or
twenty seconds), then ends on its own with status `.ended` ("Let go · 7 calls"). The same
driver back within `Drive.revival` = 180 s picks the same run up again rather than starting
over, so one task reads as one timeline. `busy` is true only while a call is in flight;
between calls the driver is thinking, and the UI says so.

**Stop.** `stop()` on a Jev run sets `stopRequested` (the Session checks it three times a
tick, as before). On an agent's run it sets `refusingUntil` = now + 30 s, finishes the run
as `.stopped`, and — for the pane — also calls `Agent.shared.stop()`. While refusing,
`Drive.refusal` is a sentence for the agent:

> Stopped by the user in Copper: they took the browser back. Do not retry; tell them what
> you were doing and wait until they ask you to continue.

`MCP.handle` and `Agent.execute` check it before `Tools.call` and answer with it as an
`isError` result; `refused(call:args:by:)` adds the turned-away attempt to the stopped run
as a row ("Refused — you stopped it") so the user sees the agent tried again. `resume()`
(the pane's *Let it back in*) ends the refusal early; a timer ends it at 30 s.

### The pane and the pill (`DrivePane.swift`, was `JevPane.swift`)

Same bones as before — header, hairline, scroll, hairline, footer, in the sidebar's palette
— now for any driver:

- **Header**: the driver's name (Jev's goal beside it when there is one), the clock, Stop
  while live, close.
- **Saying**: under the header, the latest `thought`, quoted with a 2 pt accent bar. Only
  as tall as its words (`fixedSize(horizontal: false, vertical: true)` — without it the bar
  took the whole column).
- **Rows**: `01 Clicking First name field · 600 ms` with the reason wrapped underneath, then
  the outcome line: chip, typed text in quotes, `→ page changed` / `→ no change`. A failed
  call reads its error in red. Jev rows are unchanged (phases, probability, candidates).
- **Thinking…** as an unnumbered row while an agent's run is live and no call is in flight.
- **Footer**: `Driving · thinking · 5 calls` / `Let go — 7 calls` / `Stopped by you — calls
  refused for 30 s` with **Let it back in**; `Clear` when nothing is live.
- **Pill**: "phi is driving" — the dot solid during a call, breathing while it thinks — and
  the stop square. Menu and ⌘K item: **Driver Timeline** (was Jev Timeline). ⌥⌘J unchanged.

### Wiring

- `MCP.handle(_:announce:driver:)` — `driver` is new; `Link.swift` passes
  `.bot("@\(who) · \(appName)")`. `initialize` stores `clientInfo.name` as `clientName`.
  Every `tools/call` goes `refusal?` → `began` → `Tools.call` → `ended`.
- `Agent.execute` (the pane): same, with `.pane` and the pending model text as the thought.
- `Tools`: every tool built through `Tools.tool()` gains an optional `reason` property
  ("One short sentence on what you are doing and why — shown to the user watching the
  browser"); `Tools.instructions` ends with `reasonNote`, asking for `reason` on each call
  and `element` on anything clicked or typed into, and telling the agent what "Stopped by
  the user" means. `Tools.call` draws the trail for `browser_click`, `browser_hover`,
  `browser_type`, `browser_drag` and `browser_scroll` (`Tools.trail` converts
  `Page.prepare`'s view-point rect back to CSS pixels by `web.pageZoom`; `Trail.glide` is
  awaited, capped at 400 ms as for Jev). `Drive` clears the trail when an agent's run ends.
- Split.swift / SplitPane.swift / PaneDoor.swift / Spaces.swift / CommandBar.swift /
  AgentPane.swift / Bench.swift / Progress.swift / LinkProgress.swift / Ultrafast.swift:
  the rename, nothing else.

### Bench

- `./bench drive [status|stop|resume|clear|pane on|off]` — the run as JSON (driver, live,
  busy, refusing, thought, every cycle's phases and outcome) and the pill's buttons.
- `./bench render bitwarden|drive PATH` — one SwiftUI card drawn to a PNG with
  `ImageRenderer`, no window brought forward. (AppKit text fields render as yellow
  placeholders; that is `ImageRenderer`, not a bug.)

## Verification (headless probe world `agentview`, port 4131)

The probe was launched by exec'ing the binary — `SEARCH_PROBE=agentview SEARCH_HEADLESS=1
SEARCH_MCP_PORT=4131 build/Copper.app/Contents/MacOS/Copper &` — never with `open`, so
LaunchServices never activated it and the user's keyboard and pointer stayed where they
were. `./bench --world agentview window PATH` works headless (the activation call is
swizzled off and logged "ignored").

Over MCP with `initialize` as `pi-coding-agent` and then `claude-code`:

- `browser_navigate` with a `reason` → pill "phi is driving", ring, pane header "phi", the
  reason quoted, row "Opening localhost · 459 ms · GO → page changed", "Thinking…".
- `browser_snapshot`, `browser_click`, `browser_type` ×2, a `browser_click` on a stale ref,
  `browser_scroll` → five rows with reasons, chips, typed values, the failed call in red
  ("ref:e999: no element…"), the scroll chevron and the trail pointer on the page.
- `drive stop` → status `stopped`, `refusing: true`; the next `browser_click` answered
  `isError: true` with the refusal sentence and showed as a refused row; footer "Stopped by
  you — …" with *Let it back in*; `drive resume` → the next click went through and started
  a fresh run.
- `jev_observe` without a Jev key → recorded as a READ row with its error.
- 33 s idle → `live: false`, status `ended`, note "2 calls"; the next call → the same run,
  three cycles (revival).

The tools/list carried `reason` on 24 of 29 tools (all `browser_*` but `browser_perf_probe`,
which builds its own schema; the `jev_*` tools have `goal`).

## Gotchas

- `Drive.grace` was 12 s at first; a real agent's think time split one task into several
  runs and made the pill blink. 30 s plus 180 s revival is the balance chosen.
- `Address.url(from:)` is what the tools use to parse `url` arguments; `Drive.words` uses it
  too so a bare host reads as one.
- The MCP transport is sessionless, so `clientName` is the *last* client to `initialize`.
  With two clients connected at once the name can be the other one's; the calls are still
  recorded.
- The `saying` block needs `fixedSize(horizontal: false, vertical: true)` or the accent bar
  stretches to the column's height.
