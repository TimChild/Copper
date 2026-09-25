---
kind: implementation-plan
plan_id: copper-bitwarden-credentials
title: Bitwarden as Copper's password backend, with per-credential agent sharing and an in-process sign-in op for Jev/MCP
status: draft
created: 2026-09-25
updated: 2026-09-25
repository: collinrijock/Copper (branch `fork`, worktree ~/src/copper-creds (branch credentials))
base_revision: a9455f8 "Flush session before in-app recovery" (origin/fork, 2026-09-24); local uncommitted edits in Fork/CommandBar.swift and Fork/MCP/Ultrafast.swift belong to another session — do not touch
risk: medium
owners: [felipe (plan), luna swarm (execution) — Felipe's lane per COLLIN.md ff66106: MCP/Jev/CLI/distribution; the Settings/Browser hooks are upstream-file edits and need PATCHES.md rows]
---

# Bitwarden as Copper's password backend, with per-credential agent sharing

> **FLATTENED FOR EXECUTION (2026-09-25, Felipe):** make it work first. Dropped from this round: Ask prompt, audit log, read-back taint guard, Touch ID unlock, prompt queue. Kept: `bw` subprocess driver, merged picker/save, Settings cards (Bitwarden + Agent access), `browser_sign_in` tool, `copper signin`, Jev `SIGN_IN`. The long form below is the reference; the waves here are the contract.
>
> **Agent policy (simplified):** `agent.credentials.shareAll: Bool` (default false) + `agent.credentials.allowed: [String]` (ids `kc:<host>\u{1}<user>` / `bw:<itemId>`) + Bitwarden folder `Agents` ⇒ allowed. Decision = shareAll || allowed.contains(id) || folder==Agents. No prompts: not allowed ⇒ tool error `credential not shared with agents`.
>
> **Wave 1 (parallel, disjoint):** ENV — native Vaultwarden (cargo, sqlite) on 127.0.0.1:8222 + `brew install bitwarden-cli` + registered test account + seeded items; BACKEND — `Sources/Search/Fork/Credentials/{Credential,CredentialStore,Bitwarden,AgentAccess}.swift`; PAGE — `Forms.swift` (`submit()`, `otpField()`, `fillOTP()`) + `Tab.swift` (`submitSignIn`, `fillOTP`).
> **Wave 2 (parallel, disjoint):** UI — `Browser.swift` picker/choose/offer over `Credentials`, `Prefs.passwordsBackend`, `Settings.swift` mount, new `Fork/CredentialsSettings.swift` (BitwardenCard, AgentAccessCard); AGENT — `Fork/MCP/SignIn.swift`, `Tools.swift` (`browser_sign_in`), `CLI.swift` (`copper signin`), `skill/copper-cli/SKILL.md`.
> **Wave 3 (serial):** `Ultrafast.swift` `SIGN_IN` control (check tree clean first), PATCHES/CHANGELOG/docs, build-fix, e2e against Vaultwarden. Then commit → push `fork` → tap release.

## 1. Outcome

### User-visible or operational result
- Copper fills and saves sign-ins from the user's **existing Bitwarden vault** (bitwarden.com, EU, or any self-hosted/Vaultwarden server) alongside the keychain `Vault` it has today. Same under-field account picker, same save offer, plus TOTP.
- The user decides, **per credential**, which accounts agents may use. Default: agents get nothing without an in-app "Allow" click.
- Jev / MCP / `copper` CLI gain a **`browser_sign_in`** op that fills (and submits) a permitted credential **in-process**. The secret never reaches the model, the MCP wire, or the CLI output; after an agent-initiated fill the page's password value cannot be read back through `browser_evaluate` / text tools until it has been sent.
- Apple Passwords users can bring their vault in today via CSV (already works, documented).

### Definition of done
1. With `bw` installed and a Bitwarden account signed in from Settings › Passwords, clicking a sign-in box on a site with a Bitwarden login shows that account in the picker; clicking fills it. Verified on a real site + a bench fixture page.
2. Signing in on a site with a new account offers "Save to Bitwarden" when Bitwarden is the chosen backend; the item appears in `bw list items --search <host>`.
3. Settings › Passwords › "Agent access" lists vault + Bitwarden logins with a per-item toggle and a mode (Off / Ask / Allowed only). Items in a Bitwarden folder named `Agents` are pre-allowed.
4. `copper call browser_sign_in '{}'` on a tab whose host has one allowed credential fills and submits; result JSON has `filled: true`, `account: <username>` and **no** password field. With an unallowed credential in Ask mode, Copper shows the prompt; Deny → tool error, Allow once → filled.
5. `browser_evaluate` of `document.querySelector('input[type=password]').value` on a tab holding an agent-filled, unsent password returns a refusal, not the value.
6. `./build.sh` green under the documented SDK; PATCHES.md rows added for every upstream-file edit; CHANGELOG "Added (Copper)" block updated.

### Out of scope
- Apple Passwords / passkeys (kernel launch-constraint on `PasswordManagerBrowserExtensionHelper` requires the `com.apple.developer.web-browser.public-key-credential` entitlement → Developer ID; Exowatt has none. Parked; see memory note `copper-password-manager-integration`).
- Hosting Vaultwarden on Exowatt infra (separate decision; this plan only needs "a server URL").
- Bitwarden Chrome extension inside Copper (optional retest later; not needed for this design).
- Linking Bitwarden's *desktop app* biometrics. Touch ID convenience is delivered via Copper's own keychain (T-011).
- Non-login item types (cards, identities, notes).

## 2. Current-state evidence

### Repository orientation
- SwiftPM app, Swift 5 mode, macOS 14+; no test target (`Package.swift` has no `testTarget`); validation is `./build.sh` + `./bench` + the `copper` CLI. Build: `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=-; ./build.sh` → `build/Copper.app` (~30 s).
- New fork code lives under `Sources/Search/Fork/`; upstream-file edits need a `PATCHES.md` row in the same commit (COLLIN.md). Never commit to `main`.
- `./bench` needs `defaults write com.collinrijock.copper bench -bool true`; isolated worlds via `SEARCH_PROBE=<name>` (`Store.world`), which also namespaces keychain labels (`Vault.label`).
- Distribution: tap `Exowatt-Labs/homebrew-copper` renders the cask; never hand-edit `Casks/copper.rb`.

### Existing behavior and flow (passwords)
- `Sources/Search/Vault.swift` — `enum Vault`: keychain `kSecClassInternetPassword` items labelled `Fork.name` ("Copper"); `logins(for:)`, `logins(matching:)` (registrable-domain widening), `all()`, `save`, `touch`, `forget`, `never`, `prove(_:_:)` (LocalAuthentication), `take(csv:)` (Chrome/Apple-Passwords CSV: columns url/username/password).
- `Sources/Search/Forms.swift` — `FormRelay` (`WKScriptMessageHandler` "officeForms") and the injected `script`: finds the `pair()` of user+password inputs, posts `form` / `submit` / `settled` / `focus{rect}`; `window.__officeForms.fill(user, password)` sets values through the prototype setter and dispatches `input`/`change`; `hasPassword()`.
- `Sources/Search/Tab.swift` — `foundSignIn`, `fieldFocused`, `sentSignIn`, `settleSignIn`, `fill(user:password:done:)` (evaluates `__officeForms.fill`); `shy` = private tab.
- `Sources/Search/Browser.swift` — `Offer`/`offering` (save prompt), `Suggesting`/`suggesting` (under-field list), `keepOffer()`, `neverOffer()`, `choose(_:)` → `tab.fill` + `Vault.touch`; `saved`/`relist()`/`shownSites` (Passwords panel data); `tab.onField` builds `Suggesting` from `Vault.logins(matching:)` (`prefix(5)`), gated by `prefs.fillsPasswords`; `tab.onCredentials` builds `Offer` gated by `prefs.savesPasswords`, `Vault.isNever`, and `Extensions.shared.passwordSavingTakenBy`.
- `Sources/Search/Passwords.swift` — `PasswordsPanel` (Plate/Card/Line/Pill/Switch design vocabulary; reveal gated by `Vault.prove`).
- `Sources/Search/Settings.swift` ~L235–270 — Passwords card: "Offer to save passwords", "Fill in sign-ins", "Offer passkeys" (uses `prefs.passkeysPossible`), "Sites never asked", "Bring yours in → Import…".
- `Sources/Search/Prefs.swift` — `savesPasswords` (`passwords.save`), `fillsPasswords` (`passwords.fill`), `entitledToPasskeys` via `SecTaskCopyValueForEntitlement`.
- Vault import UI: `Browser.swift` ~L399 `Vault.take(csv:)`.

### Existing behavior (agent surface)
- `Sources/Search/Fork/MCP/Tools.swift` — `tool(_:_:_:required:)` builder (L42), the tool list (L70–140), `call(_:_:in:)` dispatcher (L146+), `instructions(jev:)` (L33). Private tabs are never exposed (FORK-PLAN safety). COLLIN.md L239: **"Never expose `Vault`."**
- `Sources/Search/Fork/MCP/Ultrafast.swift` — Jev loop; `actionSpace` (L385+) maps observed elements to `CLICK`/`TYPE_TEXT`/`SELECT`, plus `controls` (scroll/wait) and `DONE`/`BLOCKED`; `act(_:_:_:text:)` (L604) executes one op.
- `Sources/Search/Fork/MCP/CLI.swift` — `copper <verb>` shim, `copper call TOOL JSON`, `--json`, exit codes 0/1/2.
- `Sources/Search/ExtensionNative.swift` — Chrome native-messaging host runner (reads NMH manifests; `HostPipe`). Not needed by this plan; noted because it is the route for KeePassXC later.

### Baseline commands and observations (2026-09-25)
- `brew info bitwarden-cli` → formula `bitwarden-cli` 2026.9.0, dep `node`. Not installed on this Mac. `op` 2.39 is installed (1Password; not used by this plan).
- `git -C ~/src/copper-jev status -sb` → `## fork...origin/fork`, ` M Sources/Search/Fork/CommandBar.swift`, ` M Sources/Search/Fork/MCP/Ultrafast.swift` (another session's work — see base_revision note).
- Apple helper probe: spawning `PasswordManagerBrowserExtensionHelper` from a shell → crash report `termination.indicator = "Launch Constraint Violation"`. Confirms the Apple route is closed without the entitlement.

## 3. Requirements and acceptance

- **R-001 — Bitwarden account connect/unlock/lock from Settings**
  - Given `bw` is on the Mac, when the user enters server (default `https://vault.bitwarden.com`), email, master password (+ optional 2FA code) in Settings › Passwords › Bitwarden and clicks Sign in, then status shows `Unlocked · synced <time>`; Lock clears the in-memory session; relaunch shows `Locked` and Unlock asks only for the master password.
  - Evidence: `copper call`-free manual run + `bw status` (with `BITWARDENCLI_APPDATA_DIR` pointed at Copper's dir) reporting `"status":"unlocked"` while Copper says Unlocked, `"locked"` after Lock.
- **R-002 — Bitwarden logins appear in the under-field picker and fill**
  - Given Unlocked and a site with a matching Bitwarden login (URI match by Bitwarden's rules via `bw list items --url`), when the caret enters the sign-in box, then the picker lists the Bitwarden account (with a source glyph) merged with keychain accounts, newest-used first; clicking fills via `Tab.fill`.
  - Evidence: bench fixture page (`file://` HTML with user+password inputs) + a Bitwarden test item whose URI is `http://localhost:<bench-port>`; `./bench eval ID "document.querySelector('input[type=password]').value.length"` > 0 after a scripted click on the picker row (or manual click documented with screenshot).
- **R-003 — Save offers route to the chosen backend**
  - Given `passwords.backend = bitwarden` and Unlocked, when a sign-in takes for an unknown account, then the offer reads "Save to Bitwarden"; Keep → `bw create item` succeeds and `bw list items --search <host>` shows it. Given backend = keychain (default when Bitwarden is not connected), behaviour is unchanged.
- **R-004 — TOTP fill**
  - Given an allowed/selected Bitwarden item with a `login.totp` seed and a page with a one-time-code input (`autocomplete="one-time-code"` or `inputmode=numeric` + name/id matching /otp|code|totp|2fa/), the picker (human) and `browser_sign_in {what:"otp"}` (agent) fill the current code from `bw get totp <id>`.
- **R-005 — Per-credential agent access policy**
  - Settings › Passwords › Agent access: mode `Off` / `Ask` (default) / `Allowed only`; per-item toggle over the union of keychain logins and Bitwarden login items; items in a Bitwarden folder named `Agents` (case-insensitive) show as allowed-by-folder; a Bitwarden custom field `copper-agent: deny` overrides to denied. Policy is stored in `Store.settings` (`agent.credentials.mode`, `agent.credentials.allowed: [String]` of stable ids `bw:<itemId>` / `kc:<host>\u{1}<user>`), never editable through MCP/CLI.
- **R-006 — `browser_sign_in` fills in-process, never returns the secret**
  - Tool schema: `{ account?: string, what?: "password"|"otp", submit?: bool (default true) }`. Resolution: current tab host → candidates (Bitwarden `--url` match ∪ `Vault.logins(matching:)`), filtered by R-005. 0 candidates → error `no credential for <host>`; >1 and no `account` → result lists usernames only; 1 (or matched `account`) → fill, optional submit (Enter on the password field), return `{filled:true, account, host, submitted}`. Private (`shy`) tabs → error. `Off` mode → error. `Ask` mode with unallowed item → in-app prompt "Agent wants to sign in to <host> as <user>" with Allow once / Always for this account / Deny (60 s timeout = Deny); Always adds the id to `allowed`.
  - Every attempt appends one JSONL line (ts, host, id, account, decision, source: mcp|jev|cli) to `~/Library/Application Support/Copper/agent-credentials.log` — never the secret.
- **R-007 — No read-back of an agent-filled secret**
  - After an agent-initiated fill, until the page navigates or the password input is emptied/removed, `browser_evaluate`, `browser_get_text`, `browser_snapshot`, `jev_extract`/`jev_observe` text on that tab refuse with `page holds an unsent credential filled by Copper` (evaluate/get_text) or redact the field's value (snapshot/observe). Human fills (picker) do not set this state.
- **R-008 — Jev can choose to sign in**
  - In `Ultrafast.actionSpace`, when the observation shows a password field and R-005 yields ≥1 permitted candidate for the tab host, a `SIGN_IN` control appears (label "Sign in with the saved account for this site"); `act` routes it through the same code path as R-006 (so Ask-mode prompts still apply).
- **R-009 — CLI parity**
  - `copper signin [--account USER] [--otp] [--no-submit]` → wraps `browser_sign_in`; exit 1 on tool error; `--json` prints the tool result.
- **R-010 — Graceful absence**
  - Without `bw` installed: Settings shows "Install with `brew install bitwarden-cli`" and a Copy button; everything else behaves exactly as today. Without network: unlock of a previously synced vault still works (bw's local encrypted cache); sync errors are announced, not fatal.
- **R-011 — Docs and distribution**
  - `skill/copper-cli/SKILL.md` and `Tools.instructions(jev:)` mention `browser_sign_in` and the no-secret contract; CHANGELOG "Added (Copper)" block; PATCHES.md rows; README/docs note the Apple Passwords CSV import path.

## 4. Constraints, invariants, and forbidden changes
- Never log, print, return over MCP/CLI, or persist a password/TOTP seed/session key outside process memory (exception: T-011's opt-in master password keychain item, gated by `Vault.prove`).
- Never mutate the user's own `~/Library/Application Support/Bitwarden CLI/` state: Copper always runs `bw` with `BITWARDENCLI_APPDATA_DIR=<Copper support dir>/bitwarden` (0700).
- Do not expose or change `Vault`'s MCP invisibility (COLLIN.md). `browser_sign_in` is a *fill* capability, not a read capability.
- Do not add SwiftPM dependencies (repo ethos: Apple frameworks only). `bw` is an external process, GPL-3, separate process boundary; do not link Bitwarden's SDK (restrictive licence).
- Upstream files touched must be minimal hooks; logic lives in `Sources/Search/Fork/Credentials/*` and `Fork/MCP/*`. Every upstream edit gets a PATCHES.md row in the same commit.
- No git mutations by implementer subagents (Felipe's rule); the orchestrator commits. Never commit to `main`.
- Do not touch Felipe's live tabs with mutating tools during validation; use bench worlds (`SEARCH_PROBE`) or `--test` runs.
- Existing behavior for users without Bitwarden must be byte-for-byte unchanged in feel (picker, offer, Settings copy) — only new cards appear.

## 5. Facts, assumptions, decisions, and open questions

### Facts
- F-1 Apple Passwords helper is gated by a kernel launch constraint (entitlement or hardcoded browser allowlist); Exowatt has no Developer ID (Felipe, 2026-09-25).
- F-2 `bw` (bitwarden-cli 2026.9.0, Node) is the official client; it talks to bitwarden.com by default and to any server via `bw config server <url>`; vault decrypts locally; `bw list items` returns decrypted items **including** `login.password`/`login.totp`.
- F-3 Copper already has all the page-side machinery (`__officeForms.fill`, focus rects, save detection) and a Playwright-shaped MCP tool dispatcher with a CLI mirror.
- F-4 `bw serve` exposes an **unauthenticated** localhost REST API while unlocked → any same-user process (including agent shell tools) could dump the vault. Rejected as the transport (D-2).

### Assumptions
- A-1 `bw unlock --passwordenv BW_PASSWORD --raw` works non-interactively and prints the session key; `bw login <email> --passwordenv BW_PASSWORD --method 0 --code <otp> --raw` handles TOTP 2FA. Basis: bw CLI docs (`--passwordenv`, `--passwordfile`, `--method`, `--code`). Verify in T-002 with a throwaway account. If false: use `--passwordfile` on a 0600 temp FIFO.
- A-2 `bw` cold start is ~0.7–1.5 s per invocation. Impact: picker must render from an in-memory metadata cache (T-003), fetching only the secret per fill. If slower, add a background `bw list items` refresh on unlock + every 5 min.
- A-3 `BITWARDENCLI_APPDATA_DIR` isolates `data.json`. Basis: bw docs. Verify by checking the file appears under Copper's dir in T-002.
- A-4 Bitwarden's `--url` matching honours per-URI match rules (domain/host/starts-with/exact/regex/never). If `--url` proves too strict for `localhost` fixtures, fall back to `--search <host>` in tests only.
- A-5 Accessibility snapshot never includes password input values (WebKit AX). Verify in T-008; if it does, redact there too.

### Decisions
- D-1 **Bitwarden over 1Password/KeePassXC/pass**: open source end to end, free tier + free self-host, official CLI, no browser-signature check anywhere in the path. 1Password is paid and its desktop link refuses unsigned browsers. Revisit: never for this phase.
- D-2 **Transport = short-lived `bw` subprocesses with the session key in the child's env**, not `bw serve`, not `rbw-agent`. Rationale F-4. Tradeoff: ~1 s per secret fetch (acceptable for a sign-in); env visible to same-uid `ps -E` for that second (accepted residual; same trust boundary as Copper's own memory). Revisit if latency complaints; then consider a Copper-owned `bw serve` on a random port **with** an nginx-less shim — no, revisit only with an authenticated transport.
- D-3 **Metadata cache holds no secrets**: after `bw list items`, Copper strips `login.password`, `login.totp`, `fields[].value` for hidden types, `notes` before caching. Secret fetch = `bw get password <id>` / `bw get totp <id>` at fill time.
- D-4 **Policy lives in Copper (`Store.settings`), with Bitwarden-side conveniences** (folder `Agents` = allowed, custom field `copper-agent: deny` = denied). Rationale: works with any existing vault without reorganising it; folder convention lets a team pre-share from any Bitwarden client. Hard boundary for *headless* agents remains Bitwarden collections + a machine account (documented, out of code scope).
- D-5 **Default mode = Ask**, not Off: keeps agents useful on day one while every first use is a human click. Revisit if prompt fatigue.
- D-6 **`browser_sign_in` submits by default** so the secret leaves the DOM immediately; plus the R-007 read-back guard for the `submit:false` case and for slow pages.
- D-7 **No cask dependency on `bitwarden-cli`** for now (pulls Node onto every Mac). Settings guides the install. Revisit after adoption feedback (would be a one-line `depends_on formula:` in the tap renderer).
- D-8 Backend selector `passwords.backend ∈ keychain|bitwarden` governs **where saves go**; **fills always merge both** sources.

### Open questions / blockers
- Q-1 (Felipe, non-blocking) Vaultwarden on Exowatt infra vs bitwarden.com Teams for the org vault. Plan is server-agnostic; default copy points at bitwarden.com.
- Q-2 (Felipe, non-blocking) Should `Always for this account` in the Ask prompt be offered, or only `Allow once` + manage in Settings? Plan assumes offered (reversible).
- Q-3 (Collin, courtesy) Settings/Browser hooks are upstream-file edits outside Felipe's declared lane; COLLIN.md asks for a ping before taking plan items outside the lane. Not blocking the MCP/CLI/Fork parts; blocks landing T-006/T-007 hooks until acknowledged or Felipe waives.

## 6. Proposed design

### Components and responsibilities (all new files under `Sources/Search/Fork/Credentials/` unless noted)
- `Credential.swift` — `struct Credential { id: CredentialID; source: .keychain|.bitwarden; host: String; user: String; sites: [String]; hasTOTP: Bool; used: Date?; folder: String?; agentHint: .allow|.deny|.none }` and `enum CredentialID: Hashable, Codable { case keychain(host,user), bitwarden(itemID) }` with a stable string form (`kc:…` / `bw:…`).
- `CredentialStore.swift` — `@MainActor enum Credentials`: `candidates(for host:) -> [Credential]` (merge Vault + Bitwarden cache, dedupe by user+host, sort by `used`), `secret(_:) async throws -> String`, `totp(_:) async throws -> String`, `save(host:user:password:) async throws` routed by `Prefs.passwordsBackend`, `touch(_:)`.
- `Bitwarden.swift` — `final class Bitwarden` (actor-like, MainActor-published state): locate binary (`/opt/homebrew/bin/bw`, `/usr/local/bin/bw`, `PATH`), `status`, `configure(server:)`, `login(email:password:otp:)`, `unlock(password:)`, `lock()`, `sync()`, `items()` (stripped, cached, refreshed on unlock and every 5 min while unlocked), `password(for id)`, `totp(for id)`, `create(login:)`, `generate()`. Runs `Process` with env `BITWARDENCLI_APPDATA_DIR`, `BW_SESSION` (never on argv), `BW_PASSWORD` only for login/unlock. Session key kept in a private `String?`; idle auto-lock timer (`bitwarden.autolockMinutes`, default 15).
- `AgentAccess.swift` — `enum AgentAccess`: `mode` (`agent.credentials.mode`), `allowed: Set<String>` (`agent.credentials.allowed`), `decision(for: Credential) -> .allowed|.denied|.ask`, `ask(_:host:) async -> Bool` (drives a `Browser`-published prompt model, 60 s timeout), `audit(...)` JSONL appender.
- `Fork/MCP/SignIn.swift` — `enum SignIn { static func run(args, in browser, source:) async throws -> [Content] }` implementing R-006/R-007's tainting via `Tab.holdsAgentSecret`.
- `Fork/CredentialsSettings.swift` — SwiftUI: `BitwardenCard`, `AgentAccessCard`, `AgentPrompt` (the Ask sheet), using the existing `Card`/`Line`/`Pill`/`Switch`/`Rule`/`Hunt` vocabulary from `Passwords.swift`/`Settings.swift`.
- Upstream hooks (each a PATCHES row): `Prefs.swift` (+`passwordsBackend`), `Settings.swift` (mount the two cards + install hint), `Browser.swift` (`onField` → `Credentials.candidates`; `choose` → `Credentials.secret`; `onCredentials` → `Credentials.save`; publish `agentPrompt`), `Tab.swift` (+`holdsAgentSecret`, `fillOTP`), `Forms.swift` (script: `fill` marks `__officeForms.agentFilled`, `otpField()` finder, `fillOTP(code)`, `submit()`; message `cleared` when the password box empties/leaves).

### Data / state / control flow
1. Unlock → `Bitwarden.items()` → stripped metadata cache (`[BWItem]`, in memory only) → `Credentials.candidates`.
2. Caret enters sign-in box → `Browser.onField` → `Credentials.candidates(for: host)` → `Suggesting` (now `[Credential]`) → click → `Credentials.secret(id)` (keychain sync, or `bw get password` ~1 s with a spinner row) → `tab.fill` → `touch`.
3. Sign-in takes → `onCredentials` → if backend = bitwarden & unlocked → Offer copy "Save to Bitwarden" → `Bitwarden.create`.
4. Agent → `browser_sign_in` → `SignIn.run`: tab (not `shy`) → host → candidates → `AgentAccess.decision` → maybe prompt → secret → `tab.fill(agent: true)` → optional submit → audit → result without secret. Jev's `SIGN_IN` control and `copper signin` call the same function.
5. Read-back guard: `Tab.holdsAgentSecret` set on agent fill, cleared by navigation (`didCommit`) or the page's `cleared` message; `Tools.call` checks it for evaluate/get_text; snapshot/observe redact password values.

### Interfaces and contracts
- MCP tool `browser_sign_in` (schema in R-006). Result content: JSON text `{filled, account, host, submitted}` or `{candidates:[usernames]}`.
- Jev control `SIGN_IN` (no target index).
- CLI `copper signin`.
- Settings keys: `passwords.backend`, `bitwarden.server`, `bitwarden.autolockMinutes`, `agent.credentials.mode`, `agent.credentials.allowed`.
- Files: `<support>/bitwarden/` (bw appdata, 0700), `<support>/agent-credentials.log` (JSONL, 0600).

### Error and edge-case behavior
- `bw` missing → Bitwarden features hidden behind the install hint; `browser_sign_in` still works for keychain credentials.
- Locked vault at fill time → picker row shows "Unlock Bitwarden…" (opens Settings card); agent tool error `bitwarden locked`.
- `bw` non-zero exit / timeout (10 s) → announce `Bitwarden: <first stderr line>`; never retry a `create`.
- Two candidates with the same username from both sources → prefer Bitwarden, keep keychain as second row.
- Multi-step sign-ins (username page then password page): `fill` already tolerates a missing user box; `browser_sign_in` on the password-only step fills only the password.
- Prompt while another prompt is open → queue, one at a time.

### Alternatives rejected
- Apple Passwords helper protocol (F-1). `bw serve` / `rbw-agent` (F-4). Bitwarden Chrome extension as the primary path (UX not ours, upstream-reported breakage, no agent control). 1Password `op` (paid, closed). Bundling `bw` inside Copper.app (100 MB Node payload; GPL packaging questions).

## 7. Conditional domain design

### UI (Settings cards, picker rows, Ask prompt)
- **Design intent:** same white-and-hairline `Plate`/`Card`/`Line` language as Settings › Passwords; audience = the Copper user managing their own vault; density = one line per setting, one row per credential; supported theme = the app's existing light/dark handling. Product-specific decision: the source glyph on picker rows is a small monochrome mark (key = keychain, shield = Bitwarden), never a brand logo.
- **Bitwarden card states:** *not installed* (hint + Copy command), *installed/unauthenticated* (server field, email, password, 2FA, Sign in), *locked* (email shown, password field, Unlock), *unlocked* (status line with last sync, Lock, Sync now, Auto-lock picker, Backend switch "Save new passwords to Bitwarden"), *error* (inline red-muted line with `bw` stderr first line, retry). Loading: Pill shows a spinner and is disabled; focus stays on the card.
- **Agent access card states:** mode segmented control; *empty* ("Nothing kept yet — sign in somewhere or connect Bitwarden"); list rows: name/host · username · source glyph · folder badge `Agents` when applicable · `Switch`; rows forced by `copper-agent: deny` show a disabled off switch with "denied in Bitwarden"; search via existing `Hunt`. Long names truncate middle; ≥200 rows scroll (`.frame(maxHeight: 400)` like `PasswordsPanel`).
- **Ask prompt:** sheet anchored to the window (reuse the `Offer` bar pattern in `Browser`/`Dialogs.swift`): "An agent wants to sign in to **host** as **user**" · `Deny` (default, Esc) · `Allow once` · `Always for this account`. 60 s countdown text; announces via `announce()` on decision. Keyboard: Esc = Deny, Return = Allow once.
- **Accessibility:** every switch labelled with credential name+user; prompt buttons are real buttons; status text not colour-only (prefix "Locked"/"Unlocked").
- **Visual QA:** `./bench shot` of Settings with each Bitwarden state + Agent access list (empty, 3 rows, 200 rows), and the Ask prompt; light + dark.

### Security gate
- Threat boundary: the model / MCP client / CLI caller is untrusted; Copper's process and the local user are trusted. Secrets cross only Copper↔`bw` (child env/stdout) and Copper↔page (`evaluateJavaScript`).
- Abuse cases covered: read-back via evaluate/text/snapshot (R-007); policy edit via tools (none exists); prompt spam (queue + 60 s deny); private tabs (refused); log leakage (audit has no secrets; `NSLog` never receives bw output).
- Residual: `ps -E` window on `bw` child env (D-2); an agent typing a password it already knows (out of scope — not a Copper secret).
- Human approval required before: T-013 (docs claiming the contract) ships; any future change adding a *read* tool.

## 8. Execution graph

### Milestones
- **M1 Foundation (no UI):** T-001 Credential model + store skeleton; T-002 Bitwarden driver; T-003 metadata cache + candidates merge.
- **M2 Human path:** T-004 Forms.js additions; T-005 Tab hooks; T-006 Browser picker/offer hooks; T-007 Settings + Prefs + Bitwarden card.
- **M3 Agent path:** T-008 AgentAccess policy + audit + prompt model; T-009 `browser_sign_in` tool + read-back guard; T-010 Jev `SIGN_IN` control + CLI `copper signin`.
- **M4 Polish/ship:** T-011 Touch ID unlock (opt-in); T-012 Agent access Settings card; T-013 docs/PATCHES/CHANGELOG/skill; T-014 integration validation.

### Dependency DAG
```
T-001 → T-002 → T-003 → T-006 → T-014
T-001 → T-004 → T-005 → T-006
T-003 → T-007 → T-014
T-003 → T-008 → T-009 → T-010 → T-014
T-005 → T-009
T-008 → T-012 → T-014
T-002 → T-011 → T-014
T-009, T-010, T-007 → T-013 → T-014
```

### Parallel lanes
- Lane A (backend): T-001 → T-002 → T-003 → T-011.
- Lane B (page/browser): T-004 → T-005 (parallel with A after T-001).
- Lane C (agent): T-008 after T-003 ; T-009 after T-005+T-008 ; T-010 after T-009.
- Lane D (UI): T-007 after T-003 ; T-012 after T-008.
- Serialized: T-006 (Browser.swift) is the integration point of A+B; T-013/T-014 last. Write sets are disjoint per lane; `Browser.swift` is owned only by T-006, `Tools.swift`/`Ultrafast.swift`/`CLI.swift` only by T-009/T-010 (note another session has uncommitted `Ultrafast.swift` edits — T-010 must rebase onto whatever landed, not overwrite).

## 9. Tasks

### T-001 — Credential model and store skeleton [R-002, R-005, R-006]
- **Objective:** a source-agnostic `Credential`/`CredentialID` and a `Credentials` façade that today returns only keychain data, so every later task codes against one type.
- **Context packet:** `Login` in `Vault.swift` is host+user+password+used; `Vault.logins(matching:)` widens by registrable domain; `Store.settings` is the UserDefaults suite; `Fork.name` is "Copper".
- **Read set:** `Sources/Search/Vault.swift::Login, Vault.logins(matching:), Vault.all, Vault.touch`; `Sources/Search/Fork/` (any small enum for style, e.g. `Fork/MCP/Setup.swift`).
- **Write set:** new `Sources/Search/Fork/Credentials/Credential.swift`, `Sources/Search/Fork/Credentials/CredentialStore.swift`.
- **Dependencies:** none. Produces the `Credential` contract consumed by T-003/T-005/T-006/T-008/T-009.
- **Preconditions:** `./build.sh` green at base.
- **Actions:** define `CredentialID` (`kc:`/`bw:` string form, `Codable`), `Credential` (fields in §6), `enum Credentials` with `candidates(for:)` (keychain only for now), `secret(_:)`, `totp(_:)` (throws `unsupported` for keychain), `save(host:user:password:)` (Vault only), `touch(_:)`, `all()`. Mark `@MainActor` where Vault is called from UI.
- **Acceptance:** builds; no behaviour change (nothing calls it yet).
- **Validation:** `SDKROOT=… SEARCH_SIGN_IDENTITY=- ./build.sh app` exits 0.
- **Exit:** DONE on green build; BLOCKED if `Login` shape differs from the read set.
- **Recovery:** write set is new files only — delete them to restore. Retry budget 2 for build-tool flakes.
- **Handoff:** file list; unlocks T-002, T-004.

### T-002 — Bitwarden CLI driver [R-001, R-003, R-004, R-010]
- **Objective:** `Bitwarden` class that can locate `bw`, configure server, login, unlock, lock, sync, list (stripped), get password/totp, create a login item, generate — with the session key only in memory and an isolated appdata dir.
- **Context packet:** D-2/D-3; env keys `BITWARDENCLI_APPDATA_DIR`, `BW_SESSION`, `BW_PASSWORD`; `bw` JSON shapes: `bw status` → `{status: unauthenticated|locked|unlocked, serverUrl, userEmail, lastSync}`; `bw list items --url <u>` → array with `id, type(1=login), name, folderId, organizationId, collectionIds, login{username,password,totp,uris[{uri,match}]}, fields[{name,value,type}]`; `bw list folders` → `[{id,name}]`; `bw get template item`, `bw encode`, `bw create item <b64>`; `bw get password|totp <id>`; `bw generate -ulns --length 20`. `Process` + `Pipe` usage example: `Sources/Search/ExtensionNative.swift::HostPipe`.
- **Read set:** `Sources/Search/ExtensionNative.swift::HostPipe` (Process pattern); `Sources/Search/Store.swift` (support folder + `Store.world`); T-001 files.
- **Write set:** new `Sources/Search/Fork/Credentials/Bitwarden.swift`.
- **Dependencies:** T-001. Produces `Bitwarden.shared` API consumed by T-003/T-007/T-011.
- **Preconditions:** `brew install bitwarden-cli` on the dev Mac; a throwaway Bitwarden account (free) with 2 test login items (one with TOTP seed, URIs `https://example.org` and `http://localhost`), a folder `Agents` containing one of them.
- **Actions:** binary discovery; a private `run(_ args:[String], env:[String:String], stdin: Data?) async throws -> (out: Data, err: Data, code: Int32)` with a 10 s timeout (30 s for `sync`/`login`); appdata dir under `Store` support folder (`bitwarden/`, world-suffixed in probe runs), 0700; `status()`, `configure(server:)`, `login(email:password:otp:)` (`--passwordenv BW_PASSWORD [--method 0 --code X] --raw`), `unlock(password:)` (`--passwordenv --raw` → session), `lock()` (`bw lock` + drop key), `sync()`, `items()` → strip secrets (D-3) → `[BWItem]`, `folders()`, `password(id)`, `totp(id)`, `create(host:user:password:)` (template → fill `name`, `login.username/password`, `login.uris=[{uri:"https://"+host, match:null}]` → `encode` via stdin → `create item`), `generate()`. Idle auto-lock timer. Publish `@Published state: .missing|.unauthenticated|.locked|.unlocked(lastSync)`.
- **Acceptance:** each method behaves against the throwaway account; `~/Library/Application Support/Copper/bitwarden/data.json` exists and the user's own `Bitwarden CLI/` dir is untouched; no password or session key appears in any `NSLog`/stdout (grep the run's `log show` output for the test password — must be absent).
- **Validation:** a `bench` verb is not available yet — validate via a temporary `Copper --cli`-free path: T-007's card, or a debug `Bench` verb `bw status|unlock|list` behind `Fork.bench` (allowed, fork-only). Expected: `./bench bw status` → `locked`, after unlock → `unlocked`, `./bench bw list` prints names/usernames only.
- **Exit:** DONE with the above; BLOCKED if A-1 fails (report the exact `bw` error and try `--passwordfile` once).
- **Recovery:** new file; delete to restore. Do not retry `create`.
- **Handoff:** API surface, measured cold-start latency (feeds A-2), unlocks T-003, T-007, T-011.

### T-003 — Metadata cache and merged candidates [R-002, R-005]
- **Objective:** `Credentials.candidates(for:)` returns keychain + Bitwarden credentials for a host from an in-memory cache, with `folder` and `agentHint` populated; `secret`/`totp`/`save` route to Bitwarden when appropriate.
- **Read set:** T-001/T-002 files; `Vault.registrable`.
- **Write set:** `Sources/Search/Fork/Credentials/CredentialStore.swift` (extend), `Bitwarden.swift` (cache refresh hooks only).
- **Dependencies:** T-002. Produces the final `Credentials` contract.
- **Actions:** on unlock and every 5 min: `items()` + `folders()` → cache; host matching: run `bw list items --url https://<host>` when unlocked? No — that costs ~1 s per focus. Match locally against cached URIs using Bitwarden default rule "base domain" (`Vault.registrable`) unless the URI's `match` says host/exact/startsWith/never; `agentHint` = `.deny` if a field named `copper-agent` has value `deny`, `.allow` if folder name lowercased == "agents"; merge with `Vault.logins(matching:)`; dedupe; sort by `used`.
- **Acceptance:** with the two test items, `candidates(for: "www.example.org")` includes the Bitwarden item and any keychain item; `candidates(for:"localhost")` includes the `http://localhost` item.
- **Validation:** `./bench bw candidates example.org` (extend the debug verb) prints both sources; no secrets in output.
- **Exit/Recovery/Handoff:** as T-001; unlocks T-006, T-007, T-008.

### T-004 — Page script additions [R-004, R-006, R-007]
- **Objective:** `__officeForms` gains `fill(user, password, byAgent)`, `submit()`, `otpField()`, `fillOTP(code)`, and posts `cleared` when a password box that was filled empties or leaves the DOM.
- **Context packet:** existing `pair()`, `put()`, `fill`, MutationObserver in `Forms.swift::script`; `Tab.arm` re-injects scripts every navigation.
- **Read set:** `Sources/Search/Forms.swift` (whole file).
- **Write set:** `Sources/Search/Forms.swift` (`script`, `FormRelay.userContentController` new `cleared` case) — upstream file → PATCHES row `credentials-forms`.
- **Dependencies:** none (parallel with T-002). Produces the JS contract for T-005.
- **Actions:** `fill(u,p,byAgent)` sets `agentFilled = byAgent ? pass : null`; `submit()` = dispatch Enter keydown/keyup on the password box then `form.requestSubmit()` if any; `otpField()` = first visible input with `autocomplete=one-time-code` or (`inputmode=numeric|tel` and /otp|code|totp|verif|2fa|mfa/i on name/id/aria-label/placeholder); `fillOTP(code)` via `put`; observer: if `agentFilled` && (!agentFilled.isConnected || !agentFilled.value) → post `{kind:'cleared'}` and reset.
- **Acceptance:** on a fixture page, `__officeForms.fill('a','b',true); __officeForms.agentFilled` is the input; clearing it posts `cleared` (observe via a `console.log` in a `--test` build or the relay's handler in T-005).
- **Validation:** `./bench open file://…/fixture.html` + `./bench eval ID "…"` sequences; expected values above.
- **Exit/Recovery:** restore `Forms.swift` from `git show HEAD:Sources/Search/Forms.swift` into place (not `git checkout` of anything else). Unlocks T-005.

### T-005 — Tab hooks for agent fill, OTP, and taint [R-006, R-007]
- **Objective:** `Tab.fill(user:password:byAgent:done:)`, `Tab.submitSignIn()`, `Tab.fillOTP(_:done:)`, `Tab.holdsAgentSecret` (set on agent fill, cleared on `cleared` message and on navigation commit), `Tab.hasOTPField() async -> Bool`.
- **Read set:** `Sources/Search/Tab.swift::fill, settleSignIn, escape`, navigation delegate `didCommit`/`didStartProvisionalNavigation` site in `Tab.swift`; `Forms.swift::FormRelay`.
- **Write set:** `Sources/Search/Tab.swift` (upstream → PATCHES row `credentials-tab`), `Forms.swift::FormRelay` (`cleared` → `tab?.agentSecretCleared()`).
- **Dependencies:** T-004.
- **Acceptance:** after `fill(byAgent:true)`, `holdsAgentSecret == true`; after `submitSignIn()` and navigation, `false`; after page clears the box, `false`.
- **Validation:** bench fixture + a debug `Bench` verb `taint ID` printing the flag (fork-only).
- **Exit/Recovery:** as T-004. Unlocks T-006, T-009.

### T-006 — Browser: picker, choose, and save offers over `Credentials` [R-002, R-003]
- **Objective:** the under-field list and save offer use `Credentials` (both sources); choosing a Bitwarden row fetches the secret asynchronously; offers route by backend.
- **Context packet:** `Suggesting.logins: [Login]` becomes `[Credential]`; `choose(_:)` currently synchronous with `login.password`; `Offer` copy in `Dialogs.swift`/wherever the offer bar renders ("Save"/"Never") — locate by `offering` usages.
- **Read set:** `Sources/Search/Browser.swift::Suggesting, choose, keepOffer, onField closure (~L1255), onCredentials closure (~L1272), relist, shownSites`; the view that renders `suggesting` rows and the offer bar (`rg -n "suggesting|offering" Sources/Search/*.swift`).
- **Write set:** `Sources/Search/Browser.swift` (PATCHES row `credentials-browser`), the suggestion/offer views (same row), `Passwords.swift` only if `SiteRow` must accept `Credential` (keep `PasswordsPanel` keychain-only otherwise).
- **Dependencies:** T-003, T-005. Q-3 applies (upstream files outside the declared lane) — proceed, flag in handoff.
- **Actions:** `onField` → `Credentials.candidates(for: host).prefix(5)`; row shows source glyph; `choose` → `Task { secret = try await Credentials.secret(id); tab.fill(...) }` with a transient "Fetching…" row state and `announce` on failure; locked Bitwarden → row "Unlock Bitwarden…" → `tuning = true` (opens Settings); `onCredentials` → if `Credentials.saveTarget == .bitwarden` set `Offer.target` and copy "Save to Bitwarden"; `keepOffer` → `Credentials.save`.
- **Acceptance:** R-002 and R-003 scenarios pass; keychain-only users see identical behaviour.
- **Validation:** manual on `https://example.org`-URI test item (bench world, not Felipe's session): screenshot of picker with both glyphs; `bw list items --search example.org` shows the newly saved item after Keep.
- **Exit/Recovery:** restore each touched upstream file from `HEAD` individually. Unlocks T-014.

### T-007 — Prefs + Settings › Passwords › Bitwarden card [R-001, R-010]
- **Objective:** `Prefs.passwordsBackend`; Settings shows the Bitwarden card with all states in §7; install hint when `bw` is absent.
- **Read set:** `Sources/Search/Settings.swift` Passwords section (~L235–275) and its `Card/Line/Pill/Switch` usage; `Sources/Search/Prefs.swift::savesPasswords` pattern; `Bitwarden.state`.
- **Write set:** new `Sources/Search/Fork/CredentialsSettings.swift::BitwardenCard`; `Settings.swift` (one `BitwardenCard(browser:)` mount → PATCHES row `credentials-settings`); `Prefs.swift` (`passwordsBackend`, key `passwords.backend` → same row).
- **Dependencies:** T-003.
- **Acceptance:** every state renders; Sign in/Unlock/Lock/Sync act; password fields are `SecureField`; copy install command works; backend switch persists.
- **Validation:** `./bench shot` per state (light/dark); `defaults read com.collinrijock.copper passwords.backend`.
- **Exit/Recovery:** restore `Settings.swift`/`Prefs.swift` from HEAD; delete new file. Unlocks T-013.

### T-008 — Agent access policy, audit, and prompt model [R-005, R-006]
- **Objective:** `AgentAccess` with mode/allowlist persistence, `decision(for:)`, async `ask(...)` that publishes a prompt on `Browser` and resolves on user action or 60 s timeout, and the JSONL audit appender.
- **Read set:** T-001/T-003; `Browser.swift::offering/announce` (publishing pattern); `Store.settings`.
- **Write set:** new `Sources/Search/Fork/Credentials/AgentAccess.swift`; `Browser.swift` (+`@Published var agentPrompt: AgentAccess.Prompt?` — fold into T-006's PATCHES row; coordinate: T-006 owns Browser.swift, so T-008 hands T-006 the one-line addition or lands after T-006).
- **Dependencies:** T-003 (and ordering after T-006 for the Browser line).
- **Actions:** keys `agent.credentials.mode` (`off|ask|allowlist`, default `ask`), `agent.credentials.allowed` `[String]`; `decision`: `.deny` if `agentHint == .deny` or mode off; `.allow` if allowed set contains id or `agentHint == .allow`; else mode allowlist → `.deny`, mode ask → `.ask`. `ask` queues prompts; `audit(entry)` appends to `<support>/agent-credentials.log` (0600, create if missing) with `ts, host, id, account, decision, source` only.
- **Acceptance:** unit-style check via a bench verb `agent policy <id>` returning the decision; log lines contain no secrets.
- **Validation:** `./bench agent policy bw:<id>` → `ask`; after `defaults write … agent.credentials.allowed -array bw:<id>` → `allow`; `cat agent-credentials.log | jq` parses.
- **Exit/Recovery:** delete new file. Unlocks T-009, T-012.

### T-009 — `browser_sign_in` tool and read-back guard [R-006, R-007]
- **Objective:** the MCP tool per R-006, plus refusal/redaction in evaluate/get_text/snapshot/observe/extract while `tab.holdsAgentSecret`.
- **Read set:** `Sources/Search/Fork/MCP/Tools.swift::tool(...), call(...), instructions(jev:)`; the `browser_evaluate`, `browser_get_text`, `browser_snapshot` cases; `Fork/MCP/Page.swift` (snapshot builder) and `Ultrafast.swift` observe/extract text builders; T-005 `Tab` API; T-008.
- **Write set:** new `Sources/Search/Fork/MCP/SignIn.swift`; `Tools.swift` (register tool, dispatch, guard checks, one paragraph in `instructions`); `Page.swift` (redact `input[type=password]` values if A-5 is false).
- **Dependencies:** T-005, T-008.
- **Actions:** implement `SignIn.run(args, in:, source:)` per R-006 flow; `Tools.call` case `"browser_sign_in"`; guard: at the top of evaluate/get_text cases `if tab.holdsAgentSecret { throw ToolError("page holds an unsent credential filled by Copper; submit or navigate first") }`; snapshot/observe: redact values of password inputs. Add tool doc line to `instructions(jev:)`: "browser_sign_in fills a saved account in-process; you never receive the password."
- **Acceptance:** R-006 and R-007 scenarios; `copper tools` lists the tool; result JSON never contains the test password (assert with `grep -c`).
- **Validation:** in a `SEARCH_PROBE=creds` world with the test items allowed: `copper --json call browser_sign_in '{"submit":false}'` → `filled:true`; `copper eval "document.querySelector('input[type=password]').value"` → tool error exit 1; `copper call browser_sign_in '{"submit":true}'` → page navigates, then `copper eval …` allowed again. Ask mode: run without allowlist → prompt visible in the probe window → click Deny → exit 1 with `denied`.
- **Exit/Recovery:** restore `Tools.swift`/`Page.swift` from HEAD; delete `SignIn.swift`. Unlocks T-010, T-013.

### T-010 — Jev `SIGN_IN` control and `copper signin` [R-008, R-009]
- **Objective:** Jev can pick `SIGN_IN` when a password field is observed and a permitted credential exists; CLI verb mirrors the tool.
- **Read set:** `Ultrafast.swift::actionSpace, act` (rebase onto the other session's uncommitted edits if they landed — check `git log -1 -- Sources/Search/Fork/MCP/Ultrafast.swift` and the working tree before editing); `CLI.swift` verb table and `call` plumbing; `skill/copper-cli/SKILL.md`.
- **Write set:** `Ultrafast.swift` (controls entry + `act` case), `CLI.swift` (verb), `skill/copper-cli/SKILL.md` (verb row).
- **Dependencies:** T-009.
- **Actions:** in `actionSpace`, if any observed element is a password input and `AgentAccess.hasPermittedCandidate(for: host)` (cheap: candidates ∩ decision != deny) add `controls["SIGN_IN"] = ["label": "Sign in with the saved account for this site"]`; in `act`, `SIGN_IN` → `SignIn.run([:], in: browser, source: .jev)`; CLI `signin [--account U] [--otp] [--no-submit]`.
- **Acceptance:** `copper run "sign in and stop when the dashboard shows"` on the fixture picks `SIGN_IN` (visible in trace); `copper signin --json` returns the same shape as the tool.
- **Validation:** trace output contains `SIGN_IN`; no password in trace (`grep -c <testpw>` = 0).
- **Exit/Recovery:** restore the two fork files from HEAD (careful: preserve the other session's edits — restore only your hunks, or BLOCK if the tree is dirty in your write set). Unlocks T-013.

### T-011 — Opt-in Touch ID unlock [R-001]
- **Objective:** Settings toggle "Unlock Bitwarden with Touch ID": stores the master password as a Copper keychain item (`kSecClassGenericPassword`, label `Fork.name`, account `bitwarden-master`, `kSecAttrAccessControl` with `.userPresence`) and uses it after `Vault.prove` to call `unlock`.
- **Read set:** `Vault.swift::save/prove` patterns; `Bitwarden.unlock`.
- **Write set:** `Bitwarden.swift` (`rememberMaster(_:)`, `forgetMaster()`, `unlockWithBiometrics()`), `Fork/CredentialsSettings.swift` (toggle).
- **Dependencies:** T-002, T-007.
- **Acceptance:** toggle on → next launch, Unlock shows Touch ID and unlocks without typing; toggle off deletes the item (`security` CLI must NOT be used to verify — use the app's own status + a failed unlock after toggle-off).
- **Validation:** manual; relaunch in probe world.
- **Exit/Recovery:** as T-002.

### T-012 — Agent access Settings card [R-005]
- **Objective:** the card per §7 UI: mode control, searchable per-item list with switches, folder/deny badges.
- **Read set:** `Passwords.swift::PasswordsPanel` (Hunt, Card, Rule, Site rows), T-008 API, `Credentials.all()`.
- **Write set:** `Fork/CredentialsSettings.swift::AgentAccessCard`; `Settings.swift` mount (same PATCHES row as T-007).
- **Dependencies:** T-008 (T-007 for the mount line).
- **Acceptance:** states in §7; toggling persists to `agent.credentials.allowed`; deny-badged rows are not toggleable.
- **Validation:** `./bench shot` empty/3/200 rows, light/dark; `defaults read … agent.credentials.allowed`.
- **Exit/Recovery:** as T-007.

### T-013 — Docs, PATCHES, CHANGELOG, skill [R-011]
- **Objective:** PATCHES rows (`credentials-forms`, `credentials-tab`, `credentials-browser`, `credentials-settings`), CHANGELOG "Added (Copper)" entries, `skill/copper-cli/SKILL.md` + `docs/agents.md` (tool contract: fills, never returns secrets; Ask prompt; policy in Settings), README/docs note "Apple Passwords → File › Export All Passwords → Settings › Passwords › Import…".
- **Read set:** `PATCHES.md` (table format), `CHANGELOG.md` top block, `docs/agents.md`, `skill/copper-cli/SKILL.md`.
- **Write set:** those four + README passwords paragraph (upstream file → row `credentials-readme`, or keep README untouched and put it in `docs/` — prefer docs/).
- **Dependencies:** T-007, T-009, T-010.
- **Acceptance:** every upstream file in `git diff --name-only` outside `Fork/` has a row; docs describe the shipped behaviour exactly.
- **Validation:** `git diff --name-only | grep -v Fork/` vs PATCHES rows — set equality.

### T-014 — Integration validation and ship gate
- **Objective:** prove the Definition of done end to end in a `SEARCH_PROBE=creds` world, then hand to the orchestrator for commit → push `fork` → tap release.
- **Read set:** §1 Definition of done; §10 scenarios.
- **Write set:** none (evidence only, under `~/exowatt/reports/partials/<date>/copper-credentials/`).
- **Dependencies:** all.
- **Actions:** run §10 scenarios; collect screenshots + CLI transcripts; `grep -rc <testpw>` over transcripts/logs = 0; confirm Felipe's live session untouched (`copper tabs` URL set before/after identical — read-only).
- **Exit:** DONE → orchestrator commits with PATCHES in the same commit, pushes `fork`, runs `gh workflow run release.yml -R Exowatt-Labs/homebrew-copper -f ref=fork`, and follows the session-backup rule from memory `copper-session-format-and-download-trap` before `brew upgrade --cask copper`.

## 10. Integration and final validation

### Requirement → task → check
| Req | Tasks | Check |
|---|---|---|
| R-001 | T-002, T-007, T-011 | Settings states + `bw status` in Copper's appdata dir |
| R-002 | T-003, T-006 | picker shows both sources; fill works |
| R-003 | T-003, T-006, T-007 | "Save to Bitwarden" → `bw list items --search` |
| R-004 | T-002, T-004, T-005, T-009 | OTP filled on fixture with `one-time-code` input |
| R-005 | T-008, T-012 | policy decisions + persisted keys |
| R-006 | T-009 | CLI transcript, no secret in output |
| R-007 | T-004, T-005, T-009 | evaluate refused while tainted |
| R-008 | T-010 | Jev trace shows `SIGN_IN` |
| R-009 | T-010 | `copper signin --json` |
| R-010 | T-002, T-007 | uninstall `bw` (rename) → hint shown, keychain path intact |
| R-011 | T-013 | diff/PATCHES set equality |

### End-to-end scenarios (probe world)
1. Fresh world → Settings → Bitwarden Sign in (test account) → Unlocked. 2. Open fixture → caret in user box → picker shows Bitwarden row → click → filled → submit → landing page. 3. New account on fixture → Keep → item in vault. 4. `copper call browser_sign_in` in Ask mode → prompt → Allow once → filled+submitted → audit line. 5. Allowlist mode + unallowed → error. 6. `submit:false` → evaluate refused → navigate → allowed. 7. Lock → picker row "Unlock Bitwarden…". 8. Rename `bw` → hint; keychain picker still works.

### Security checks
- `grep -rc "<testpw>"` across bench output, CLI transcripts, `log show --predicate 'process == "Copper"' --last 1h`, and `agent-credentials.log` → 0 everywhere.
- Confirm `ps -Eww` never shows `BW_SESSION` on a long-lived process (only transient `bw` children).

### Final evidence
Screenshots (Settings states, picker, prompt), CLI transcripts for scenarios 4–6, the grep results, `./build.sh` output, PATCHES diff.

## 11. Rollout, observability, and rollback
- Ships via the tap release (`release.yml -f ref=fork`); brew users upgrade. Feature is inert without `bw`; agent tool exists but returns "no credential" for users with nothing shared — safe default.
- Observability: `agent-credentials.log` (local), `announce()` toasts, `Bitwarden.state`.
- Rollback: `brew` reinstall of the previous cask version (tap keeps prior `copper-<ver>` zips on the Forca feed); user data: nothing migrates — keychain `Vault` untouched, Copper's bw appdata dir can be deleted.

## 12. Executor recovery and resumption
- Start a task only when its predecessor's handoff evidence exists. Checkpoint = `git stash list`-free: record `git diff --stat` and build result in the task handoff before and after.
- Stop on: anchor not found (symbol renamed), `Ultrafast.swift`/`CommandBar.swift` dirty from the other session inside your write set, A-1/A-3 false, any secret appearing in output, or 2 failed build/validation attempts with the same strategy.
- Restore only your write set: new files → delete; upstream files → `git show HEAD:<path> > <path>` (never `git checkout .`, never `git clean`).
- Escalation packet: task id, failed criterion, exact command + first 30 lines of output, `git status -sb`, hypotheses, one decision needed.
- Resume: `git -C ~/src/copper-jev status -sb`, re-read this plan's task, re-resolve anchors with `rg`, rebuild, continue.

## 13. Risks and mitigations
- `bw` non-interactive flags differ from docs (A-1) → T-002 verifies first; `--passwordfile` fallback.
- Node cold start makes the picker feel slow → cache (D-3); secret fetch shows a row spinner; measure in T-002.
- Bitwarden URI match semantics mismatch → implement Bitwarden's documented rules; `--url` cross-check in tests.
- Upstream-file churn on rebase → hooks are one-liners; PATCHES rows.
- Prompt fatigue in Ask mode → `Always for this account`; folder `Agents` bulk path.
- Another session editing `Ultrafast.swift` → T-010 checks tree state and BLOCKS rather than overwrites.
- Collin lane etiquette (Q-3) → ping before landing T-006/T-007 hooks.

## 14. Handoff
- **First executable tasks (parallel):** T-001 (then T-002) and T-004.
- **Approval gate:** Felipe approves D-2 (subprocess transport), D-4/D-5 (policy in Copper, default Ask), D-7 (no cask dependency); Q-1/Q-2 non-blocking; Q-3 courtesy ping to Collin before T-006/T-007 land.
- **Invocation:** `/use-luna` or `/orchestrate docs/plans/2026-09-25-bitwarden-credentials.md` — lanes A/B first (T-001→T-002→T-003 ∥ T-004→T-005), then T-006 + T-008, then T-007 ∥ T-009 → T-010 ∥ T-012 → T-011 → T-013 → T-014. Implementers: no git mutations; build with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=-`; never touch Felipe's live tabs.
- **Executor report format:** task id + DONE/BLOCKED/FAILED, files changed, commands + exit codes, evidence paths, deviations, residual risks, next unlocked tasks.

## 15. References
- Repo: `Sources/Search/{Vault,Forms,Tab,Browser,Passwords,Settings,Prefs,ExtensionNative}.swift`, `Sources/Search/Fork/MCP/{Tools,Ultrafast,CLI,Page}.swift`, `PATCHES.md`, `COLLIN.md`, `FORK-PLAN.md`, `skill/copper-cli/SKILL.md`, `docs/agents.md`.
- Bitwarden CLI docs: https://bitwarden.com/help/cli/ (commands `login`, `unlock`, `list`, `get`, `create`, `generate`, `config server`; env `BW_SESSION`, `BITWARDENCLI_APPDATA_DIR`, `--passwordenv`); Homebrew formula `bitwarden-cli` 2026.9.0.
- Apple route (closed): launch constraints dumped from `/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app` on macOS 27.0 (2026-09-25); protocol reference `github.com/au2001/icloud-passwords-firefox` `src/utils/{api,srp,enums}.ts`; entitlement `com.apple.developer.web-browser.public-key-credential`.
- Memory: `copper-password-manager-integration`, `copper-browser-fork`, `copper-session-format-and-download-trap`.
