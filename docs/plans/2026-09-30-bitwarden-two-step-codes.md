---
kind: implementation-record
plan_id: copper-bitwarden-two-step-codes
title: Bitwarden sign-in with email two-step codes and new-device verification codes — `bw login` with its prompts on
status: shipped
created: 2026-09-30
shipped: 2026-09-30 (fork 0045d7a → Copper 1.0.20260930.35)
repository: collinrijock/Copper (branch `fork`; built in worktree ~/src/copper-agentview, branch agent-view-bw-email)
base_revision: 44ec5a3 (origin/fork, 2026-09-30)
owners: [felipe]
predecessor: docs/plans/2026-09-25-bitwarden-credentials.md (logins + TOTP + agent sign-in), docs/plans/2026-09-27-bitwarden-autofill-everything.md
---

# Bitwarden: email two-step codes and new-device codes

## The problem

Settings › Passwords › Bitwarden signed in with email, master password and an *optional
two-factor code* — one shot, `bw login EMAIL --passwordenv BW_PASSWORD [--method 0 --code
OTP] --raw`, always with `BW_NOINTERACTION=true`. That works for an authenticator app: the
user already has the six digits. It cannot work for **email two-step login**, and a
teammate hit exactly that:

1. Bitwarden only emails the code once the password has been accepted — so the first
   attempt, with the code field blank, is what makes the email go out. Non-interactive, the
   CLI then fails with `Code is required.` and Copper showed that as an error.
2. The user reads the email and types the code into the *optional* field. Copper sent it
   with `--method 0` — an **authenticator** code — so the server refused it.

The same shape hides a second case: an account **without** two-step login signing in from a
Mac Bitwarden has not seen. Since 2025 the server answers with *new device verification*
and emails a code; the CLI's only way to take it is its own prompt ("New device
verification required. Enter OTP sent to login email:") — there is no `--code`-style flag
for it at all. Non-interactive that is also `Code is required.` A casual user describes
either as "Bitwarden emailed me a code and Copper wouldn't take it".

## What the CLI actually does (bw 2026.9.0, read from `bw.js`)

- With `--method N --code X` the token rides in the *first* token request; a valid code
  signs in with no prompt and no second email.
- Without a code: the password grant comes back `requiresTwoFactor`. If `--method` names a
  provider the account has, it is selected; else with one provider that one is selected;
  else the CLI asks **"Two-step login method:"** as an arrow-key list (non-interactive:
  `Login failed. No provider selected.`). If the selected provider is Email and there is no
  token, the CLI calls `postTwoFactorEmail` (**this** is what sends the email when the
  account has several methods; when email is the only method the server already sent one on
  the failed grant). Then it asks **"Two-step login code:"** (non-interactive: `Code is
  required.`), and finishes with `logInTwoFactor`.
- `requiresDeviceVerification` → prompt **"New device verification required. Enter OTP
  sent to login email:"**, then `logInNewDeviceVerification(otp)`. No flag.
- `canInteract` is simply `process.env.BW_NOINTERACTION !== "true"`; inquirer renders its
  prompts on **stderr** and reads **stdin**. Verified over plain pipes: the prompt line
  arrives (`? Two-step login code: `), a line written to stdin answers it (the prompt is
  re-drawn once per echoed character), exit 0 leaves the session key alone on stdout with
  `--raw`, a wrong code exits 1 with `Token is invalid! IP: …` (Vaultwarden) / `Two-step
  token is invalid. Try again.` (Bitwarden cloud) on stderr.

So: run `bw login` the way its authors did — interactively — and be the terminal.

## What was built

### `Bitwarden.Interactive` (`Sources/Search/Fork/Credentials/BitwardenLogin.swift`)

One `bw login … --raw` with its prompts on: `BW_NOINTERACTION` removed from the child's
environment (every other `bw` command keeps it), `BW_PASSWORD` and
`BITWARDENCLI_APPDATA_DIR` set as before, `COLUMNS=120` so inquirer has a width. stdin,
stdout and stderr are pipes. Two background readers drain stdout and stderr to their end;
the stderr reader strips ANSI (`Interactive.plain`) and scans what came since the last
answer for:

| stderr contains | `Prompt` | What Copper does |
|---|---|---|
| `New device verification required` | `.newDevice` | holds `bw`, asks the user for the emailed code |
| `Two-step login code:` | `.code` | holds `bw`, asks for the code (an email went out if the method is email) |
| `Two-step login method:` … `Cancel` | `.methods([names])` | parses the list (`❯ Authenticator App`, `Email`, `Yubico OTP Security Key`), **terminates `bw`** — nothing was sent yet — and lets the caller pick |

`start(timeout:)` answers with the first prompt or the exit; `answer(_:timeout:)` writes
`code\n` and answers with what follows; the exit is reported only after both readers hit
EOF, so the caller sees every byte (the readers are counted into the group *before*
`process.run()`). A prompt that reappears right after its own answer is the echo, not
news. `onLostWhileWaiting` fires when `bw` ends while nobody is waiting on it (it died or
timed out on its own), so the holder can let the pending sign-in go.

### `Bitwarden.login` and friends

```swift
func login(email:, password:, otp: String? = nil, method: Int? = nil) async throws -> LoginOutcome
// .signedIn
// .step(.chooseMethod([TwoStepMethod]))          // several methods; call again with method
// .step(.needsCode(.twoStep(method: Int?)))      // bw is waiting; method nil = the CLI picked the only one
// .step(.needsCode(.newDevice))
func submit(code:) async throws                    // answers the held prompt; success = unlocked
func cancelPendingLogin()
@Published private(set) var pendingLogin: PendingLogin?   // {email, prompt, method, started}
```

`method` is `bw --method` (0 authenticator, 1 email, 3 YubiKey; `TwoStepMethod`); nil lets
the CLI pick when the account has one. An `otp` given up front is passed as `--code` (with
`--method 0` when no method was named — the old single-shot authenticator behaviour, kept)
and, should a prompt still appear, is written to it at once. A held sign-in lives ten
minutes (`pendingLoginLifetime`), then `bw` is let go. `logout()` cancels a pending sign-in.
`loginFailure` turns the CLI's last line into a sentence ("That code wasn't accepted",
"Username or password is incorrect").

### Settings › Passwords › Bitwarden (`CredentialsSettings.swift`)

The card is a small state machine — `.credentials` → `.chooseMethod([…])` → `.code(prompt)`:

- **Credentials**: server, email, master password ("A two-step or new-device code is asked
  for next, if the account wants one"), **Sign in**. The always-visible optional code field
  is gone.
- **Choose method**: one pill per method the CLI listed; picking one signs in again with it.
- **Code**: worded for the prompt — *Enter the code Bitwarden emailed* (+ **Send again**),
  *Enter your authenticator app code*, *Touch your YubiKey*, *Enter your two-step login code*
  (+ **Email me a code**, when the CLI picked the method itself and Copper cannot tell which),
  *New device — enter the emailed code*. **Continue** submits; **Cancel** lets `bw` go.
- A refused code ends that `bw`; the card starts a fresh sign-in at once (a fresh email goes
  out when that is the method) and says so under the error, so the next code has somewhere
  to go. If `bw` gives up on its own (ten minutes) the card falls back to credentials with a
  sentence.
- A card that opens while a sign-in started elsewhere (`copper bitwarden login -`, a linked
  app's Mac page) is waiting starts on the code step for that email — `init` reads
  `Bitwarden.shared.pendingLogin`, and `onChange` follows it later.

### `copper bitwarden login -` (`BitwardenControl.swift`, `CLI.swift`)

The control op became a two-call protocol, backwards compatible:

- A call with `otp` (and `otpMethod`, default 0 when `otp` is present) behaves as before —
  one shot, authenticator.
- A call without `otp` that hits a prompt answers `{ok:false, needs:"code",
  prompt:"twoStep"|"newDevice", method: N|null, pending:true, error:"Bitwarden emailed a
  two-step code to the account — call again with otp"}` and `bw` is held open. The **second
  call with the same `email` and the `otp`** hands the code over (`submit`), unlocks and
  applies the policy.
- Several methods and none named → `{needs:"method", methods:[{id,name}]}`; call again with
  `otpMethod`.
- New op **`cancel`** lets a waiting sign-in go. Unknown extra keys are ignored by older
  callers; secrets are still cut out of every echoed message.

### Bench

`./bench bw login EMAIL PASSWORD [OTP] [--method N]` runs the same `login`; `bw status` then
reports `step` (`signedIn`, `needsCode:twoStep:1`, `needsCode:twoStep:-`,
`needsCode:newDevice`, `chooseMethod:0,1`, `failed`, `cancelled`) and `pending` (the held
prompt). `bw code OTP` answers it; `bw cancel` lets go. `./bench render bitwarden PATH`
draws the card on its own.

## Verification

Rig (kept, documented in `~/exowatt/tmp/copper-creds/ENV.md`): native Vaultwarden at
`http://127.0.0.1:8222` started with SMTP pointed at a Python `aiosmtpd` sink on
`127.0.0.1:1025` (every message lands as an `.eml`), the throwaway account
`copper-test@example.com`, and two small scripts that turn email two-step and an
authenticator factor on and off through the API. Vaultwarden rate-limits logins (60 s / 10
attempts by default) — the SMTP run script raises it.

Against bw 2026.9.0, in a headless probe world (`SEARCH_PROBE=agentview SEARCH_HEADLESS=1`,
exec'd directly so nothing came forward), every path ended where it should:

| Path | Result |
|---|---|
| email + authenticator on the account, no method | `chooseMethod:0,1` (the CLI's list, parsed) |
| `--method 1` | `needsCode:twoStep:1`, one email in the sink, `pending` set |
| `bw code <emailed>` | `signedIn`, state **unlocked**, vault counts present |
| wrong code `000000` | "That code wasn't accepted", `bw` gone, `pending` cleared |
| email only on the account, no method | `needsCode:twoStep:-` (the CLI picked it; the server sent the email), then unlocked with the code |
| control: `login` no method → `login otpMethod:1` → `login otpMethod:1 otp:<emailed>` | `needs:"method"` → `needs:"code", pending:true` → `ok:true, state:unlocked` |
| control: single call, authenticator code up front | `ok:true, state:unlocked` (unchanged behaviour) |
| the Settings card, rendered while a sign-in waits | the code step with the right wording and pills |

New-device verification could not be produced on Vaultwarden (it does not implement the
gate); the prompt string and the feed path are the same code as the two-step prompt,
verified from the CLI source.

The test account was left with two-step login **off**, so the non-interactive recipes in
`ENV.md` keep working. Turn it back on with `enable_email_2fa.py` for a test.

## Gotchas

- Bitwarden emails the code only after the password grant; a UI that asks for the code up
  front can never work for email two-step. Ask after.
- `--method 1` with no code always sends an email (the CLI's `postTwoFactorEmail`); when
  email is the account's only method the server has already sent one on the grant, so the
  user may get two emails with (on Vaultwarden) different codes — the newest counts. The
  card says so.
- A wrong code ends `bw`. There is no "try again" inside one process; re-arm with a fresh
  `login` (which sends a fresh email when that is the method) rather than asking the user to
  retype into nothing.
- `ImageRenderer` cannot draw AppKit text fields (yellow placeholders); fine for reading the
  card's words and layout.
- Both pipe readers must be counted into the `DispatchGroup` before `process.run()`, or a
  process that exits instantly can report its exit before its stderr has been read.
