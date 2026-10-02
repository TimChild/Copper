# Updates and relaunch

Copper's updater (`Sources/Search/Fork/Updates.swift`) verifies the feed manifest, the
archive's SHA-256, the bundle's identity and version and its code signature before it swaps
anything (README › Updates). This page is about how an update is offered — the sidebar's pill —
and the part after the swap: getting the new
Copper running again, in the same world, every time — and about the instance lock that keeps
agents' probe worlds from swallowing the real browser.

## The update pill

Arc's way of saying an update is waiting: not a dialog, a button you cannot miss in the place
you already look. `Fork/UpdatePill.swift` reads everything off `Updates` — it never checks,
downloads or swaps on its own — and draws one of five states (`Updates.cue`):

| state | when | label | click |
|---|---|---|---|
| available | `available`, nothing staged | Update Copper | `stage(force: true)` |
| downloading | `downloading` | Downloading… 42% (a bar fills the pill; a turning ring until the server sends a size) | — |
| ready | `ready` | Restart to Update | `upgrade()` — back up, swap, relaunch |
| installing | `state == .upgrading` | Restarting… | — |
| failed | `stageError`, or a swap refusal kept as the outcome while still `ready` | Retry Update (the reason in the tooltip) | `stage(force: true)`, or `upgrade()` for a failed swap |

The tooltip has the version (and the one you have). The download's fraction is `Updates.progress`:
the async `URLSession.download(for:delegate:)` reports nothing until it is done, so a task
delegate (`DownloadWatch`) picks the task up in `didCreateTask` and watches its `Progress`,
thinned to whole percents. Clicking Update Copper downloads and stops at Restart to Update — the
relaunch is always its own click (README: it never restarts without your say-so).

Where it is:

- **Sidebar:** full width at the column's foot, between the rows and the space strip
  (`UpdatePillSlot`, mounted in `Side.swift`). The rows' scroll gives up the room; the strip
  does not move.
- **Tabs across the top:** a capsule left of the downloads and bookmarks doors
  (`UpdateToolbarPill`, in `TabBar.swift`).
- **Sidebar folded (⌘S):** a round badge in the window's bottom-left corner that spells out its
  label under the pointer (`UpdateCorner`, an overlay in `App.swift`). The column, peeking out,
  has the full pill.

Its colour (`UpdateInk`) is the space's hue, deepened until white words read at about 5:1 (a
luminance near 0.16, never below 0.52 brightness, where green turns to mud); a yellow hue is a
bright gold with the hue's own near-black words instead; a grey space or a picture with no hue
takes the system accent. The fill is opaque so an animated backdrop or a photo cannot take its
contrast. Failed is quiet on purpose — the column's own surface with an orange mark.

The first time a version reaches *available* or *ready* in a run, a band of light crosses the
pill once and the arrow hops twice; under Reduce Motion it only fades in. Another window, a
folded column peeking out or a redraw does not replay it (`UpdatePill.introduced`).

Right-click: the click's own action, **What's New…** (a popover with the feed's `notes` — the
first paragraph of `NOTES.md`, written into `copper-version.json` by `release.yml` — and Full
Changelog, `CHANGELOG.md` at the release's commit), **Remind Me Later** (hidden for that version
until the next launch; a newer version brings it back) and **Settings…** (Settings › Updates).

A test world on the real feed shows no pill (`Updates.quietHere`, the same rule that keeps it
from staging real releases), so probe-world screenshots stay clean; a world the bench pointed at
its own feed (`updates stub`) shows the real one.

To look at it without a release: `./bench --world <w> updates pill STATE`, where STATE is
`available`, `downloading [0.42]`, `ready`, `installing`, `failed [swap] [WHY…]`, with an optional
`v=VERSION`; `off` goes back to the real state. A forced pill's clicks are rehearsed — a two-second
fake download, then *Restarting…* and a toast saying what a real one would do — never made.
`pill click`, `pill later`, `pill unsnooze`, `pill notes [TEXT]` (opens What's New), `pill hover
on|off`, `pill replay` (the entrance again) and `pill status` (state, label, tooltip) drive the
rest.

## What went wrong (October 2026)

Every in-app update swapped the bundle and then, often, nothing came back. `update.log` ended
at `swapped; relaunching /Applications/Copper.app` with no `launched as …`. The macOS unified
log showed why:

- The old relaunch was a `/bin/sh` loop: `while kill -0 PID; do sleep 0.2; done; exec open
  /Applications/Copper.app`. About 100 ms after the pid died LaunchServices still listed it, so
  `open` (no `-n`) decided Copper was running and sent the dead instance a reopen Apple event
  (`aevt/rapp`). CoreServicesUIAgent answered `-600 procNotFound`, "Asking CSUI to launch 0
  items", and nothing launched or logged.
- Agents run headless/probe worlds from the same bundle (`open -n --env SEARCH_PROBE=…
  --env SEARCH_HEADLESS=1 …`). With one alive, a plain `open Copper.app` — and a Dock click —
  was routed as `rapp` to the invisible probe, which swallowed it: "Copper won't even open".
- The relaunch forwarded only `SEARCH_PROBE`, `SEARCH_MCP_PORT` and `SEARCH_MEASURE`, so a
  headless world could come back windowed, and the waiter's output went nowhere.

`/usr/bin/lsappinfo find pid=<pid>` prints `ASN:…` while LaunchServices still lists a pid and
nothing once it is gone; the waiter uses that.

## The relaunch

`Updates.relaunch` starts a small POSIX `sh` waiter (its own process group, so a launchd job's
exit does not take it down) and quits. Every step is a dated `copper-update:` line in
`~/Library/Logs/Copper/update.log`:

1. Wait (≤ 60 s) for the old pid to exit.
2. **Ordinary launch** (Finder, Dock, `open`, a shell): wait (≤ 10 s, 0.1 s polls) until
   `lsappinfo` no longer lists the old pid, settle 0.5 s, then `/usr/bin/open -n` — always a
   new instance, never a reopen event to a dead or probe instance — with `-g` when headless,
   `--env` for each of `SEARCH_PROBE`, `SEARCH_MCP_PORT`, `SEARCH_MEASURE`, `SEARCH_HEADLESS`,
   `SEARCH_HEADLESS_SIZE`, `SEARCH_HEADLESS_WINDOW`, `SEARCH_HEADLESS_DEBUG`,
   `COPPER_AGENT_PORT`, `COPPER_MAIN_WORLD`, `COPPER_MAIN_WORLD_PORT` that the old process
   had, and `--args --headless` when it was started with `--headless`. A non-zero exit is
   retried (3 attempts, 1 s / 2 s backoff) with its stderr in the log.
3. **A launchd job** (a LaunchAgent on a headless Mac, docs/headless.md): no `open`. Copper
   decides this itself — its parent is launchd (pid 1) *and* `XPC_SERVICE_NAME` is a job label,
   not `application.<bundle id>.…` (every LaunchServices launch is a launchd job too and carries
   that) — and passes the label to the waiter. The waiter gives launchd 3 s to restart the job
   (`KeepAlive` true), then `launchctl kickstart gui/<uid>/<label>` (the recipe's
   `KeepAlive {SuccessfulExit: false}` does not restart a clean quit), so the new Copper stays
   under launchd.
4. Confirm (≤ 20 s): the world's `instance.lock` names a new live pid, or `updates.json` no
   longer has `pending` (the new process clears it in `settleAtLaunch`, which logs
   `launched as X: update from Y landed`).
5. Not confirmed and no process has the lock open (`lsof -t`): start
   `Contents/MacOS/Copper` directly, detached (`nohup env -i HOME=… <world keys> …`), and
   confirm again.
6. The last line is `relaunch confirmed` or `relaunch not confirmed: <why>`. Only the latter
   writes `update-result.txt`; the next launch turns it into *The last update didn't finish*
   in Settings › Updates with **Open log**.

A normal relaunch is back in about a second (open → lock held ≈ 0.1–0.5 s after LaunchServices
lets go). Measured end to end (`upgrade` → `/health` answers the new version) on macOS 27:
1.05–1.72 s over eight updates, with and without another headless world of the same bundle
running; 3.5 s for the launchd job (the 3 s KeepAlive grace, then kickstart).

## One instance per world

`SearchApp.init`'s first line is `Instance.acquireIfNeeded()` (`Fork/Instance.swift`): before
the passkeys migration, the headless boot, session restore, MCP or any window, it opens
`<world folder>/instance.lock` (`O_CLOEXEC`) and takes `flock(LOCK_EX|LOCK_NB)`, holds the
descriptor for the life of the process and writes its pid into the file.

- Already held (`EWOULDBLOCK` after eight 40 ms retries — a probe's momentary check must not
  read as a second Copper): log `instance lock: Copper (w) already running as pid N; pid M
  exiting`, activate the holder unless headless, `exit(0)`.
- Any other error: log and start without the lock (fail open).
- `--cli` (the `copper` command) and `--mcp-stdio` (the stdio bridge) are clients of a running
  Copper and never take it.
- Exit, crash and `kill -9` all release it; there is no stale-lock cleanup.

`Instance.isRunning(worldFolder:)` answers "who holds this world?" with a shared non-blocking
probe; the waiter reads the pid from the file and checks it with `kill -0`.

## Probes hand reopen to the real Copper

A Dock click or a plain `open Copper.app` goes to whichever instance LaunchServices picks.
`Links.applicationShouldHandleReopen` asks `Instance.reopenFromProbe` first. In a probe world
(`Store.world != nil` or headless) of Copper's own bundle id it never shows or activates
itself; it hands the reopen to the main world (`~/Library/Application Support/Copper`):

- held lock → activate that pid;
- no lock but a running instance of the bundle without `SEARCH_PROBE` in its environment (a
  main Copper from before the lock existed) → activate it, never a second browser on the same
  profile;
- otherwise → launch it from the installed Copper (`/Applications`, then `~/Applications`, then
  this bundle) with `open -n`.

LaunchServices hands the caller's whole environment to the app it launches — `open` and
`NSWorkspace.openApplication` alike, with or without `OpenConfiguration.environment` (checked
on macOS 27 with an env-dumping app: 98–103 variables, the caller's canary among them). So that
`open -n` runs with a minimal, Dock-like environment (`HOME`, `USER`, `LOGNAME`, `SHELL`,
`TMPDIR`, `LANG`, a default `PATH`): no `SEARCH_*` (which would reopen the probe's own world),
no `COPPER_*`, nothing from the agent that started the probe. A probe of another bundle id (an
isolated test copy) never reaches the main world.

## The test seam

For end-to-end tests that must never reach the real browser: a probe started with
`COPPER_MAIN_WORLD=<name>` (optionally `COPPER_MAIN_WORLD_PORT=<mcp port>`) treats the world
`Copper (<name>)` as main and launches it from its own bundle with `open -n -g` and only
`SEARCH_PROBE=<name>`, `SEARCH_HEADLESS=1`, `SEARCH_HEADLESS_WINDOW=hidden` (and
`SEARCH_MCP_PORT`) — headless, hidden, never activated.

## Testing it

Only in an isolated copy: `build/Copper.app` copied to `/tmp`, `CFBundleIdentifier` set to a
test id (a separate LaunchServices identity, so nothing reaches the installed Copper —
`fetchAndStage` accepts the running bundle's own id), `codesign --force --deep --sign -`,
`xattr -cr`. Always headless, always a named world. A fake feed is a stamped copy zipped with
`ditto -c -k --keepParent` plus a schema-1 manifest served by `python3 -m http.server` on
127.0.0.1; drive it with `./bench --world <w> updates stub <manifest URL>`, `updates check`,
`updates upgrade` (the world needs `defaults write com.officecommun.search.test.<w> bench
-bool true`), and watch `update.log`. Never test reopen forwarding without the seam: the
target would be the real main world.
