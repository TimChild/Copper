import Combine
import CryptoKit
import Foundation
import Network
import Security
import SwiftUI

// Claude account access lives here so the rest of Copper only ever asks for a
// token. The browser performs the OAuth hand-off, while this object keeps the
// loopback listener, credential file, refresh rotation, and account details.

@MainActor
final class ClaudeAccount: ObservableObject {
    static let shared = ClaudeAccount()

    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let scopes = "org:create_api_key user:profile user:inference"
    private static let callbackPath = "/callback"
    private static let fallbackRedirectURI = "http://localhost:53692/callback"

    struct Credential: Codable, Equatable {
        var access: String
        var refresh: String
        var expires: Date
        var email = ""
        var name = ""
        var organization = ""

        init(access: String, refresh: String, expires: Date, email: String = "", name: String = "", organization: String = "") {
            self.access = access
            self.refresh = refresh
            self.expires = expires
            self.email = email
            self.name = name
            self.organization = organization
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            access = try container.decode(String.self, forKey: .access)
            refresh = try container.decode(String.self, forKey: .refresh)
            expires = try container.decode(Date.self, forKey: .expires)
            email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            organization = try container.decodeIfPresent(String.self, forKey: .organization) ?? ""
        }
    }

    enum Phase: Equatable {
        case idle, waiting, exchanging, failed(String)
    }

    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    @Published private(set) var credential: Credential? {
        didSet { if (oldValue == nil) != (credential == nil) || oldValue?.email != credential?.email { session += 1 } }
    }
    /// Counts sign-ins and sign-outs (not token refreshes), so whatever was
    /// learnt about one sign-in — a check's verdict — can tell it is past.
    private(set) var session = 0
    @Published private(set) var phase: Phase = .idle

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var timeoutTask: Task<Void, Never>?
    private var exchangeTask: Task<Void, Never>?
    private var refreshTask: Task<String, Error>?
    private weak var browser: Browser?
    private var signInTabID: UUID?
    private var verifier: String?
    private var redirectURI: String?
    private var callbackHandled = false

    private static var file: URL { Store.file("claude.json") }

    init() {
        let file = Self.file
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            credential = try JSONDecoder().decode(Credential.self, from: data)
        } catch {
            Store.quarantine(file)
        }
    }

    var signedIn: Bool { credential != nil }
    var email: String { credential?.email ?? "" }
    /// The useful account label, without making an email address disappear.
    var who: String {
        guard let credential else { return "Signed in" }
        if !credential.name.isEmpty, !credential.email.isEmpty {
            return "\(credential.name) · \(credential.email)"
        }
        if !credential.email.isEmpty { return credential.email }
        return "Signed in"
    }

    func signIn(in browser: Browser) {
        if phase == .waiting || phase == .exchanging {
            cancel()
        }
        self.browser = browser
        signInTabID = nil
        callbackHandled = false
        let verifier = Self.randomVerifier()
        self.verifier = verifier

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard self.redirectURI == nil else { return }
                        guard let port = listener?.port?.rawValue else {
                            self.failFlow("Couldn't determine the Claude sign-in port")
                            return
                        }
                        self.openAuthorize(on: port)
                    case .failed:
                        guard self.verifier != nil else { return }
                        self.failFlow("Couldn't open the Claude sign-in listener")
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: .main)
            // Waiting begins at the click, not when the port is ready: whoever
            // asked (Settings, the pane, `copper claude signin`) sees it at once.
            setPhase(.waiting)
        } catch {
            self.verifier = nil
            setPhase(.failed("Couldn't open the Claude sign-in listener"))
        }
    }

    func complete(pasted: String) {
        let parsed = Self.parseRedirect(pasted)
        guard let code = parsed.code, !code.isEmpty else {
            failFlow("That does not contain a Claude sign-in code")
            return
        }

        let expectedVerifier = verifier
        if let state = parsed.state {
            guard let expectedVerifier, state == expectedVerifier else {
                failFlow("That code is from a different sign-in attempt")
                return
            }
        }
        let redirect = redirectURI ?? Self.fallbackRedirectURI
        callbackHandled = true
        stopFlowListener()
        beginExchange(code: code, state: parsed.state ?? expectedVerifier ?? "", redirectURI: redirect)
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        exchangeTask?.cancel()
        exchangeTask = nil
        stopFlowListener(closeConnections: true)
        verifier = nil
        redirectURI = nil
        // Cancel ends the attempt, so the claude.ai tab it opened goes too;
        // nobody should have to find and close it by hand.
        closeSignInTabIfAppropriate()
        signInTabID = nil
        callbackHandled = false
        setPhase(.idle)
    }

    func signOut() {
        cancel()
        credential = nil
        try? FileManager.default.removeItem(at: Self.file)
    }

    func token() async throws -> String {
        guard let credential else {
            throw Failure(text: "Not signed in to Claude — Settings › Intelligence › Model access")
        }
        guard credential.expires.timeIntervalSinceNow <= 300 else { return credential.access }
        return try await refreshShared()
    }

    func refreshNow() async throws -> String {
        guard credential != nil else {
            throw Failure(text: "Not signed in to Claude — Settings › Intelligence › Model access")
        }
        return try await refreshShared()
    }

    var status: [String: Any] {
        let state: (String, String) = {
            switch phase {
            case .idle: return ("idle", "")
            case .waiting: return ("waiting", "")
            case .exchanging: return ("exchanging", "")
            case .failed(let text): return ("failed", text)
            }
        }()
        let expires: String
        if let date = credential?.expires {
            expires = ISO8601DateFormatter().string(from: date)
        } else {
            expires = ""
        }
        return [
            "signedIn": signedIn,
            "email": email,
            "name": credential?.name ?? "",
            "organization": credential?.organization ?? "",
            "expires": expires,
            "phase": state.0,
            "trouble": state.1,
        ]
    }

    func control(_ params: [String: Any], in browser: Browser?) -> [String: Any] {
        switch params["op"] as? String ?? "status" {
        case "status":
            return status
        case "signin":
            guard let browser else { return ["error": "no window"] }
            signIn(in: browser)
            return status
        case "paste":
            guard let code = params["code"] as? String else { return ["error": "paste needs code"] }
            complete(pasted: code)
            return status
        case "signout":
            signOut()
            return status
        case "cancel":
            cancel()
            return status
        case let op:
            return ["error": "unknown claude op \(op) (status, signin, paste, signout, cancel)"]
        }
    }

    // MARK: - OAuth listener

    private func openAuthorize(on port: UInt16) {
        guard let verifier else { return }
        let redirect = "http://localhost:\(port)\(Self.callbackPath)"
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier),
        ]
        guard let url = components?.url else {
            failFlow("Couldn't build the Claude sign-in URL")
            return
        }
        redirectURI = redirect
        guard let browser else {
            failFlow("No browser window is available")
            return
        }
        let tab = browser.open(url, foreground: true)
        signInTabID = tab.id
        setPhase(.waiting)
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 600_000_000_000)
            } catch {
                return
            }
            guard let self, self.phase == .waiting else { return }
            // Ten minutes on: the code that tab shows has run out too.
            self.closeSignInTabIfAppropriate()
            self.failFlow("Sign-in timed out — try again")
        }
    }

    private func accept(_ connection: NWConnection) {
        let wrapped = Connection(connection) { [weak self] request, answer in
            guard let self else {
                answer(HTTPResponse(status: 503, body: Data()))
                return
            }
            self.handle(request, answer: answer)
        } gone: { [weak self] id in
            self?.connections[id] = nil
        }
        connections[wrapped.id] = wrapped
        wrapped.open()
    }

    private func handle(_ request: HTTPRequest, answer: @escaping (HTTPResponse) -> Void) {
        guard request.method == "GET" else {
            answer(HTTPResponse(status: 404, body: Data()))
            return
        }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard path == Self.callbackPath, !callbackHandled else {
            answer(HTTPResponse(status: 404, body: Data()))
            return
        }
        guard let components = URLComponents(string: "http://localhost" + request.path),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              !code.isEmpty,
              let expectedVerifier = verifier,
              state == expectedVerifier,
              let redirect = redirectURI
        else {
            answer(Self.htmlResponse(status: 400, heading: "Copper could not sign in.", line: "The callback was not valid. You can close this tab."))
            failFlow("The Claude sign-in callback was not valid", closeConnections: false)
            return
        }
        callbackHandled = true
        answer(Self.htmlResponse(status: 200, heading: "Copper is signed in with your Claude account.", line: "You can close this tab."))
        stopFlowListener()
        beginExchange(code: code, state: state, redirectURI: redirect)
    }

    private func stopFlowListener(closeConnections: Bool = false) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        if closeConnections {
            for connection in connections.values { connection.close() }
            connections = [:]
        }
    }

    // MARK: - Token exchange and profile

    private func beginExchange(code: String, state: String, redirectURI: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        setPhase(.exchanging)
        exchangeTask?.cancel()
        exchangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let exchanged = try await self.exchange(code: code, state: state, redirectURI: redirectURI)
                guard !Task.isCancelled else { return }
                self.credential = exchanged
                self.save()
                Intelligence.shared.keys.lane = .claude
                self.closeSignInTabIfAppropriate()
                self.browser?.announce("Signed in to Claude as \(self.who)")
                self.cleanupFlow()
                self.setPhase(.idle)
            } catch is CancellationError {
                // A new sign-in or cancel owns the next state transition.
            } catch let failure as Failure {
                guard !Task.isCancelled else { return }
                // The attempt is spent (its verifier goes below), so its tab
                // is no use; Try again opens a fresh one.
                self.closeSignInTabIfAppropriate()
                self.cleanupFlow()
                self.setPhase(.failed(failure.text))
            } catch {
                guard !Task.isCancelled else { return }
                self.closeSignInTabIfAppropriate()
                self.cleanupFlow()
                self.setPhase(.failed(error.localizedDescription))
            }
        }
    }

    private func exchange(code: String, state: String, redirectURI: String) async throws -> Credential {
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "code_verifier": verifier ?? state,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(text: "Claude sign-in request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(text: "Claude sign-in returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(text: Self.httpFailure(prefix: "Claude sign-in", status: http.statusCode, data: data))
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = payload["access_token"] as? String,
              let refresh = payload["refresh_token"] as? String,
              let expiresNumber = payload["expires_in"] as? NSNumber
        else {
            throw Failure(text: "Claude sign-in returned an incomplete token")
        }
        var result = Credential(access: access, refresh: refresh, expires: Date().addingTimeInterval(expiresNumber.doubleValue))
        if let profile = try? await fetchProfile(access: access) {
            result.email = profile.email
            result.name = profile.name
            result.organization = profile.organization
        }
        return result
    }

    private struct Profile {
        var email = ""
        var name = ""
        var organization = ""
    }

    private func fetchProfile(access: String) async throws -> Profile {
        var request = URLRequest(url: Self.profileURL, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.1.283", forHTTPHeaderField: "user-agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure(text: "Claude profile was unavailable")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = payload["account"] as? [String: Any]
        else { throw Failure(text: "Claude profile was unavailable") }
        let displayName = (account["display_name"] as? String) ?? ""
        let fullName = (account["full_name"] as? String) ?? ""
        let organization = (payload["organization"] as? [String: Any])?["name"] as? String ?? ""
        return Profile(email: account["email"] as? String ?? "", name: displayName.isEmpty ? fullName : displayName, organization: organization)
    }

    private func refreshShared() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw Failure(text: "Not signed in to Claude — Settings › Intelligence › Model access") }
            return try await self.performRefresh()
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let original = credential else {
            throw Failure(text: "Not signed in to Claude — Settings › Intelligence › Model access")
        }
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": original.refresh,
        ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(text: "Claude token refresh failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(text: "Claude token refresh returned no HTTP response")
        }
        if http.statusCode == 400 || http.statusCode == 401 {
            signOut()
            throw Failure(text: "Claude sign-in expired — sign in again in Settings › Intelligence")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(text: Self.httpFailure(prefix: "Claude token refresh", status: http.statusCode, data: data))
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = payload["access_token"] as? String,
              let refresh = payload["refresh_token"] as? String,
              let expiresNumber = payload["expires_in"] as? NSNumber
        else {
            throw Failure(text: "Claude token refresh returned an incomplete token")
        }
        guard credential?.refresh == original.refresh else {
            throw Failure(text: "Claude sign-in changed while the token was refreshing")
        }
        var updated = original
        updated.access = access
        updated.refresh = refresh
        updated.expires = Date().addingTimeInterval(expiresNumber.doubleValue)
        credential = updated
        save()
        return access
    }

    private func save() {
        guard let credential, let data = try? JSONEncoder().encode(credential) else { return }
        let file = Self.file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// A failed or timed-out flow keeps its verifier and redirect address:
    /// the code claude.ai showed is still good for a few minutes, and
    /// pasting it is the whole point of the fallback. Only cancel, success
    /// or a fresh sign-in forget them.
    private func failFlow(_ text: String, closeConnections: Bool = true) {
        timeoutTask?.cancel()
        timeoutTask = nil
        stopFlowListener(closeConnections: closeConnections)
        signInTabID = nil
        callbackHandled = false
        setPhase(.failed(text))
    }

    private func cleanupFlow() {
        timeoutTask?.cancel()
        timeoutTask = nil
        verifier = nil
        redirectURI = nil
        signInTabID = nil
        callbackHandled = false
        exchangeTask = nil
    }

    /// Closes the tab the sign-in opened — unless it has since gone
    /// somewhere that isn't part of signing in, which makes it the person's.
    private func closeSignInTabIfAppropriate() {
        guard let browser, let signInTabID,
              let tab = browser.tabs.first(where: { $0.id == signInTabID }) else { return }
        guard Self.isSignInHost(tab.address?.host) else { return }
        browser.close(tab)
    }

    /// claude.ai and its sign-in pages, or the callback on this Mac. A tab
    /// that never got an address is still the one the sign-in opened.
    nonisolated static func isSignInHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return true }
        if host == "localhost" || host == "127.0.0.1" { return true }
        return ["claude.ai", "claude.com", "anthropic.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func setPhase(_ next: Phase) {
        guard phase != next else { return }
        phase = next
        let label: String
        switch next {
        case .idle: label = "idle"
        case .waiting: label = "waiting"
        case .exchanging: label = "exchanging"
        case .failed: label = "failed"
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) copper: claude phase \(label)\n".utf8))
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func parseRedirect(_ pasted: String) -> (code: String?, state: String?) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.queryItems != nil {
            return (components.queryItems?.first(where: { $0.name == "code" })?.value,
                    components.queryItems?.first(where: { $0.name == "state" })?.value)
        }
        if trimmed.contains("#"), let hash = trimmed.firstIndex(of: "#") {
            let code = String(trimmed[..<hash])
            let state = String(trimmed[trimmed.index(after: hash)...])
            return (code.removingPercentEncoding ?? code, state.removingPercentEncoding ?? state)
        }
        if let components = URLComponents(string: "http://localhost/callback?\(trimmed)"),
           let items = components.queryItems,
           items.contains(where: { $0.name == "code" }) {
            return (items.first(where: { $0.name == "code" })?.value,
                    items.first(where: { $0.name == "state" })?.value)
        }
        return (trimmed, nil)
    }

    private static func htmlResponse(status: Int, heading: String, line: String) -> HTTPResponse {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Copper</title><style>body{font-family:system-ui,sans-serif;max-width:38rem;margin:12vh auto;padding:0 1.5rem;line-height:1.5;color:#202124}h1{font-size:1.35rem;font-weight:600}p{color:#5f6368}</style></head><body><h1>\(heading)</h1><p>\(line)</p></body></html>
        """
        var response = HTTPResponse(status: status, body: Data(html.utf8))
        response.contentType = "text/html; charset=utf-8"
        return response
    }

    private static func httpFailure(prefix: String, status: Int, data: Data) -> String {
        let detail: String
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (payload["error_description"] as? String) ?? (payload["message"] as? String) ?? (payload["error"] as? String),
           !message.isEmpty {
            detail = String(message.prefix(240))
        } else {
            detail = "HTTP \(status)"
        }
        return "\(prefix) failed: \(detail)"
    }
}
