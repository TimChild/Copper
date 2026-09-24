import Foundation
import Network
import Security

// Copper as an MCP server: an agent drives the window you are looking at.
//
// Playwright's MCP and Chrome's DevTools MCP each start a browser of their
// own, signed in as nobody. This one is the browser you already have open —
// your tabs, your sign-ins, your extensions — listening on the loopback
// interface for the tools those agents already know how to use. Tool names
// and arguments follow Playwright MCP's, so a skill written for it works
// here without a word changed.
//
// Transport is MCP's Streamable HTTP, the simplest shape of it: one POST per
// message, one JSON reply, no session, no stream. Every request carries a
// bearer token that lives in a file only this user can read; the socket
// never leaves 127.0.0.1. A `--mcp-stdio` bridge (Bridge.swift) is there for
// clients that only speak stdio.

@MainActor
final class MCP: ObservableObject {
    static let shared = MCP()

    struct Config: Codable, Equatable {
        var enabled = false
        var port: UInt16 = 4123
        var token = ""
        /// Say each tool call in the line at the bottom, so you can see the
        /// agent's hands.
        var announces = true
        /// Jev mode: the jev_run / jev_step / jev_observe tools, which drive
        /// the page with TypeSafe's Jev at ~200 ms a decision (Ultrafast.swift).
        var jev = false

        init(enabled: Bool = false, port: UInt16 = 4123, token: String = "", announces: Bool = true, jev: Bool = false) {
            self.enabled = enabled
            self.port = port
            self.token = token
            self.announces = announces
            self.jev = jev
        }

        // Lenient on purpose: a field added later must not make an older
        // agent.json unreadable, or the token would rotate under every
        // client that has it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 4123
            token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
            announces = try c.decodeIfPresent(Bool.self, forKey: .announces) ?? true
            jev = try c.decodeIfPresent(Bool.self, forKey: .jev) ?? false
        }
    }

    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            save()
            if config.enabled != oldValue.enabled || config.port != oldValue.port { apply() }
        }
    }
    @Published private(set) var running = false
    @Published private(set) var trouble: String?
    @Published private(set) var calls = 0
    @Published private(set) var lastTool = ""
    /// The last Jev run, in a few words, for Settings.
    @Published var jevNote = ""

    private weak var browser: Browser?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]

    static let path = "/mcp"
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Where the token and port live. Beside the session, this user only.
    static var file: URL { Store.file("agent.json") }

    var endpoint: String { "http://127.0.0.1:\(config.port)\(MCP.path)" }

    private init() {
        if let data = try? Data(contentsOf: MCP.file),
           let saved = try? JSONDecoder().decode(Config.self, from: data), !saved.token.isEmpty {
            config = saved
        } else {
            config = Config(token: MCP.freshToken())
            save()
        }
    }

    static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func save() {
        let file = MCP.file
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func rotateToken() {
        config.token = MCP.freshToken()
    }

    /// What to paste into Claude Code's or phi's mcp.json.
    var clientConfig: String {
        """
        {
          "mcpServers": {
            "copper": {
              "type": "http",
              "url": "\(endpoint)",
              "headers": { "Authorization": "Bearer \(config.token)" }
            }
          }
        }
        """
    }

    /// The same, for a client that only speaks stdio.
    var stdioConfig: String {
        let binary = Bundle.main.executablePath ?? "/Applications/Copper.app/Contents/MacOS/Copper"
        return """
        {
          "mcpServers": {
            "copper": {
              "type": "stdio",
              "command": "\(binary)",
              "args": ["--mcp-stdio"]
            }
          }
        }
        """
    }

    /// One paragraph to paste into a chat with an agent: where Copper is,
    /// how to connect, what it can do. The Playwright-shaped tools.
    var agentPrompt: String {
        """
        My browser, Copper, is running a local MCP server you can drive — it's the browser I'm already signed into, with my open tabs. Connect to it as an MCP server named `copper`: Streamable HTTP at \(endpoint) with the header `Authorization: Bearer \(config.token)` (Claude Code: `claude mcp add --transport http copper \(endpoint) --header "Authorization: Bearer \(config.token)"`; phi/Cursor: add `{"type":"http","url":"\(endpoint)","headers":{"Authorization":"Bearer \(config.token)"}}` under mcpServers.copper). It speaks Playwright MCP's tool set against the tab I have open — browser_tabs, browser_navigate, browser_snapshot (accessibility tree with refs like e12), browser_click, browser_type, browser_fill_form, browser_press_key, browser_hover, browser_select_option, browser_drag, browser_scroll, browser_take_screenshot, browser_evaluate, browser_wait_for, browser_get_text, browser_find, browser_console_messages, browser_resize, browser_close, plus browser_groups for my tab groups — so anything you know how to do with Playwright MCP works unchanged. Start with browser_tabs, then browser_snapshot to get refs, then act with those refs; work in the tab I'm on unless I say otherwise, and remember you're acting as me, signed in as me.
        """
    }

    /// The same, with Jev mode: hand over a goal, get a finished run back.
    var jevPrompt: String {
        """
        My browser, Copper, is running a local MCP server you can drive — the browser I'm already signed into, with my open tabs — and it's in Jev mode. Connect to it as an MCP server named `copper`: Streamable HTTP at \(endpoint) with the header `Authorization: Bearer \(config.token)` (Claude Code: `claude mcp add --transport http copper \(endpoint) --header "Authorization: Bearer \(config.token)"`; phi/Cursor: add `{"type":"http","url":"\(endpoint)","headers":{"Authorization":"Bearer \(config.token)"}}` under mcpServers.copper). Prefer `jev_run` with ONE plain-English goal (optional `url`, `newTab`): Copper runs browser-use's jev-ultrafast loop natively — TypeSafe's Jev picks an operation and an indexed element every ~200 ms, a small model writes any text, and it acts with real clicks and keystrokes until DONE or BLOCKED — so a multi-step task takes seconds, not a snapshot-and-click round trip per step. Put every concrete value in the goal (places, dates, names, filters, and when to stop). Use `jev_observe` for a fast indexed read of what's actionable, `jev_extract` to get values off the page as JSON, `jev_step` to supervise one decision at a time, and the full Playwright-shaped set (browser_snapshot, browser_click, browser_type, browser_take_screenshot, browser_evaluate…) for anything Jev reports BLOCKED on — frames, canvas, uploads, odd keyboard widgets — then hand back to jev_run. DONE is the model's claim: check the page yourself before telling me it worked. Work in the tab I'm on unless I say otherwise; you're acting as me, signed in as me.
        """
    }

    // MARK: - starting and stopping

    func start(for browser: Browser) {
        self.browser = browser
        apply()
    }

    private func apply() {
        stop(keepingState: true)
        guard config.enabled, browser != nil else { running = false; return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Loopback only. Nothing on the network can reach this, whatever
            // the firewall says.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: config.port) ?? 4123)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        self.trouble = nil
                    case .failed(let error):
                        self.running = false
                        self.trouble = "Couldn't listen on port \(self.config.port): \(error.localizedDescription)"
                    case .cancelled:
                        self.running = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            trouble = "Couldn't open the agent port: \(error.localizedDescription)"
            running = false
        }
    }

    func stop(keepingState: Bool = false) {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections = [:]
        running = false
        if !keepingState { trouble = nil }
    }

    private func accept(_ connection: NWConnection) {
        let wrapped = Connection(connection) { [weak self] request, answer in
            guard let self else { answer(HTTPResponse(status: 503, body: Data())); return }
            self.route(request, answer)
        } gone: { [weak self] id in
            self?.connections[id] = nil
        }
        connections[wrapped.id] = wrapped
        wrapped.open()
    }

    // MARK: - HTTP

    private func route(_ request: HTTPRequest, _ answer: @escaping (HTTPResponse) -> Void) {
        // A page in some other browser must never be able to reach in here:
        // a browser sends Origin, a proper MCP client does not.
        if let origin = request.headers["origin"]?.lowercased(),
           !(origin.contains("://127.0.0.1") || origin.contains("://localhost")) {
            answer(HTTPResponse(status: 403, json: ["error": "forbidden origin"]))
            return
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        if path == "/" || path == "/health" {
            answer(HTTPResponse(status: 200, json: ["name": "copper", "version": Fork.version, "mcp": MCP.path, "running": running]))
            return
        }
        guard path == MCP.path else {
            answer(HTTPResponse(status: 404, json: ["error": "not found"]))
            return
        }
        guard authorised(request) else {
            answer(HTTPResponse(status: 401, json: ["error": "bearer token required — Settings › Agents"]))
            return
        }
        switch request.method {
        case "POST":
            guard let body = try? JSONSerialization.jsonObject(with: request.body) else {
                answer(HTTPResponse(status: 400, jsonrpcError: nil, code: -32700, message: "Parse error"))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let one = body as? [String: Any] {
                    if let reply = await self.handle(one) {
                        answer(HTTPResponse(status: 200, json: reply))
                    } else {
                        answer(HTTPResponse(status: 202, body: Data()))
                    }
                } else if let many = body as? [[String: Any]] {
                    var replies: [[String: Any]] = []
                    for one in many { if let reply = await self.handle(one) { replies.append(reply) } }
                    answer(replies.isEmpty ? HTTPResponse(status: 202, body: Data()) : HTTPResponse(status: 200, jsonArray: replies))
                } else {
                    answer(HTTPResponse(status: 400, jsonrpcError: nil, code: -32600, message: "Invalid request"))
                }
            }
        case "GET":
            // No server-to-client stream; the spec lets a server say so.
            answer(HTTPResponse(status: 405, json: ["error": "no event stream — POST JSON-RPC messages here"]))
        case "DELETE":
            answer(HTTPResponse(status: 200, body: Data()))
        default:
            answer(HTTPResponse(status: 405, json: ["error": "method not allowed"]))
        }
    }

    private func authorised(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"] else { return false }
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return !config.token.isEmpty && parts[1] == config.token
    }

    // MARK: - JSON-RPC

    /// One message in, one reply out — or none, for a notification.
    func handle(_ message: [String: Any]) async -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        func reply(_ result: [String: Any]) -> [String: Any]? {
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        }
        func fail(_ code: Int, _ text: String) -> [String: Any]? {
            guard let id else { return nil }
            return ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = MCP.protocolVersions.contains(asked) ? asked : "2025-06-18"
            return reply([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false], "resources": [:], "prompts": [:]],
                "serverInfo": ["name": "copper", "version": Fork.version],
                "instructions": Tools.instructions(jev: config.jev),
            ])
        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
            return nil
        case "ping":
            return reply([:])
        case "tools/list":
            return reply(["tools": Tools.catalogue(jev: config.jev)])
        case "tools/call":
            guard let browser else { return fail(-32000, "Copper has no window") }
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            calls += 1
            lastTool = name
            if config.announces { browser.announce("Agent · \(name)") }
            do {
                let content = try await Tools.call(name, arguments, in: browser)
                return reply(["content": content.map(\.json), "isError": false])
            } catch {
                let text = (error as? Tools.Failure)?.text ?? error.localizedDescription
                return reply(["content": [["type": "text", "text": text]], "isError": true])
            }
        case "resources/list":
            return reply(["resources": []])
        case "resources/templates/list":
            return reply(["resourceTemplates": []])
        case "prompts/list":
            return reply(["prompts": []])
        case "logging/setLevel":
            return reply([:])
        default:
            return fail(-32601, "Method not found: \(method)")
        }
    }

    // MARK: - bench

    func bench(_ request: [String: Any]) -> [String: Any] {
        switch request["op"] as? String ?? "" {
        case "on": config.enabled = true
        case "off": config.enabled = false
        case "rotate": rotateToken()
        case "jev": config.jev = (request["arg"] as? String ?? "on") != "off"
        default: break
        }
        return ["enabled": config.enabled, "running": running, "port": Int(config.port), "endpoint": endpoint, "calls": calls, "last": lastTool, "trouble": trouble ?? "",
                "jev": config.jev, "jevKey": Intelligence.shared.jevReady, "jevLast": jevNote]
    }
}

// MARK: - one connection

/// Reads HTTP/1.1 requests off one socket, one after another, and writes
/// the replies. Small on purpose: the requests are a few kilobytes of JSON
/// from a client on this machine.
final class Connection {
    let id: ObjectIdentifier
    private let connection: NWConnection
    private var buffer = Data()
    private let handle: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private let gone: (ObjectIdentifier) -> Void
    private var closed = false

    init(_ connection: NWConnection, handle: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void, gone: @escaping (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.id = ObjectIdentifier(connection)
        self.handle = handle
        self.gone = gone
    }

    func open() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: .main)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > 8_000_000 {
                self.write(HTTPResponse(status: 413, json: ["error": "request too large"]), thenClose: true)
                return
            }
            self.drain()
            if complete || error != nil { self.close(); return }
            self.read()
        }
    }

    /// Every whole request in the buffer, in order.
    private func drain() {
        while let request = HTTPRequest.take(from: &buffer) {
            let wantsClose = request.headers["connection"]?.lowercased() == "close"
            handle(request) { [weak self] response in
                self?.write(response, thenClose: wantsClose)
            }
        }
    }

    private func write(_ response: HTTPResponse, thenClose: Bool) {
        guard !closed else { return }
        connection.send(content: response.bytes, completion: .contentProcessed { [weak self] _ in
            if thenClose { self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        gone(id)
    }
}

// MARK: - HTTP, the little that is needed

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// One request off the front of the buffer, if a whole one is there.
    static func take(from buffer: inout Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        lines.removeFirst()
        let words = first.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else {
            buffer.removeAll()
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        let bodyStart = end.upperBound
        let bodyEnd = bodyStart + length
        guard buffer.endIndex >= bodyEnd else { return nil }
        let body = Data(buffer[bodyStart..<bodyEnd])
        // A fresh Data, so indices start at zero again for the next request.
        buffer = Data(buffer[bodyEnd...])
        return HTTPRequest(method: words[0].uppercased(), path: words[1], headers: headers, body: body)
    }
}

struct HTTPResponse {
    let status: Int
    let body: Data
    var contentType = "application/json"

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    init(status: Int, json: [String: Any]) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    }

    init(status: Int, jsonArray: [[String: Any]]) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: jsonArray)) ?? Data("[]".utf8)
    }

    init(status: Int, jsonrpcError id: Any?, code: Int, message: String) {
        self.status = status
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
        self.body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static let reasons: [Int: String] = [
        200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable",
    ]

    var bytes: Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reasons[status] ?? "OK")\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
