---
kind: implementation-plan
plan_id: copper-bitwarden-autofill-everything
title: Autofill everything from Bitwarden — identities (addresses), cards, custom fields, most-used usernames — in the page and for agents
status: executing
created: 2026-09-27
repository: collinrijock/Copper (branch `fork`, worktree ~/src/copper-autofill (branch autofill))
base_revision: 49bee60 (origin/fork, 2026-09-27)
owners: [felipe (plan + orchestration), luna swarm (execution)]
predecessor: docs/plans/2026-09-25-bitwarden-credentials.md (logins + TOTP + agent sign-in — shipped)
---

# Autofill everything from Bitwarden

Today Copper's Bitwarden integration handles **logins** only (username, password, TOTP). The
vault also holds **identities** (name, address, email, phone, company, SSN, passport,
licence, username), **cards** (holder, brand, number, expiry, CVV), **secure notes**, and
**custom fields** on any item. This plan brings all of it into Copper's under-field picker
and into the agent fill path, so any form — checkout, shipping address, sign-up,
"enter your PIN" — fills from the vault with one pick.

## Outcome / definition of done

1. Click into **any** recognised form field (not only a sign-in pair) and a list hangs from
   it with what the vault can put there:
   - sign-in fields → accounts (today's behaviour, unchanged);
   - a username/email field on a site with **no** saved account → the user's most-used
     usernames and identity emails ("Use farce@exowatt.com");
   - a card field (number / holder / expiry / CVV) → the vault's **cards**, "Visa •••• 4242 ·
     Felipe Arce"; a pick fills the whole card group in that form;
   - an identity field (name / address / city / zip / country / phone / company …) → the vault's
     **identities**, "Felipe Arce · 123 Main St, Miami"; a pick fills every identity field in the
     form;
   - a field whose name/id/label matches a **custom field** on a login item for this site →
     that field ("PIN · Chase"); a pick fills that one box.
2. Values that are secrets (card number, CVV, hidden custom fields) are treated like
   passwords: kept in memory while unlocked, cleared on lock, never returned over MCP/CLI.
3. Agents: `browser_autofill` MCP tool (+ `copper autofill`, + Jev `AUTOFILL` control) fills a
   card or identity in-process by name or by "the only one", subject to the same
   `AgentAccess` allow-list (ids `bw:<itemId>`), returning status only.
4. Settings › Passwords: a "Fill addresses and cards" switch (`prefs.fillsEverything`,
   default on) and the Bitwarden card shows counts (N logins · N identities · N cards).
   Agent access lists identities and cards too.
5. `./bench bw` gains `identities`, `cards`, `fields HOST`, `usernames`, `autofill card|identity ID`
   for probe-world testing; verified end-to-end against the local Vaultwarden fixture with
   seeded identity/card/custom-field items.
6. `./build.sh` green; PATCHES.md rows updated for upstream-file edits (Forms.swift, Tab.swift,
   Browser.swift, Accounts.swift, Prefs.swift, Settings.swift); docs/passwords.md, docs/agents.md,
   CHANGELOG, skill/copper-cli/SKILL.md updated.

## Interface contracts (workers build against these — do not rename)

### Field kinds (shared vocabulary, JS ⇄ Swift)

```
enum FieldKind: String  // Sources/Search/Fork/Credentials/Autofill.swift
  // login group
  case username, password, otp
  // identity group
  case fullName, firstName, middleName, lastName, email, phone, company,
       address1, address2, address3, city, state, postalCode, country,
       ssn, passportNumber, licenseNumber
  // card group
  case cardNumber, cardName, cardExpMonth, cardExpYear, cardExp /*MM/YY combined*/, cardCode, cardBrand
  // anything else the classifier could not place but that has a name/label
  case other
  var group: Group  // .login | .identity | .card | .other
```

The JS classifier emits the same raw strings (`"cardNumber"`, `"address1"`, …).

### Autofill.swift (new, Fork/Credentials) — models

```swift
struct AutofillIdentity: Identifiable, Hashable {
  let id: String            // bw item id
  let name: String          // item name
  let title, firstName, middleName, lastName, username, company, email, phone: String
  let address1, address2, address3, city, state, postalCode, country: String
  let ssn, passportNumber, licenseNumber: String   // sensitive; in memory only
  var fullName: String      // first [middle] last
  var summary: String       // "123 Main St, Miami" or email/phone fallback
  func values() -> [FieldKind: String]   // every non-empty mapping, fullName included
}
struct AutofillCard: Identifiable, Hashable {
  let id: String
  let name: String
  let cardholderName, brand, expMonth, expYear: String
  let number, code: String  // sensitive; in memory only
  var last4: String
  var label: String         // "Visa •••• 4242"
  func values() -> [FieldKind: String]   // includes cardExp "MM/YY" + cardExpYear 4- and 2-digit handled by the filler
}
struct AutofillField: Hashable {          // custom field on a site-matching item
  let itemID: String; let itemName: String; let name: String; let value: String; let hidden: Bool
}
enum Autofill {   // @MainActor façade over Bitwarden cache (+ future sources)
  static var identities: [AutofillIdentity]
  static var cards: [AutofillCard]
  static func fields(for host: String) -> [AutofillField]     // custom fields on login items matching host
  static func fields(for host: String, matching label: String) -> [AutofillField]  // name ≈ label (case/space/dash-insensitive, contains either way)
  static var topUsernames: [String]   // most-used login usernames desc, then identity emails/usernames, deduped, max 8
  static func isAllowed(_ id: String) -> Bool  // AgentAccess.shareAll || AgentAccess.allowed.contains("bw:"+id)
}
```

### Bitwarden.swift additions

- Decode `type` 3 (card: `card{cardholderName,brand,number,expMonth,expYear,code}`) and
  `type` 4 (identity: `identity{title,firstName,middleName,lastName,address1,address2,address3,
  city,state,postalCode,country,company,email,phone,ssn,username,passportNumber,licenseNumber}`)
  and `type` 2 (secure note: keep `notes` in memory as a secret, expose `Item.hasNotes`).
- `Item.fields` keeps **all** custom field types (0 text, 1 hidden, 2 boolean, 3 linked) with a
  `hidden: Bool` flag; hidden values go to the `secrets` map instead of the metadata item —
  add `func fieldValue(itemID:name:) -> String?` that resolves either.
- `private(set) var cachedIdentities: [AutofillIdentity]`, `cachedCards: [AutofillCard]`
  populated in `items()`; cleared in `clearCache()`; `cacheVersion` bump covers them.
- `var counts: (logins: Int, identities: Int, cards: Int, notes: Int)`.
- Nothing else changes (session handling, timers, login/unlock).

### Forms.swift JS additions (`window.__officeForms`)

- `classify(el) -> {kind, group}`: autocomplete tokens first (`cc-number`, `cc-name`, `cc-exp`,
  `cc-exp-month`, `cc-exp-year`, `cc-csc`, `cc-type`, `given-name`, `additional-name`,
  `family-name`, `name`, `email`, `tel`/`tel-national`, `organization`, `street-address`,
  `address-line1/2/3`, `address-level1` (state), `address-level2` (city), `postal-code`,
  `country`/`country-name`, `username`, `current-password`, `new-password`,
  `one-time-code`); then `name`/`id`/`aria-label`/`placeholder`/associated `<label>` text
  regexes (English + common abbreviations: `zip|postal`, `cvv|cvc|csc|security code`,
  `exp|expir`, `card.?number|ccnum|pan`, `first.?name|fname|given`, `last.?name|lname|surname|family`,
  `street|address.?(line)?1|addr1`, `apt|suite|unit|address.?(line)?2`, `city|town|locality`,
  `state|province|region`, `country`, `phone|tel|mobile`, `company|organi[sz]ation`, `ssn|social`,
  `passport`, `licen[cs]e`); `<select>` elements count for state/country/expMonth/expYear/brand.
  Password inputs are `password`; the username of a `pair()` stays `username`.
- `focus` message gains `field: {kind, group, label}` for any classified element, and `rect`
  is now sent for **every** classified input/select/textarea, not only the sign-in pair
  (login-group behaviour unchanged).
- `fillValues(map)` — `map` is `{kind: value}`; for the focused element's scope
  (`form` or nearest container up to 4 levels, else document) fill every classified element
  whose kind has a value; for `<select>`, choose by option value or text (case-insensitive,
  also 2-letter state/country codes ⇄ names for US states and common countries, month
  `1`/`01`/`January`, year `2029`/`29`); `cardExp` fills `MM/YY` or `MM / YYYY` by
  the box's placeholder/maxlength; `fullName` fills only when there is no first/last pair.
  Returns the count of boxes filled.
- `fillFocused(value)` — put `value` into the focused element (custom fields, usernames).
- `hasFields(group) -> Bool` and `fieldsPresent() -> [kind]` for agents/Jev.
- `put()` stays the one setter; also dispatch `keyup`/`blur` after `input`/`change` so React/Vue
  and Stripe-style validators notice.

### Tab.swift additions

```swift
struct FocusedField: Equatable { let kind: FieldKind; let group: FieldKind.Group; let label: String }
var fieldFocus: FocusedField?                       // set from FormRelay `focus`
func fieldFocused(_ rect: CGRect?, hint: String = "", field: FocusedField? = nil)
func fillValues(_ values: [FieldKind: String], done: ((Int) -> Void)? = nil)
func fillFocused(_ value: String, done: ((Bool) -> Void)? = nil)
func hasFields(_ group: FieldKind.Group) async -> Bool
```
`onField` closure keeps its shape `(Tab, CGRect?) -> Void`; Browser reads `tab.fieldFocus`.

### Browser.swift / Accounts.swift

```swift
struct Suggesting: Equatable {
  let tab: Tab.ID; let spot: CGRect
  let credentials: [Credential]     // unchanged
  let rows: [Suggestion]            // NEW — what the list draws, in order
}
enum Suggestion: Identifiable, Hashable {
  case credential(Credential)
  case username(String)             // "Use <name>"
  case identity(AutofillIdentity)
  case card(AutofillCard)
  case field(AutofillField)
  var id: String
}
func choose(_ suggestion: Suggestion)  // routes: credential → existing choose(_:), others → tab.fillValues / fillFocused
```
`onField`: build rows per `tab.fieldFocus?.group`: login → credentials (+ usernames when the
focused kind is `username`/`email` and credentials are empty); card → cards; identity →
identities; any → `Autofill.fields(for: host, matching: label)` first when non-empty.
Gate identity/card/field/username rows on `prefs.fillsEverything`.
`AccountList` renders `asked.rows`; symbols: credential `key`/`shield`, username `person`,
identity `person.text.rectangle`, card `creditcard`, field `textformat.123`. Footer text
"From your keychain and Bitwarden" unchanged; when rows are only autofill kinds:
"From Bitwarden".

### Agent: `browser_autofill`

Tool schema: `{ kind: "card" | "identity" | "field", name?: string, submit?: bool (default false) }`.
`Fork/MCP/AgentAutofill.swift` (new) `enum AgentAutofill { static func run(_ args, in: Browser, source:) async throws -> [String: Any] }`:
- refuses `shy` tabs; requires an unlocked vault; `kind=card|identity`: candidates =
  `Autofill.cards/identities` filtered by `Autofill.isAllowed`; `name` matches item `name`,
  card `label`/`last4`, identity `fullName`/`email` case-insensitively; one candidate → fill;
  several → `["candidates": [names], "kind": kind]`; none permitted but some exist → error
  "… not shared with agents — enable it in Settings › Passwords › Agent access".
- checks `tab.hasFields(group)` **before** touching values; fills via `tab.fillValues`;
  returns `["filled": n, "kind": kind, "name": item name, "submitted": Bool]` — never a value.
- `kind=field`: `name` required; `Autofill.fields(for: host, matching: name)` filtered by
  allowed item ids; fills the focused box or, if none focused, the first page box whose
  label matches (`fillField(label, value)` JS helper).
- `Tools.swift`: catalogue entry after `browser_sign_in`; dispatch case.
- `CLI.swift`: `copper autofill card|identity|field [--name NAME] [--submit]` → `browser_autofill`;
  help text; `skill/copper-cli/SKILL.md` line.
- `Ultrafast.swift`: when the observation includes card-group fields and an allowed card exists →
  control `AUTOFILL_CARD` "Fill the saved card (number, expiry, code) for you"; identity-group
  fields + allowed identity → `AUTOFILL_IDENTITY`. `act` routes both to `AgentAutofill.run`.
  Mirror how `SIGN_IN` is threaded (`signInAvailable` → an `autofillAvailable: Set<String>`).
- `AgentAccess`: unchanged API; `AgentAccessCard` (CredentialsSettings.swift) gets two more
  sections listing identities and cards with the same toggle, ids `bw:<id>`.

### Prefs / Settings

- `Prefs.fillsEverything: Bool` key `"autofill.everything"`, default `true`.
- Settings › Passwords: `Line("Fill addresses and cards", "Click into a checkout or address form and your Bitwarden identities and cards hang from it") { Switch(on: $prefs.fillsEverything) }` right after "Fill in sign-ins".
- `BitwardenCard` unlocked state shows `Bitwarden.shared.counts` as "12 logins · 2 identities · 3 cards".

### bench (`Fork.swift` `case "bw"`, `bench` help)

- `bw identities` → `[{id, name, fullName, summary, agent}]`; `bw cards` → `[{id, name, label, holder, agent}]` (never number/code);
  `bw fields HOST` → `[{item, name, hidden}]`; `bw usernames` → `[String]`;
  `bw autofill card|identity ID` → runs `browser.choose(.card/.identity)` on the active tab; returns `{started}`.
- `bw candidates` unchanged.

## Waves

**Wave 1 (parallel, disjoint files):**
- W1-A BACKEND: `Fork/Credentials/Autofill.swift` (new), `Fork/Credentials/Bitwarden.swift`, `Fork/Credentials/CredentialStore.swift` (only if needed), `Fork/Credentials/AgentAccess.swift` (no API change).
- W1-B PAGE: `Forms.swift` JS + `Tab.swift` (FocusedField, fillValues, fillFocused, hasFields). Defines `FieldKind` **stub-free**: FieldKind lives in Autofill.swift (W1-A) — W1-B must use the exact enum above; to compile independently W1-B may add the enum to `Fork/Credentials/FieldKind.swift` (new file) and W1-A must NOT define it again. → Decision: **`FieldKind` lives in `Fork/Credentials/FieldKind.swift`, owned by W1-B.**

**Wave 2 (parallel, after Wave 1 compiles):**
- W2-C UI: `Browser.swift` (Suggestion/rows/choose), `Accounts.swift`, `Prefs.swift`, `Settings.swift`, `Fork/CredentialsSettings.swift` (counts + agent access sections), `App.swift` only if required.
- W2-D AGENT: `Fork/MCP/AgentAutofill.swift` (new), `Tools.swift`, `CLI.swift`, `Ultrafast.swift`, `skill/copper-cli/SKILL.md`, `docs/agents.md`.
- W2-E BENCH+DOCS: `Fork/Fork.swift` bw verbs, `bench` help, `docs/passwords.md`, `CHANGELOG.md`, `PATCHES.md`, seed Vaultwarden fixture items (identity, card, login with custom fields incl. a hidden one) via `bw` against `~/exowatt/tmp/copper-creds/ENV.md`, plus a local fixture page `docs/fixtures/autofill.html` (checkout form with address + card + PIN fields, autocomplete attrs on half of them, plain names on the other half).

**Wave 3 (serial, main thread + one worker):** build, fix, probe-world e2e with `./bench --world autofill …` against the fixture page; window-shot QA of the picker; commit → push `fork` → tap release.
