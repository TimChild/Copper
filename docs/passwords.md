# Passwords in Copper

Copper keeps the two password sources side by side:

- **The macOS keychain** remains the default save destination.
- **Bitwarden** is an optional backend driven by the official `bw` command-line
  client. When it is connected, fills merge keychain and Bitwarden accounts;
  choosing Bitwarden only changes where new save offers go.

Copper never needs a browser extension for either source. A saved account is
read only when the user picks it (or an agent is allowed to use it), not while
the picker is being drawn.

## Speed, staying unlocked, and updates

- After unlock Copper reads the item list once (and every five minutes) and keeps
  it in memory — names, sites, and the secrets that came with it. A pick fills
  at once; one-time codes are computed locally from the stored seed (`bw get
  totp` is the fallback for formats Copper does not parse). Locking clears all
  of it.
- **Stay unlocked between launches** (on by default, Bitwarden card) keeps the
  session key in a 0600 file beside Bitwarden's own data under Copper's support
  folder, so the vault opens with the app. Turn it off to be asked for the
  master password once per launch. Lock deletes the file.
- Saving a sign-in whose account already exists in Bitwarden for that site
  **updates that item's password** instead of adding a twin.

## Connect Bitwarden

Install the CLI first:

```sh
brew install bitwarden-cli
```

Then open **Settings › Passwords › Bitwarden**. Enter the server, email, master
password, and (when needed) the optional two-factor code, then choose **Sign
in**. The server field accepts:

- Bitwarden cloud: `https://vault.bitwarden.com`
- Bitwarden EU: `https://vault.bitwarden.eu`
- a self-hosted Bitwarden server; or
- a Vaultwarden server (use the server URL it provides).

Copper passes the password to a short-lived `bw` process through its environment,
never as a command-line argument. It gives `bw` a Copper-owned appdata directory
under the current Copper support folder, so it does not read or mutate the
user's normal Bitwarden CLI directory. Probe worlds have their own support
folder as well.

After sign-in or unlock, Copper holds the Bitwarden session key **only in its
process memory**. Locking clears that key and the in-memory metadata. It is
therefore expected that an external `bw status` can report `locked` while
Copper's Settings card says `Unlocked`: the external CLI has no Copper session
key. Relaunching Copper also starts locked; unlock it from Settings with the
master password.

The auto-lock picker is **5 minutes**, **15 minutes**, **60 minutes**, or
**Never**. The default is **Never**. A background metadata refresh runs every
five minutes while unlocked; a cold `bw` start is about 2.5 seconds, so the
picker uses an in-memory cache instead of launching `bw` for every row.

The cache contains only matching metadata: item names, usernames, URI rules,
folder information, whether a TOTP exists, and the agent-sharing hint. It does
not retain passwords, TOTP seeds, or the Bitwarden session key. Copper fetches
a password or TOTP code only for the single fill operation that needs it.

## Fills and saves

The under-field picker combines keychain and Bitwarden candidates. Select a row
to fill it; a Bitwarden TOTP can also be filled into a one-time-code field.
While Bitwarden is unlocked, turn on **Save new passwords to Bitwarden** in its
Settings card to route new save offers there. Turn it off (or leave Bitwarden
unavailable) to keep saving to the keychain. Existing fills continue to include
both sources.

## Agent access

Open **Settings › Passwords › Agent access** to decide which saved accounts an
agent may use. The card exposes a share-everything switch and a per-account
toggle over the keychain + Bitwarden list. Sharing is off unless the user turns
on the broad switch, enables that account, or uses the Bitwarden convention:

- an item in a folder named `Agents` (case-insensitive) is allowed; and
- a custom field named `copper-agent` with value `deny` always denies that item,
  including when share-everything is enabled.

The policy and toggles stay in Copper and are not editable through MCP or the
CLI. See [Agents](agents.md) for `browser_sign_in`, `copper signin`, and Jev's
`SIGN_IN` control. Those operations fill in-process and return status only;
they do not return a password, TOTP code, or Bitwarden session key. Private
(`shy`) tabs are refused. With `--no-submit`, the secret remains in the page by
design, so do not immediately ask ordinary page-reading tools to inspect that
tab.

## Apple Passwords import

Apple's live Passwords AutoFill integration is closed to Copper: Apple's helper
has a kernel launch constraint that requires the Developer ID entitlement Copper
does not have. Import a copy instead:

1. Open the **Passwords** app.
2. Choose **File › Export All Passwords** and save Apple's CSV export.
3. In Copper, open **Settings › Passwords › Import…** and choose that CSV.

The import goes into Copper's keychain backend. It is a one-time import, not a
live Apple Passwords connection; handle the exported CSV as sensitive data and
delete it when it is no longer needed.

## Testing with `./bench bw`

The bench backend is intended for isolated probe worlds, not the user's live
Copper session. Run the command with a world name when testing, for example
`./bench --world creds bw status`.

Available verbs are:

```text
./bench bw status
./bench bw server URL
./bench bw login EMAIL PASSWORD [OTP]
./bench bw unlock PASSWORD
./bench bw lock
./bench bw sync
./bench bw candidates HOST
./bench bw share all on|off
./bench bw share bw:<item-id> on|off
```

`status` reports state, server, installation, and the last error. `candidates`
returns stripped usernames and matching metadata; `share` changes Copper's
agent policy. Use placeholders in examples and avoid shell history or
transcripts containing credentials—never paste a real password, TOTP, or session
key into documentation or a report.
