# Flow

Flow is Copper's one-button move in from Chrome or Arc. It reads the other
browser's files locally and never changes them.

## What moves

- open tabs, windows and Arc spaces (as sleeping Copper tabs)
- pinned tabs and tab groups
- bookmarks and history

Chrome stores signed-in synced bookmarks in `AccountBookmarks` and local-only
bookmarks in `Bookmarks`. Flow reads both for every profile found by
`Preferences` (no `Login Data` needed), in profile order (`Default`, then named
profiles); within a profile, account bookmarks come first, then local. The
Chrome bookmark bar is Copper's top-level bookmark list, followed by an
`Other` folder and a `Mobile` folder for Chrome's other/synced roots. Matching
folder names merge recursively, preserving child order; an identical URL and
title at the same level is kept only once. Only HTTP(S) sites move. Copper's
existing top-level bookmarks stay in place: imported bar items follow them,
not a `Chrome` folder. If an imported root folder's name collides with one of
yours, the imported folder is named `Other (Chrome)` (or similarly). A repeat
Flow import replaces *untouched top-level items from the previous import*;
anything you edited, moved (including a move within the top level), or saved
yourself is left alone. If a present Chrome bookmark file cannot be read,
Flow keeps previous imported roots and merges what it can read; a successfully
read empty tree does remove untouched imported roots. The source-owned root
IDs are recorded in `flow-bookmarks-chrome.json` in Copper's own data folder. On a first import into an older Copper tree without that record,
previously filed `Chrome` folders are left alone rather than guessed at or
deleted.

History import reads every visible URL with a visit from the selected Chromium
profile; it is not capped at the old 3,000-row preview limit. Copper keeps up to
20,000 distinct places locally and merges a repeated import idempotently (the
larger visit count and newest title/date win).
- passwords, cookies, and Google Password Manager passkeys, after one macOS
  approval for the browser's Safe Storage key
- Chrome Web Store extensions that Copper can reinstall

A source is detected from its profile folders and `Preferences`, not from the
presence of `Login Data`, so a browser with no saved passwords still appears.
Each imported space is new. A name collision gets ` (Chrome)` or ` (Arc)`.
Imported pages do not load until their space is visited.

After a Chrome move finishes, Copper opens **Switching from Chrome** in front: a
local canvas explaining where Chrome windows, tabs, bookmarks and more landed,
plus the sidebar and the keys to start with. It stays on this Mac, even when
Copper Cloud is signed in. A later move reopens the same canvas (including any
edits you made), without adding its template shapes again. Arc and other
Chromium sources do not open this Chrome-specific guide.

The new spaces are written to `session.json` the moment they are adopted,
before the keychain prompt, cookie decryption, and extension downloads that
follow. Quitting (or force-quitting) Copper during those later steps keeps the
spaces. Extensions are queued and installed one after another in the
background with no dialog per item — the Extensions switch is the yes — and
the sheet's "All set" count updates when they have landed. Every step logs one
`Copper: Flow …` line to the unified log (`log show --predicate 'process ==
"Copper" AND eventMessage CONTAINS "Flow"'`).

## What needs an answer

macOS may ask once for Chrome or Arc's keychain key. Say **Allow** to move
passwords, signed-in cookies, and Google Password Manager passkeys. The footer
names the selected browser and disappears when those three choices are off. If
the key is refused, tabs, bookmarks, history and extensions still move and Flow
reports the refusal. The key is never written to disk.

### macOS keeps Chrome private

macOS 26 puts other apps' data behind "App Data" protection
(`kTCCServiceSystemPolicyAppDataDetailed`, keyed by the other app's bundle id).
Copper's first listing of `~/Library/Application Support/Google/Chrome` is
denied — and, measured on 26.x with a Finder-launched build, **macOS never
prompts for this service** (`tccd`: "does not allow prompting; recording
denied"). Arc's folder is not covered. Flow keeps Chrome in the picker as a
locked source instead of silently dropping it.

Press **Choose folder…** on Chrome's card. The panel opens beside Chrome; pick
the `Chrome` folder and press **Allow**. Picking it yourself is the consent
macOS accepts: Copper verifies the folder is the expected root, uses it only
for this session, and never writes into it. The first denied attempt also
records Copper under **System Settings › Privacy & Security** (Files & Folders
/ App Data), where it can be switched on for good; reopen Move in afterwards.

Flow does not move Apple Passwords, iCloud tabs, or a password manager's
private vault. Chrome passkeys saved to iCloud Keychain (rather than Google
Password Manager) cannot be read by anyone but Apple's own stack, so they do
not move. Arc's per-space profiles and passwords also depend on Arc's keychain
key; without it, the spaces still arrive but their signed-in state does not.

Passwords exported as a CSV can be brought in separately from the empty-state
link or Settings › Passwords.

## Test runs

The `bench flow` commands are available in an isolated `SEARCH_PROBE` world:

```sh
./bench --world flowqa flow sources
./bench --world flowqa flow root --source Chrome --path /tmp/chrome-copy
./bench --world flowqa flow scan --source Chrome
./bench --world flowqa flow move --source Chrome --only bookmarks
./bench --world flowqa flow bookmarks  # imported tree, sites and folder order
./bench --world flowqa flow open
```

`docs/fixtures/flow-bookmarks-e2e.sh` copies the small fake Chrome root,
starts a fresh headless `SEARCH_PROBE` world, asserts the scan count and the
actual moved tree (including a moved root, a corrupt file, an empty source,
and preservation of an existing Copper bookmark), then removes only that world. Build the app with `./build.sh` first.
The fixture commits only bookmark files for Profile 1 and Profile 2; the
script writes the two empty `Preferences` markers into its *copy* because
Flow uses them to discover profiles. The shared fixture root may also hold
other workers' Default profile metadata.

The finished `flow move`/`flow status` JSON has a `canvasId` for Chrome. For an
isolated headless run using a generated fake Chrome profile, run
`docs/fixtures/flow-canvas-e2e.sh [build/Copper.app]` (no real Chrome data or
Copper world is opened).

`./arc-import` remains for older installations and one-off recovery, but is
superseded by Flow.
