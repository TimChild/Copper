import Foundation

// The models Copper can ask, and the keys that let it. Nothing here is
// used until a key is pasted in Settings › Intelligence; until then every
// caller sees `configured == false` and stays local, which keeps upstream's
// promise that nothing leaves the Mac unless you set it up.
//
// Two lanes, on purpose:
//   - Jev (TypeSafe's System One model) answers typed questions — pick one of
//     these, how likely is this — in ~200 ms with a calibrated confidence.
//     It is the fast lane for anything that can be phrased as a choice.
//   - The router (a LiteLLM gateway, OpenAI-compatible) is the slow lane:
//     free-form judgement when Jev is unsure or when something has to be
//     *named*, which a closed set can't do.

@MainActor
final class Intelligence: ObservableObject {
    static let shared = Intelligence()

    /// where the model comes from.
    enum Lane: String, Codable, CaseIterable, Identifiable {
        case key
        case claude
        var id: String { rawValue }
        var title: String {
            switch self {
            case .key: return "API key"
            case .claude: return "Claude account"
            }
        }
    }

    /// the three sizes, shared by every model caller.
    enum Tier: String, Codable, CaseIterable, Identifiable {
        case haiku, sonnet, opus
        var id: String { rawValue }
        var title: String {
            switch self {
            case .haiku: return "Haiku"
            case .sonnet: return "Sonnet"
            case .opus: return "Opus"
            }
        }
        var blurb: String {
            switch self {
            case .haiku: return "Quick"
            case .sonnet: return "The balance"
            case .opus: return "Thinks hardest"
            }
        }
    }

    struct Keys: Codable, Equatable {
        var jevKey = ""
        var jevModel = "jev-latest"
        var jevEndpoint = "https://api.typesafe.ai/v1/systemone"
        var routerKey = ""
        var routerURL = "https://llm.dev.exowatt.com"
        var routerModel = "sonnet"
        var lane: Lane = .key
        var tier: Tier = .sonnet
        /// tier.rawValue → model id at Anthropic (Claude account lane).
        var claudeModels: [String: String] = Keys.defaultClaudeModels
        /// tier.rawValue → model name on the gateway (API key lane).
        var routerModels: [String: String] = Keys.defaultRouterModels
        static let defaultClaudeModels = [
            "haiku": "claude-haiku-4-5",
            "sonnet": "claude-sonnet-5",
            "opus": "claude-opus-5-5",
        ]
        static let defaultRouterModels = ["haiku": "haiku", "sonnet": "sonnet", "opus": "opus"]
        /// The small model Jev mode asks to write field values (TYPE_TEXT).
        /// Empty means the router model; a small fast one is the point.
        var textModel = ""

        init() {}

        // Lenient: a field added later must never make an older
        // intelligence.json unreadable — that would drop the keys.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let fresh = Keys()
            jevKey = try c.decodeIfPresent(String.self, forKey: .jevKey) ?? fresh.jevKey
            jevModel = try c.decodeIfPresent(String.self, forKey: .jevModel) ?? fresh.jevModel
            jevEndpoint = try c.decodeIfPresent(String.self, forKey: .jevEndpoint) ?? fresh.jevEndpoint
            routerKey = try c.decodeIfPresent(String.self, forKey: .routerKey) ?? fresh.routerKey
            routerURL = try c.decodeIfPresent(String.self, forKey: .routerURL) ?? fresh.routerURL
            routerModel = try c.decodeIfPresent(String.self, forKey: .routerModel) ?? fresh.routerModel
            lane = try c.decodeIfPresent(Lane.self, forKey: .lane) ?? fresh.lane
            tier = try c.decodeIfPresent(Tier.self, forKey: .tier) ?? fresh.tier
            var decodedClaude = Keys.defaultClaudeModels
            if let saved = try c.decodeIfPresent([String: String].self, forKey: .claudeModels) {
                decodedClaude.merge(saved) { _, value in value }
            }
            claudeModels = decodedClaude
            var decodedRouter = Keys.defaultRouterModels
            let hadRouterModels = c.contains(.routerModels)
            if let saved = try c.decodeIfPresent([String: String].self, forKey: .routerModels) {
                decodedRouter.merge(saved) { _, value in value }
            } else if !hadRouterModels,
                      ![Tier.haiku.rawValue, Tier.sonnet.rawValue, Tier.opus.rawValue].contains(routerModel) {
                decodedRouter[Tier.sonnet.rawValue] = routerModel
            }
            routerModels = decodedRouter
            textModel = try c.decodeIfPresent(String.self, forKey: .textModel) ?? fresh.textModel
        }
    }

    @Published var keys: Keys { didSet { if keys != oldValue, !loading { save() } } }

    /// True while `reload()` assigns what it read: that is the file, and
    /// writing it straight back would only race whoever just wrote it.
    private var loading = false
    private var hangup: DispatchSourceSignal?

    /// the lane and tier selected for every model caller.
    var lane: Lane { keys.lane }
    var tier: Tier { keys.tier }

    /// what Jev mode types with: the text model when one is named, else the chosen model.
    var textModelName: String { keys.textModel.trimmingCharacters(in: .whitespaces).isEmpty ? model() : keys.textModel }

    /// Whether Jev can be asked at all.
    var jevReady: Bool { !keys.jevKey.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Whether the router can be asked at all.
    var routerReady: Bool { !keys.routerKey.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: keys.routerURL) != nil }
    /// Whether the active model lane can be asked at all.
    var claudeReady: Bool { ClaudeAccount.shared.signedIn }
    var modelReady: Bool { lane == .key ? routerReady : claudeReady }
    var configured: Bool { jevReady || modelReady }

    /// resolve a tier name or pass through a full model name.
    func model(_ named: String? = nil, tier: Tier? = nil) -> String {
        let raw = named ?? ""
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty {
            if let namedTier = Tier(rawValue: candidate.lowercased()) {
                return model(for: namedTier)
            }
            return raw
        }
        return model(for: tier ?? self.tier)
    }

    private func model(for tier: Tier) -> String {
        let map = lane == .claude ? keys.claudeModels : keys.routerModels
        let defaults = lane == .claude ? Keys.defaultClaudeModels : Keys.defaultRouterModels
        return map[tier.rawValue] ?? defaults[tier.rawValue] ?? tier.rawValue
    }

    var modelName: String { model() }

    /// one short line for menus and headers.
    var accessLine: String {
        guard modelReady else { return "Not set up" }
        switch lane {
        case .key:
            let host = URL(string: keys.routerURL)?.host ?? keys.routerURL
            return "API key · \(host)"
        case .claude:
            return "Claude account · \(ClaudeAccount.shared.email)"
        }
    }

    private static var file: URL { Store.file("intelligence.json") }

    private init() {
        if let data = try? Data(contentsOf: Intelligence.file),
           let saved = try? JSONDecoder().decode(Keys.self, from: data) {
            keys = saved
        } else {
            keys = Keys()
        }
    }

    // MARK: - outside writers

    /// intelligence.json, read again. An external daemon writes keys it was
    /// provisioned with into the file, then signals (SIGHUP) or calls
    /// `copper intelligence reload`, so nobody restarts the browser for a key.
    @discardableResult
    func reload() -> Bool {
        guard let data = try? Data(contentsOf: Intelligence.file),
              let saved = try? JSONDecoder().decode(Keys.self, from: data) else { return false }
        loading = true
        keys = saved
        loading = false
        return true
    }

    /// SIGHUP → reload. SIGHUP's default is to end the process, so it is
    /// ignored first and taken as an event on the main queue instead.
    func watchForReload() {
        guard hangup == nil else { return }
        signal(SIGHUP, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let ok = Intelligence.shared.reload()
                let line = ok
                    ? "intelligence.json reloaded on SIGHUP — jevReady \(Intelligence.shared.jevReady), routerReady \(Intelligence.shared.routerReady)"
                    : "SIGHUP: intelligence.json missing or unreadable; keys unchanged"
                FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) copper: \(line)\n".utf8))
            }
        }
        source.resume()
        hangup = source
    }

    /// readiness and the non-secret settings. Never a key.
    var status: [String: Any] {
        ["jevReady": jevReady, "routerReady": routerReady, "routerURL": keys.routerURL,
         "routerModel": keys.routerModel, "jevModel": keys.jevModel,
         "lane": lane.rawValue, "tier": tier.rawValue, "model": modelName,
         "modelReady": modelReady, "claudeReady": claudeReady,
         "claudeAccount": ClaudeAccount.shared.email]
    }

    /// The loopback server's `copper/intelligence` method (`copper
    /// intelligence …`). `set` takes any of jevKey, routerKey, routerURL,
    /// routerModel, textModel and writes through `keys`, so the file is
    /// saved 0600 the same way Settings saves it. Answers name what changed,
    /// never its value.
    func control(_ params: [String: Any]) -> [String: Any] {
        switch params["op"] as? String ?? "status" {
        case "status":
            return status
        case "reload":
            var out = status
            out["reloaded"] = reload()
            return out
        case "set":
            var next = keys
            var applied: [String] = []
            var problem: String?
            func take(_ name: String, _ apply: (String) -> Void) {
                guard problem == nil, let raw = params[name] else { return }
                guard let value = raw as? String else {
                    problem = "\(name) must be a string"
                    return
                }
                apply(value.trimmingCharacters(in: .whitespacesAndNewlines))
                applied.append(name)
            }
            if let raw = params["lane"] {
                guard let text = raw as? String, let value = Lane(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    return ["error": "lane must be key or claude"]
                }
                next.lane = value
                applied.append("lane")
            }
            if let raw = params["tier"] {
                guard let text = raw as? String, let value = Tier(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                    return ["error": "tier must be haiku, sonnet or opus"]
                }
                next.tier = value
                applied.append("tier")
            }
            if let raw = params["routerURL"] {
                guard let text = raw as? String else { return ["error": "routerURL must be a string"] }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    return ["error": "routerURL must be an http(s) URL"]
                }
            }
            take("jevKey") { next.jevKey = $0 }
            take("routerKey") { next.routerKey = $0 }
            take("routerURL") { next.routerURL = $0 }
            take("textModel") { next.textModel = $0 }
            take("routerModel") {
                next.routerModel = $0
                next.routerModels[next.tier.rawValue] = $0
            }
            let modelFields: [(String, Tier)] = [("haikuModel", .haiku), ("sonnetModel", .sonnet), ("opusModel", .opus)]
            for (name, modelTier) in modelFields {
                take(name) { value in
                    if next.lane == .claude {
                        next.claudeModels[modelTier.rawValue] = value
                    } else {
                        next.routerModels[modelTier.rawValue] = value
                    }
                }
            }
            if let problem { return ["error": problem] }
            guard !applied.isEmpty else {
                return ["error": "set needs at least one of lane, tier, jevKey, routerKey, routerURL, routerModel, haikuModel, sonnetModel, opusModel, textModel"]
            }
            keys = next
            var out = status
            out["applied"] = applied
            return out
        case let op:
            return ["error": "unknown intelligence op \(op) (status, set, reload)"]
        }
    }

    /// Keys are secrets: the file is this user's alone (0600), and it is
    /// never the session or the settings, which other things read and write.
    private func save() {
        let file = Intelligence.file
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// MARK: - Jev

/// One System One call. `state` is whatever the question is about; each
/// question is a `choice` (pick one of these), a `score` (where on this
/// rubric) or a `noul` (how likely is this true). Text only, no streaming,
/// one round trip — see https://docs.typesafe.ai.
enum Jev {
    struct Choice {
        let key: String
        let confidence: Double
        let probabilities: [String: Double]
    }

    struct Answer {
        var choices: [String: Choice] = [:]
        var nouls: [String: Double] = [:]
        var scores: [String: Double] = [:]
        var latencyMs: Double = 0
        var inputTokens = 0
    }

    struct Failure: LocalizedError {
        let kind: String
        let detail: String
        var errorDescription: String? { detail.isEmpty ? kind : "\(kind): \(detail)" }
    }

    static func choice(_ instructions: String, _ criteria: [String: String]) -> [String: Any] {
        ["type": "choice", "instructions": instructions, "criteria": criteria]
    }

    static func noul(_ instructions: String) -> [String: Any] {
        ["type": "noul", "instructions": instructions]
    }

    static func score(_ instructions: String, _ levels: [String]) -> [String: Any] {
        ["type": "score", "instructions": instructions, "criteria": levels]
    }

    /// Ask, with a hard budget. Anything but a clean 200 with `answers`
    /// throws; the caller decides whether to fail open to the router.
    static func ask(state: Any, questions: [String: Any], keys: Intelligence.Keys, timeout: TimeInterval = 4) async throws -> Answer {
        guard !keys.jevKey.isEmpty else { throw Failure(kind: "not_configured", detail: "No Jev key — Settings › Intelligence") }
        guard let url = URL(string: keys.jevEndpoint) else { throw Failure(kind: "bad_endpoint", detail: keys.jevEndpoint) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(keys.jevKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": keys.jevModel, "state": state, "questions": questions])

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = Date().timeIntervalSince(started) * 1000
        guard let http = response as? HTTPURLResponse else { throw Failure(kind: "transport", detail: "no HTTP response") }
        guard http.statusCode == 200 else {
            throw Failure(kind: "http_\(http.statusCode)", detail: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = payload["answers"] as? [String: Any]
        else { throw Failure(kind: "bad_response", detail: "no answers in body") }

        var out = Answer(latencyMs: latency)
        if let usage = payload["usage"] as? [String: Any] { out.inputTokens = (usage["input_tokens"] as? Int) ?? 0 }
        for (name, raw) in answers {
            guard let a = raw as? [String: Any] else { continue }
            if let picked = a["choice"] as? String {
                var probabilities: [String: Double] = [:]
                for (k, v) in (a["probabilities"] as? [String: Any]) ?? [:] { probabilities[k] = (v as? NSNumber)?.doubleValue ?? 0 }
                out.choices[name] = Choice(key: picked, confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? 0, probabilities: probabilities)
            } else if let p = a["noul"] as? NSNumber {
                out.nouls[name] = p.doubleValue
            } else if let s = a["score"] as? NSNumber {
                out.scores[name] = s.doubleValue
            }
        }
        return out
    }
}

// MARK: - the router

/// The slow lane: one chat completion against an OpenAI-compatible gateway
/// (LiteLLM, here), asked for JSON and read leniently — fences and preambles
/// stripped — because not every model behind a router honours a format flag.
enum Router {
    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    struct Reply {
        let json: [String: Any]
        let text: String
        let latencyMs: Double
        let model: String
    }

    static func ask(system: String, user: String, keys: Intelligence.Keys, timeout: TimeInterval = 20, maxTokens: Int = 400, model override: String? = nil) async throws -> Reply {
        if keys.lane == .claude {
            let token = try await ClaudeAccount.shared.token()
            let model = await MainActor.run { Intelligence.shared.model(override) }
            do {
                return try await Claude.ask(token: token, model: model, system: system, user: user, timeout: timeout, maxTokens: maxTokens)
            } catch let failure as Claude.Failure where failure.status == 401 {
                let refreshed = try await ClaudeAccount.shared.refreshNow()
                return try await Claude.ask(token: refreshed, model: model, system: system, user: user, timeout: timeout, maxTokens: maxTokens)
            }
        }

        guard !keys.routerKey.isEmpty else { throw Failure(detail: "No router key — Settings › Intelligence") }
        guard let base = URL(string: keys.routerURL) else { throw Failure(detail: "Bad router address: \(keys.routerURL)") }
        let url = base.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(keys.routerKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        let chosen = await MainActor.run { Intelligence.shared.model(override) }
        let body: [String: Any] = [
            "model": chosen,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = Date().timeIntervalSince(started) * 1000
        guard let http = response as? HTTPURLResponse else { throw Failure(detail: "no HTTP response") }
        guard http.statusCode == 200 else {
            throw Failure(detail: "router \(http.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { throw Failure(detail: "router answered with no choices") }
        // Content is a string for chat models; a few gateways hand back a
        // list of parts, of which the text ones are what we want.
        var text = ""
        if let s = message["content"] as? String { text = s }
        else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        let model = (payload["model"] as? String) ?? chosen
        return Reply(json: Router.json(in: text), text: text, latencyMs: latency, model: model)
    }

    /// The first JSON object in a reply, fences and chatter around it ignored.
    static func json(in text: String) -> [String: Any] {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return [:] }
        let slice = String(text[open...close])
        if let data = slice.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return [:]
    }
}
