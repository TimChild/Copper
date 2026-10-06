import Foundation

/// The process boundary around the official 1Password CLI (`op`): where it is,
/// how a child is started, and what its error lines mean. Nothing in here
/// holds a secret; the caller hands the child its session or service-account
/// token through the environment and its password through stdin — never as
/// an argument, so neither shows up in `ps`.
enum OnePasswordCLI {
    /// What went wrong, in the terms the card and the picker speak.
    enum Problem: String, Equatable {
        case notInstalled
        case notSignedIn
        case sessionExpired
        case integrationOff
        case unknownAccount
        case network
        case dismissed
        case wrongPassword
        case badToken
        case timeout
        case passkey
        case other
    }

    struct Failure: LocalizedError, Equatable {
        let problem: Problem
        let message: String
        var errorDescription: String? { message }

        init(_ problem: Problem, _ message: String) {
            self.problem = problem
            self.message = message
        }
    }

    struct Execution {
        let stdout: Data
        let stderr: Data
        let status: Int32
    }

    // MARK: - Discovery

    /// Where `op` is, first match wins: `SEARCH_OP_PATH` (a test world points
    /// it at the mock, an installer at the CLI it put down), `~/.local/bin/op`,
    /// Homebrew's two prefixes, then `$PATH`.
    /// Where `op` is. Asked often (every card draw), so the answer is kept:
    /// a found path until it disappears, a miss for five seconds — long enough
    /// not to walk the disk per frame, short enough that a fresh
    /// `brew install 1password-cli` shows up without a relaunch.
    /// `SEARCH_OP_PATH=none` is a Mac without the CLI, for a test world.
    static var executableURL: URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let files = FileManager.default
        if let found = cachedExecutable {
            if let url = found, files.isExecutableFile(atPath: url.path) { return url }
            if found == nil, Date().timeIntervalSince(cachedAt) < 5 { return nil }
        }
        let url = locateExecutable()
        cachedExecutable = .some(url)
        cachedAt = Date()
        return url
    }

    private static let cacheLock = NSLock()
    private static var cachedExecutable: URL??
    private static var cachedAt = Date.distantPast

    private static func locateExecutable() -> URL? {
        let files = FileManager.default
        if let raw = ProcessInfo.processInfo.environment["SEARCH_OP_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if raw == "none" { return nil }
            let path = (raw as NSString).expandingTildeInPath
            if files.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let local = files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/op").path
        for path in [local, "/opt/homebrew/bin/op", "/usr/local/bin/op"] where files.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Last, the PATH a GUI app was given, walked here rather than by
        // forking `which`: this is asked from the main thread (at launch, by
        // the card), and a stat per directory costs nothing.
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = (String(directory) as NSString).appendingPathComponent("op")
            if files.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// The 1Password desktop app, whose own Touch ID prompt approves the CLI
    /// when "Integrate with 1Password CLI" is on. `SEARCH_OP_APP_PATH` stands
    /// in for it in a test world (`none` = no app).
    static var appURL: URL? {
        let files = FileManager.default
        if let raw = ProcessInfo.processInfo.environment["SEARCH_OP_APP_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if raw == "none" { return nil }
            let path = (raw as NSString).expandingTildeInPath
            return files.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = files.homeDirectoryForCurrentUser.appendingPathComponent("Applications/1Password.app").path
        for path in ["/Applications/1Password.app", home, "/Applications/1Password 7.app"] where files.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Environment

    /// The child's environment: Copper's own, minus every `OP_*` credential a
    /// shell might have left there, plus exactly what this call needs.
    static func environment(adding extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("OP_SESSION") {
            environment.removeValue(forKey: key)
        }
        for key in ["OP_SERVICE_ACCOUNT_TOKEN", "OP_ACCOUNT", "OP_SECRET_KEY", "OP_FORMAT",
                    "OP_CONNECT_HOST", "OP_CONNECT_TOKEN", "OP_CONFIG_DIR", "OP_DEBUG",
                    "OP_INCLUDE_ARCHIVE", "OP_BIOMETRIC_UNLOCK_ENABLED"] {
            environment.removeValue(forKey: key)
        }
        if let config = ProcessInfo.processInfo.environment["SEARCH_OP_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !config.isEmpty {
            environment["OP_CONFIG_DIR"] = (config as NSString).expandingTildeInPath
        }
        environment["OP_FORMAT"] = "json"
        environment["NO_COLOR"] = "1"
        extra.forEach { environment[$0.key] = $0.value }
        return environment
    }

    /// The name `op` gives a session token's variable: the user's id,
    /// upper-cased and stripped to what a shell variable may hold.
    static func sessionVariable(for userID: String) -> String {
        let cleaned = userID.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return "OP_SESSION_\(cleaned)"
    }

    // MARK: - Running one

    /// Start `op`, write `stdin` (and close it, so a prompt never waits on a
    /// terminal), and wait for it — or kill it after `timeout`. Nothing here
    /// can hang: stdin is fed off this thread (a big batch can't deadlock
    /// against a full stdout), a child that shrugs off SIGTERM gets SIGKILL,
    /// and a grandchild still holding the pipes (op's own helper) is not
    /// waited for past a short grace.
    static func execute(path: String, args: [String], environment: [String: String],
                        stdin: Data?, timeout: TimeInterval) throws -> Execution {
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
        // A child that exits before reading its stdin must not take Copper
        // down with SIGPIPE on the write below.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()

        let group = DispatchGroup()
        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()
        let feed = stdin ?? Data()
        DispatchQueue.global(qos: .utility).async {
            if !feed.isEmpty { try? input.fileHandleForWriting.write(contentsOf: feed) }
            try? input.fileHandleForWriting.close()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); stdout = data; lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); stderr = data; lock.unlock()
            group.leave()
        }
        var timedOut = false
        let pid = process.processIdentifier
        let killer = DispatchWorkItem {
            lock.lock()
            let running = process.isRunning
            if running { timedOut = true }
            lock.unlock()
            guard running else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        // The pipes close when op does; a helper op left running may still
        // hold them, and its output is not ours to wait for.
        _ = group.wait(timeout: .now() + 3)
        lock.lock()
        let didTimeOut = timedOut
        let out = stdout
        let err = stderr
        lock.unlock()
        if didTimeOut { throw Failure(.timeout, "1Password took too long to answer") }
        return Execution(stdout: out, stderr: err, status: process.terminationStatus)
    }

    // MARK: - Reading its errors

    /// The line meant for people out of `op`'s stderr, with the
    /// `[ERROR] 2026/10/06 11:39:59 ` stamp taken off.
    static func message(from stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self)
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Using configuration at") }
        let line = lines.last(where: { $0.contains("[ERROR]") }) ?? lines.last ?? ""
        return strip(line)
    }

    static func strip(_ line: String) -> String {
        var value = line
        if let range = value.range(of: "[ERROR]") {
            value = String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            // "2026/10/06 11:39:59 message"
            let parts = value.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count == 3, parts[0].contains("/"), parts[1].contains(":") {
                value = String(parts[2])
            }
        }
        return String(value.prefix(240))
    }

    /// What kind of trouble a line of `op` output is. Matched on the phrases
    /// op 2.x prints; anything unknown is `.other` and shown as it came.
    static func classify(_ raw: String, appPath: Bool = false) -> Problem {
        let text = raw.lowercased()
        let integration = ["integrate with 1password cli", "connecting to desktop app", "app integration",
                           "cannot connect to 1password app", "1password app is not running", "desktop app"]
        if integration.contains(where: { text.contains($0) }) { return .integrationOff }
        if appPath && (text.contains("enter the password for") || text.contains("no accounts configured")
                       || text.contains("operation not supported by device")) {
            return .integrationOff
        }
        if text.contains("dismissed") || text.contains("authorization denied") || text.contains("authorization timeout") {
            return .dismissed
        }
        if text.contains("session expired") || text.contains("invalid session") || text.contains("session token") {
            return .sessionExpired
        }
        if text.contains("decodesacredentials") || text.contains("service account token")
            || text.contains("invalid token") || text.contains("token is invalid") {
            return .badToken
        }
        if text.contains("no account found") || text.contains("found no account") || text.contains("isn't known")
            || text.contains("no accounts configured") {
            return .unknownAccount
        }
        if text.contains("not currently signed in") || text.contains("not signed in")
            || text.contains("no active session") || text.contains("authentication required") {
            return .notSignedIn
        }
        if text.contains("couldn't sign in") || text.contains("unauthorized") || text.contains("incorrect")
            || text.contains("check your sign-in details") || text.contains("wrong password") {
            return .wrongPassword
        }
        let network = ["dial tcp", "no such host", "network", "connection refused", "i/o timeout",
                       "couldn't connect", "could not connect", "tls handshake", "offline"]
        if network.contains(where: { text.contains($0) }) { return .network }
        if text.contains("operation not supported by device") || text.contains("enter the password for") {
            return .notSignedIn
        }
        return .other
    }

    /// The sentence the card shows for a problem.
    static func explain(_ problem: Problem, raw: String) -> String {
        switch problem {
        case .notInstalled: return "The 1Password CLI is not installed"
        case .notSignedIn: return "Not signed in to 1Password"
        case .sessionExpired: return "The 1Password session ended — unlock again"
        case .integrationOff:
            return "The 1Password app didn't answer — turn on Settings › Developer › Integrate with 1Password CLI"
        case .unknownAccount: return "1Password doesn't know that account on this Mac"
        case .network: return "Couldn't reach 1Password — check the connection"
        case .dismissed: return "The 1Password approval was dismissed"
        case .wrongPassword: return "1Password didn't accept those sign-in details"
        case .badToken: return "That service account token wasn't accepted"
        case .timeout: return "1Password took too long to answer"
        case .passkey: return raw
        case .other: return raw.isEmpty ? "1Password command failed" : raw
        }
    }

    // MARK: - JSON

    /// `op item get -` writes one JSON object per item, back to back, rather
    /// than an array. Accept either, and split the stream by depth.
    static func objects(in data: Data) -> [[String: Any]] {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return array }
        if let one = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return [one] }
        var result: [[String: Any]] = []
        let bytes = [UInt8](data)
        var depth = 0
        var start: Int?
        var inString = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B:
                if depth == 0 { start = index }
                depth += 1
            case 0x7D:
                // A stray brace in broken output must not push the depth
                // below zero and hide every object after it.
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let from = start {
                    let slice = Data(bytes[from...index])
                    if let object = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
                        result.append(object)
                    }
                    start = nil
                }
            default: break
            }
        }
        return result
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// A sign-in address as `op account add --address` takes it.
    static func address(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) { value.removeFirst(scheme.count) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
