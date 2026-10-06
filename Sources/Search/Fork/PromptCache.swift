import Foundation

// Prompt caching on both model lanes. Neither Bedrock (behind the gateway)
// nor Anthropic caches anything on its own: a request has to mark where a
// reusable prefix ends with `cache_control: {"type": "ephemeral"}`, and a
// later request whose prompt starts with exactly the same tokens reads that
// prefix at a tenth of the price instead of paying for it again. An agent
// question re-sends the whole conversation every turn — 40–50k tokens by
// the tenth tool call — so without marks every turn paid full price for
// everything before it.
//
// Where the marks go (at most four, Anthropic's limit):
//   1. the end of the system prompt — with the tools in front of it, the
//      part that is the same for every question;
//   2. the last tool definition — the tools alone;
//   3. the last message — what the next turn reads back;
//   4. the message just before the last assistant reply — the last message
//      of the previous request, which that request wrote to the cache. It
//      carries the same mark it was sent with, so the prefix up to it is
//      the same bytes turn after turn, and the read never depends on how
//      far back the cache looks for an earlier mark.
// A mark moves on as the conversation grows; the marked and unmarked forms
// of a message differ only by the mark itself, because a turn that carries
// marks sends every user and tool message's text as one content part (the
// cache keys on the content, not on where the marks sit).
// One-shot asks (Router.ask, Claude.ask) mark only 1 and 2: their question
// is never sent again, and writing it to the cache costs more than reading
// it would save.
//
// The marks only help if the prefix is byte-stable. The system prompt and
// the tool list carry nothing that changes per turn (the page goes in the
// question), earlier messages are kept as sent, and every body is written
// with sorted keys: a Swift dictionary's order is seeded per instance, so
// the same tool schema or tool_use input rebuilt for the next request came
// out in a different order and missed the cache.
//
// Shapes proven against LiteLLM 1.95 on both Bedrock routes (Converse for
// `opus`, Invoke for `sonnet`) and against Anthropic directly:
//   gateway:  {"role":"system","content":[{"type":"text","text":…,"cache_control":{"type":"ephemeral"}}]}
//             tools[-1] = {"type":"function","function":{…},"cache_control":{"type":"ephemeral"}}
//             last message content → parts, the last part (text or image_url) marked
//   Messages: system[-1], tools[-1] and the last content block of a message
//             (text, image or tool_result) carry "cache_control".
// A model behind the gateway that is not Claude (kimi) refuses the marks
// with an error, so only Claude names get them, and an answer that says
// the marks were the problem (a content-policy fallback to such a model)
// is asked again without them.
enum PromptCache {
    /// Anthropic's ceiling on cache_control marks in one request.
    static let limit = 4

    /// Which marks a request gets.
    enum Marks {
        /// None at all.
        case none
        /// The system prompt and the last tool: a one-shot ask.
        case prefix
        /// Those, plus the last message and the previous request's last
        /// message: an agent turn whose conversation comes back next turn.
        case rolling
    }

    static var mark: [String: Any] { ["type": "ephemeral"] }

    /// Whether a model behind the gateway takes cache_control: any spelling
    /// of a Claude tier does, on either Bedrock route. A custom name may be a
    /// model that refuses the marks (kimi answers 500), so it gets none.
    static func gatewayCaches(_ model: String) -> Bool {
        Intelligence.family(of: model) != nil
    }

    /// Every request body is written with sorted keys, so the same history
    /// and tools are the same bytes on every turn.
    static func json(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Whether an error answer says the marks were the problem: a model that
    /// does not cache, a gateway fallback to one, or too many marks.
    static func refused(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(4000), as: UTF8.self).lowercased()
        return text.contains("prompt caching") || text.contains("cache_control") || text.contains("cachepoint")
    }

    // MARK: - the gateway's chat shape

    /// The chat messages (system first) and tools with the marks for `marks`.
    static func chat(messages: [[String: Any]], tools: [[String: Any]], marks: Marks) -> (messages: [[String: Any]], tools: [[String: Any]]) {
        guard marks != .none else { return (messages, tools) }
        var messages = messages
        var tools = tools
        var used = 0
        if let system = messages.firstIndex(where: { $0["role"] as? String == "system" }),
           let withMark = marked(messages[system]) {
            messages[system] = withMark
            used += 1
        }
        if !tools.isEmpty {
            tools[tools.count - 1]["cache_control"] = mark
            used += 1
        }
        guard marks == .rolling else { return (messages, tools) }
        for index in messages.indices where ["user", "tool"].contains(messages[index]["role"] as? String ?? "") {
            messages[index] = asParts(messages[index])
        }
        for index in rollingIndices(messages.map { $0["role"] as? String ?? "" }) where used < limit {
            guard let withMark = marked(messages[index]) else { continue }
            messages[index] = withMark
            used += 1
        }
        return (messages, tools)
    }

    /// The previous request's last message and this one's, by role: the
    /// message right before the last assistant reply, and the last message.
    /// Only a user or tool message is marked (and never the system prompt).
    static func rollingIndices(_ roles: [String], takes: Set<String> = ["user", "tool"]) -> [Int] {
        guard let last = roles.indices.last else { return [] }
        var out: [Int] = []
        if let reply = roles.lastIndex(of: "assistant"), reply > 0, reply - 1 != last, takes.contains(roles[reply - 1]) {
            out.append(reply - 1)
        }
        if takes.contains(roles[last]) { out.append(last) }
        return out
    }

    /// A message whose content is a string, as one text part (a block, on
    /// the Messages API) — the same tokens, in the one shape a mark can sit
    /// on. Empty text stays as it is: an empty part cannot be marked.
    static func asParts(_ message: [String: Any]) -> [String: Any] {
        guard let text = message["content"] as? String, !text.isEmpty else { return message }
        var message = message
        message["content"] = [["type": "text", "text": text] as [String: Any]]
        return message
    }

    /// A message with its last content part (block) marked; a string
    /// becomes one text part first. Nil when there is nothing a mark can sit
    /// on: empty content, or a thinking block last.
    static func marked(_ message: [String: Any]) -> [String: Any]? {
        var message = asParts(message)
        var content = parts(message["content"])
        guard let last = content.indices.last, markable(content[last]) else { return nil }
        content[last]["cache_control"] = mark
        message["content"] = content
        return message
    }

    // MARK: - Anthropic's Messages shape (the Claude-account lane)

    /// System blocks, messages and tools with the marks for `marks`. The
    /// first system block is the Claude Code identity and stays exactly as
    /// it is; the mark goes on the last one after it.
    static func messages(system: [[String: Any]], messages: [[String: Any]], tools: [[String: Any]], marks: Marks)
        -> (system: [[String: Any]], messages: [[String: Any]], tools: [[String: Any]]) {
        guard marks != .none else { return (system, messages, tools) }
        var system = system
        var messages = messages
        var tools = tools
        var used = 0
        if system.count > 1, markable(system[system.count - 1]) {
            system[system.count - 1]["cache_control"] = mark
            used += 1
        }
        if !tools.isEmpty {
            tools[tools.count - 1]["cache_control"] = mark
            used += 1
        }
        guard marks == .rolling else { return (system, messages, tools) }
        for index in messages.indices where messages[index]["role"] as? String == "user" {
            messages[index] = asParts(messages[index])
        }
        for index in rollingIndices(messages.map { $0["role"] as? String ?? "" }, takes: ["user"]) where used < limit {
            guard let withMark = marked(messages[index]) else { continue }
            messages[index] = withMark
            used += 1
        }
        return (system, messages, tools)
    }

    private static func parts(_ value: Any?) -> [[String: Any]] {
        if let parts = value as? [[String: Any]] { return parts }
        return (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// A block a mark may sit on: not a thinking block, not empty text.
    private static func markable(_ block: [String: Any]) -> Bool {
        switch block["type"] as? String {
        case "thinking", "redacted_thinking": return false
        case "text": return !((block["text"] as? String) ?? "").isEmpty
        case nil: return false
        default: return true
        }
    }

    // MARK: - what the answer says it read

    /// One turn's tokens: everything the prompt held, what was read from the
    /// cache and what was written to it, and the reply.
    static func usage(chat payload: [String: Any]) -> [String: Int]? {
        guard let usage = payload["usage"] as? [String: Any] else { return nil }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let details = usage["prompt_tokens_details"] as? [String: Any] ?? [:]
        let read = max(int(details["cached_tokens"]), int(usage["cache_read_input_tokens"]))
        let written = max(int(usage["cache_creation_input_tokens"]), int(details["cache_creation_tokens"]))
        return ["prompt": int(usage["prompt_tokens"]), "cached": read, "written": written, "output": int(usage["completion_tokens"])]
    }

    /// The same, from a Messages answer, whose input_tokens count only what
    /// was neither read from nor written to the cache.
    static func usage(messages payload: [String: Any]) -> [String: Int]? {
        guard let usage = payload["usage"] as? [String: Any] else { return nil }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let read = int(usage["cache_read_input_tokens"])
        let written = int(usage["cache_creation_input_tokens"])
        return ["prompt": int(usage["input_tokens"]) + read + written, "cached": read, "written": written, "output": int(usage["output_tokens"])]
    }
}

// MARK: - self test (part of `./bench --world W ai selftest` and `agent selftest`)

extension PromptCache {
    /// Both lanes' bodies over a four-turn conversation: the marks where they
    /// belong and never more than four, and each turn's body starting with
    /// the bytes of the turn before it. Pure: no file, no network.
    static func selfTest() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append("prompt cache: \(name)") } }
        func count(_ value: Any?) -> Int {
            if let object = value as? [String: Any] {
                return (object["cache_control"] == nil ? 0 : 1) + object.values.reduce(0) { $0 + count($1) }
            }
            if let array = value as? [Any] { return array.reduce(0) { $0 + count($1) } }
            return 0
        }
        func isMarked(_ value: Any?) -> Bool { ((value as? [String: Any])?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral" }
        func lastPart(_ message: Any?) -> [String: Any]? { parts((message as? [String: Any])?["content"]).last }
        func json(_ value: Any) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        /// Without its marks: the content the cache keys on.
        func unmarked(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, inner) in object where key != "cache_control" { out[key] = unmarked(inner) }
                return out
            }
            if let array = value as? [Any] { return array.map(unmarked) }
            return value
        }
        /// The same value rebuilt — new dictionaries, each with its own key
        /// order — the way the next turn builds its request again.
        func rebuilt(_ value: [[String: Any]]) -> [[String: Any]] {
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let again = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return value }
            return again
        }

        // A question that reads the page, calls tools twice (once with a
        // screenshot back), answers, and a follow-up.
        let tools: [[String: Any]] = ["browser_navigate", "browser_snapshot", "canvas_apply"].map { name -> [String: Any] in
            ["type": "function", "function": [
                "name": name, "description": "Does \(name).",
                "parameters": ["type": "object", "required": ["url"], "properties": [
                    "url": ["type": "string", "description": "Where to go"], "ref": ["type": "string", "description": "Element"],
                    "limit": ["type": "number", "description": "How many"], "focus": ["type": "boolean", "description": "Show it"],
                ] as [String: Any]] as [String: Any],
            ] as [String: Any]]
        }
        func call(_ id: String, _ name: String, _ arguments: String) -> [String: Any] {
            ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
        }
        let system = "You are the agent inside Copper."
        let question: [String: Any] = ["role": "user", "content": "<page>\nCurrent page: https://example.com/\n</page>\n\nWhat is this page?"]
        let first: [String: Any] = ["role": "assistant", "content": "Reading it.", "tool_calls": [call("call_1", "browser_snapshot", "{}")]]
        let snapshot: [String: Any] = ["role": "tool", "tool_call_id": "call_1", "content": "- heading \"Example Domain\" [e1]"]
        let second: [String: Any] = ["role": "assistant", "tool_calls": [
            call("call_2", "browser_navigate", "{\"url\":\"https://example.com/more\",\"focus\":false,\"limit\":3,\"ref\":\"e1\"}"),
            call("call_3", "canvas_apply", "{\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"id\":\"n1\",\"text\":\"x\"}}]}"),
        ]]
        let navigated: [String: Any] = ["role": "tool", "tool_call_id": "call_2", "content": "Navigated"]
        let applied: [String: Any] = ["role": "tool", "tool_call_id": "call_3", "content": "{\"applied\":1}"]
        let picture: [String: Any] = ["role": "user", "content": [
            ["type": "text", "text": "Screenshot from the tool call above:"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,iVBORw0KGgo="]],
        ]]
        let answer: [String: Any] = ["role": "assistant", "content": "It is the example page."]
        let followUp: [String: Any] = ["role": "user", "content": "And its title?"]
        let turns: [[[String: Any]]] = [
            [question],
            [question, first, snapshot],
            [question, first, snapshot, second, navigated, applied, picture],
            [question, first, snapshot, second, navigated, applied, picture, answer, followUp],
        ]

        /// Turn after turn: at most four marks; system, last tool and last
        /// message marked; and the body begins with last turn's bytes — the
        /// system prompt and tools exactly, the messages through last turn's
        /// last one the same once the marks are set aside (they move on),
        /// and that last message exactly, mark and all, where this turn reads.
        func walk(_ lane: String, _ body: ([[String: Any]]) -> [String: Any]) {
            var before: [String: Any]?
            for (n, history) in turns.enumerated() {
                let name = "\(lane) turn \(n + 1)"
                let now = body(history)
                let messages = now["messages"] as? [[String: Any]] ?? []
                let tools = now["tools"] as? [[String: Any]] ?? []
                check(count(now) <= limit, "\(name): \(count(now)) marks, at most \(limit)")
                check(count(now) == (n == 0 ? 3 : 4), "\(name): system, last tool, previous turn's last message and this one's")
                check(isMarked(tools.last) && tools.dropLast().allSatisfy { !isMarked($0) }, "\(name): the last tool is marked, no other")
                check(isMarked(lastPart(messages.last)), "\(name): the last message's last part is marked")
                check(now["temperature"] == nil && now["thinking"] == nil, "\(name): no temperature, no thinking")
                check((try? PromptCache.json(now)).map { String(decoding: $0, as: UTF8.self) } == json(now), "\(name): written with sorted keys")
                if let before, let was = before["messages"] as? [[String: Any]] {
                    check(json(tools) == json(before["tools"] ?? []), "\(name): tools are last turn's bytes")
                    if let system = before["system"] { check(json(now["system"] ?? []) == json(system), "\(name): system is last turn's bytes") }
                    let prefix = String(json(unmarked(was)).dropLast()) + ","
                    check(json(unmarked(messages)).hasPrefix(prefix), "\(name): messages begin with last turn's, marks aside")
                    let k = was.count - 1
                    check(messages.count > k && json(messages[k]) == json(was[k]) && isMarked(lastPart(messages[k])),
                          "\(name): last turn's last message is sent again as it was, mark and all")
                }
                before = now
            }
        }

        // The gateway: the system prompt is the first message.
        walk("gateway") { history in
            let body = Router.body(model: "opus", maxTokens: 16_000, messages: [["role": "system", "content": system]] + rebuilt(history),
                                   tools: rebuilt(tools), cache: .rolling)
            let messages = body["messages"] as? [[String: Any]] ?? []
            check(messages.first?["role"] as? String == "system" && isMarked(lastPart(messages.first)), "gateway: the system prompt is marked")
            return body
        }
        // The Claude account: the identity block first and untouched.
        walk("claude") { history in
            let body = Claude.body(model: "claude-opus-5-5", system: [["type": "text", "text": Claude.identity], ["type": "text", "text": system]],
                                   messages: Claude.messages(fromChat: rebuilt(history)), tools: Claude.tools(fromChat: rebuilt(tools)),
                                   maxTokens: 16_000, cache: .rolling)
            let blocks = body["system"] as? [[String: Any]] ?? []
            check(blocks.count == 2 && json(blocks[0]) == json(["type": "text", "text": Claude.identity]), "claude: the identity block is exactly the identity")
            check(isMarked(blocks.last), "claude: the last system block is marked")
            check((body["tool_choice"] as? [String: String]) == ["type": "auto"], "claude: tool choice auto")
            return body
        }

        // A one-shot ask: the instructions marked, the question not.
        let ask = Router.body(model: "sonnet", maxTokens: 400, messages: [["role": "system", "content": system], ["role": "user", "content": "hi"]])
        let asked = ask["messages"] as? [[String: Any]] ?? []
        check(count(ask) == 1 && isMarked(lastPart(asked.first)) && asked.last?["content"] as? String == "hi", "ask: only the instructions marked")
        let claudeAsk = Claude.body(model: "claude-haiku-4-5", system: [["type": "text", "text": Claude.identity], ["type": "text", "text": system]],
                                    messages: [["role": "user", "content": "hi"]], tools: [], maxTokens: 400)
        check(count(claudeAsk) == 1 && isMarked((claudeAsk["system"] as? [[String: Any]])?.last), "claude ask: only the instructions marked")
        let identityOnly = Claude.body(model: "claude-haiku-4-5", system: [["type": "text", "text": Claude.identity]],
                                       messages: [["role": "user", "content": "hi"]], tools: [], maxTokens: 400)
        check(count(identityOnly) == 0, "claude: the identity block alone is never marked")

        // A model that is not Claude gets no marks; nor does `.none`.
        let custom = Router.body(model: "kimi", maxTokens: 400, messages: [["role": "system", "content": system]] + turns[3], tools: tools, cache: .rolling)
        check(count(custom) == 0 && (custom["messages"] as? [[String: Any]])?.first?["content"] as? String == system, "a custom model gets no marks")
        check(count(Router.body(model: "opus", maxTokens: 1, messages: [["role": "system", "content": system]] + turns[3], tools: tools, cache: .none)) == 0, "none is none")
        check(gatewayCaches("exowatt/opus") && gatewayCaches("claude-sonnet-5") && !gatewayCaches("luna") && !gatewayCaches("kimi"), "which gateway names cache")

        // Nothing to mark is no mark, never an empty marked part.
        let empty = Router.body(model: "opus", maxTokens: 1, messages: [["role": "system", "content": system], question, second,
                                                                        ["role": "tool", "tool_call_id": "call_2", "content": ""]], cache: .rolling)
        check(count(empty) == 2, "an empty last message is not marked")

        // Answers that say the marks were the trouble, and ones that don't.
        check(refused(Data("BedrockException - You invoked an unsupported model or your request did not allow prompt caching.".utf8)), "refused: no prompt caching")
        check(refused(Data("A maximum of 4 blocks with cache_control may be provided. Found 6.".utf8)), "refused: too many marks")
        check(!refused(Data("max_tokens: 16000 > 8192, which is the maximum allowed".utf8)), "refused: max_tokens is not about marks")

        // What each answer says it read.
        let chatUsage = usage(chat: ["usage": ["prompt_tokens": 9717, "completion_tokens": 4, "prompt_tokens_details": ["cached_tokens": 8354],
                                               "cache_read_input_tokens": 8354, "cache_creation_input_tokens": 1361]])
        check(chatUsage == ["prompt": 9717, "cached": 8354, "written": 1361, "output": 4], "usage from the gateway")
        let messagesUsage = usage(messages: ["usage": ["input_tokens": 2, "cache_read_input_tokens": 9433, "cache_creation_input_tokens": 0, "output_tokens": 4]])
        check(messagesUsage == ["prompt": 9435, "cached": 9433, "written": 0, "output": 4], "usage from Anthropic")
        return failures
    }
}
