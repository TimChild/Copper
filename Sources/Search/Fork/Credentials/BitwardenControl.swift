import Foundation

// `copper bitwarden …` and the agents app's Mac page's Bitwarden panel land here,
// through the loopback server's `copper/bitwarden` method (MCP.swift) — never
// through the agent link, which refuses every `copper/*` method.
//
// What goes out is a status report: whether the CLI is there, its version,
// signed-in / locked / unlocked, the account email, the server, the last
// sync, the agent-access policy and how many logins, identities and cards
// the unlocked cache holds. Never a password, an API secret, a session key
// or a vault value. What comes in for `login` is the sealed payload the
// host daemon decrypted (server, email, master password, optional API key,
// optional two-step code, policy); the secrets go to `bw` through the child's
// environment only (Bitwarden.run) and are gone when this returns.

extension Bitwarden {
    /// Everything Copper may say about the vault. No secret, by construction:
    /// every value here is a flag, a count, an email, a URL or a date.
    func statusReport() -> [String: Any] {
        let cli = Self.installed
        let stateKey: String
        var email: String?
        var lastSync: Date?
        switch state {
        case .missing:
            stateKey = cli ? "unauthenticated" : "missing"
        case .unauthenticated:
            stateKey = cli ? "unauthenticated" : "missing"
        case .locked(let who):
            stateKey = "locked"
            email = who
        case .unlocked(let who, let synced):
            stateKey = "unlocked"
            email = who
            lastSync = synced
        }
        let server: Any
        if !cli {
            server = NSNull()
        } else if cliStatusKnown {
            server = cliServer ?? Self.defaultServer
        } else {
            server = serverURL
        }
        let counts = self.counts
        return [
            "cli": cli,
            "cliVersion": (cli ? cliVersion : nil).map { $0 as Any } ?? NSNull(),
            "state": stateKey,
            "email": email.map { $0 as Any } ?? NSNull(),
            "server": server,
            "lastSync": lastSync.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull(),
            "agentAccess": AgentAccess.shareAll ? "all" : "folder",
            "stayUnlocked": stayUnlocked,
            "counts": ["logins": counts.logins, "identities": counts.identities, "cards": counts.cards],
        ]
    }

    /// `op`: status | login | lock | logout | sync | policy. Always answers
    /// `{ok, …statusReport()}`; a failure adds `error`, one sanitized line.
    func control(_ params: [String: Any]) async -> [String: Any] {
        let op = (params["op"] as? String ?? "status").trimmingCharacters(in: .whitespacesAndNewlines)
        // Whatever the caller sent that must never be echoed back, even
        // inside a message `bw` wrote.
        let secrets = ["password", "clientId", "clientSecret", "otp"]
            .compactMap { params[$0] as? String }.filter { !$0.isEmpty }
        do {
            switch op {
            case "", "status":
                await refreshStatus()
            case "login":
                try await controlLogin(params)
            case "lock":
                await lock()
            case "logout":
                await logout()
                await refreshStatus()
            case "sync":
                try await sync()
            case "policy":
                try applyPolicy(params)
            default:
                throw Failure(message: "unknown bitwarden command: \(String(op.prefix(40)))")
            }
            await loadCLIVersion()
            var out = statusReport()
            out["ok"] = true
            return out
        } catch {
            await loadCLIVersion()
            var raw = (error as? Failure)?.message ?? error.localizedDescription
            // What the SDK says when an unlock key is wrong, in words.
            if raw.localizedCaseInsensitiveContains("decryption operation failed") { raw = "Invalid master password" }
            var out = statusReport()
            out["ok"] = false
            out["error"] = Self.sanitize(raw, hiding: secrets)
            return out
        }
    }

    // MARK: - login

    private func controlLogin(_ p: [String: Any]) async throws {
        func text(_ key: String) -> String? {
            guard let value = (p[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        // The master password is taken as typed: leading or trailing spaces
        // can be part of it.
        let password = p["password"] as? String ?? ""
        let email = text("email")
        let clientId = text("clientId")
        let clientSecret = text("clientSecret")
        let otp = text("otp")
        let method = (p["otpMethod"] as? NSNumber)?.intValue ?? 0

        // Everything is checked before anything runs, so a bad payload never
        // leaves the CLI half signed in.
        guard (clientId == nil) == (clientSecret == nil) else {
            throw Failure(message: "Bitwarden API key needs both clientId and clientSecret")
        }
        let apiKey = clientId != nil
        guard !password.isEmpty else { throw Failure(message: "Bitwarden master password is required to unlock the vault") }
        if !apiKey, email == nil { throw Failure(message: "Bitwarden email is required") }
        guard [0, 1, 3].contains(method) else {
            throw Failure(message: "otpMethod must be 0 (authenticator), 1 (email) or 3 (YubiKey)")
        }
        let server = try text("server").map(Self.validServer)
        try validatePolicy(p)
        guard Self.installed else { throw Failure(message: "Bitwarden CLI is not installed") }

        await refreshStatus()

        // Already signed in: keep the account when it is the same one on the
        // same server, otherwise sign out first — `bw login` refuses while
        // signed in, and `bw config server` refuses too.
        var current: String?
        var authenticated = false
        switch state {
        case .locked(let who), .unlocked(let who, _):
            authenticated = true
            current = who
        case .missing, .unauthenticated:
            break
        }
        if authenticated {
            let sameAccount = email != nil && current?.lowercased() == email?.lowercased()
            let sameServer = server == nil || Self.same(server!, cliServer ?? Self.defaultServer)
            if !(sameAccount && sameServer) {
                await logout()
                await refreshStatus()
            }
        }

        if case .unauthenticated = state {
            // The CLI with no server configured talks to bitwarden.com; say
            // so explicitly, so the report names the server it uses.
            let target = server ?? (cliServer == nil ? Self.defaultServer : nil)
            if let target, cliServer.map({ !Self.same($0, target) }) ?? true {
                try await configure(server: target)
            }
            if let clientId, let clientSecret {
                try await loginWithAPIKey(clientId: clientId, clientSecret: clientSecret)
            } else if let email {
                try await login(email: email, password: password, otp: otp, method: method)
            }
        }

        if case .locked = state {
            try await unlock(password: password)
        }
        guard case .unlocked = state else {
            switch state {
            case .unauthenticated: throw Failure(message: "Bitwarden did not sign in")
            default: throw Failure(message: "Bitwarden did not unlock")
            }
        }
        try applyPolicy(p)
    }

    // MARK: - policy

    private func validatePolicy(_ p: [String: Any]) throws {
        if let share = p["share"], !(share is NSNull) {
            guard let value = share as? String, ["folder", "all"].contains(value) else {
                throw Failure(message: "share must be folder or all")
            }
        }
        if let stay = p["stayUnlocked"], !(stay is NSNull) {
            guard Self.flag(stay) != nil else { throw Failure(message: "stayUnlocked must be true or false") }
        }
    }

    /// `share`: 'folder' (only the Agents folder / `copper-agent: allow`) or
    /// 'all'; `stayUnlocked`: keep the 0600 session file across launches.
    private func applyPolicy(_ p: [String: Any]) throws {
        try validatePolicy(p)
        if let share = p["share"] as? String { AgentAccess.shareAll = share == "all" }
        if let stay = p["stayUnlocked"].flatMap(Self.flag) { stayUnlocked = stay }
    }

    private static func flag(_ any: Any) -> Bool? {
        if let bool = any as? Bool { return bool }
        if let string = any as? String {
            switch string.lowercased() {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    // MARK: - small helpers

    /// https anywhere; http only to this Mac (a local Vaultwarden).
    static func validServer(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil
        else { throw Failure(message: "Bitwarden server must be an https URL") }
        if scheme == "https" { return text }
        if scheme == "http", ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) { return text }
        throw Failure(message: "Bitwarden server must be an https URL (http only for this Mac)")
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        return norm(a) == norm(b)
    }

    /// One line, at most 200 characters, with anything the caller sent as a
    /// secret cut out — whatever `bw` chose to print.
    static func sanitize(_ message: String, hiding secrets: [String]) -> String {
        var text = message
        for secret in secrets.sorted(by: { $0.count > $1.count }) where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "…")
        }
        let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let clean = String(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        let out = clean.isEmpty ? "Bitwarden command failed" : clean
        return out.count > 200 ? String(out.prefix(199)) + "…" : out
    }
}
