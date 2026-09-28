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

After sign-in or unlock, Copper holds the Bitwarden session key in its process
memory and — only while **Stay unlocked between launches** is on — in the 0600
`session` file described below. Locking clears the key, the file and the
in-memory metadata. It is expected that an external `bw status` can report
`locked` while Copper's Settings card says `Unlocked`: the external CLI has no
Copper session key. With Stay unlocked off, relaunching Copper starts locked;
unlock it from Settings with the master password.

The auto-lock picker is **5 minutes**, **15 minutes**, **60 minutes**, or
**Never**. The default is **Never**. A background metadata refresh runs every
five minutes while unlocked; a cold `bw` start is about 2.5 seconds, so the
picker uses an in-memory cache instead of launching `bw` for every row.

While Bitwarden is unlocked, the in-memory cache holds matching metadata and the
values needed for an immediate fill: passwords, TOTP seeds, identity details,
card numbers/CVV, notes, and custom-field values. It is protected by the same
process boundary as the session key, is never returned over MCP or the CLI, and
is wiped (including identity/card values) when you lock the vault.

## Fills and saves

The under-field picker combines keychain and Bitwarden candidates. Select a row
to fill it; a Bitwarden TOTP can also be filled into a one-time-code field.
While Bitwarden is unlocked, turn on **Save new passwords to Bitwarden** in its
Settings card to route new save offers there. Turn it off (or leave Bitwarden
unavailable) to keep saving to the keychain. Existing fills continue to include
both sources.

## Autofill everything

Turn on **Fill addresses and cards** in Settings › Passwords to let the
under-field picker fill more than sign-ins (`prefs.fillsEverything` is on by
default). Click any recognised field in a checkout or address form:

- **Identities** fill a name, email, phone, company, street lines, city, state,
  postal code, and country as one group. Copper shows the identity name and a
  short address summary, never the private values in the row.
- **Cards** fill the cardholder, number, expiry, brand, and security code as one
  group. Card numbers and codes stay in memory only while unlocked.
- **Custom fields** are matched by a field's name, id, placeholder, or label to
  a custom field on a login item for the current host. Hidden custom fields are
  treated like passwords and are never listed with their values.
- **Most-used usernames** appear on an email or username field even when there
  is no saved account for that site. They are deduplicated and limited to the
  eight most-used names (then identity emails/usernames).

Agent access applies to identities and cards as well as login credentials. Open
Settings › Passwords › Agent access and enable a per-item toggle (or the
share-everything switch) before an agent can use one. The picker itself can
still use every unlocked item; the agent allow-list only gates agent fills.

## Signing in without a window: `copper bitwarden` and the headless Mac page

A headless Copper (a headless Mac mini's LaunchAgent, docs/headless.md) has no
Settings window to type into. The same backend is driven through the loopback
agent server's `copper/bitwarden` method (127.0.0.1 + the bearer token in
`agent.json`; the agent link refuses every `copper/*` method, so no bot can
reach it) and its CLI:

```sh
copper bitwarden status                    # JSON report (default)
copper bitwarden login - < payload.json    # sign in + unlock; ONE JSON object on stdin
copper bitwarden lock | logout | sync
copper bitwarden policy [--share folder|all] [--stay-unlocked on|off]
```

`login -` reads `{server?, email, password, clientId?, clientSecret?, otp?,
otpMethod?, share?, stayUnlocked?}` from stdin. Secrets are refused on argv, so
they never show up in `ps`. The headless Mac page seals the same object in the
owner's browser to the Mac's device key; an external daemon decrypts it in
memory and pipes it into `copper bitwarden login -`. The service only ever
relays ciphertext.

What `login` does, in order:

1. `bw config server <server>`, but only when the CLI is signed out. With no
   `server`, and no server configured in the CLI, it uses
   `https://vault.bitwarden.com`. Only `https://` URLs are accepted, plus
   `http://` to this Mac for a local Vaultwarden.
2. If the CLI is already signed in to another account or server, `bw logout`
   first. The same account on the same server is kept as it is.
3. **API key** (recommended for an unattended Mac): with `clientId` +
   `clientSecret` (Bitwarden web vault › Settings › Security › Keys › View API
   key) it runs `bw login --apikey`, passing `BW_CLIENTID` / `BW_CLIENTSECRET`
   only through the child's environment. This skips the two-step prompt and
   new-device email verification. It leaves the account signed in but
   **locked**.
   **Email + master password** otherwise: `bw login EMAIL --passwordenv
   BW_PASSWORD`, plus `--method N --code OTP` when `otp` is given. N is 0 for an
   authenticator app (the default), 1 for email and 3 for YubiKey OTP.
4. `bw unlock --passwordenv BW_PASSWORD` when the vault is locked. The master
   password is always required, because it is what decrypts the vault.
5. Applies the policy: `share` `folder` | `all` (below) and `stayUnlocked`.

Every answer is `{ok, cli, cliVersion, state
(missing|unauthenticated|locked|unlocked), email, server, lastSync,
agentAccess (folder|all), stayUnlocked, counts {logins, identities, cards}}`. A
failure adds `error`: one line of at most 200 characters, with anything the
caller sent as a secret cut out. No answer ever holds a password, API secret,
session key or vault value. Exit codes: 0 `ok`, 1 `ok: false`, 2 usage or Copper
unreachable.

`bw` itself is found in this order: `SEARCH_BW_PATH` (the daemon points its
LaunchAgent at the CLI it installed), `/opt/homebrew/bin/bw`,
`/usr/local/bin/bw`, then `$PATH`.

**What is stored where:**

| Where | What | Who writes it |
|---|---|---|
| `<Copper support>/bitwarden/` (0700; `bitwarden (<world>)` in a probe world) | `bw`'s own `data.json`: the encrypted vault, auth tokens, and, after an API-key login, the client secret it keeps for token refresh (the Bitwarden CLI always does this) | `bw` |
| `<Copper support>/bitwarden/session` (0600) | the session key, only while *stay unlocked* is on | Copper |
| Copper's defaults | server URL, *stay unlocked*, agent-access policy | Copper |

Nothing of Copper's writes a master password, or an API secret, to disk.
**Lock** drops the session key and its file. **Sign out** (`logout`) wipes the
CLI's account state. Turn *stay unlocked* off to need the master password after
every restart, and keep FileVault on for the Mac.

**Agent policy:** `share: folder`, the default, lets agents use only items in
the Bitwarden folder named `Agents`, items with `copper-agent: allow`, and
accounts shared one by one in Settings. `share: all` shares everything
(Settings' share-everything switch). `copper-agent: deny` always wins. Either
way, agents never receive the secret itself (next section).

## Agent access

Open **Settings › Passwords › Agent access** to decide which saved accounts an
agent may use. The card exposes a share-everything switch and a per-account
toggle over the keychain + Bitwarden list. Sharing is off unless the user turns
on the broad switch, enables that account, or uses the Bitwarden convention:

- an item in a folder named `Agents` (case-insensitive) is allowed; and
- a custom field named `copper-agent` with value `deny` always denies that item,
  including when share-everything is enabled.

The per-account toggles stay in Copper and are not editable through MCP. The
broad switch can also be set by the owner from the shell or the headless Mac page
(`copper bitwarden policy --share folder|all`, loopback only; see above). See [Agents](agents.md) for `browser_sign_in`, `copper signin`, and Jev's
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
./bench bw identities
./bench bw cards
./bench bw fields HOST
./bench bw usernames
./bench bw counts
./bench bw autofill card ID
./bench bw autofill identity ID
./bench bw share all on|off
./bench bw share bw:<item-id> on|off
```

`status` reports state, server, installation, and the last error. `candidates`
returns stripped usernames and matching metadata; `share` changes Copper's
agent policy. Use placeholders in examples and avoid shell history or
transcripts containing credentials—never paste a real password, TOTP, or session
key into documentation or a report.
