import Foundation
import SystemConfiguration

// Copper as an agent link: the owner's bots get this window's tools.
//
// The MCP server in MCP.swift listens on 127.0.0.1 and nothing off this Mac
// can reach it — which is right, and also why a bot running in the cloud
// can't. So this side dials out instead. It registers the browser with the
// agents service as a *link* (`POST /v1/me/links`), holds one
// server-sent-events stream open (`GET …/frames`), and answers each
// `request` frame by handing the JSON-RPC message to the same
// `MCP.shared.handle` the loopback server uses, then posting the reply back
// (`POST …/frames`). The service is the hub: a bot only sees these tools
// after the owner grants it, and every call is written down on both sides.
//
// The credential is the owner's personal token (`fxb_…`). It lives in
// agent.json (0600, beside the loopback token), goes only to the agents app
// address in `api`, and is never logged. Copper's own loopback token never
// leaves the Mac. The link works whether or not the loopback listener is
// on; it needs a window, like every tool call does.
//
// Wire parsing lives in LinkWire.swift, which has no app in it.

@MainActor
final class AgentLink: ObservableObject {
    static let shared = AgentLink()

    typealias Grant = LinkWire.Grant
    typealias Bot = LinkWire.Bot
    typealias Call = LinkWire.Call

    nonisolated static let defaultAPI = "https://agents.example"

    /// Stored in agent.json under `agentLink`, beside the MCP server's own
    /// settings (see `MCP.Config.agentLink`).
    struct Config: Codable, Equatable {
        var enabled = false
        var api = AgentLink.defaultAPI
        var token = ""
        var name = "copper"
        var linkId: String?
        /// Say each bot's tool call in the line at the bottom.
        var announces = true

        init() {}

        // Lenient, like MCP.Config: an older file, or one a later version
        // wrote, must still read — a missing key is its default.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            api = try c.decodeIfPresent(String.self, forKey: .api) ?? AgentLink.defaultAPI
            token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "copper"
            linkId = try c.decodeIfPresent(String.self, forKey: .linkId)
            announces = try c.decodeIfPresent(Bool.self, forKey: .announces) ?? true
            if api.trimmingCharacters(in: .whitespaces).isEmpty { api = AgentLink.defaultAPI }
            if name.isEmpty { name = "copper" }
        }
    }

    enum Status: Equatable {
        case off
        case connecting
        case online(String)
        case offline(String)
        case revoked
        case tokenRejected

        var text: String {
            switch self {
            case .off: return "Off"
            case .connecting: return "Connecting…"
            case .online(let label): return "Online as \(label)"
            case .offline(let why): return why
            case .revoked: return "Revoked — every bot lost these tools. Switch on to link again."
            case .tokenRejected: return "Token rejected — mint a new one"
            }
        }

        /// For `copper link status --json`.
        var key: String {
            switch self {
            case .off: return "off"
            case .connecting: return "connecting"
            case .online: return "online"
            case .offline: return "offline"
            case .revoked: return "revoked"
            case .tokenRejected: return "token-rejected"
            }
        }

        var isOnline: Bool { if case .online = self { return true } else { return false } }
    }

    enum Failure: Error {
        case setup(String)
        case unauthorized
        case revoked
        case superseded
        case http(Int, String)
        case transport(String)

        var text: String {
            switch self {
            case .setup(let why): return why
            case .unauthorized: return "Token rejected — mint a new one"
            case .revoked: return "The link was revoked"
            case .superseded: return "Another Copper took this link — switch off and on to take it back"
            case .http(let status, let why): return why.isEmpty ? "the agents app answered \(status)" : "the agents app answered \(status): \(why)"
            case .transport(let why): return why
            }
        }
    }

    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            MCP.shared.config.agentLink = config
            react(from: oldValue)
        }
    }
    @Published private(set) var status: Status = .off
    @Published private(set) var grants: [Grant] = []
    /// The owner's bots, for "Grant a bot…". Loaded on demand.
    @Published private(set) var bots: [Bot] = []
    /// The last calls bots made through this window, newest first, this run
    /// only.
    @Published private(set) var recentCalls: [Call] = []
    @Published private(set) var lastError: String?
    /// The link as the service last described it.
    @Published private(set) var link: LinkWire.Link?

    private var started = false
    private var runner: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    /// Bumped on every connect and disconnect, so a stream or a reply from
    /// an earlier connection never writes over the current one's state.
    private var generation = 0

    private init() {
        config = MCP.shared.config.agentLink ?? Config()
    }

    /// From `MCP.start(for:)`, once Copper has a window. Nothing connects
    /// before this — a CLI invocation of the binary never dials out.
    func start() {
        guard !started else { return }
        started = true
        if config.enabled { connect(fresh: config.linkId == nil) }
    }

    var tokenReady: Bool { config.token.hasPrefix("fxb_") && config.token.count > 8 }

    /// "Copper on Felipe's MacBook Pro".
    static var label: String { "Copper on \(computerName)" }

    static var computerName: String {
        // SCDynamicStoreCopyComputerName is the name in Sharing settings —
        // what Host.current().localizedName returns, without the DNS walk
        // Host does first.
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return device
    }

    static var device: String {
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }

    // MARK: - reacting to settings

    private func react(from old: Config) {
        guard started else { return }
        if config.enabled != old.enabled {
            if config.enabled {
                lastError = nil
                // Switching on is the owner's say-so: it (re)creates the link,
                // which un-revokes one revoked earlier. A reconnect never does.
                connect(fresh: true)
            } else {
                disconnect()
                status = .off
            }
            return
        }
        if config.token != old.token || config.api != old.api {
            if !config.enabled {
                if status == .tokenRejected { status = .off }
                return
            }
            // A token is pasted in one go but typed a key at a time; wait for
            // the typing to stop before dialling with it.
            disconnect()
            status = .connecting
            let g = generation
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, !Task.isCancelled, g == self.generation else { return }
                // A new token may be a new owner: the link is theirs to create.
                self.connect(fresh: true)
            }
        }
    }

    // MARK: - the connection

    private func connect(fresh: Bool) {
        disconnect()
        guard config.enabled else { status = .off; return }
        let g = generation
        status = .connecting
        runner = Task { [weak self] in await self?.loop(g, fresh: fresh) }
    }

    private func disconnect() {
        pending?.cancel()
        pending = nil
        runner?.cancel()
        runner = nil
        generation += 1
    }

    private func current(_ g: Int) -> Bool { g == generation && !Task.isCancelled }

    /// Connect, serve, and when the stream drops, wait and connect again:
    /// 1 s, 2 s, 4 s … 30 s. It stops for good on a revoke, a takeover, a
    /// rejected token, or being switched off.
    private func loop(_ g: Int, fresh: Bool) async {
        var attempt = 0
        var fresh = fresh
        while current(g), config.enabled {
            status = .connecting
            do {
                if fresh || config.linkId == nil {
                    try await createLink()
                    fresh = false
                } else {
                    try await checkLink()
                }
                guard current(g) else { return }
                if try await stream(g) { attempt = 0 }
                guard current(g) else { return }
                status = .offline("Disconnected — reconnecting")
            } catch Failure.unauthorized {
                if current(g) { rejectToken() }
                return
            } catch Failure.revoked {
                if current(g) { markRevoked() }
                return
            } catch Failure.superseded {
                if current(g) {
                    disconnect()
                    status = .offline(Failure.superseded.text)
                }
                return
            } catch Failure.setup(let why) {
                // No token, or an address that isn't one: waiting won't fix
                // it. Editing either field dials again.
                if current(g) { status = .offline(why) }
                return
            } catch {
                guard current(g) else { return }
                let why = describe(error)
                lastError = why
                status = .offline("\(why) — retrying")
            }
            let wait = LinkWire.backoff(attempt)
            attempt += 1
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func createLink() async throws {
        let body: [String: Any] = [
            "name": config.name, "label": AgentLink.label, "kind": "mcp",
            "device": AgentLink.device, "clientVersion": Fork.version,
        ]
        let object = try await send("POST", ["v1", "me", "links"], body: body, gone: .notFound)
        guard let made = LinkWire.Link(object) else { throw Failure.http(200, "no link in the answer") }
        link = made
        if config.linkId != made.id { config.linkId = made.id }
    }

    /// On a reconnect: is the link still there and still ours to serve? A
    /// revoke made while this Mac slept must hold — only switching on again
    /// re-creates a revoked link.
    private func checkLink() async throws {
        guard let id = config.linkId else { return }
        let object = try await send("GET", ["v1", "me", "links", id], gone: .revoked)
        if let known = LinkWire.Link(object) {
            link = known
            if known.revoked { throw Failure.revoked }
        }
    }

    /// One frames stream, until it ends. True when it got as far as being
    /// online, so the next reconnect starts from a short wait again.
    private func stream(_ g: Int) async throws -> Bool {
        guard let id = config.linkId else { throw Failure.setup("No link yet") }
        var request = try makeRequest("GET", ["v1", "me", "links", id, "frames"],
                                      query: [URLQueryItem(name: "device", value: AgentLink.device),
                                              URLQueryItem(name: "clientVersion", value: Fork.version)],
                                      timeout: 45) // the service pings every 15 s; three missed is a dead stream
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        var online = false
        var beat: Task<Void, Never>?
        defer { beat?.cancel() }
        for try await item in LinkWire.events(for: request) {
            guard current(g) else { return online }
            switch item {
            case .refused(let code, let data):
                throw AgentLink.classify(code, data, gone: .revoked)
            case .opened:
                online = true
                lastError = nil
                status = .online(link?.label ?? AgentLink.label)
                beat = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        guard !Task.isCancelled, let self, self.current(g) else { return }
                        try? await self.post(frames: [LinkWire.heartbeat], to: id)
                    }
                }
            case .event(let event):
                switch LinkWire.frame(event) {
                case .hello(let described, let items):
                    if let described { link = described }
                    grants = items
                    status = .online(described?.label ?? link?.label ?? AgentLink.label)
                case .request(let request):
                    Task { [weak self] in await self?.serve(request, linkId: id, generation: g) }
                case .grants(let items):
                    grants = items
                case .superseded:
                    throw Failure.superseded
                case .revoked:
                    throw Failure.revoked
                case .ping, .unknown:
                    break
                }
            }
        }
        return online
    }

    /// One request from a bot: through Copper's MCP server, reply posted back.
    private func serve(_ request: LinkWire.Request, linkId: String, generation g: Int) async {
        let began = Date()
        let rpc: [String: Any]?
        if request.method.hasPrefix("copper/") {
            // The loopback CLI's own control methods are never a bot's.
            rpc = ["jsonrpc": "2.0", "id": request.id, "error": ["code": -32601, "message": "Method not found: \(request.method)"]]
        } else {
            let who = request.caller.botHandle.isEmpty ? "bot" : request.caller.botHandle
            rpc = await MCP.shared.handle(request.message, announce: config.announces ? .prefix("agents · @\(who)") : .quiet)
        }
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        if let tool = request.tool {
            let outcome = LinkWire.outcome(rpc)
            let handle = request.caller.botHandle.isEmpty ? request.caller.botId : request.caller.botHandle
            recentCalls.insert(Call(handle: handle, tool: tool, ok: outcome.ok, at: began, ms: ms, error: outcome.error), at: 0)
            if recentCalls.count > 20 { recentCalls.removeLast(recentCalls.count - 20) }
        }
        // Switched off or revoked while the tool ran: there is nobody left
        // to answer, and the service would refuse the post anyway.
        guard current(g), config.enabled else { return }
        do {
            try await post(frames: [LinkWire.reply(requestId: request.id, rpc: rpc)], to: linkId)
        } catch {
            if current(g) { lastError = "Couldn't send a reply: \(describe(error))" }
        }
    }

    private func post(frames: [[String: Any]], to id: String) async throws {
        var request = try makeRequest("POST", ["v1", "me", "links", id, "frames"], timeout: 60)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = LinkWire.body(frames)
        _ = try await perform(request, gone: .revoked)
    }

    private func rejectToken() {
        disconnect()
        status = .tokenRejected
        lastError = Status.tokenRejected.text
    }

    private func markRevoked() {
        disconnect()
        grants = []
        link = nil
        if config.enabled { config.enabled = false } // react() → .off; the reason goes on top
        status = .revoked
    }

    // MARK: - the owner's actions

    /// Every bot with a grant, fresh from the service.
    @discardableResult
    func refreshGrants() async throws -> [Grant] {
        let id = try linkID()
        let items = LinkWire.grants(try await guarded { try await self.send("GET", ["v1", "me", "links", id, "grants"]) })
        grants = items
        return items
    }

    /// The owner's bots.
    @discardableResult
    func listBots() async throws -> [Bot] {
        let items = LinkWire.bots(try await guarded { try await self.send("GET", ["v1", "bots"]) })
        bots = items
        return items
    }

    /// Grant a bot, or pause or resume its grant.
    @discardableResult
    func setGrant(_ botId: String, enabled: Bool) async throws -> Grant? {
        let id = try linkID()
        let before = grants
        if let index = grants.firstIndex(where: { $0.botId == botId }) { grants[index].enabled = enabled }
        do {
            let object = try await guarded { try await self.send("PUT", ["v1", "me", "links", id, "grants", botId], body: ["enabled": enabled]) }
            if var grant = LinkWire.Grant(object) {
                // The PUT answers with the grant; the bot's name may ride
                // only on the list — keep what we had.
                if let known = grants.first(where: { $0.botId == botId }) ?? bots.first(where: { $0.id == botId }).map({ Grant(botId: $0.id, handle: $0.handle, name: $0.name, enabled: enabled) }) {
                    if grant.handle.isEmpty { grant.handle = known.handle }
                    if grant.name.isEmpty { grant.name = known.name }
                }
                if let index = grants.firstIndex(where: { $0.botId == botId }) { grants[index] = grant } else { grants.append(grant) }
                return grant
            }
            return try await refreshGrants().first { $0.botId == botId }
        } catch {
            grants = before
            throw error
        }
    }

    /// Take a bot's grant away entirely.
    func removeGrant(_ botId: String) async throws {
        let id = try linkID()
        _ = try await guarded { try await self.send("DELETE", ["v1", "me", "links", id, "grants", botId]) }
        grants.removeAll { $0.botId == botId }
    }

    /// Kill the link: every bot loses these tools, and Copper disconnects.
    func revokeLink() async throws {
        let id = try linkID()
        _ = try await guarded { try await self.send("DELETE", ["v1", "me", "links", id], gone: .notFound) }
        markRevoked()
    }

    /// The service's record of calls, newest first — what the owner sees in
    /// the agents app, including calls made while this window was not watching.
    func fetchCalls(limit: Int = 20) async throws -> [Call] {
        let id = try linkID()
        return LinkWire.calls(try await guarded {
            try await self.send("GET", ["v1", "me", "links", id, "calls"], query: [URLQueryItem(name: "limit", value: String(limit))])
        })
    }

    private func linkID() throws -> String {
        guard let id = config.linkId, !id.isEmpty else { throw Failure.setup("Not linked yet — switch it on first") }
        return id
    }

    /// Runs one owner action: a rejected token stops the stream too; any
    /// failure becomes `lastError`; success clears it.
    private func guarded(_ work: () async throws -> Any?) async throws -> Any? {
        do {
            let out = try await work()
            lastError = nil
            return out
        } catch Failure.unauthorized {
            rejectToken()
            throw Failure.unauthorized
        } catch {
            lastError = describe(error)
            throw error
        }
    }

    // MARK: - HTTP

    /// What a 404 means for this route: a link that is gone (revoked), or an
    /// address that is simply wrong.
    private enum Gone { case revoked, notFound }

    private func makeRequest(_ method: String, _ path: [String], query: [URLQueryItem] = [], timeout: TimeInterval = 20) throws -> URLRequest {
        guard let base = LinkWire.base(config.api) else { throw Failure.setup("The app address must be an https URL") }
        let token = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw Failure.setup("Paste a personal token") }
        let joined = base.absoluteString + "/" + path.map(LinkWire.segment).joined(separator: "/")
        guard var components = URLComponents(string: joined) else { throw Failure.setup("The app address must be an https URL") }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw Failure.setup("The app address must be an https URL") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ method: String, _ path: [String], query: [URLQueryItem] = [], body: [String: Any]? = nil, gone: Gone = .notFound) async throws -> Any? {
        var request = try makeRequest(method, path, query: query)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return try await perform(request, gone: gone)
    }

    private func perform(_ request: URLRequest, gone: Gone) async throws -> Any? {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.transport(describe(error))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AgentLink.classify(code, data, gone: gone) }
        return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
    }

    /// A refusal, as something the loop can act on. A 404 that is JSON on a
    /// link route means the link is gone; an HTML one means the address is
    /// wrong, and switching the link off for that would be a lie.
    private static func classify(_ code: Int, _ data: Data, gone: Gone) -> Failure {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (object?["error"] as? String) ?? (object?["message"] as? String)
            ?? ((object?["error"] as? [String: Any])?["message"] as? String) ?? ""
        switch code {
        case 401: return .unauthorized
        case 404, 410:
            // A framework's own 404 ("Route GET:/v1/… not found") is an app
            // without these routes, not a link that is gone.
            if gone == .revoked, object != nil, !message.hasPrefix("Route ") { return .revoked }
            return .http(code, message.isEmpty ? "not found — check the app address" : message)
        default:
            return .http(code, String(message.prefix(200)))
        }
    }

    private func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.text }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Offline"
            case .timedOut: return "the agents app stopped answering"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Can't reach \(URL(string: config.api)?.host ?? "the app")"
            default: return url.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - bench and the CLI

    /// Everything but the token.
    var summary: [String: Any] {
        [
            "enabled": config.enabled, "api": config.api, "name": config.name, "linkId": config.linkId ?? "",
            "tokenSet": !config.token.isEmpty, "announces": config.announces,
            "status": status.key, "statusText": status.text, "online": status.isOnline,
            "label": link?.label ?? "", "grants": grants.map(\.json),
            "recentCalls": recentCalls.count, "lastError": lastError ?? "",
        ]
    }

    /// `./bench agent link [on|off|status]`.
    func bench(_ arg: String) -> [String: Any] {
        switch arg {
        case "on": config.enabled = true
        case "off": config.enabled = false
        case "", "status": break
        default: return ["error": "link takes on, off or status"]
        }
        return summary
    }

    /// `copper link …`, over the loopback server (`copper/link`). Never
    /// reachable through the link itself — see `serve`.
    func control(_ params: [String: Any]) async -> [String: Any] {
        let op = params["op"] as? String ?? "status"
        let arg = (params["arg"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch op {
            case "status":
                return summary
            case "on":
                config.enabled = true
                return await settled()
            case "off":
                config.enabled = false
                return summary
            case "token":
                guard !arg.isEmpty else { return ["error": "link token needs fxb_…"] }
                guard arg.hasPrefix("fxb_") else { return ["error": "that isn't a personal token (fxb_…)"] }
                config.token = arg
                return config.enabled ? await settled() : summary
            case "api":
                guard LinkWire.base(arg) != nil else { return ["error": "link api needs an https URL"] }
                config.api = arg
                return config.enabled ? await settled() : summary
            case "grants":
                return ["grants": try await refreshGrants().map(\.json)]
            case "grant":
                let bot = try await resolve(arg, among: .bots)
                guard let grant = try await setGrant(bot, enabled: true) else { return ["error": "the agents app did not return the grant"] }
                return ["grant": grant.json]
            case "revoke":
                if arg.isEmpty {
                    try await revokeLink()
                    return ["revoked": true]
                }
                let bot = try await resolve(arg, among: .grants)
                try await removeGrant(bot)
                return ["removed": bot]
            case "calls":
                if let calls = try? await fetchCalls(limit: 20) { return ["source": "agents", "calls": calls.map(\.json)] }
                return ["source": "local", "calls": recentCalls.map(\.json)]
            default:
                return ["error": "unknown link command: \(op)"]
            }
        } catch {
            return ["error": describe(error)]
        }
    }

    private enum Among { case bots, grants }

    /// `@felix`, `felix` or a bot id → the bot id.
    private func resolve(_ raw: String, among: Among) async throws -> String {
        guard !raw.isEmpty else { throw Failure.setup("which bot? @handle or a bot id") }
        let wanted = LinkWire.bare(raw).lowercased()
        if among == .grants {
            if grants.isEmpty { _ = try? await refreshGrants() }
            if let grant = grants.first(where: { $0.botId == raw || $0.handle.lowercased() == wanted }) { return grant.botId }
        }
        let all = try await listBots()
        if let bot = all.first(where: { $0.id == raw || $0.handle.lowercased() == wanted }) { return bot.id }
        if !raw.hasPrefix("@") { return raw } // an id the list did not show; let the service decide
        throw Failure.setup("no bot \(raw)")
    }

    /// After switching on: wait a few seconds for the first answer, so the
    /// CLI can say online or why not.
    private func settled() async -> [String: Any] {
        for _ in 0..<40 {
            if status != .connecting { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return summary
    }
}
