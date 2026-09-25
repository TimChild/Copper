# Flow

Flow is Copper's one-button move in from Chrome or Arc. It reads the other
browser's files locally and never changes them.

## What moves

- open tabs, windows and Arc spaces (as sleeping Copper tabs)
- pinned tabs and tab groups
- bookmarks and history
- passwords, cookies, and Google Password Manager passkeys, after one macOS
  approval for the browser's Safe Storage key
- Chrome Web Store extensions that Copper can reinstall

A source is detected from its profile folders and `Preferences`, not from the
presence of `Login Data`, so a browser with no saved passwords still appears.
Each imported space is new. A name collision gets ` (Chrome)` or ` (Arc)`.
Imported pages do not load until their space is visited.

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
./bench --world flowqa flow scan --source Chrome
./bench --world flowqa flow root --source Chrome --path /tmp/chrome-copy
./bench --world flowqa flow move --source Arc --only tabs,bookmarks,history,extensions
./bench --world flowqa flow open
```

`./arc-import` remains for older installations and one-off recovery, but is
superseded by Flow.
