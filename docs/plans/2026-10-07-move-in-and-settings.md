---
kind: implementation-record
plan_id: copper-move-in-and-settings
title: Move in and Settings — what broke in a live demo, what changed, how to keep it fixed
status: shipped
created: 2026-10-07
shipped: 2026-10-08 (signing: #46 merged as bdef413, released from fork 320c8e4 as Copper 1.0.20261007.42; Settings and Move in in fork e3d642d → Copper 1.0.20261008.46)
repository: copper-browser/Copper (branch `fork`)
base_revision: 6bcfb04 (origin/fork, 2026-10-07 = Copper 1.0.20261007.34)
owners: [felipe]
predecessor: Tim's Move-in fixes on `fork` (#40 extensions keep their on/off state, #41 account bookmarks and an idempotent bookmark re-import, #42 the Switching from Chrome guide); docs/flow.md
---

# Move in and Settings

In a live demo, Move in from Chrome brought nothing over. Running it again made the sheet slide
in and out over and over, with text from two layouts drawn on top of each other and cut off at
the left edge. Neither had shown up in testing, because every test ran against a Chrome folder
the test could read and a single window.

This record covers the two causes, the three pull requests that fixed them and the Settings pass
that shipped alongside, how each change was checked, what still needs a person, and what now
catches each failure if it comes back. How the pieces work today is in
[docs/flow.md](../flow.md), [docs/settings.md](../settings.md),
[docs/releasing.md](../releasing.md), [docs/updates.md](../updates.md) and
[docs/headless.md](../headless.md).

| PR | What | Released in |
|---|---|---|
| #46 | Stable release signing with an explicit designated requirement, the updater's signature check, and a bundle id of their own for development builds | 1.0.20261007.42, the first signed release |
| #48 | Settings usability pass across every page | 1.0.20261008.46 |
| #49 | Move in rebuilt for Chrome, Arc and Safari, including the QA fixes in d2e1b40 | 1.0.20261008.46 |

## Why Move in from Chrome brought nothing

Four things stacked up. The first two are why Copper could not read Chrome at all; the last two
are why nobody could tell.

1. **macOS keeps Chrome's folder private, and never asks.** On macOS 26 and 27, another app's
   data folder (Chrome's, under `~/Library/Application Support`) sits behind Privacy & Security ›
   Files & Folders. Listing it fails with `EPERM`. macOS does not show a prompt for this check:
   tccd records the denial ("does not allow prompting; recording denied") and lists the app in
   Files & Folders, switched off. The only way in is for the person to turn that switch on.

2. **Every update threw the grant away.** The Mac in the demo had been granted access before.
   But Copper releases were signed ad hoc, so each release's designated requirement was
   `cdhash H"…"`, the hash of that one build. macOS stores a grant against the designated
   requirement, so each update looked like a different app. The update on 6 October replaced
   the build, and tccd logged `Failed to match existing code requirement` the next time Copper
   asked. The same thing silently dropped Full Disk Access, Automation and every keychain
   "Always Allow". System Settings still showed Copper switched on, because the row was there;
   it just no longer matched the running app.

3. **The card offered nothing that worked.** It said "macOS keeps Chrome's data private" and
   named a pane, "App Data", that does not exist in System Settings. Its "Choose folder…" opened
   one level above Chrome's folder, outside the sheet, and returned silently when the folder
   could not be read. Nothing re-checked when the person came back from System Settings; the
   copy said to reopen.

4. **A move that read nothing still said it worked.** Even with access, the Chrome on the demo
   Mac held one window with only `about:blank`, no bookmarks and 44 history entries. The old
   move made an empty space named "Chrome" from that window and showed a summary of zeros
   ("0 tabs in 1 spaces · 0 bookmarks…") as one line of counts, with no reason for any of them.
   Then #42's guide opened in front and the summary closed itself about a second later. Other
   gaps in the same path:
   - one keychain failure hid passwords, sign-ins and passkeys together and blamed the key;
   - the sign-in count was what had been read, not what WebKit took;
   - `Flow.init` listed sources on the first window draw, so every launch of Copper made an App
     Data request, recorded as a denial, before anyone opened Move in.

## Why the sheet cycled

- **One sheet per window.** `Fork/Split.swift` attached `.sheet(isPresented: $flow.open)` to
  every window's page area. With two windows, one click put up two sheets, drawn over each
  other.
- **Rebuilds dismissed it.** Switching the active tab or taking the page area away
  (`App.swift`'s stage) tore down the view that held the sheet. SwiftUI dismissed it and put it
  up again, so the sheet faded out and back in while the person watched.
- **Its size followed its content.** The sheet measured 733, then 283, then 273 points tall as
  the phase changed (831 → 800 in a window), and `FlowUI` drew its own card, background, clip
  and 32-point shadow inside the system sheet. With no scroll view, each phase re-centred the
  sheet, clipped its left edge, and for a frame drew both layouts at once. That was the
  overlapping text.
- **It opened inside Settings' closing animation.** From Settings › General, `tuning = false`
  and `open = true` were set in one animated transaction, so the sheet's text morphed glyph by
  glyph out of Settings'.
- **It rescanned on every activation.** `onAppear` and every `didBecomeActive` called
  `refreshSources`, which republished the list, reset the selection and could start another
  scan. A keychain prompt activates the app once per item, so a move with passwords rescanned
  several times. Scans had no generation guard, so an older, slower read could land last.
- **It never started fresh, and it was hard to leave.** `.done` was never cleared, so reopening
  showed the last run's "All set" and its Undo. Escape didn't close it, Return did nothing on
  the done screen, and ⌘Q did nothing while it was up, because a window-attached SwiftUI sheet
  refuses termination.
- **A second move duplicated everything.** `Spaces.adopt` always made new spaces: a re-run made
  "Chrome (Chrome)", and Arc made seven extra "… (Arc)" spaces with every tab in them twice.

## What the Settings audit found

The same week, every Settings page was walked at the smallest window, with the keyboard, with
VoiceOver and in a test run. The main findings:

- `Switch` and `Segmented` were drawn shapes with a tap gesture. Tab couldn't reach them, Space
  and the arrow keys did nothing, and VoiceOver couldn't see them. Text fields drew no focus
  ring, so Tab landed somewhere invisible. The close button read "xmark".
- At the minimum window (640×420) Spaces and Extensions were wider than the panel. The rail read
  "ettings", the Look choices were cut to "Gradie…", and the page slid sideways when Details
  opened.
- Choosing a folder, Ask where to save, a space's picture and Load Unpacked used `runModal`,
  which froze every window until answered.
- Clear history (which also clears Copper Cloud's copy), Sign out of everything, Rotate token,
  Delete space and Remove extension acted on one click. Sign out of everything and Clear cache
  cleared only the front space's cookie jar.
- Several pages reported things that weren't true. Cloud said "Up to date · just now" with the
  server down. Updates said "Couldn't check: Not checked yet". About checked the upstream
  project's feed and said "latest" while Updates offered a newer Copper. Send Feedback drafted a
  mail to the upstream project's author. A password manager's Sync now hung for about 39
  seconds and then said it had synced, and a cut-off item list was reported as fine.
- Tabs show: Letters did nothing with tabs in the sidebar. Swipe between spaces and Trails were
  live with tabs across the top, where they do nothing.
- Test runs reached past their world. They wrote WebKit's spelling switches into the installed
  Copper's defaults domain, copied to the real clipboard, opened the real editor, could change
  the default browser, appended to the real `update.log`, and every development build shared
  the installed Copper's bundle id, privacy grants and WebKit container.

## Decisions

| | Decision | Chosen | Why |
|---|---|---|---|
| D1 | The Chrome guide after a move | No automatic opening. The done screen offers "Open the Chrome guide" when tabs or bookmarks arrived; Done lands on the first imported space. | The summary has to stay readable, and a guide saying "what you brought over is here" after nothing came is worse than no guide. Tim's guide and its once-only behaviour are kept. |
| D2 | Release signing and dev builds | One self-signed code-signing certificate of Copper's own, with an explicit designated requirement. Development builds are `com.collinrijock.copper.dev`. | It keeps grants across updates without an Apple developer account. A separate dev id stops test builds overwriting the installed Copper's grants, defaults and cookies. |
| D3 | Where Send Feedback goes | A prefilled new issue on Copper's own GitHub repository, in a Copper tab | Feedback about Copper was going to a third party; the people using Copper can file issues there. |
| D4 | What the locked Chrome card offers | "Allow in System Settings…" plus "Use an export instead…" (Chrome's bookmarks HTML or passwords CSV). "Choose folder…" removed. | Allow is the only real way in, and Copper re-checks on its own. An export needs no permission. Picking the folder was never shown to grant access. |
| D5 | Drafts written before Tim's fixes landed | Kept where they fitted, carried over where they had to adapt to #41/#42, and redone by hand where they collided | Tim's bookmark merge and guide were already on `fork`; nothing of his was reverted. |
| D6 | What a second move does | Fill. Each source keeps a registry (`flow.spaces.<source>`) from its own space key to the Copper space it became; a space still there gets only tabs it hasn't had, a deleted one is made again, and Undo removes only that run. | One rule for Arc, Chrome and Safari, and running Move in twice is safe. |
| D7 | Settings that work in one tab layout | Letters made to work in the sidebar. Trails and Swipe between spaces say they need the sidebar and are disabled without it. | Letters was two lines; drawing trails or swiping in the top strip is new feature work. |
| D8 | Export passwords to CSV | Ship it, behind Touch ID, written with mode 0600, with a warning in the save panel | People moving away from Copper need it, and it was already verified. |
| D9 | Test seams in release builds | A runtime gate only: a test run, in a named world, with the bench on (and, for the file keychain, asked for). A unit test proves each gate is off outside a test world. | Probe runs drive release builds too; compiling the seams out would make the shipped binary untestable. |
| D10 | Safari in this wave | Both ways in: Full Disk Access (Safari's own files) and Safari's export zip | Either one alone leaves some people with no way in. A Safari guide stays out. |
| D11 | How to ship it | Three PRs: signing (#46) on its own, then Settings (#48), then Move in (#49) | CI is slow, so few PRs. Settings was mostly verified and could go first; Move in carried the risky sheet rewrite. |

## What changed

### Release signing and dev builds — #46, first in 1.0.20261007.42

- Releases are signed with `CN=Copper Release Signing` and the designated requirement
  `identifier "com.collinrijock.copper" and certificate leaf = H"76264b1f…"`
  (`release/designated-requirement.txt`, `release/package-app.sh`). Two dry runs built from the
  same commit had different cdhashes and identical requirement text, so the requirement no
  longer depends on the build.
- The release workflow decodes the certificate into a keychain made for the run, checks that it
  is the one in `release/`, and fails if `codesign -dr -` prints anything but that requirement.
  `release/package-app.sh` refuses a bundle whose id isn't the release id or whose binary
  doesn't pin the same certificate (`Signing.releaseCertificate`).
- The updater holds every download to the requirement, at staging and again just before the
  swap (`Fork/Signing.swift`, `Fork/Updates.swift`). An update that fails it is refused with a
  sentence that says where to download Copper instead ([docs/updates.md](../updates.md)).
- `./build.sh` without `COPPER_RELEASE=1` builds `com.collinrijock.copper.dev`. It is always a
  test run, it is the world `dev` when started with no world, and it doesn't claim
  `copper://` ([docs/headless.md](../headless.md)).
- **One last re-grant.** The update from the last ad-hoc release (1.0.20261007.38) to
  1.0.20261007.42 still changed the requirement, from a cdhash to the certificate, so people
  turn Copper on once more in Full Disk Access and Files & Folders and click Always Allow once
  more. After that the grants stay ([docs/releasing.md](../releasing.md)).

### Settings — #48, in 1.0.20261008.46

How Settings is built, and the rules this pass set, are in [docs/settings.md](../settings.md).

- **Every page.** `Switch`, `Segmented`, `Pill` and `Quick` are each one accessibility element
  with a role, a name (the row's title, or one given where the control is made) and a value.
  Tab reaches them with Keyboard navigation on; Space or Return flips a switch; ← → move along
  choices; a ring in ink follows the control's shape. Text fields show an ink edge while
  focused. ⌘W closes Settings rather than the tab behind it. A search result for a card lands
  with the card's title in view.
- **Narrow windows.** Spaces' icon and picture grids are adaptive, the swatches wrap, and the
  preview moves under the controls when there is no room beside them. Extensions' pills wrap and
  its tools stack. At the narrowest page column (345 points) nothing is cut off or scrolls
  sideways.
- **Sheets, not app-modal panels.** The folder chooser, Ask where to save, a space's picture and
  Load Unpacked open on their window (`SettingsPanels.present`).
- **Questions before what can't be undone.** Clear history, Sign out of everything, New token…,
  Delete space and Remove extension ask first, saying exactly what will happen; Cancel is the
  default. Cache stays one click. Sign out of everything and Clear cache now reach every profile's
  jar.
- **Browsing.** Letters work with sidebar tabs. Swipe between spaces is disabled with tabs across
  the top: "Needs tabs in a sidebar — the swipe is two fingers across it." Labs › Trails says it
  is shown in the sidebar.
- **AI & agents.** Intelligence › Check gives one plain sentence per lane that names the next step
  (`Fork/IntelligenceCheck.swift`), and the verdict is dropped when the lane, model or key
  changes. A refused key gets an orange dot. The agents page explains a port clash, shows a test
  run's port read-only, asks before New token… and names the clients that need updating, marks
  terminal agents "Out of date", and copies a prompt or config with "— with the address and
  token" said out loud. Cancelling a model-account sign-in closes its tab.
- **Data & privacy.** Send Feedback (Settings › About and Help › Send Feedback…) opens a
  prefilled issue on Copper's GitHub page (`Fork/Feedback.swift`). About reads Copper's own
  updater. Updates says "Not checked yet — Copper looks every six hours on its own", shows a
  disabled "Checking…", gives each feed error a next step, and shows "What's new in X" before
  you update. Cloud keeps a failure for the whole Sync now pass, so it no longer says "Up to
  date" when it couldn't reach the server. Passwords imports a CSV with a header check, UTF-8
  (with or without a byte-order mark), UTF-16 or Latin-1, and one of seven exact sentences, off the main thread
  (`Fork/Credentials/PasswordCSV.swift`), and exports one behind Touch ID. The password-manager
  cards record a sync that timed out, keep their cache when an item list arrives cut off, can sign
  out, and say "Wrong master password — try again". Sites never asked get one row each.
- **Search.** More phrases find their row ("sign out of everything", "change model", "beta
  features", "update channel", "ask before download"). Two words typed together match only
  whole, from the start, or with one slip, so "font" no longer lights "front of". Flipping a
  switch in the results redraws it at once.
- **Test runs stay in their world.** Autocorrect goes to WebKit through the launch's volatile
  domain; profile cookie stores are named per world; Copy and Open go to a world-private
  pasteboard and log; Make default is refused; `update.log` is the world's own; terminal-agent
  setup writes under `SEARCH_SETUP_HOME`; a Settings question in a headless test run is held for
  `bench settings confirm` instead of being declined.

### Move in — #49, in 1.0.20261008.46

How Move in works now is in [docs/flow.md](../flow.md).

- **One sheet.** `Fork/Flow/FlowPresenter.swift` is the only owner: one AppKit sheet on the
  window that asked, 560 points wide and up to 640 tall, its size never its content's. The
  per-window `.sheet` in `Split.swift` is gone. A phase redraws the middle in place, which
  scrolls in a short window. Every door goes through `Flow.present(from:via:)`; from Settings,
  Settings closes with animations off and the sheet comes up on the next turn. Every quit path
  ends the sheet first, so ⌘Q works with it up.
- **One state machine.** `Fork/Flow/FlowState.swift` holds the rules, apart from AppKit:
  sources are listed when the sheet opens and re-checked on activation only while one is
  locked; a selection is never switched under the person; a scan lands only if it holds the
  newest ticket for the selected source; every open, present, dismiss and scan is logged
  (`FlowEvents`). Nothing reads another browser's folder at launch.
- **A locked card with a way in.** `Fork/Flow/FlowAccess.swift` makes one real directory read
  and calls a source readable, locked or missing, and tells a browser installed but never opened
  from one that isn't there. The locked
  card has one sentence, "Allow in System Settings…" (Files & Folders, or Full Disk Access for
  Safari) and "Use an export instead…" (`Fork/Flow/FlowFiles.swift`). Coming back to Copper
  unlocks the card without reopening.
- **A summary that tells the truth.** One row per chosen category, filled in place as the move
  goes, ending in what arrived or why it didn't (`FlowSummary`). One key read, then three
  separate reads for passwords, sign-ins and passkeys, each with its own failure. Sign-ins are
  counted as WebKit took them. A window with only new-tab pages makes no space and is named.
  The summary stays until Done.
- **Moving in again.** The `flow.spaces.<source>` registry and `flow.brought.<source>` record
  fill existing spaces with only new tabs, remake a deleted space, skip pins already brought, and
  name a clash with the source ("Work (Arc)"). Undo removes only that run's tabs and spaces.
- **Safari.** `Fork/Flow/FlowSafari.swift` and `FlowSafariFormats.swift`: Safari's own files with
  Full Disk Access (windows, tab groups and pins become spaces), or the zip from File › Export
  Browsing Data to File… (bookmarks, history, passwords), or both. A passwords-only export never
  touches the bookmarks. One bookmarks-HTML parser (`FlowBookmarksHTML.swift`) serves Chrome's
  export and Safari's.
- **Bookmarks at scale.** The bookmark merge and take run off the main thread, in linear time;
  10,000 bookmarks in 1,000 same-named folders fold in one pass.
- **QA fixes (d2e1b40).** ⌘ shortcuts typed on the sheet no longer act on the window behind it
  (`FlowKeys`). Chrome's `Default` profile wears the shared cookie jar, so imported tabs open
  signed in. A Chrome with no session file says "no open windows" rather than "couldn't read". A
  move closed half-way announces itself and shows its summary on the next open. Asking again
  from a second window brings the sheet's window forward. With two readable sources and none
  picked, the footer says what to do.

## How it was verified

Every result below was on the tree that shipped. `swift test` was re-run on e3d642d while this
record was written: 184 tests in 37 suites passed.

**Unit tests** (`Tests/SearchTests/`, `swift test`, see [docs/settings.md](../settings.md) for
the command):

| Suite file | Tests | Covers |
|---|---|---|
| `FlowStateTests.swift` | 17 | picking, reconcile, activation re-check, scan tickets, one sheet, scans per open |
| `FlowMoveTests.swift` | 29 | fill / remake / skip, pins, naming, the summary's rows and sentences, per-leg failures, locked vs missing, file kinds, test key and stand-in, the demo Mac's Chrome (only new-tab pages, no bookmarks, 44 places) |
| `FlowChromeTabsTests.swift` | 5 | closed tabs never open, profile jars, no session files, profile order |
| `FlowBookmarksMergeTests.swift` | 4 | linear merge and take against the old per-node search, on random trees and 10,000 bookmarks |
| `FlowBookmarksHTMLTests.swift` | 18 | the bookmarks-HTML parser, encodings, one-pass fold |
| `FlowSafariTests.swift`, `FlowSafariSourceTests.swift` | 30, 10 | Safari's plist, History.db, tabs, export zip and CSV; which way in reads what; a probe never looks at this Mac's Safari |
| `SettingsShellTests.swift` | 13 | control names, arrow steps, ⌘W, confirmation answers, folder and save-panel seams, symbol names, search matching |
| `SettingsAITests.swift` | 16 | Intelligence check sentences and their lifetime, Trails and Tide by layout, sign-in cancel |
| `DataSettingsTests.swift`, `PasswordCSVTests.swift` | 17, 7 | feedback URL, CSV headers and sentences, Cloud's offline state, link codes, staged release identity, test seams off outside a test world |
| `SigningTests.swift` | 3 | the updater pins the certificate in a release; each identity is held to its own requirement |

**End-to-end scripts** (`docs/fixtures/flow-*.sh`, each in fresh headless worlds, last run on the
final tree): `flow-sheet-e2e.sh` 12 ok, `flow-move-e2e.sh` 9 ok generated and 11 ok against
read-only copies of the demo Mac's Chrome and an Arc, `flow-safari-e2e.sh` 16 ok including a
read-only real-scale Safari copy, `flow-secrets-fixture.sh` 8 ok, `flow-bookmarks-e2e.sh` 19,
`flow-canvas-e2e.sh` 2, `flow-extensions-e2e.sh` 9, `flow-extensions-parser.sh` 9, and
`flow-sheet-shots.sh` 16 ok with the frame held at 560×640. During the whole pass tccd logged no
App Data request from the development build.

**Settings gates** (fresh world): `bench settings index check` 146 entries, 0 failures;
`bench settings ax sweep` 65 controls, none unnamed, none unreachable; every page in light and
dark at 640×448 and 1440×960, scrolled top to bottom (154 pictures), with `settings browse
scroll` reporting nothing wider than the column; each confirmation held, cancelled and confirmed
through `bench settings confirm` (New token… was checked by the old token getting 401 and the new
one 200); a real ⌘Q and relaunch kept every preference while the installed Copper's
`WebAutomaticSpellingCorrectionEnabled` stayed 0. Against `fork` before the pass, back to back on
one backing: opening Settings 106.4 vs 111.9 ms busy, a keystroke 45.6 vs 42.2 ms (ranges
overlap), a page switch median 31.8 vs 31.1 ms. The one measurable cost is the first frame of
opening, 14.6 vs 11.1 ms, the price of every switch and pill being a real keyboard stop.

**Signing.** Two dry runs of the release workflow from one commit: identical requirement text,
different cdhashes, the second satisfies the first's requirement, and the last ad-hoc release's
requirement is not satisfied by a signed build (the one re-grant). An updater simulation on stub
feeds: the old updater installs a certificate-signed build; the new one refuses an ad-hoc build at
staging, and refuses a staged copy re-signed ad hoc on disk just before the swap, leaving the
running Copper untouched. A dev build's tccd events, defaults writes and WebKit store all landed
under `com.collinrijock.copper.dev`; `defaults export com.collinrijock.copper` was byte-identical
before and after.

**Adversarial QA of #49.** Eight findings, all fixed in d2e1b40:

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | P1 | ⌘W, ⌘T, ⌘K, ⌘L, ⌘N, ⌘, acted on the window behind the sheet (⌘W closed two tabs nobody could see) | `FlowKeys.take`, first in the app's key monitor after Voice: ⌘W closes the sheet, other ⌘ keys wait, ⌘Q/⌘H/⌘M/⌘\` and editing pass |
| 2 | P1 | Imported Chrome tabs opened signed out: `Default` was a profile jar of its own while the cookies went to the front space's jar | `Default` wears the shared jar; each other profile's cookies go to its own jar |
| 3 | P2 | A fresh Chrome profile said "couldn't read Chrome's open tabs", the demo's failure in other words | No session file in any profile is "no open windows"; an unreadable one still says so |
| 4 | P2 | A move closed half-way lost its summary | An announcement, and the next open shows the summary |
| 5 | P2 | Asking from a second window while the sheet was up did nothing visible | `FlowPresenter.raise()` brings its window forward |
| 6 | P2 | Two readable sources, none picked: a dimmed list and a dead button | "Choose a browser above to see what comes over" |
| 7 | P2 | `settings ax sweep` failed in any world with a saved password (an outer label overridden by the switch's empty one) | The label is handed to `Switch(label:)` |
| 8 | P2 | `flow-sheet-e2e.sh`'s "no App Data request" check looked for the release bundle id, so on a dev build it always passed | The id is read from the app's Info.plist |

What held under attack: 30 open/close cycles through every door in one and three windows, with
activations in between (presents equal dismisses, never two at once, one scan per open, the size
fixed); Escape, ⌘W and ⌘Q in every phase, including ⌘Q in the middle of a slowed move and a
relaunch; switching sources mid-scan on a 20,000-bookmark Chrome (the last pick wins, every
superseded scan dropped); 400 tabs, 20,000 bookmarks and 30,000 places in one move (main-thread
round-trip p95 2.0 ms, worst 84 ms); every malformed file tried, each a plain sentence; Chrome,
Safari, Arc and Chrome again in one world without twins; 65 open–scan–close cycles with no memory
growth.

Left as known, by design or too rare to change now: a source that becomes locked while the sheet
is open is not noticed until a move says what it couldn't read; after another source's import, a
Chrome re-run with nothing new moves Chrome's bookmark root to the end of the top level; a CSV row
with an unterminated quote reads as "no site or no password".

## What still needs a person

These need the installed Copper, real permissions or real accounts, which no test run touches.

- **Grants survive the next update.** After the update from 1.0.20261007.42 to
  1.0.20261008.46 (the first between two signed releases), Copper must still be on in Full Disk
  Access and Files & Folders with no prompt, and the keychain must not ask again.
- **Chrome, real permission.** Allow in System Settings… opens Files & Folders; turning Copper's
  Chrome switch on and coming back unlocks the card without reopening.
- **Chrome, real keychain.** macOS asks once for "Chrome Safe Storage". Allow: passwords,
  sign-ins and passkeys arrive, and a second move adds none. Deny: those three rows say why.
- **Safari, real Full Disk Access and a real export.** Allow Full Disk Access… opens the right
  pane; after granting and relaunching, a move makes windows and tab groups into spaces. Drag an
  exported zip onto the sheet (the only way to see the drag highlight), move, then delete the
  zip.
- **No morphing, one sheet.** Settings › General › Move in…: nothing morphs as Settings goes;
  two windows still give one sheet.
- **Keyboard and VoiceOver.** With Keyboard navigation on, Tab through General, Intelligence,
  Passwords and Voice: every control shows a ring, Space flips a switch, ← → move Appearance,
  Escape closes. VoiceOver reads "Correct spelling as you type, off, switch", and the Move in
  sheet's ✕ reads "Close".
- **Dialogs and sheets.** New token… (Cancel keeps it; confirm marks terminal agents "Out of
  date"); Clear history; Sign out of everything with two profile spaces signs out both; Delete
  Space…; Remove an extension; Ask where to save attaches to the window and Cancel stops the
  download; a changed downloads folder survives a relaunch.
- **Real accounts.** Make default; model-account Sign in, Sign out and Cancel; a password
  manager's Sign out and Sync now; import an Apple Passwords CSV, then Export… → Touch ID →
  delete the file; Forget a passkey; delete the last hour of one site on Copper Cloud.
- **By eye.** A search for "agents may use" glides to the Agent access card with its title
  showing (headless runs jump instead of gliding); a port clash on the agents page shows its
  sentence and an orange dot; swiping over the sidebar with Natural and Inverted scrolling.

## Regression guards

If one of these failures comes back, this is what catches it.

| Failure | Caught by |
|---|---|
| Releases signed ad hoc, or with another certificate (grants lost on update) | The release workflow's *Check the signature* (exact requirement text); `release/package-app.sh`'s pin check; `SigningTests.theUpdaterPinsTheCertificateInRelease` |
| The updater installs a build that would drop grants | `SigningTests` (each identity to its own requirement); the updater's refusal at staging and before the swap, rehearsed with `bench updates requirement` and `updates stub` ([docs/updates.md](../updates.md)) |
| A development build lands on the installed Copper's grants, defaults or cookies | `build.sh`'s dev id; `Store.testing` for any non-release id; the `defaults export` and tccd check in [docs/headless.md](../headless.md) |
| Two sheets, or a sheet that fades out and back | `FlowStateTests` (sequential, twoSheets); `flow-sheet-e2e.sh` (two windows, presents = opens, never overlapping); `bench flow events` |
| The sheet changes size between phases or clips | `flow-sheet-e2e.sh` (size between phases); `flow-sheet-shots.sh` (frame held at 560×640) |
| Rescans on activation, or a stale scan landing | `FlowStateTests` (activation, newestWins, leftSourceDropped, scansPerOpen); `flow-sheet-e2e.sh` (one scan per open) |
| An App Data request at launch | `flow-sheet-e2e.sh` ("no source read at launch", and the tccd log for the app's own bundle id) |
| ⌘ keys acting behind the sheet; Escape, Return or ⌘Q not working | `flow-sheet-e2e.sh`, through `bench flow key escape\|return\|cmd-…` and `windows quit` |
| A locked source with no way in, or one that needs a reopen | `FlowMoveTests` (denied, state, privacyPage, kinds); `flow-move-e2e.sh` and `flow-safari-e2e.sh` (locked → export → allowed → `flow activate`) |
| A summary that hides why nothing came | `FlowMoveTests` (rows, inPlace, secondRun, legs, refusedKey, emptiesLeftOut, realChromeCopy); `flow-move-e2e.sh` |
| A second move duplicating spaces, tabs, bookmarks or places; Undo taking too much | `FlowMoveTests` (secondMoveFills, nothingNew, deletedIsRemade, redirected, pinsBrought, record); `flow-move-e2e.sh`, `flow-safari-e2e.sh` (mixed world), `flow-bookmarks-e2e.sh` |
| Imported tabs signed out | `FlowChromeTabsTests.profileJar`; `flow-secrets-fixture.sh` |
| A slow bookmark merge | `FlowBookmarksMergeTests` (tenThousand, manyFolders); `FlowBookmarksHTMLTests.aLongFlatLevelFoldsInOnePass` |
| A passwords-only Safari export deleting bookmarks | `FlowSafariTests.noBookmarkFileMeansNoTake`, `FlowSafariSourceTests.aPasswordsOnlyExportHasNoBookmarkRead`; `flow-safari-e2e.sh` |
| A test run reading this Mac's Safari, the keychain, or Chrome's real key | `FlowSafariSourceTests.aProbeNeverLooksAtThisMacsSafari`; `FlowMoveTests` (testKey, probeSink); `DataSettingsTests.probeSeamsAreOffOutsideATestWorld` |
| A Settings control Tab can't reach or VoiceOver can't name | `bench settings ax sweep`; `SettingsShellTests` (nameComesFromWhereItWasMadeThenTheRow, arrowsStepAlongAndStopAtTheEnds) |
| A row search can't land on, or an anchor with no entry | `bench settings index check` |
| Search finding the wrong thing | `SettingsShellTests` (shortWordsNeedTheirOwnLetters, eightLettersForgiveOneSlipNotTwo, wordsRunTogetherLandWholeNotPickedApart, prefixesAndShorthandStillLand); `bench settings search --table` |
| ⌘W closing the tab behind Settings | `SettingsShellTests.onlyPlainCommandWClosesSettings` |
| A destructive action without a question | `bench settings confirm` (and `confirm selftest`); `SettingsShellTests` (aButtonIsNamedByNumberTitleOrItsStart, answersAreTheAlertsOwnResponses) |
| A page wider than the column at the minimum size | `bench settings browse scroll` (`sideways`) and `settings browse picture` at 640×420 |
| Settings getting slower | `bench settings perf run` and `settings perf switch 3`, compared back to back with `fork` |
| Send Feedback going anywhere but Copper's issues page | `DataSettingsTests` (feedbackOpensANewIssueOnCoppersOwnPage, feedbackKeepsAPlusAPlus); `bench about feedback` |
| Cloud or Updates saying something untrue | `DataSettingsTests` (cloudSaysOfflineWhenAPassFailedEvenIfALaterStepHadNothingToSend, aReCutReleaseUnderTheSameVersionIsNotTheStagedOne); `bench updates stub` |
| CSV import or export saying the wrong thing | `PasswordCSVTests`; `DataSettingsTests` (csv…); `bench passwords csvcheck\|import\|export` |
| Intelligence › Check showing raw errors | `SettingsAITests` |

## Not done in this wave

- No `scripts/test.sh` wrapper for `swift test`; the plugin flag it would pass is written out in
  [docs/settings.md](../settings.md).
- The test-seam gates are separate functions (`Store.testing`, `ProbeKeychain.decide`,
  `SettingsActions.probe`, `FlowSecrets.seams`, `Setup.testHome`, `Links.refusesDefault`), not
  one shared function. `DataSettingsTests.probeSeamsAreOffOutsideATestWorld` checks each.
- In a probe world, Chrome-family sources are read from this Mac's own folders unless the run
  points them elsewhere with `flow limit` and `flow root`. The e2e scripts point every source
  they move at a fixture; a hand-driven probe that opens Move in without them asks macOS for Chrome's folder as the dev app.
- The Safari guard is `SEARCH_PROBE` (`Flow.probe`), not "a test run": a dev build opened with
  no world (the world `dev`) is a test run but not a probe, and looks at this Mac's Safari.
- Passwords › Import still opens its file panel app-modal (`Browser.importPasswords`).
