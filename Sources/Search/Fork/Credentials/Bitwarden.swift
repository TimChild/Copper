import Combine
import Foundation

/// A small, in-process boundary around the official Bitwarden CLI. Metadata is
/// retained only in memory; passwords, TOTP seeds, and the BW session key are
/// fetched or held only for the operation that needs them.
@MainActor
final class Bitwarden: ObservableObject {
    static let shared = Bitwarden()

    enum State: Equatable {
        case missing
        case unauthenticated
        case locked(email: String?)
        case unlocked(email: String?, lastSync: Date?)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct URI: Hashable {
        let uri: String
        let match: Int?
    }

    struct Field: Hashable {
        let name: String
        let value: String
    }

    /// A deliberately stripped login item. In particular, there is no
    /// password, TOTP seed, notes, or hidden/custom-field secret here.
    struct Item: Hashable {
        let id: String
        let name: String
        let folderId: String?
        let username: String
        let uris: [URI]
        let hasTOTP: Bool
        let fields: [Field]
    }

    struct Folder: Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var state: State
    private(set) var cachedItems: [Item] = []
    private(set) var cachedFolders: [Folder] = []

    private var sessionKey: String?
    private var lastActivity = Date()
    private var lastCacheRefresh = Date.distantPast
    private var cacheRefreshInFlight = false
    private var idleTimer: Timer?
    private var cacheTimer: Timer?

    private static let serverKey = "bitwarden.server"
    private static let defaultServer = "https://vault.bitwarden.com"

    private init() {
        state = Self.installed ? .unauthenticated : .missing
        // What `bw` knows from last time — signed in, locked — so the picker
        // can say "Unlock Bitwarden…" from the first sign-in box, not only
        // after Settings has been opened.
        if Self.installed { Task { await self.refreshStatus() } }
    }

    // MARK: - Discovery and process boundary

    static var installed: Bool { executableURL != nil }

    private static var executableURL: URL? {
        let files = FileManager.default
        for path in ["/opt/homebrew/bin/bw", "/usr/local/bin/bw"]
        where files.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["bw"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, files.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var appDataURL: URL {
        let suffix = Store.world.map { " (\($0))" } ?? ""
        return Store.folder.appendingPathComponent("bitwarden\(suffix)", isDirectory: true)
    }

    /// Run a CLI command away from the main actor. `extra` is used for the
    /// password environment during login/unlock; secrets are never arguments.
    private func run(_ args: [String], env extra: [String: String] = [:], stdin: Data? = nil,
                     timeout: TimeInterval = 10) async throws -> Data {
        guard let executable = Self.executableURL else {
            throw Failure(message: "Bitwarden CLI is not installed")
        }

        var environment = ProcessInfo.processInfo.environment
        // Do not inherit either secret from a shell or another process. The
        // session is supplied only when Copper itself currently holds it, and
        // the password is supplied only by login/unlock below.
        environment.removeValue(forKey: "BW_SESSION")
        environment.removeValue(forKey: "BW_PASSWORD")
        environment["BITWARDENCLI_APPDATA_DIR"] = appDataURL.path
        environment["BW_NOINTERACTION"] = "true"
        if let sessionKey { environment["BW_SESSION"] = sessionKey }
        extra.forEach { environment[$0.key] = $0.value }
        let executablePath = executable.path
        let appDataPath = appDataURL.path
        let input = stdin

        if sessionKey != nil && args.first != "status" {
            lastActivity = Date()
        }

        let result = try await Task.detached(priority: nil) {
            try Self.execute(path: executablePath, args: args, environment: environment,
                             appDataPath: appDataPath, stdin: input, timeout: timeout)
        }.value

        guard result.status == 0 else {
            let text = String(data: result.stderr, encoding: .utf8) ?? ""
            let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: line?.isEmpty == false ? line! : "Bitwarden command failed")
        }
        return result.stdout
    }

    private struct Execution {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    private nonisolated static func execute(path: String, args: [String], environment: [String: String],
                                            appDataPath: String, stdin: Data?, timeout: TimeInterval) throws -> Execution {
        let files = FileManager.default
        try files.createDirectory(atPath: appDataPath, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDataPath)

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input

        try process.run()
        if let stdin {
            try input.fileHandleForWriting.write(contentsOf: stdin)
        }
        try? input.fileHandleForWriting.close()

        let group = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let lock = NSLock()
        var timedOut = false
        let killer = DispatchWorkItem {
            lock.lock()
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            lock.unlock()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()

        lock.lock()
        let didTimeOut = timedOut
        lock.unlock()
        if didTimeOut {
            throw Failure(message: "Bitwarden command timed out")
        }
        return Execution(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    // MARK: - Status and account lifecycle

    private struct RawStatus: Decodable {
        let status: String
        let userEmail: String?
        let lastSync: String?
        let serverUrl: String?
    }

    var serverURL: String {
        get { Store.settings.string(forKey: Self.serverKey) ?? Self.defaultServer }
        set { Store.settings.set(newValue, forKey: Self.serverKey) }
    }

    func refreshStatus() async {
        guard Self.installed else {
            state = .missing
            return
        }
        do {
            let data = try await run(["status"])
            let status = try JSONDecoder().decode(RawStatus.self, from: data)
            if let server = status.serverUrl, !server.isEmpty {
                Store.settings.set(server, forKey: Self.serverKey)
            }
            switch status.status.lowercased() {
            case "unlocked":
                // A relaunch must not claim an unlocked Copper session merely
                // because the CLI's status file says unlocked: our key is only
                // ever the private property above.
                if sessionKey != nil {
                    state = .unlocked(email: status.userEmail, lastSync: Self.date(status.lastSync))
                    startTimer()
                } else {
                    state = .locked(email: status.userEmail)
                }
            case "locked":
                sessionKey = nil
                cachedItems = []
                cachedFolders = []
                stopTimer()
                state = .locked(email: status.userEmail)
            default:
                sessionKey = nil
                cachedItems = []
                cachedFolders = []
                stopTimer()
                state = .unauthenticated
            }
        } catch {
            if sessionKey == nil, case .missing = state { return }
            if sessionKey == nil { state = .unauthenticated }
        }
    }

    func configure(server: String) async throws {
        let value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Failure(message: "Bitwarden server URL is empty") }
        _ = try await run(["config", "server", value])
        serverURL = value
    }

    func login(email: String, password: String, otp: String? = nil) async throws {
        guard !email.isEmpty, !password.isEmpty else {
            throw Failure(message: "Bitwarden email and password are required")
        }
        var args = ["login", email, "--passwordenv", "BW_PASSWORD"]
        if let otp, !otp.isEmpty { args += ["--method", "0", "--code", otp] }
        args.append("--raw")
        let data = try await run(args, env: ["BW_PASSWORD": password], timeout: 30)
        let key = Self.session(from: data)
        guard !key.isEmpty else { throw Failure(message: "Bitwarden did not return a session") }
        sessionKey = key
        await refreshStatus()
        await refreshCacheIfPossible()
    }

    func unlock(password: String) async throws {
        guard !password.isEmpty else { throw Failure(message: "Bitwarden master password is required") }
        let data = try await run(["unlock", "--passwordenv", "BW_PASSWORD", "--raw"],
                                 env: ["BW_PASSWORD": password], timeout: 30)
        let key = Self.session(from: data)
        guard !key.isEmpty else { throw Failure(message: "Bitwarden did not return a session") }
        sessionKey = key
        await refreshStatus()
        await refreshCacheIfPossible()
    }

    func lock() async {
        let missing: Bool
        if case .missing = state { missing = true } else { missing = false }
        _ = try? await run(["lock"])
        sessionKey = nil
        cachedItems = []
        cachedFolders = []
        let email = Self.email(from: state)
        state = missing ? .missing : .locked(email: email)
        stopTimer()
    }

    func logout() async {
        let missing: Bool
        if case .missing = state { missing = true } else { missing = false }
        _ = try? await run(["logout"])
        sessionKey = nil
        cachedItems = []
        cachedFolders = []
        state = missing ? .missing : .unauthenticated
        stopTimer()
    }

    func sync() async throws {
        try await requireUnlocked()
        _ = try await run(["sync"], timeout: 30)
        await refreshStatus()
        try await refreshCache()
    }

    // MARK: - Stripped metadata and secret fetches

    private struct RawURI: Decodable {
        let uri: String?
        let match: Int?
    }

    private struct RawLogin: Decodable {
        let username: String?
        let totp: String?
        let uris: [RawURI]?
    }

    private struct RawField: Decodable {
        let name: String?
        let value: String?
        let type: Int?
    }

    private struct RawItem: Decodable {
        let id: String?
        let type: Int?
        let name: String?
        let folderId: String?
        let login: RawLogin?
        let fields: [RawField]?
    }

    func items() async throws -> [Item] {
        try await requireUnlocked()
        let data = try await run(["list", "items"])
        let rows = try JSONDecoder().decode([RawItem].self, from: data)
        let result = rows.compactMap { row -> Item? in
            guard row.type == 1, let id = row.id, !id.isEmpty else { return nil }
            let uris = (row.login?.uris ?? []).compactMap { raw -> URI? in
                guard let uri = raw.uri, !uri.isEmpty else { return nil }
                return URI(uri: uri, match: raw.match)
            }
            let fields = (row.fields ?? []).compactMap { raw -> Field? in
                guard raw.type == 0, let name = raw.name, let value = raw.value else { return nil }
                return Field(name: name, value: value)
            }
            return Item(id: id, name: row.name ?? "", folderId: row.folderId,
                        username: row.login?.username ?? "", uris: uris,
                        hasTOTP: !(row.login?.totp?.isEmpty ?? true), fields: fields)
        }
        cachedItems = result
        return result
    }

    private struct RawFolder: Decodable {
        let id: String?
        let name: String?
    }

    func folders() async throws -> [Folder] {
        try await requireUnlocked()
        let data = try await run(["list", "folders"])
        let rows = try JSONDecoder().decode([RawFolder].self, from: data)
        let result = rows.compactMap { row -> Folder? in
            guard let id = row.id, !id.isEmpty else { return nil }
            return Folder(id: id, name: row.name ?? "")
        }
        cachedFolders = result
        return result
    }

    func password(for id: String) async throws -> String {
        try await requireUnlocked()
        let data = try await run(["get", "password", id])
        return Self.trimTrailingNewlines(String(decoding: data, as: UTF8.self))
    }

    func totp(for id: String) async throws -> String {
        try await requireUnlocked()
        let data = try await run(["get", "totp", id])
        return Self.trimTrailingNewlines(String(decoding: data, as: UTF8.self))
    }

    func create(host: String, user: String, password: String) async throws -> String {
        try await requireUnlocked()
        let templateData = try await run(["get", "template", "item"])
        guard var object = try JSONSerialization.jsonObject(with: templateData) as? [String: Any]
        else { throw Failure(message: "Bitwarden returned an invalid item template") }
        object["type"] = 1
        object["name"] = host
        object["login"] = [
            "username": user,
            "password": password,
            "totp": NSNull(),
            "uris": [["uri": "https://\(host)", "match": NSNull()]],
        ]
        let itemJSON = try JSONSerialization.data(withJSONObject: object, options: [])
        let encoded = try await run(["encode"], stdin: itemJSON)
        let value = Self.trimTrailingNewlines(String(decoding: encoded, as: UTF8.self))
        guard !value.isEmpty else { throw Failure(message: "Bitwarden did not encode the item") }
        let created = try await run(["create", "item", value])
        guard let object = try JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty
        else { throw Failure(message: "Bitwarden did not return the new item id") }
        await refreshCacheIfPossible()
        return id
    }

    func generate() async throws -> String {
        let data = try await run(["generate", "-ulns", "--length", "20"])
        return Self.trimTrailingNewlines(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Cache and timers

    private func requireUnlocked() async throws {
        guard sessionKey != nil else { throw Failure(message: "Bitwarden is locked") }
        guard case .unlocked = state else { throw Failure(message: "Bitwarden is locked") }
    }

    private func refreshCache() async throws {
        guard !cacheRefreshInFlight else { return }
        cacheRefreshInFlight = true
        defer { cacheRefreshInFlight = false }
        _ = try await items()
        _ = try await folders()
        lastCacheRefresh = Date()
    }

    private func refreshCacheIfPossible() async {
        guard sessionKey != nil else { return }
        do {
            try await refreshCache()
        } catch {
            // A successful login/unlock remains useful even if a networked
            // metadata refresh is temporarily unavailable.
        }
    }

    private func startTimer() {
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        idleTimer?.tolerance = 10
        cacheTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sessionKey != nil else { return }
                Task { await self.refreshCacheIfPossible() }
            }
        }
        cacheTimer?.tolerance = 30
    }

    private func stopTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        cacheTimer?.invalidate()
        cacheTimer = nil
    }

    private func checkIdle() {
        guard sessionKey != nil else { stopTimer(); return }
        let minutes: TimeInterval
        if let value = Store.settings.object(forKey: "bitwarden.autolockMinutes") as? NSNumber {
            minutes = max(0, value.doubleValue)
        } else {
            // Never, unless asked: the vault is as open as the keychain is
            // while the Mac is unlocked, and asking for the master password
            // every quarter hour is what makes people turn a feature off.
            minutes = 0
        }
        guard minutes > 0, Date().timeIntervalSince(lastActivity) >= minutes * 60 else { return }
        Task { await lock() }
    }

    // MARK: - Small decoding helpers

    private static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func session(from data: Data) -> String {
        trimTrailingNewlines(String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func trimTrailingNewlines(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.newlines)
    }

    private static func email(from state: State) -> String? {
        switch state {
        case .locked(let email), .unlocked(let email, _): return email
        case .missing, .unauthenticated: return nil
        }
    }
}
