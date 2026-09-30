import Foundation

// Signing in to Bitwarden the way `bw login` itself does it: interactively.
//
// `bw login <email>` with no two-step code is a conversation. The CLI tries
// the password; if the account has two-step login it picks the method (or
// lists them when there are several), sends the email when the method is
// email, and asks on stderr — "Two-step login code:" — reading the answer
// from stdin. An account without two-step login gets "New device
// verification required. Enter OTP sent to login email:" the first time a
// Mac signs in, the same way. With BW_NOINTERACTION the CLI cannot ask, so
// it fails with "Code is required." and the email code, which only exists
// once the password was tried, has nowhere to go. That is what broke email
// two-step and new-device sign-ins here.
//
// So the sign-in runs `bw` with its prompts on: stdin, stdout and stderr are
// pipes, stderr is watched for the prompt it asks with, and the answer is
// written to stdin when the user has it — seconds or minutes later, from
// Settings, `copper bitwarden login`, or a linked app. Only `login` goes
// this way; every other command keeps BW_NOINTERACTION.
//
// Verified against bw 2026.9.0: the prompts render over a pipe (inquirer
// writes to stderr, re-drawing the line as the answer is echoed), a line on
// stdin answers them, and `--raw` leaves the session key alone on stdout.

extension Bitwarden {
    /// A two-step method the CLI can take a code for. `id` is `bw --method`.
    struct TwoStepMethod: Equatable, Identifiable {
        let id: Int
        let name: String

        static let authenticator = TwoStepMethod(id: 0, name: "Authenticator app")
        static let email = TwoStepMethod(id: 1, name: "Email")
        static let yubikey = TwoStepMethod(id: 3, name: "YubiKey")
        static let all = [authenticator, email, yubikey]

        static func named(_ id: Int) -> TwoStepMethod? { all.first { $0.id == id } }

        /// The CLI's own name for a method, from its list prompt.
        static func fromCLI(_ line: String) -> TwoStepMethod? {
            let l = line.lowercased()
            if l.contains("authenticator") { return authenticator }
            if l == "email" || l.hasPrefix("email") { return email }
            if l.contains("yubi") { return yubikey }
            return nil
        }
    }

    /// What `bw` is waiting for.
    enum CodePrompt: Equatable {
        /// A two-step login code. `method` is the one asked for with
        /// `--method`, or nil when the account has one method and the CLI
        /// picked it itself (an email was sent if that method is email).
        case twoStep(method: Int?)
        /// New-device verification: the server emailed a code to the
        /// account's address because this Mac has not signed in before.
        case newDevice
    }

    /// What a sign-in attempt came back with, when it is not a session yet.
    enum LoginStep: Equatable {
        /// Several two-step methods on the account; the CLI listed them.
        /// Pick one and sign in again with it.
        case chooseMethod([TwoStepMethod])
        /// A code is needed and `bw` is holding the sign-in open for it.
        /// `submit(code:)` finishes; `cancelPendingLogin()` lets go.
        case needsCode(CodePrompt)
    }

    enum LoginOutcome: Equatable {
        case signedIn
        case step(LoginStep)
    }

    /// The sign-in `bw` is holding open for a code, for the UI to describe.
    struct PendingLogin: Equatable {
        let email: String
        let prompt: CodePrompt
        let method: Int?
        let started: Date
    }

    /// How long a sign-in waits for its code before `bw` is let go.
    static let pendingLoginLifetime: TimeInterval = 10 * 60

    // MARK: - the conversation

    /// One `bw login` with its prompts on. Not main-actor: the readers block.
    final class Interactive: @unchecked Sendable {
        enum Prompt: Equatable {
            case methods([String])
            case code
            case newDevice
        }

        enum Event {
            case prompt(Prompt)
            case exited(status: Int32, stdout: String, stderr: String)
        }

        struct TimedOut: Error {}

        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let errors = Pipe()
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        /// Where the next prompt scan starts: after the last prompt answered.
        private var scanFrom = 0
        /// The prompt reported and not yet answered, if any — its re-renders
        /// as the answer is echoed must not read as a new prompt.
        private var open: Prompt?
        /// The last prompt answered; the same one again is an echo, not news.
        private var answered: Prompt?
        private var waiter: CheckedContinuation<Event, Error>?
        private var deadline: DispatchWorkItem?
        private let readers = DispatchGroup()
        private var finished = false
        private var started = false
        private let queue = DispatchQueue(label: "copper.bitwarden.login")
        /// Called when `bw` ends while nobody is waiting on it — a held
        /// sign-in that died on its own — so the holder can let it go.
        var onLostWhileWaiting: (() -> Void)?

        init(executable: URL, arguments: [String], environment: [String: String]) {
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
        }

        /// Starts `bw` and answers with the first thing that happens: a
        /// prompt, or the exit.
        func start(timeout: TimeInterval) async throws -> Event {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Event, Error>) in
                queue.async {
                    guard !self.started else {
                        continuation.resume(throwing: Failure(message: "Bitwarden sign-in already started"))
                        return
                    }
                    self.started = true
                    self.waiter = continuation
                    // Both readers are counted before the process can end, so
                    // an exit is only reported once every byte has been read.
                    self.readers.enter()
                    self.readers.enter()
                    self.process.terminationHandler = { [weak self] process in
                        guard let self else { return }
                        // The pipes close with the process; the readers reach
                        // their end. Both, before the exit is reported, so the
                        // caller sees every byte.
                        self.readers.notify(queue: self.queue) {
                            self.finished = true
                            let lost = self.waiter == nil
                            self.settle(.exited(status: process.terminationStatus,
                                                stdout: String(decoding: self.stdout, as: UTF8.self),
                                                stderr: Interactive.plain(self.stderr)))
                            if lost { self.onLostWhileWaiting?() }
                        }
                    }
                    do {
                        try self.process.run()
                    } catch {
                        self.waiter = nil
                        self.readers.leave()
                        self.readers.leave()
                        continuation.resume(throwing: Failure(message: "Couldn't start the Bitwarden CLI: \(error.localizedDescription)"))
                        return
                    }
                    self.arm(timeout)
                    self.read(self.output.fileHandleForReading) { chunk in self.stdout.append(chunk) }
                    self.read(self.errors.fileHandleForReading) { chunk in
                        self.stderr.append(chunk)
                        self.scan()
                    }
                }
            }
        }

        /// Answers the open prompt with a line and waits for what follows.
        func answer(_ line: String, timeout: TimeInterval) async throws -> Event {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Event, Error>) in
                queue.async {
                    guard self.started, !self.finished, self.process.isRunning else {
                        continuation.resume(throwing: Failure(message: "The Bitwarden sign-in is no longer waiting — sign in again"))
                        return
                    }
                    guard self.waiter == nil else {
                        continuation.resume(throwing: Failure(message: "Bitwarden sign-in is already waiting"))
                        return
                    }
                    self.lock.lock()
                    self.answered = self.open
                    self.open = nil
                    self.scanFrom = self.stderr.count
                    self.lock.unlock()
                    self.waiter = continuation
                    self.arm(timeout)
                    do {
                        try self.input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
                    } catch {
                        self.settle(.exited(status: -1, stdout: "", stderr: "Couldn't hand the code to the Bitwarden CLI"))
                    }
                }
            }
        }

        /// Ends the conversation. Whatever was waiting hears an exit.
        func terminate() {
            queue.async {
                if self.process.isRunning { self.process.terminate() }
                try? self.input.fileHandleForWriting.close()
            }
        }

        var isRunning: Bool { process.isRunning }

        // MARK: readers

        /// Drains a pipe to its end on a background thread; `readers` was
        /// entered for it in `start`.
        private func read(_ handle: FileHandle, _ sink: @escaping (Data) -> Void) {
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    self.lock.lock()
                    sink(chunk)
                    self.lock.unlock()
                }
                try? handle.close()
                self.readers.leave()
            }
        }

        /// Under `lock`: a prompt in what came since the last answer.
        private func scan() {
            guard open == nil, scanFrom <= stderr.count else { return }
            let text = Interactive.plain(stderr[stderr.startIndex.advanced(by: scanFrom)...])
            let found: Prompt?
            if text.contains("New device verification required") {
                found = .newDevice
            } else if text.contains("Two-step login code:") {
                found = .code
            } else if text.contains("Two-step login method:") {
                // The list ends with Cancel; until it has rendered, wait.
                guard text.contains("Cancel") else { return }
                let lines = text.components(separatedBy: "\n")
                guard let head = lines.firstIndex(where: { $0.contains("Two-step login method:") }) else { return }
                var names: [String] = []
                for raw in lines[(head + 1)...] {
                    let line = raw.replacingOccurrences(of: "❯", with: "").replacingOccurrences(of: ">", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if line.isEmpty { continue }
                    if line.contains("──") || line == "Cancel" { break }
                    names.append(line)
                }
                found = .methods(names)
            } else {
                found = nil
            }
            guard let found else { return }
            // The same prompt again right after its answer is the echo.
            if let answered, answered == found, case .code = found { return }
            if let answered, answered == found, case .newDevice = found { return }
            open = found
            queue.async { self.settle(.prompt(found)) }
        }

        // MARK: the waiter

        private func arm(_ timeout: TimeInterval) {
            deadline?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let waiter = self.waiter else { return }
                self.waiter = nil
                if self.process.isRunning { self.process.terminate() }
                waiter.resume(throwing: TimedOut())
            }
            deadline = item
            queue.asyncAfter(deadline: .now() + timeout, execute: item)
        }

        /// On `queue`.
        private func settle(_ event: Event) {
            deadline?.cancel()
            deadline = nil
            guard let waiter else { return }
            self.waiter = nil
            waiter.resume(returning: event)
        }

        /// Text without the terminal's escape sequences or carriage returns.
        static func plain(_ data: Data) -> String {
            let raw = String(decoding: data, as: UTF8.self)
            var out = ""
            out.reserveCapacity(raw.count)
            var iterator = raw.makeIterator()
            while let ch = iterator.next() {
                if ch == "\u{1B}" {
                    // CSI: ESC [ … final byte in @…~ ; OSC and the rest: ESC + one char.
                    guard let next = iterator.next() else { break }
                    if next == "[" {
                        while let c = iterator.next(), !(c.asciiValue.map { $0 >= 0x40 && $0 <= 0x7E } ?? false) {}
                    }
                    continue
                }
                if ch == "\r" { continue }
                out.append(ch)
            }
            return out
        }

        /// The sentence `bw` ended on, for a person: not a prompt echo, not a
        /// list row, not an SDK log line.
        static func errorLine(_ stderr: String) -> String? {
            let lines = stderr.split(whereSeparator: { $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
            for line in lines.reversed() {
                if line.isEmpty { continue }
                if line.hasPrefix("?") || line.hasPrefix("❯") || line == "Cancel" || line.contains("──") { continue }
                if line.hasPrefix("(Use arrow keys)") { continue }
                if let space = line.firstIndex(of: " "),
                   ["ERROR", "WARN", "INFO", "DEBUG", "TRACE"].contains(String(line[..<space])), line.contains("::") { continue }
                return line
            }
            return nil
        }
    }
}

// MARK: - Bitwarden: the sign-in

extension Bitwarden {
    /// Where the CLI's data lives for the interactive run — the same folder
    /// `run` uses, so the session it leaves is the one `status` reads.
    private func interactiveLogin(_ arguments: [String], password: String) throws -> Interactive {
        guard let executable = Self.executableURL else { throw Failure(message: "Bitwarden CLI is not installed") }
        var environment = ProcessInfo.processInfo.environment
        for key in ["BW_SESSION", "BW_PASSWORD", "BW_CLIENTID", "BW_CLIENTSECRET", "BW_NOINTERACTION"] {
            environment.removeValue(forKey: key)
        }
        environment["BITWARDENCLI_APPDATA_DIR"] = appDataURL.path
        environment["BW_PASSWORD"] = password
        // inquirer measures the terminal it draws in; a pipe has no width.
        environment["COLUMNS"] = "120"
        let files = FileManager.default
        try files.createDirectory(at: appDataURL, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        return Interactive(executable: executable, arguments: arguments, environment: environment)
    }

    /// Email + master password, and whatever else the account asks for.
    ///
    /// Comes back `.signedIn` when that was enough — no two-step login and a
    /// Mac the account knows. Otherwise a step: the methods to choose from,
    /// or the code `bw` now waits for (`pendingLogin` describes it; finish
    /// with `submit(code:)`). `method` is `bw --method`: 0 authenticator app,
    /// 1 email, 3 YubiKey; nil lets the CLI pick when the account has one.
    /// An `otp` given here answers the prompt at once (an authenticator code
    /// the user already has, or a second call carrying the emailed one).
    func login(email: String, password: String, otp: String? = nil, method: Int? = nil) async throws -> LoginOutcome {
        guard !email.isEmpty, !password.isEmpty else {
            throw Failure(message: "Bitwarden email and password are required")
        }
        if let method, TwoStepMethod.named(method) == nil {
            throw Failure(message: "Bitwarden two-step method must be 0 (authenticator), 1 (email) or 3 (YubiKey)")
        }
        cancelPendingLogin()
        var arguments = ["login", email, "--passwordenv", "BW_PASSWORD", "--raw"]
        let code = otp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let method {
            arguments += ["--method", String(method)]
        } else if !code.isEmpty {
            // A code with no method: the CLI needs one to send it with.
            arguments += ["--method", "0"]
        }
        if !code.isEmpty { arguments += ["--code", code] }
        let runner = try interactiveLogin(arguments, password: password)
        let event: Interactive.Event
        do {
            event = try await runner.start(timeout: 90)
        } catch is Interactive.TimedOut {
            throw Failure(message: "Bitwarden did not answer in time — check the server address and try again")
        }
        return try await settle(event, runner: runner, email: email, method: method, otp: code.isEmpty ? nil : code)
    }

    private func settle(_ event: Interactive.Event, runner: Interactive, email: String, method: Int?, otp: String?) async throws -> LoginOutcome {
        switch event {
        case .exited(let status, let stdout, let stderr):
            guard status == 0 else {
                throw Failure(message: Self.loginFailure(Interactive.errorLine(stderr)))
            }
            let key = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == "\n" }).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !key.isEmpty else { throw Failure(message: "Bitwarden did not return a session") }
            adopt(sessionKey: key)
            await refreshStatus()
            await refreshCacheIfPossible()
            return .signedIn
        case .prompt(.methods(let names)):
            // Nothing was sent yet — the email goes out only once a method
            // is chosen — so letting go here costs nothing.
            runner.terminate()
            let methods = names.compactMap(TwoStepMethod.fromCLI)
            guard !methods.isEmpty else {
                throw Failure(message: "Bitwarden offered no two-step method this app can take a code for (\(names.joined(separator: ", ")))")
            }
            return .step(.chooseMethod(methods))
        case .prompt(.code), .prompt(.newDevice):
            let prompt: CodePrompt
            if case .prompt(.newDevice) = event { prompt = .newDevice } else { prompt = .twoStep(method: method) }
            if let otp, !otp.isEmpty {
                // The caller had the code already: hand it over now.
                let next: Interactive.Event
                do { next = try await runner.answer(otp, timeout: 90) } catch is Interactive.TimedOut {
                    throw Failure(message: "Bitwarden did not answer the code in time")
                }
                return try await settle(next, runner: runner, email: email, method: method, otp: nil)
            }
            runner.onLostWhileWaiting = { [weak self, weak runner] in
                Task { @MainActor in
                    guard let self, let runner, self.isHolding(runner) else { return }
                    self.cancelPendingLogin()
                }
            }
            hold(runner, PendingLogin(email: email, prompt: prompt, method: method, started: Date()))
            return .step(.needsCode(prompt))
        }
    }

    /// The code the sign-in is waiting for. On success the vault is open;
    /// on a wrong code `bw` has given up and a fresh `login` is needed.
    func submit(code: String) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(message: "Enter the code first") }
        guard let (runner, pending) = takePendingLogin() else {
            throw Failure(message: "No Bitwarden sign-in is waiting for a code — sign in again")
        }
        let event: Interactive.Event
        do { event = try await runner.answer(trimmed, timeout: 90) } catch is Interactive.TimedOut {
            throw Failure(message: "Bitwarden did not answer the code in time — sign in again")
        }
        let outcome = try await settle(event, runner: runner, email: pending.email, method: pending.method, otp: nil)
        guard outcome == .signedIn else {
            cancelPendingLogin()
            throw Failure(message: "Bitwarden asked for something else — sign in again")
        }
    }

    /// What the CLI's last line means for a person.
    static func loginFailure(_ line: String?) -> String {
        guard let line, !line.isEmpty else { return "Bitwarden sign-in failed" }
        let l = line.lowercased()
        if l.contains("token is invalid") || l.contains("invalid two-step") || l.contains("two-step token") {
            return "That code wasn't accepted"
        }
        if l.contains("code is required") { return "Bitwarden needs a code" }
        if l.contains("username or password is incorrect") { return "Username or password is incorrect" }
        return line
    }
}
