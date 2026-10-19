import CryptoKit
import Foundation

// Passkeys kept in the Bitwarden vault (`login.fido2Credentials`), signed by
// Copper's own authenticator.
//
// The unlocked item cache carries only their metadata (Bitwarden.Passkey):
// site, account, credential id, counter. The private key is read from
// `bw get item` at the moment a sign-in has been chosen and verified, used
// in memory, and the buffers Copper holds are overwritten before it returns.
// Nothing here writes a vault key to disk, the keychain, a log or a reply.
//
// Bitwarden keeps one shape for every passkey: ES256 (keyAlgorithm ECDSA,
// keyCurve P-256), the key as base64url PKCS#8, the credential id as a GUID
// (or `b64.` + base64url for an imported one), the user handle as base64url,
// counter and discoverable as strings.

@MainActor
enum BitwardenPasskeys {
    /// One vault passkey with the login it lives on.
    struct Match: Hashable {
        let item: Bitwarden.Item
        let passkey: Bitwarden.Passkey
        /// The credential id as the site knows it (raw bytes).
        let id: Data

        /// What a person recognises: the passkey's account, else the login's.
        var label: String {
            if !passkey.userName.isEmpty { return passkey.userName }
            if !passkey.userDisplayName.isEmpty { return passkey.userDisplayName }
            return item.username.isEmpty ? item.name : item.username
        }

        var userHandle: Data { passkey.userHandle.flatMap(Data.init(base64URL:)) ?? Data() }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static var unlocked: Bool {
        if case .unlocked = Bitwarden.shared.state { return true }
        return false
    }

    /// Every vault passkey, for Settings and the bench. Empty while locked.
    static func all() -> [Match] {
        guard unlocked else { return [] }
        return Bitwarden.shared.cachedItems.filter { $0.type == 1 }.flatMap { item in
            item.passkeys.compactMap { passkey in rawID(passkey.credentialId).map { Match(item: item, passkey: passkey, id: $0) } }
        }
    }

    /// The vault passkeys a sign-in may use: this relying party exactly,
    /// then the site's list when it gave one, or only discoverable passkeys
    /// when it left the choice to the authenticator (an empty list).
    static func matching(rpId: String, allow: [Data]) -> [Match] {
        all().filter { match in
            guard match.passkey.rpId.caseInsensitiveCompare(rpId) == .orderedSame else { return false }
            return allow.isEmpty ? match.passkey.discoverable : allow.contains(match.id)
        }
    }

    /// Whether the person shared this passkey's login with agents — the same
    /// rule, and the same switch, as its password (AgentAccess).
    static func sharedWithAgents(_ match: Match) -> Bool {
        AgentAccess.isAllowed(Credentials.credential(bitwarden: match.item))
    }

    // MARK: - ids

    /// A vault credential id as bytes: a GUID is its 16 bytes, `b64.` marks
    /// base64url, and anything else is tried as base64url.
    nonisolated static func rawID(_ text: String) -> Data? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: value) {
            return withUnsafeBytes(of: uuid.uuid) { Data($0) }
        }
        if value.hasPrefix("b64.") { return Data(base64URL: String(value.dropFirst(4))) }
        return Data(base64URL: value)
    }

    /// How a credential id made here is written to the vault: Bitwarden's
    /// own GUID form for 16 bytes, `b64.` + base64url otherwise.
    nonisolated static func vaultID(_ raw: Data) -> String {
        guard raw.count == 16 else { return "b64." + raw.base64URL }
        let b = Array(raw)
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return uuid.uuidString.lowercased()
    }

    // MARK: - signing

    struct Assertion {
        let authenticatorData: Data
        let signature: Data
    }

    /// Sign one assertion with the vault key. `authenticatorData` is built by
    /// the caller from the counter handed to it, which comes from the item
    /// as `bw get item` returns it now, not the cache. Bitwarden leaves most
    /// counters at zero and so does this; a non-zero counter is advanced and
    /// written back to the item before the answer goes to the site.
    static func sign(_ match: Match, clientDataHash: Data,
                     authenticatorData: (UInt32) -> Data) async throws -> Assertion {
        try await Bitwarden.shared.requireUnlocked()
        var raw = try await Bitwarden.shared.run(["get", "item", match.item.id])
        defer { raw.resetBytes(in: 0..<raw.count) }
        guard var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var login = object["login"] as? [String: Any],
              var entries = login["fido2Credentials"] as? [[String: Any]],
              let at = entries.firstIndex(where: { ($0["credentialId"] as? String) == match.passkey.credentialId }),
              let keyText = entries[at]["keyValue"] as? String
        else { throw Failure(message: "Bitwarden no longer has that passkey") }

        let stored = counter(entries[at]["counter"])
        let next: UInt32 = stored == 0 ? 0 : stored &+ 1
        let auth = authenticatorData(next)
        var der = Data(base64URL: keyText) ?? Data(base64Encoded: keyText) ?? Data()
        defer { der.resetBytes(in: 0..<der.count) }
        let signature: Data
        do {
            let key = try P256.Signing.PrivateKey(derRepresentation: der)
            signature = try key.signature(for: auth + clientDataHash).derRepresentation
        } catch {
            throw Failure(message: "Bitwarden's passkey key could not be read")
        }

        if stored != 0 {
            // Keep the vault's spelling: the CLI writes a string.
            entries[at]["counter"] = entries[at]["counter"] is NSNumber ? NSNumber(value: next) : String(next)
            login["fido2Credentials"] = entries
            object["login"] = login
            do {
                try await edit(match.item.id, object)
            } catch {
                // The sign-in still stands; the next one repeats this count,
                // which a site that checks may refuse. Said, not hidden.
                NSLog("Copper: could not advance the Bitwarden passkey counter: \(error.localizedDescription)")
            }
            Task { await Bitwarden.shared.refreshCacheIfPossible() }
        }
        return Assertion(authenticatorData: auth, signature: signature)
    }

    private static func counter(_ value: Any?) -> UInt32 {
        if let number = value as? NSNumber { return number.uint32Value }
        if let text = value as? String { return UInt32(text.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return 0
    }

    // MARK: - writing

    /// `bw edit item ID` with the encoded item on stdin, never in argv where
    /// any process on the Mac could read it.
    private static func edit(_ id: String, _ object: [String: Any]) async throws {
        var json = try JSONSerialization.data(withJSONObject: object, options: [])
        defer { json.resetBytes(in: 0..<json.count) }
        var encoded = Data(json.base64EncodedString().utf8)
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        _ = try await Bitwarden.shared.run(["edit", "item", id], stdin: encoded, timeout: 30)
    }

    /// A passkey made in Copper, saved to the vault instead of the keychain
    /// (Save new passwords to: Bitwarden). It joins the site's login for the
    /// same account when that login has no passkey yet — Bitwarden keeps one
    /// per login — and is a new login otherwise.
    static func save(_ credential: PasskeyStore.Credential, key: P256.Signing.PrivateKey, rpName: String) async throws {
        try await Bitwarden.shared.requireUnlocked()
        var pkcs8 = key.derRepresentation
        defer { pkcs8.resetBytes(in: 0..<pkcs8.count) }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry: [String: Any] = [
            "credentialId": vaultID(credential.id),
            "keyType": "public-key",
            "keyAlgorithm": "ECDSA",
            "keyCurve": "P-256",
            "keyValue": pkcs8.base64URL,
            "rpId": credential.rpId,
            "rpName": rpName.isEmpty ? credential.rpId : rpName,
            "userHandle": credential.userHandle.base64URL,
            "userName": credential.userName,
            "userDisplayName": credential.displayName,
            "counter": "0",
            "discoverable": "true",
            "creationDate": stamp.string(from: credential.created),
        ]

        let joining = Credentials.itemsMatching(host: credential.rpId).first {
            $0.passkeys.isEmpty && !credential.userName.isEmpty
                && $0.username.caseInsensitiveCompare(credential.userName) == .orderedSame
        }
        if let joining {
            var raw = try await Bitwarden.shared.run(["get", "item", joining.id])
            defer { raw.resetBytes(in: 0..<raw.count) }
            guard var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw Failure(message: "Bitwarden returned an invalid item")
            }
            var login = object["login"] as? [String: Any] ?? [:]
            login["fido2Credentials"] = [entry]
            object["login"] = login
            try await edit(joining.id, object)
        } else {
            let object: [String: Any] = [
                "organizationId": NSNull(), "collectionIds": NSNull(), "folderId": NSNull(),
                "type": 1, "name": credential.rpId, "notes": NSNull(), "favorite": false,
                "fields": [], "reprompt": 0,
                "login": [
                    "username": credential.userName.isEmpty ? NSNull() : credential.userName,
                    "password": NSNull(), "totp": NSNull(),
                    "uris": [["uri": "\(OnePassword.scheme(for: credential.rpId))://\(credential.rpId)", "match": NSNull()]],
                    "fido2Credentials": [entry],
                ] as [String: Any],
            ]
            var json = try JSONSerialization.data(withJSONObject: object, options: [])
            defer { json.resetBytes(in: 0..<json.count) }
            var encoded = Data(json.base64EncodedString().utf8)
            defer { encoded.resetBytes(in: 0..<encoded.count) }
            _ = try await Bitwarden.shared.run(["create", "item"], stdin: encoded, timeout: 30)
        }
        // The next sign-in looks in the cache; it has to see this one.
        await Bitwarden.shared.refreshCacheIfPossible()
    }
}
