import Foundation

// The wire of the agent link, with nothing of the app in it: the SSE
// reader, the frames that come down it, the frames that go back up, and the
// lenient readers for the service's objects. Foundation only, on purpose —
// it compiles on its own next to a test file, so the parsing is checked
// without a window, a token or a network. Link.swift does the talking.

enum LinkWire {
    // MARK: - bytes to lines

    /// Splits a byte stream into lines. `URLSession.AsyncBytes.lines` drops
    /// empty lines, and in SSE the empty line is the whole point — it ends
    /// an event — so the stream is read a byte at a time through this.
    struct Lines {
        private var buffer: [UInt8] = []
        /// A line longer than this is garbage or an attack; it is dropped.
        var limit = 8 << 20

        init() {}

        /// The line this byte completes, if it completes one. `\n` and
        /// `\r\n` both end a line.
        mutating func push(_ byte: UInt8) -> String? {
            if byte == 0x0A {
                if buffer.last == 0x0D { buffer.removeLast() }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll(keepingCapacity: true)
                return line
            }
            if buffer.count < limit { buffer.append(byte) }
            return nil
        }

        /// Whatever was left without a newline, at the end of the stream.
        mutating func finish() -> String? {
            guard !buffer.isEmpty else { return nil }
            defer { buffer.removeAll() }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    // MARK: - lines to events

    struct Event: Equatable, Sendable {
        var event: String
        var data: String
        var id: String?
    }

    /// Server-sent events, the part of the spec a frame stream uses: `event:`
    /// and `data:` (several `data:` lines join with a newline), `id:`, a
    /// blank line to dispatch, `:` lines are comments (keep-alives).
    struct SSE {
        private var event = ""
        private var data: [String] = []
        private var id: String?
        private var any = false

        init() {}

        mutating func feed(_ raw: String) -> Event? {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { return dispatch() }
            if line.hasPrefix(":") { return nil }
            let field: Substring
            var value: Substring
            if let colon = line.firstIndex(of: ":") {
                field = line[line.startIndex..<colon]
                value = line[line.index(after: colon)...]
                if value.hasPrefix(" ") { value = value.dropFirst() }
            } else {
                field = Substring(line)
                value = ""
            }
            switch field {
            case "event": event = String(value); any = true
            case "data": data.append(String(value)); any = true
            case "id": id = String(value)
            default: break // retry: and anything unknown
            }
            return nil
        }

        /// A last event the stream ended in the middle of, if it has data.
        mutating func finish() -> Event? { data.isEmpty ? nil : dispatch() }

        private mutating func dispatch() -> Event? {
            defer { event = ""; data = []; any = false }
            guard any else { return nil }
            return Event(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"), id: id)
        }
    }

    // MARK: - the service's objects, read leniently

    /// The link as the service describes it. Only what Copper shows.
    struct Link: Equatable {
        var id: String
        var name: String
        var label: String
        var state: String
        var online: Bool
        var device: String?
        var revoked: Bool

        init?(_ any: Any?) {
            guard let o = any as? [String: Any], let id = o["id"] as? String, !id.isEmpty else { return nil }
            self.id = id
            name = o["name"] as? String ?? ""
            label = o["label"] as? String ?? ""
            state = o["state"] as? String ?? ""
            online = o["online"] as? Bool ?? (state == "online")
            device = o["device"] as? String
            revoked = state == "revoked" || (o["revokedAt"].map { !($0 is NSNull) } ?? false)
        }
    }

    /// One bot's permission to use the link.
    struct Grant: Identifiable, Equatable {
        var botId: String
        var handle: String
        var name: String
        var enabled: Bool
        var toolAllowlist: [String]
        var id: String { botId }

        init(botId: String, handle: String, name: String, enabled: Bool, toolAllowlist: [String] = []) {
            self.botId = botId
            self.handle = handle
            self.name = name
            self.enabled = enabled
            self.toolAllowlist = toolAllowlist
        }

        /// `{botId, enabled, toolAllowlist, bot: {id, handle, name}}`, or the
        /// same flattened.
        init?(_ any: Any?) {
            guard let o = any as? [String: Any] else { return nil }
            let bot = o["bot"] as? [String: Any] ?? [:]
            guard let botId = (o["botId"] as? String) ?? (bot["id"] as? String), !botId.isEmpty else { return nil }
            self.botId = botId
            handle = LinkWire.bare((bot["handle"] as? String) ?? (o["handle"] as? String) ?? (o["botHandle"] as? String) ?? "")
            name = (bot["name"] as? String) ?? (o["name"] as? String) ?? (o["botName"] as? String) ?? ""
            enabled = o["enabled"] as? Bool ?? true
            toolAllowlist = o["toolAllowlist"] as? [String] ?? []
        }

        var json: [String: Any] {
            ["botId": botId, "handle": handle, "name": name, "enabled": enabled, "toolAllowlist": toolAllowlist]
        }
    }

    /// One of the owner's bots, for "Grant a bot…".
    struct Bot: Identifiable, Equatable {
        var id: String
        var handle: String
        var name: String

        init(id: String, handle: String, name: String) {
            self.id = id
            self.handle = handle
            self.name = name
        }

        init?(_ any: Any?) {
            guard let o = any as? [String: Any], let id = (o["id"] as? String) ?? (o["botId"] as? String), !id.isEmpty else { return nil }
            self.id = id
            handle = LinkWire.bare((o["handle"] as? String) ?? (o["slug"] as? String) ?? "")
            name = (o["name"] as? String) ?? (o["displayName"] as? String) ?? ""
        }
    }

    /// One tool call a bot made through the link: from a `request` frame as
    /// it is answered, or from the service's audit (`GET …/calls`).
    struct Call: Identifiable, Equatable {
        var id: String
        var handle: String
        var tool: String
        var ok: Bool
        var at: Date
        var ms: Int
        var error: String?

        init(id: String = UUID().uuidString, handle: String, tool: String, ok: Bool, at: Date, ms: Int, error: String? = nil) {
            self.id = id
            self.handle = handle
            self.tool = tool
            self.ok = ok
            self.at = at
            self.ms = ms
            self.error = error
        }

        /// `{id, botId, tool, ok, durationMs, error, at, bot: {handle}}`.
        init?(_ any: Any?) {
            guard let o = any as? [String: Any], let tool = o["tool"] as? String else { return nil }
            let bot = o["bot"] as? [String: Any] ?? [:]
            id = o["id"] as? String ?? UUID().uuidString
            handle = LinkWire.bare((bot["handle"] as? String) ?? (o["botHandle"] as? String) ?? (o["botId"] as? String) ?? "")
            self.tool = tool
            ok = o["ok"] as? Bool ?? true
            ms = (o["durationMs"] as? Int) ?? (o["durationMs"] as? NSNumber)?.intValue ?? 0
            error = o["error"] as? String
            at = (o["at"] as? String).flatMap(LinkWire.date) ?? Date()
        }

        var json: [String: Any] {
            var out: [String: Any] = ["bot": handle, "tool": tool, "ok": ok, "ms": ms, "at": ISO8601DateFormatter().string(from: at)]
            if let error { out["error"] = error }
            return out
        }
    }

    /// ISO 8601, with or without fractional seconds (JavaScript's
    /// `toISOString` has them; plenty of other writers do not).
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func calls(_ any: Any?) -> [Call] { items(any).compactMap { Call($0) } }

    /// A list the way the service returns one — `{items: [...]}` — or a few
    /// shapes it might grow into, so a rename does not empty the screen.
    static func items(_ any: Any?, _ keys: [String] = ["items", "bots", "grants", "calls", "data"]) -> [Any] {
        if let array = any as? [Any] { return array }
        guard let object = any as? [String: Any] else { return [] }
        for key in keys { if let array = object[key] as? [Any] { return array } }
        return []
    }

    static func grants(_ any: Any?) -> [Grant] { items(any).compactMap { Grant($0) } }
    static func bots(_ any: Any?) -> [Bot] { items(any).compactMap { Bot($0) } }

    /// `@felix` and `felix` are the same bot.
    static func bare(_ handle: String) -> String {
        handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
    }

    // MARK: - frames down

    struct Caller: Equatable {
        var botId: String
        var botHandle: String
        var botName: String
        var sessionId: String?
        var runId: String?
    }

    struct Request {
        var id: String
        var method: String
        var params: [String: Any]
        var caller: Caller
        var deadlineAt: String?

        /// The JSON-RPC message this becomes for Copper's own MCP server.
        /// The request id rides as the JSON-RPC id, so the reply is never
        /// mistaken for a notification.
        var message: [String: Any] {
            ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        }

        /// The tool a `tools/call` names; nil for anything else.
        var tool: String? {
            method == "tools/call" ? (params["name"] as? String) : nil
        }
    }

    enum Frame {
        case hello(link: Link?, grants: [Grant])
        case request(Request)
        case grants([Grant])
        case superseded
        case revoked
        case ping
        case unknown(String)
    }

    /// One SSE event as a frame. The type is the SSE `event:`; a stream that
    /// only sends `message` events with `{type, …}` data is read the same.
    static func frame(_ event: Event) -> Frame {
        let object = (event.data.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        var type = event.event
        if type == "message", let inner = object["type"] as? String { type = inner }
        switch type {
        case "hello":
            return .hello(link: Link(object["link"]), grants: grants(object["grants"]))
        case "request":
            guard let id = (object["id"] as? String) ?? (object["requestId"] as? String), !id.isEmpty,
                  let method = object["method"] as? String, !method.isEmpty
            else { return .unknown("request without id or method") }
            let c = object["caller"] as? [String: Any] ?? [:]
            let caller = Caller(botId: c["botId"] as? String ?? "",
                                botHandle: bare(c["botHandle"] as? String ?? ""),
                                botName: c["botName"] as? String ?? "",
                                sessionId: c["sessionId"] as? String,
                                runId: c["runId"] as? String)
            return .request(Request(id: id, method: method, params: object["params"] as? [String: Any] ?? [:],
                                    caller: caller, deadlineAt: object["deadlineAt"] as? String))
        case "grants":
            return .grants(grants(object))
        case "superseded": return .superseded
        case "revoked": return .revoked
        case "ping": return .ping
        default: return .unknown(type)
        }
    }

    // MARK: - frames up

    /// What goes back for one request, from the JSON-RPC reply Copper's MCP
    /// server gave (nil for a notification — an empty result, so the waiter
    /// is not left hanging).
    static func reply(requestId: String, rpc: [String: Any]?) -> [String: Any] {
        if let error = rpc?["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? (error["code"] as? NSNumber)?.intValue ?? -32000
            let message = error["message"] as? String ?? "error"
            return ["type": "reply", "requestId": requestId, "error": ["code": code, "message": message]]
        }
        return ["type": "reply", "requestId": requestId, "result": rpc?["result"] as? [String: Any] ?? [:]]
    }

    static func failure(requestId: String, code: Int, message: String) -> [String: Any] {
        ["type": "reply", "requestId": requestId, "error": ["code": code, "message": message]]
    }

    static let heartbeat: [String: Any] = ["type": "heartbeat"]

    /// The body of `POST …/frames`.
    static func body(_ frames: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["frames": frames], options: [.sortedKeys])) ?? Data("{\"frames\":[]}".utf8)
    }

    /// Did a `tools/call` go well? A JSON-RPC error or `isError: true` is
    /// a failed call; the first text of the content is the reason.
    static func outcome(_ rpc: [String: Any]?) -> (ok: Bool, error: String?) {
        if let error = rpc?["error"] as? [String: Any] { return (false, error["message"] as? String ?? "error") }
        guard let result = rpc?["result"] as? [String: Any] else { return (true, nil) }
        guard result["isError"] as? Bool == true else { return (true, nil) }
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String
        return (false, text ?? "error")
    }

    // MARK: - the stream, off the main thread

    enum StreamItem: Sendable {
        case refused(Int, Data)
        case opened
        case event(LinkWire.Event)
    }

    /// Reads the frames stream on a background task, a byte at a time into
    /// lines and events, and hands the events over. Cancelling the consumer
    /// cancels the read.
    static func events(for request: URLRequest) -> AsyncThrowingStream<StreamItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 4096 { break }
                        }
                        continuation.yield(.refused(code, body))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.opened)
                    var lines = LinkWire.Lines()
                    var sse = LinkWire.SSE()
                    for try await byte in bytes {
                        if let line = lines.push(byte), let event = sse.feed(line) { continuation.yield(.event(event)) }
                    }
                    if let line = lines.finish(), let event = sse.feed(line) { continuation.yield(.event(event)) }
                    if let event = sse.finish() { continuation.yield(.event(event)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - small words for the screen

    /// 1 s, 2 s, 4 s … never more than 30 s.
    static func backoff(_ attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, min(attempt, 5)))))
    }

    /// `340 ms`, `1.2 s`, `2 min`.
    static func duration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        if ms < 60_000 { return String(format: "%.1f s", Double(ms) / 1000) }
        return "\(ms / 60_000) min"
    }

    /// `just now`, `40 s ago`, `3 min ago`, `2 h ago`, `5 d ago`.
    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86_400 { return "\(s / 3600) h ago" }
        return "\(s / 86_400) d ago"
    }

    /// `https://x.y/` → `https://x.y`, or nil when it is not an address a
    /// token should be sent to: https anywhere, http only to this Mac.
    static func base(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) { return url }
        return nil
    }

    /// A path segment, escaped: ids come from the service, but a slash in
    /// one must never walk the URL somewhere else.
    static func segment(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
