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

### macOS may keep Chrome private

On macOS 26, App Data protection can deny Copper's first directory listing of
`~/Library/Application Support/Google/Chrome`. Flow keeps Chrome in the picker
as a locked source instead of silently dropping it. A Dock-launched Copper may
show macOS's permission prompt on that first attempt; say **Allow**, then close
and reopen Move in so Flow can try again.

If the prompt is not shown (including test worlds), choose **Choose folder…**
on Chrome's card. The panel starts beside Chrome; pick the `Chrome` folder and
press **Allow**. Copper verifies that the selected folder is the expected root,
uses it only for this session, and never writes into it. You can also grant
Copper under **System Settings › Privacy & Security › App Data** (or **Files &
Folders**) and reopen the sheet.

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
