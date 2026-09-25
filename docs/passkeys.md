# Passkeys in Copper

Copper is its own WebAuthn authenticator in builds that do not have Apple's
`com.apple.developer.web-browser.public-key-credential` entitlement. A small
page-side WebAuthn polyfill presents the normal `PublicKeyCredential` API. Its
create and get requests cross a reply-capable WebKit message bridge; Copper
validates the relying-party id, asks for Touch ID (or the Mac login password),
and signs with a P-256 key kept in the login keychain under **Copper Passkeys**.

New credentials use ES256, the platform attachment, and the standard WebAuthn
client-data and authenticator-data shapes. The Settings › Passwords page lists
the site, account, source, and use dates. **Forget** proves the user first and
then removes the keychain item.

## What Copper can and cannot do

- Copper makes a new passkey on each site. It cannot use an existing iCloud
  Keychain passkey because WebKit does not hand that credential to an
  unentitled browser.
- Passkeys imported from Chrome through Flow can be stored and used by Copper
  when their private key is available to the import path.
- Keys are local to this Copper installation and its keychain. There is no
  cross-device sync, Bluetooth/hybrid hand-off, or iCloud sync in this build.
- Conditional (autofill) mediation is reported unavailable so sites fall back
  to their explicit passkey button. A normal create/get ceremony always asks
  for user verification.
- The authenticator supports ES256 (COSE algorithm `-7`) and discoverable
  credentials. Other algorithms are rejected rather than silently producing a
  credential a site cannot verify.

For automated QA, `./bench --world pkqa passkeys answer yes` answers the native
verification prompt in that isolated test world. `list`, `count`, and
`forget --id ID` expose metadata only; private key bytes are never returned.
