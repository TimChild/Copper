import Foundation

/// The one source-neutral password façade used by the picker, save offer, and
/// agent surfaces. It is main-actor isolated because both Vault and the
/// Bitwarden cache are owned by Copper's UI process.
@MainActor
enum Credentials {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Backend: String {
        case keychain
        case bitwarden
    }

    static var saveTarget: Backend {
        guard Store.settings.string(forKey: "passwords.backend") == Backend.bitwarden.rawValue,
              isBitwardenUnlocked
        else { return .keychain }
        return .bitwarden
    }

    static func candidates(for host: String) -> [Credential] {
        let keychain = Vault.logins(matching: host).map { login in
            Credential(id: .keychain(host: login.host, user: login.user), source: .keychain,
                       host: login.host, user: login.user, sites: [login.host], name: login.user,
                       hasTOTP: false, used: login.used, folder: nil, agentHint: .none)
        }
        guard isBitwardenUnlocked else { return sorted(deduplicated(keychain)) }

        let folders = Dictionary(uniqueKeysWithValues: Bitwarden.shared.cachedFolders.map { ($0.id, $0.name) })
        let bitwarden = Bitwarden.shared.cachedItems
            .filter { item in item.uris.contains { matches($0, host: host) } }
            .map { credential(for: $0, folders: folders) }
        return sorted(deduplicated(keychain + bitwarden))
    }

    static func all() -> [Credential] {
        let keychain = Vault.all().map { login in
            Credential(id: .keychain(host: login.host, user: login.user), source: .keychain,
                       host: login.host, user: login.user, sites: [login.host], name: login.user,
                       hasTOTP: false, used: login.used, folder: nil, agentHint: .none)
        }
        guard isBitwardenUnlocked else { return sorted(deduplicated(keychain)) }
        let folders = Dictionary(uniqueKeysWithValues: Bitwarden.shared.cachedFolders.map { ($0.id, $0.name) })
        let bitwarden = Bitwarden.shared.cachedItems.map { credential(for: $0, folders: folders) }
        return sorted(deduplicated(keychain + bitwarden))
    }

    static func secret(_ id: CredentialID) async throws -> String {
        switch id {
        case .keychain(let host, let user):
            // Read now, for this one account only — the keychain may ask.
            guard let password = Vault.secret(host: host, user: user)
            else { throw Failure(message: "The keychain didn't give up that password") }
            return password
        case .bitwarden(let itemID):
            return try await Bitwarden.shared.password(for: itemID)
        }
    }

    static func totp(_ id: CredentialID) async throws -> String {
        switch id {
        case .keychain:
            throw Failure(message: "Keychain credentials do not have a TOTP code")
        case .bitwarden(let itemID):
            return try await Bitwarden.shared.totp(for: itemID)
        }
    }

    static func save(host: String, user: String, password: String) async throws {
        switch saveTarget {
        case .keychain:
            guard Vault.save(host: host, user: user, password: password) else {
                throw Failure(message: "Could not save the credential to the keychain")
            }
        case .bitwarden:
            _ = try await Bitwarden.shared.create(host: host, user: user, password: password)
        }
    }

    static func touch(_ credential: Credential) {
        guard case .keychain(let host, let user) = credential.id else { return }
        Vault.touch(Login(host: host, user: user, password: "", used: nil))
    }

    // MARK: - Bitwarden metadata and URI matching

    private static var isBitwardenUnlocked: Bool {
        if case .unlocked = Bitwarden.shared.state { return true }
        return false
    }

    private static func credential(for item: Bitwarden.Item, folders: [String: String]) -> Credential {
        let folder = item.folderId.flatMap { folders[$0] }
        let lowerFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let denied = item.fields.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "copper-agent"
                && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "deny"
        }
        let hint: Credential.AgentHint
        if denied {
            hint = .deny
        } else if lowerFolder == "agents" {
            hint = .allow
        } else {
            hint = .none
        }
        let host = item.uris.first.flatMap { uriHost($0.uri) } ?? item.name
        return Credential(id: .bitwarden(item.id), source: .bitwarden, host: host,
                          user: item.username, sites: item.uris.map(\.uri), name: item.name,
                          hasTOTP: item.hasTOTP, used: nil, folder: folder, agentHint: hint)
    }

    private static func matches(_ uri: Bitwarden.URI, host: String) -> Bool {
        let target = normalized(host)
        let match = uri.match ?? 0
        if match == 5 { return false }
        if match == 4 {
            let targetURL = canonicalURL(host: target, scheme: scheme(of: uri.uri))
            guard let expression = try? NSRegularExpression(pattern: uri.uri, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(targetURL.startIndex..<targetURL.endIndex, in: targetURL)
            return expression.firstMatch(in: targetURL, options: [], range: range) != nil
        }
        guard let uriHost = uriHost(uri.uri) else { return false }
        let stored = normalized(uriHost)
        switch match {
        case 1:
            return stored == target
        case 2:
            let targetURL = canonicalURL(host: target, scheme: scheme(of: uri.uri))
            return targetURL.lowercased().hasPrefix(uri.uri.lowercased())
        case 3:
            let targetURL = canonicalURL(host: target, scheme: scheme(of: uri.uri))
            return targetURL.caseInsensitiveCompare(uri.uri.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) == .orderedSame
                || (isLocalOrAddress(target) && stored == target)
        default:
            if isLocalOrAddress(target) || isLocalOrAddress(stored) {
                return stored == target
            }
            return Vault.registrable(stored) == Vault.registrable(target)
        }
    }

    private static func uriHost(_ value: String) -> String? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        if let host = URL(string: candidate)?.host, !host.isEmpty { return normalized(host) }
        return normalized(raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? raw)
    }

    private static func normalized(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func scheme(of uri: String) -> String {
        guard let range = uri.range(of: "://") else { return "https" }
        return String(uri[..<range.lowerBound]).lowercased()
    }

    private static func canonicalURL(host: String, scheme: String) -> String {
        "\(scheme)://\(host)"
    }

    private static func isLocalOrAddress(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.contains(":") { return true }
        let pieces = host.split(separator: ".")
        return pieces.count == 4 && pieces.allSatisfy { Int($0) != nil }
    }

    // MARK: - Ordering and duplicate policy

    private static func deduplicated(_ values: [Credential]) -> [Credential] {
        var result: [Credential] = []
        for value in values {
            let key = "\(normalized(value.host))\u{1}\(value.user.lowercased())"
            guard let existing = result.firstIndex(where: {
                "\(normalized($0.host))\u{1}\($0.user.lowercased())" == key
            }) else {
                result.append(value)
                continue
            }
            if value.source == .bitwarden && result[existing].source == .keychain {
                result[existing] = value
            }
        }
        return result
    }

    private static func sorted(_ values: [Credential]) -> [Credential] {
        values.sorted {
            let left = $0.used ?? .distantPast
            let right = $1.used ?? .distantPast
            if left != right { return left > right }
            let leftName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if leftName != .orderedSame { return leftName == .orderedAscending }
            return $0.user.localizedCaseInsensitiveCompare($1.user) == .orderedAscending
        }
    }
}
