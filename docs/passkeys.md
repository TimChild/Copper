# Passkeys in Copper

Copper is its own WebAuthn authenticator in builds that do not have Apple's
`com.apple.developer.web-browser.public-key-credential` entitlement. A small
page-side WebAuthn polyfill presents the normal `PublicKeyCredential` API. Its
create and get requests cross a reply-capable WebKit message bridge; Copper
validates the relying-party id, asks for Touch ID (or the Mac login password),
and signs with a P-256 key kept in the login keychain under **Copper Passkeys**.

The page bridge uses `publicKey.rp.id` when creating a passkey and
`publicKey.rpId` when signing in. If the site omits that field, the document
hostname is the default. An explicit parent-domain id is preserved: a page at
`accounts.example.test` can ask for its `example.test` credential, subject to
Copper's existing native origin/RP validation. Previously creation sent the
whole `rp` object and assertion ignored `rpId`, causing the native side to fall
back to the sign-in subdomain and miss credentials scoped to the parent.

New credentials use ES256, the platform attachment, and the standard WebAuthn
client-data and authenticator-data shapes. `getTransports()` reports only
`internal`; this authenticator does not support `hybrid`. The Settings › Passwords
page lists the site, account, source, and use dates. **Forget** proves the user first and
then removes the keychain item.

## Bitwarden passkeys

When Bitwarden is connected and unlocked, the passkeys in its vault
(`login.fido2Credentials` on a login item) sign in here too: Copper is the
authenticator, Bitwarden only keeps the key. No Bitwarden extension is
involved, and nothing changes when Bitwarden is locked or not connected.

**Which passkeys a sign-in offers.** Copper's own keychain passkeys first,
then the vault's whose `rpId` is exactly the request's relying-party id. When
the site sends `allowCredentials`, only those ids match (a vault id is a GUID —
its 16 bytes — or `b64.` + base64url for an imported one); when it leaves the
list empty, only passkeys marked `discoverable`. One match goes straight to
user verification; several show a chooser (account · source) first — a sheet
on the tab's window, Cancel is `NotAllowedError`.

**User verification.** Every person-driven sign-in asks for Touch ID (or the
Mac login password) through the same prompt as Copper's own passkeys —
"Sign in to *site* with your Bitwarden passkey (*account*)" — and the vault is
read only after it says yes: a refused prompt never runs `bw get item`.

**The key.** The unlocked cache carries metadata only (site, account, id,
counter, discoverable, created); `keyValue` is not even decoded into it. After
the prompt, Copper reads that one item with `bw get item`, decodes the PKCS#8
ES256 key in memory, signs `authenticatorData ‖ SHA-256(clientDataJSON)`, and
overwrites the item JSON and key bytes it holds before answering. CryptoKit
zeroes its own key storage when the key goes. Nothing is written to disk, the
keychain, a log, the bench or MCP. (Foundation's parsed JSON strings are
released, not overwritten — a limit of reading `bw`'s JSON in Swift.) Only
`ECDSA` / `P-256` passkeys are listed; others are left out rather than failing.

**Counter.** Bitwarden leaves most passkey counters at 0 and so does Copper:
0 is signed as 0 and the item is not touched. A non-zero counter is advanced by
one in `authenticatorData` and written back with `bw edit item` (the encoded
item on stdin, never argv) before the answer goes to the site; if the write
fails the sign-in still stands and the log says so.

**Saving new passkeys to Bitwarden.** With Settings › Passwords › *Save new
passwords to* set to Bitwarden **and** Bitwarden unlocked (the same rule as
password saves), a passkey a site creates goes into the vault instead of the
keychain: it joins the site's login for the same account when that login has no
passkey yet (Bitwarden keeps one per login), otherwise it becomes a new login
named after the site. It is written in Bitwarden's own shape (GUID id, base64url
PKCS#8, `counter` "0", `discoverable` "true") with `bw edit item` / `bw create
item` on stdin, and the cache is refreshed so the next sign-in sees it. If
Bitwarden is locked, set to another target, or refuses the write, the passkey
is kept in the keychain as before — a site mid-registration never gets a
failure because of the vault. `excludeCredentials` is checked against both.

**Agents.** An agent signs in with a Bitwarden passkey under the same rule as a
Bitwarden password (Settings › Passwords › Agent access: a per-item toggle,
share-everything, the `Agents` folder, `copper-agent: deny` always wins), and
never receives key material — the result is the site's own sign-in. A request
counts as the agent's, and is signed with no chooser or prompt, only when:

- the agent armed the tab with `browser_sign_in` `what: "passkey"` (`copper
  signin --passkey`) — one request, within 60 s, with the named (or only)
  shared account — and then clicked the site's passkey button; or
- the tab is one only the agent can be driving: held backstage, on no screen.

A tab on screen that an agent has merely touched lately is still the person's:
a passkey request there gets the person's chooser and Touch ID. Private tabs
are never signed for an agent. With several shared passkeys and none named,
the request is refused with their account names; an unshared one is refused
with the Agent access hint. Copper's own keychain passkeys are never used for
an agent without the person's prompt. The vault being unlocked stands in for
user verification on the agent path (the UV flag is set), as it does for
Bitwarden's own authenticator.

**Where they show.** Settings › Passwords › Passkeys lists them after Copper's
own, marked *In Bitwarden* (remove them in Bitwarden). The password picker's
row for a login that also holds a passkey reads *site · passkey*.
`./bench passkeys list|count` include them (metadata only, `source:
"bitwarden"`, with the agent rule's answer); `./bench bw candidates HOST` has a
`passkey` flag.

## Passkey extensions (1Password and others)

An extension such as 1Password intercepts WebAuthn from a MAIN-world content
script (`inline/injected/webauthn-listeners.js`). At load it binds the
current `navigator.credentials.get`/`create` as its fallback, captures the
current `PublicKeyCredential` statics, then installs non-configurable
accessors. Each call asks its background whether to handle the request
(signed in, a matching passkey, the user's save/fill settings); if not, or if
the user chooses "use another method", it calls the bound fallback.

WebKit injects extension content scripts before the tab's own user scripts,
so that fallback used to be WebKit's unentitled implementation, which rejects
every request at once (`NotAllowedError: The request is not allowed by the
user agent…`). Copper's polyfill then replaced `window.PublicKeyCredential`,
dropping the extension's conditional-mediation hooks as well.

Copper therefore carries its authenticator inside the extension:
`ExtensionShims.prepare` writes `search-passkeys.js` (`Passkeys.extensionPrelude`)
and runs it right after `search-shim.js` in every `world: MAIN` content
script. It is inert unless the tab registered the `copperPasskeys` handler,
which happens exactly while Copper is the authenticator. The order is then:

1. Copper installs its `navigator.credentials` methods and statics on WebKit's
   own `PublicKeyCredential` (kept, not replaced).
2. The extension wraps them. When it handles a request, Copper is never asked;
   when it declines, its fallback is Copper's authenticator.
3. Copper's deferred reinstall restores only a method that reverted to WebKit's
   native one, never a wrapper installed after it.

If an extension's hook still lands first (a script injected dynamically, not
from the manifest), Copper leaves it in place; if the hook is an accessor with
a setter (1Password's), Copper is offered through that setter, which the hook
uses whenever it is not intercepting.

Credentials Copper returns, and ones an extension builds with
`Object.setPrototypeOf(…, PublicKeyCredential.prototype)`, are instances of
WebKit's `PublicKeyCredential`, `AuthenticatorAssertionResponse` /
`AuthenticatorAttestationResponse` and `AuthenticatorResponse`, with
`getClientExtensionResults()` and `toJSON()`. A page without those classes gets
stand-ins of the same names.

## What Copper can and cannot do

- Copper makes a new passkey on each site (in the keychain, or in Bitwarden
  when that is the save target). It cannot use an existing iCloud Keychain
  passkey because WebKit does not hand that credential to an unentitled
  browser; passkeys kept in Bitwarden it can (above).
- Passkeys imported from Chrome through Flow can be stored and used by Copper
  when their private key is available to the import path.
- Keys are local to this Copper installation and its keychain. There is no
  cross-device sync, Bluetooth/hybrid hand-off, or iCloud sync in this build.
- Copper's own authenticator has no conditional (autofill) UI: on its own it
  reports `isConditionalMediationAvailable()` false and rejects a
  `mediation: 'conditional'` request with `NotSupportedError`, so sites fall
  back to their explicit passkey button. When an extension that offers
  passkey autofill (1Password) hooks the API, its answer is what the page
  sees — Copper does not override it. A normal create/get ceremony always
  asks for user verification.
- With no credential for the relying party, `get` rejects with
  `NotAllowedError`, the same answer a platform authenticator gives when the
  user has nothing to pick; sites treat it as a cancel and offer another way.
- The authenticator supports ES256 (COSE algorithm `-7`) and discoverable
  credentials. Other algorithms are rejected rather than silently producing a
  credential a site cannot verify.

## Regression checks

```sh
node --test docs/fixtures/passkey-bridge-test.cjs
```

This runs the production page script extracted from its Swift raw string in an
isolated JavaScript context. It covers parent-domain create/get, host defaults,
operation-specific RP fields, option immutability, native error propagation,
transport reporting, non-WebAuthn fallbacks, cancellation, conditional mediation,
a missing bridge, and the extension order: a 1Password-shaped hook installed
after Copper (declines → Copper answers, accepts → Copper not asked), one
installed before it (left in place, offered Copper through its setter), the
deferred reinstall never undoing a later wrapper, and the instance/JSON shapes. It uses only synthetic data, a mock message handler and
Node's built-in test runner: no account, network, browser profile or keychain.
It does not prove a successful live Google login or native signature verification.

```sh
# Build/package the dev app and run the native smoke test:
docs/fixtures/passkey-native-e2e.sh
# Or reuse an already-built dev app:
COPPER_SKIP_BUILD=1 docs/fixtures/passkey-native-e2e.sh
```

The native fixture uses real WebKit, the Swift relay and a localhost server in
a fresh headless test world. It creates one synthetic keychain item scoped to
that world, signs an assertion, verifies its ES256 signature with WebCrypto,
checks the RP hash/user-verification flag, rejects unrelated RP ids for both
create and get, and checks internal-only transport. It then forgets the item
and verifies the count is zero; its exit trap cleans the scoped service and
test-world files on failure as well. It never replaces the installed Copper
app or uses real credentials. Approval is automated **only** in the test world;
a successful run does not validate a real Touch ID prompt or live Google login.

```sh
# A synthetic MV3 extension whose MAIN-world script wraps WebAuthn like 1Password:
COPPER_SKIP_BUILD=1 docs/fixtures/passkey-extension-e2e.sh
```

The extension fixture installs that extension into a fresh headless test world
and opens a localhost relying party. It checks that Copper's authenticator was
in place before the extension's hook ran, that the extension's
`isConditionalMediationAvailable` hook survives, that get/create the
extension accepts never reach Copper (the scoped keychain stays empty), that
declined get/create fall through to Copper and return `PublicKeyCredential` /
`Authenticator*Response` instances, and that a missing credential is a
`NotAllowedError`. It cleans up like the native fixture. It uses no real
extension, so it does not prove 1Password's own background decisions or a
live Google sign-in.

```sh
# Bitwarden vault passkeys, with a mock `bw` (docs/fixtures/bw-mock/bw):
COPPER_SKIP_BUILD=1 docs/fixtures/passkey-bitwarden-e2e.sh
```

The Bitwarden fixture runs a fresh headless test world with the file stand-in
for the keychain, a loopback MCP port of its own, and `SEARCH_BW_PATH` pointed
at the mock CLI, which answers `bw`'s commands from a JSON file seeded with
synthetic P-256 `fido2Credentials` for `localhost` and logs every call's argv
(an encoded item only as its length), `BW_*` variable names and stdin size. It
checks the Settings/bench listing (metadata only) and the picker's passkey
flag; an `allowCredentials` sign-in with a non-discoverable passkey whose
ES256 signature WebCrypto verifies against the synthetic public key, with RP
hash, UP and UV; discoverable selection through the chooser (non-discoverable
left out); a non-zero counter advanced in authData and the vault (edit on
stdin) and a zero counter left alone; a refused Touch ID → `NotAllowedError`
with no `bw get item`; another RP's passkey never offered; the agent paths
(a backstage tab signs a shared passkey with the chooser and Touch ID set to
refuse, an unshared one is refused with the hint; `browser_sign_in
what=passkey` arms without reading the vault; an on-screen tab the agent holds
stays the person's until armed, and an arm is used once); save-to-Bitwarden
(a new login, joining a password-only login, and the keychain when the vault is
locked); and finally that no private key appears in any bench/MCP output,
calls.log, the Copper log or the world's files. It does not exercise the real
`bw` CLI, a real vault, a real Touch ID prompt or a live site.

For automated QA, `./bench --world pkqa passkeys answer yes` answers the native
verification prompt in that isolated test world, and `passkeys pick NAME|N|ask`
answers the chooser (`offered` is the rows it last showed). `list`, `count`, and
`forget --id ID` expose metadata only; private key bytes are never returned.
