import Foundation

// Copper as an MCP *client*: the servers you already give Claude Code or
// phi, read from the same `mcp.json` shape, so you paste the file you have.
//
//   {
//     "mcpServers": {
//       "feads":  { "type": "http", "url": "https://…/mcp", "headers": { "Authorization": "Bearer ${FEADS_TOKEN}" } },
//       "files":  { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me"] }
//     }
//   }
//
// Two transports, the two the spec has: Streamable HTTP (one POST per
// message; the answer is JSON or a short SSE stream, and a session id may
// ride in a header) and stdio (a child process, one JSON-RPC message per
// line). Each server is asked once for its tools; the agent sees them as
// `<server>__<tool>` beside Copper's own, and a call is routed back by that
// prefix. `${VAR}` in any string is filled from the environment.
//
// The file lives beside the session: Application Support/Copper/mcp.json.

/// One configured server, live or not.
@MainActor
final class Server: ObservableObject, Identifiable {
    let name: String
    let spec: Spec
    @Published private(set) var tools: [[String: Any]] = []
    @Published private(set) var state = "off" // off · connecting · ready · failed: …
    var id: String { name }

    enum Spec {
        case http(url: URL, headers: [String: String])
        case stdio(command: String, args: [String], env: [String: String], cwd: String?)

        var line: String {
            switch self {
            case .http(let url, _): return url.absoluteString
            case .stdio(let command, let args, _, _): return ([command] + args).joined(separator: " ")
            }
        }
    }

    private var transport: Transport?

    init(name: String, spec: Spec) {
        self.name = name
        self.spec = spec
    }

    var ready: Bool { state == "ready" }

    /// Connect, shake hands, fetch the tool list.
    func connect() async {
        state = "connecting"
        tools = []
        let transport: Transport
        switch spec {
        case .http(let url, let headers): transport = HTTPTransport(url: url, headers: headers)
        case .stdio(let command, let args, let env, let cwd): transport = StdioTransport(command: command, args: args, env: env, cwd: cwd)
        }
        self.transport = transport
        do {
            try await transport.start()
            _ = try await transport.request("initialize", [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "copper", "version": Fork.version],
            ], timeout: 20)
            try await transport.notify("notifications/initialized", [:])
            var all: [[String: Any]] = []
            var cursor: String?
            repeat {
                var params: [String: Any] = [:]
                if let cursor { params["cursor"] = cursor }
                let result = try await transport.request("tools/list", params, timeout: 20)
                all += (result["tools"] as? [[String: Any]]) ?? []
                cursor = result["nextCursor"] as? String
            } while cursor != nil && all.count < 500
            tools = all
            state = "ready"
        } catch {
            state = "failed: \(Servers.text(error))"
            transport.stop()
            self.transport = nil
        }
    }

    func disconnect() {
        transport?.stop()
        transport = nil
        state = "off"
        tools = []
    }

    /// One tool call; the content list as MCP hands it back.
    func call(_ tool: String, _ arguments: [String: Any]) async throws -> (content: [[String: Any]], isError: Bool) {
        guard let transport, ready else { throw Servers.Failure(text: "\(name) is not connected (\(state))") }
        let result = try await transport.request("tools/call", ["name": tool, "arguments": arguments], timeout: 120)
        return ((result["content"] as? [[String: Any]]) ?? [], (result["isError"] as? Bool) ?? false)
    }
}

/// All of them, from the file.
@MainActor
final class Servers: ObservableObject {
    static let shared = Servers()

    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    @Published private(set) var all: [Server] = []
    @Published private(set) var trouble: String?
    @Published private(set) var loadedAt: Date?

    static var file: URL { Store.file("mcp.json") }

    private init() {}

    nonisolated static func text(_ error: Error) -> String {
        (error as? Failure)?.text ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    var readyTools: Int { all.reduce(0) { $0 + ($1.ready ? $1.tools.count : 0) } }

    /// The example that is written when there is no file yet, so the shape
    /// is on disk to edit rather than in a doc to find.
    static let example = """
    {
      "mcpServers": {
      }
    }
    """

    /// Read the file, drop every server, connect the ones it names.
    func reload() async {
        for server in all { server.disconnect() }
        all = []
        trouble = nil
        let file = Servers.file
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Servers.example.data(using: .utf8)?.write(to: file, options: .atomic)
            loadedAt = Date()
            return
        }
        guard let data = try? Data(contentsOf: file) else { trouble = "Couldn't read \(file.lastPathComponent)"; return }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            trouble = "\(file.lastPathComponent) is not JSON: \(error.localizedDescription)"
            return
        }
        guard let root = object as? [String: Any],
              let servers = (root["mcpServers"] as? [String: Any]) ?? (root["servers"] as? [String: Any])
        else { trouble = "\(file.lastPathComponent) has no mcpServers"; return }

        var list: [Server] = []
        for name in servers.keys.sorted() {
            guard let raw = servers[name] as? [String: Any] else { continue }
            if (raw["disabled"] as? Bool) == true { continue }
            if let spec = Servers.spec(raw) { list.append(Server(name: Servers.clean(name), spec: spec)) }
        }
        all = list
        loadedAt = Date()
        await withTaskGroup(of: Void.self) { group in
            for server in list { group.addTask { @MainActor in await server.connect() } }
        }
    }

    private static func spec(_ raw: [String: Any]) -> Server.Spec? {
        let type = (raw["type"] as? String)?.lowercased()
        if let urlText = raw["url"] as? String, type == nil || type == "http" || type == "streamable-http" || type == "sse" {
            guard let url = URL(string: expand(urlText)) else { return nil }
            var headers: [String: String] = [:]
            for (k, v) in (raw["headers"] as? [String: String]) ?? [:] { headers[k] = expand(v) }
            return .http(url: url, headers: headers)
        }
        if let command = raw["command"] as? String {
            let args = ((raw["args"] as? [String]) ?? []).map(expand)
            var env: [String: String] = [:]
            for (k, v) in (raw["env"] as? [String: String]) ?? [:] { env[k] = expand(v) }
            return .stdio(command: expand(command), args: args, env: env, cwd: (raw["cwd"] as? String).map(expand))
        }
        return nil
    }

    /// `${HOME}`, `${FEADS_TOKEN}` … from the environment; `~` at the front.
    nonisolated static func expand(_ text: String) -> String {
        var out = text
        let env = ProcessInfo.processInfo.environment
        if out.hasPrefix("~/") { out = (env["HOME"] ?? NSHomeDirectory()) + out.dropFirst() }
        var result = ""
        var rest = Substring(out)
        while let open = rest.range(of: "${") {
            result += rest[rest.startIndex..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: "}") else { result += rest[open.lowerBound...]; rest = ""; break }
            let name = String(after[after.startIndex..<close])
            result += env[name] ?? ""
            rest = after[after.index(after: close)...]
        }
        result += rest
        return result
    }

    /// A server name the model can use in a tool name.
    nonisolated static func clean(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }).lowercased()
    }

    // MARK: - routing

    static let separator = "__"

    /// Every ready server's tools, named for the model.
    var toolsForModel: [[String: Any]] {
        var out: [[String: Any]] = []
        for server in all where server.ready {
            for tool in server.tools {
                guard let name = tool["name"] as? String else { continue }
                var copy = tool
                copy["name"] = server.name + Servers.separator + name
                if let d = tool["description"] as? String { copy["description"] = "[\(server.name)] " + d }
                out.append(copy)
            }
        }
        return out
    }

    /// `server__tool` → the server and its tool's own name.
    func route(_ full: String) -> (Server, String)? {
        guard let range = full.range(of: Servers.separator) else { return nil }
        let name = String(full[full.startIndex..<range.lowerBound])
        let tool = String(full[range.upperBound...])
        guard let server = all.first(where: { $0.name == name }) else { return nil }
        return (server, tool)
    }
}

// MARK: - transports

protocol Transport: AnyObject {
    func start() async throws
    func stop()
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
    func notify(_ method: String, _ params: [String: Any]) async throws
}

/// Streamable HTTP, client side. One POST per message. The reply is a JSON
/// body, or `text/event-stream` with the reply somewhere in its `data:`
/// lines — both are read to the end and the message with our id is taken.
final class HTTPTransport: Transport {
    private let url: URL
    private let headers: [String: String]
    private var session: String?
    private var next = 1
    private let client: URLSession

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 130
        client = URLSession(configuration: config)
    }

    func start() async throws {}

    func stop() {
        if session != nil {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            decorate(&request)
            client.dataTask(with: request).resume()
        }
        session = nil
    }

    private func decorate(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    }

    func notify(_ method: String, _ params: [String: Any]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        decorate(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params])
        _ = try? await client.data(for: request)
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = next
        next += 1
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        decorate(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Servers.Failure(text: "no HTTP response") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty { session = sid }
        guard (200..<300).contains(http.statusCode) else {
            throw Servers.Failure(text: "HTTP \(http.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        var messages: [[String: Any]] = []
        if type.contains("text/event-stream") {
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let d = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: d) {
                    if let one = object as? [String: Any] { messages.append(one) }
                    else if let many = object as? [[String: Any]] { messages += many }
                }
            }
        } else {
            let object = try JSONSerialization.jsonObject(with: data)
            if let one = object as? [String: Any] { messages.append(one) }
            else if let many = object as? [[String: Any]] { messages += many }
        }
        guard let reply = messages.first(where: { ($0["id"] as? NSNumber)?.intValue == id || ($0["id"] as? String) == String(id) }) else {
            throw Servers.Failure(text: "no reply to \(method)")
        }
        if let error = reply["error"] as? [String: Any] {
            throw Servers.Failure(text: (error["message"] as? String) ?? "error \(error["code"] ?? "")")
        }
        return (reply["result"] as? [String: Any]) ?? [:]
    }
}

/// stdio: a child process speaking one JSON-RPC message per line.
final class StdioTransport: Transport {
    private let command: String
    private let args: [String]
    private let env: [String: String]
    private let cwd: String?
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var next = 1
    private let lock = NSLock()
    private var stderrTail = ""

    init(command: String, args: [String], env: [String: String], cwd: String?) {
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
    }

    func start() async throws {
        let process = Process()
        // Through the user's shell, so `npx`, `uvx` and friends resolve the
        // way they do in a terminal; the app's own PATH is bare.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        let quoted = ([command] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        process.arguments = ["-lc", "exec " + quoted]
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: Servers.expand(cwd)) }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { self.failAll("server exited"); return }
            self.feed(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let self, !text.isEmpty else { return }
            self.lock.lock()
            self.stderrTail = String((self.stderrTail + text).suffix(600))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in self?.failAll("server exited") }
        do { try process.run() } catch {
            throw Servers.Failure(text: "couldn't start \(command): \(error.localizedDescription)")
        }
        self.process = process
        self.stdin = input.fileHandleForWriting
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        try? stdin?.close()
        stdin = nil
        failAll("stopped")
    }

    private func failAll(_ why: String) {
        lock.lock()
        let waiting = pending
        pending = [:]
        let tail = stderrTail
        lock.unlock()
        for (_, c) in waiting { c.resume(throwing: Servers.Failure(text: tail.isEmpty ? why : "\(why): \(tail.suffix(200))")) }
    }

    private func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<nl]))
            buffer = Data(buffer[buffer.index(after: nl)...])
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard let id = (object["id"] as? NSNumber)?.intValue ?? (object["id"] as? String).flatMap(Int.init) else { continue }
            lock.lock()
            let c = pending.removeValue(forKey: id)
            lock.unlock()
            guard let c else { continue }
            if let error = object["error"] as? [String: Any] {
                c.resume(throwing: Servers.Failure(text: (error["message"] as? String) ?? "error \(error["code"] ?? "")"))
            } else {
                c.resume(returning: (object["result"] as? [String: Any]) ?? [:])
            }
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let stdin else { throw Servers.Failure(text: "not running") }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    func notify(_ method: String, _ params: [String: Any]) async throws {
        try send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        lock.lock()
        let id = next
        next += 1
        lock.unlock()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: Any], Error>) in
            lock.lock()
            pending[id] = c
            lock.unlock()
            do { try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) } catch {
                lock.lock()
                pending[id] = nil
                lock.unlock()
                c.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let late = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                late?.resume(throwing: Servers.Failure(text: "\(method) timed out after \(Int(timeout)) s"))
            }
        }
    }
}
