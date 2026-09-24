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

    struct Keys: Codable, Equatable {
        var jevKey = ""
        var jevModel = "jev-latest"
        var jevEndpoint = "https://api.typesafe.ai/v1/systemone"
        var routerKey = ""
        var routerURL = "https://llm.dev.exowatt.com"
        var routerModel = "sonnet"
        /// The small model Jev mode asks to write field values (TYPE_TEXT).
        /// Empty means the router model; a small fast one is the point.
        var textModel = ""
        /// Grouping: off, suggest and wait, or just do it.
        var grouping: GroupingMode = .ask
        /// Jev's confidence has to clear this before its pick is taken as is.
        var threshold: Double = 0.6

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
            textModel = try c.decodeIfPresent(String.self, forKey: .textModel) ?? fresh.textModel
            grouping = try c.decodeIfPresent(GroupingMode.self, forKey: .grouping) ?? fresh.grouping
            threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? fresh.threshold
        }
    }

    enum GroupingMode: String, Codable, CaseIterable, Identifiable {
        case off, ask, auto
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .ask: return "Ask"
            case .auto: return "Automatic"
            }
        }
    }

    @Published var keys: Keys { didSet { if keys != oldValue { save() } } }

    /// What Jev mode types with: the text model when one is named, else the router's.
    var textModelName: String { keys.textModel.trimmingCharacters(in: .whitespaces).isEmpty ? keys.routerModel : keys.textModel }

    /// Whether Jev can be asked at all.
    var jevReady: Bool { !keys.jevKey.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Whether the router can be asked at all.
    var routerReady: Bool { !keys.routerKey.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: keys.routerURL) != nil }
    var configured: Bool { jevReady || routerReady }

    private static var file: URL { Store.file("intelligence.json") }

    private init() {
        if let data = try? Data(contentsOf: Intelligence.file),
           let saved = try? JSONDecoder().decode(Keys.self, from: data) {
            keys = saved
        } else {
            keys = Keys()
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
        guard !keys.routerKey.isEmpty else { throw Failure(detail: "No router key — Settings › Intelligence") }
        guard let base = URL(string: keys.routerURL) else { throw Failure(detail: "Bad router address: \(keys.routerURL)") }
        let url = base.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(keys.routerKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("copper/\(Fork.version)", forHTTPHeaderField: "User-Agent")
        let chosen = (override ?? "").trimmingCharacters(in: .whitespaces)
        let body: [String: Any] = [
            "model": chosen.isEmpty ? keys.routerModel : chosen,
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
        let model = (payload["model"] as? String) ?? (chosen.isEmpty ? keys.routerModel : chosen)
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
