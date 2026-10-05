import Foundation

// Anthropic's Messages API for the Claude-account lane. The agent keeps its
// transcript in OpenAI's chat shape, so this file also owns the small, strict
// translation at the API boundary and keeps account-only details out of the UI.
enum Claude {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let identity = "You are Claude Code, Anthropic's official CLI for Claude."
    static let userAgent = "claude-cli/2.1.283"
    static let betas = "claude-code-20250219,oauth-2025-04-20"

    struct Failure: LocalizedError {
        let status: Int
        let text: String
        var errorDescription: String? { text }
    }

    static func complete(token: String, model: String, system: String, messages: [[String: Any]],
                        tools: [[String: Any]] = [], maxTokens: Int = 8192,
                        timeout: TimeInterval = 180) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(betas, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")

        var systemBlocks: [[String: Any]] = [["type": "text", "text": identity]]
        if !system.isEmpty {
            systemBlocks.append(["type": "text", "text": system])
        }
        let body = Claude.body(model: model, system: systemBlocks, messages: messages, tools: tools, maxTokens: maxTokens)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw Failure(status: 0, text: "Claude: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(status: 0, text: "Claude: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(status: 0, text: "Claude: no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw failure(status: http.statusCode, data: data)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(status: http.statusCode, text: "Claude \(http.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return payload
    }

    /// A Messages body. No `temperature`, no `thinking` block (disabled or
    /// budgeted) and no forced tool: Opus 5.5 refuses all three, and auto
    /// is what every Claude model takes.
    static func body(model: String, system: [[String: Any]], messages: [[String: Any]],
                     tools: [[String: Any]], maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = ["type": "auto"]
        }
        return body
    }

    static func ask(token: String, model: String, system: String, user: String,
                    timeout: TimeInterval = 40, maxTokens: Int = 400) async throws -> Router.Reply {
        let started = Date()
        let payload = try await complete(
            token: token,
            model: model,
            system: system,
            messages: [["role": "user", "content": user]],
            maxTokens: max(maxTokens, 4096),
            timeout: timeout
        )
        let text = text(in: payload)
        let chosenModel = (payload["model"] as? String) ?? model
        return Router.Reply(json: Router.json(in: text), text: text,
                            latencyMs: Date().timeIntervalSince(started) * 1000,
                            model: chosenModel)
    }

    // MARK: - OpenAI chat shape ⇄ Anthropic Messages shape

    static func messages(fromChat: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for message in fromChat {
            guard let role = message["role"] as? String, role != "system" else { continue }
            switch role {
            case "user":
                let content: Any
                if let string = message["content"] as? String {
                    content = string
                } else {
                    content = userBlocks(from: message["content"])
                }
                append(["role": "user", "content": content], to: &result)

            case "assistant":
                let blocks = sanitised(arrayOfBlocks(message["_blocks"]))
                if !blocks.isEmpty {
                    append(["role": "assistant", "content": blocks], to: &result)
                    continue
                }

                var assistantBlocks: [[String: Any]] = []
                let contentText = joinedText(message["content"])
                if !contentText.isEmpty {
                    assistantBlocks.append(["type": "text", "text": contentText])
                }
                for call in arrayOfDictionaries(message["tool_calls"]) {
                    let function = (call["function"] as? [String: Any]) ?? [:]
                    let name = function["name"] as? String ?? ""
                    let id = call["id"] as? String ?? ""
                    let arguments = function["arguments"] as? String ?? "{}"
                    let input = jsonObject(arguments)
                    assistantBlocks.append(["type": "tool_use", "id": id,
                                            "name": name, "input": input])
                }
                guard !assistantBlocks.isEmpty else { continue }
                append(["role": "assistant", "content": assistantBlocks], to: &result)

            case "tool":
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": message["tool_call_id"] as? String ?? "",
                    "content": message["content"] as? String ?? "",
                ]
                append(["role": "user", "content": [block]], to: &result)

            default:
                continue
            }
        }

        if result.first?["role"] as? String != "user" {
            result.insert(["role": "user", "content": "(continued)"], at: 0)
        }
        return result
    }

    static func tools(fromChat: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for tool in fromChat {
            guard let function = tool["function"] as? [String: Any] else { continue }
            let parameters = function["parameters"] as? [String: Any]
                ?? ["type": "object", "properties": [:] as [String: Any]]
            result.append([
                "name": function["name"] as? String ?? "",
                "description": function["description"] as? String ?? "",
                "input_schema": parameters,
            ])
        }
        return result
    }

    static func chatMessage(from payload: [String: Any]) -> [String: Any] {
        let blocks = sanitised(arrayOfBlocks(payload["content"]))
        var message: [String: Any] = [
            "role": "assistant",
            "content": blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(),
            "_blocks": blocks,
        ]
        var calls: [[String: Any]] = []
        for block in blocks where block["type"] as? String == "tool_use" {
            let input = block["input"] as? [String: Any] ?? [:]
            let arguments: String
            if let data = try? JSONSerialization.data(withJSONObject: input),
               let string = String(data: data, encoding: .utf8) {
                arguments = string
            } else {
                arguments = "{}"
            }
            calls.append([
                "id": block["id"] as? String ?? "",
                "type": "function",
                "function": [
                    "name": block["name"] as? String ?? "",
                    "arguments": arguments,
                ],
            ])
        }
        if !calls.isEmpty { message["tool_calls"] = calls }
        // Why the reply ended, in the router's words as well as Anthropic's:
        // "max_tokens" means it was cut off, possibly in the middle of a
        // tool call whose input is then incomplete (Agent.cutOff).
        if let stop = payload["stop_reason"] as? String { message["_stop"] = stop }
        if let answered = payload["model"] as? String { message["_model"] = answered }
        return message
    }

    static func sanitised(_ blocks: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                guard let text = block["text"] as? String else { continue }
                result.append(["type": "text", "text": text])
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String else { continue }
                result.append(["type": "tool_use", "id": id, "name": name,
                               "input": block["input"] as? [String: Any] ?? [:]])
            case "thinking":
                guard let thinking = block["thinking"] as? String,
                      let signature = block["signature"] as? String else { continue }
                result.append(["type": "thinking", "thinking": thinking, "signature": signature])
            case "redacted_thinking":
                guard let data = block["data"] as? String else { continue }
                result.append(["type": "redacted_thinking", "data": data])
            default:
                continue
            }
        }
        return result
    }

    static func text(in payload: [String: Any]) -> String {
        joinedText(payload["content"])
    }

    // MARK: - Small pure helpers

    private static func failure(status: Int, data: Data) -> Failure {
        switch status {
        case 401:
            return Failure(status: status, text: "Claude sign-in expired or was revoked — sign in again in Settings › Intelligence")
        case 429:
            return Failure(status: status, text: "Claude is rate-limiting this account right now — try again in a moment")
        case 503, 529:
            return Failure(status: status, text: "Claude is overloaded right now")
        default:
            var message: String?
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = object["error"] as? [String: Any] {
                message = error["message"] as? String
            }
            return Failure(status: status,
                           text: "Claude \(status): \(message ?? String(decoding: data.prefix(300), as: UTF8.self))")
        }
    }

    private static func arrayOfBlocks(_ value: Any?) -> [[String: Any]] {
        if let blocks = value as? [[String: Any]] { return blocks }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func arrayOfDictionaries(_ value: Any?) -> [[String: Any]] {
        if let dictionaries = value as? [[String: Any]] { return dictionaries }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func userBlocks(from value: Any?) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for part in arrayOfBlocks(value) {
            switch part["type"] as? String {
            case "text":
                result.append(["type": "text", "text": part["text"] as? String ?? ""])
            case "image_url":
                guard let imageURL = part["image_url"] as? [String: Any],
                      let url = imageURL["url"] as? String else { continue }
                if let (mediaType, data) = dataURL(url) {
                    result.append(["type": "image", "source": [
                        "type": "base64", "media_type": mediaType, "data": data,
                    ]])
                } else {
                    result.append(["type": "text", "text": url])
                }
            default:
                continue
            }
        }
        return result.isEmpty ? [["type": "text", "text": "(empty)"]] : result
    }

    private static func dataURL(_ url: String) -> (String, String)? {
        guard url.hasPrefix("data:"),
              let semicolon = url.firstIndex(of: ";"),
              let comma = url.firstIndex(of: ","),
              semicolon < comma,
              url[url.index(after: semicolon)..<comma].lowercased() == "base64" else { return nil }
        let start = url.index(url.startIndex, offsetBy: 5)
        let mediaType = String(url[start..<semicolon])
        let dataStart = url.index(after: comma)
        return (mediaType, String(url[dataStart...]))
    }

    private static func joinedText(_ value: Any?) -> String {
        if let string = value as? String { return string }
        return arrayOfBlocks(value).compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
    }

    private static func jsonObject(_ string: String) -> [String: Any] {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func contentBlocks(_ value: Any?) -> [[String: Any]] {
        if let string = value as? String {
            return [["type": "text", "text": string]]
        }
        let blocks = arrayOfBlocks(value)
        return blocks.isEmpty ? [["type": "text", "text": "(empty)"]] : blocks
    }

    private static func append(_ message: [String: Any], to result: inout [[String: Any]]) {
        guard let role = message["role"] as? String else { return }
        guard let lastRole = result.last?["role"] as? String, lastRole == role else {
            result.append(message)
            return
        }
        var merged = result.removeLast()
        let blocks = contentBlocks(merged["content"]) + contentBlocks(message["content"])
        merged["content"] = blocks.isEmpty ? [["type": "text", "text": "(empty)"]] : blocks
        result.append(merged)
    }

    // MARK: - Pure smoke checks used by the CLI/build harness.

    static func selfTest() -> [String] {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }

        let user = messages(fromChat: [["role": "user", "content": "hello"]])
        check(user.count == 1 && user[0]["content"] as? String == "hello", "user string")

        let image = messages(fromChat: [["role": "user", "content": [[
            "type": "image_url", "image_url": ["url": "data:image/png;base64,abc"],
        ]]]])
        let imageBlock = arrayOfBlocks(image.first?["content"]).first
        check(imageBlock?["type"] as? String == "image" &&
              (imageBlock?["source"] as? [String: Any])?["media_type"] as? String == "image/png",
              "user image part")

        let call = messages(fromChat: [[
            "role": "assistant", "content": "", "tool_calls": [[
                "id": "call-1", "type": "function", "function": [
                    "name": "lookup", "arguments": "{\"q\":\"copper\"}",
                ],
            ]],
        ]])
        let callBlock = arrayOfBlocks(call.last?["content"]).first
        check(callBlock?["type"] as? String == "tool_use" &&
              (callBlock?["input"] as? [String: Any])?["q"] as? String == "copper",
              "assistant tool call arguments")

        let merged = messages(fromChat: [
            ["role": "user", "content": "seed"],
            ["role": "tool", "tool_call_id": "one", "content": "first"],
            ["role": "tool", "tool_call_id": "two", "content": "second"],
            ["role": "user", "content": [[
                "type": "image_url", "image_url": ["url": "https://example.com/image.png"],
            ]]],
        ])
        let mergedUsers = merged.filter { ($0["role"] as? String) == "user" }
        check(mergedUsers.count == 1 && arrayOfBlocks(mergedUsers.first?["content"]).count == 4,
              "consecutive tool results merge with user image")

        let blocks: [[String: Any]] = [
            ["type": "thinking", "thinking": "", "signature": "sig", "caller": "drop"],
            ["type": "tool_use", "id": "tool-1", "name": "lookup", "input": ["q": "x"], "caller": "drop"],
        ]
        let clean = sanitised(blocks)
        check(clean.count == 2 && clean[0].count == 3 && clean[1].count == 4 &&
              clean[1]["caller"] == nil, "sanitised thinking and tool use")
        let roundTrip = messages(fromChat: [["role": "assistant", "_blocks": blocks]])
        check(arrayOfBlocks(roundTrip.last?["content"]).count == 2, "assistant blocks round trip")

        let payload: [String: Any] = ["content": [
            ["type": "thinking", "thinking": "consider", "signature": "sig"],
            ["type": "text", "text": "done"],
            ["type": "tool_use", "id": "tool-2", "name": "lookup", "input": ["q": "x"]],
        ]]
        let chat = chatMessage(from: payload)
        check(chat["role"] as? String == "assistant" && chat["content"] as? String == "done" &&
              (chat["tool_calls"] as? [[String: Any]])?.count == 1 &&
              arrayOfBlocks(chat["_blocks"]).count == 3, "payload chat message")
        let cut = chatMessage(from: ["content": [["type": "text", "text": "half"]], "stop_reason": "max_tokens"])
        check(cut["_stop"] as? String == "max_tokens", "stop reason carried through")

        let mappedTools = tools(fromChat: [[
            "type": "function", "function": ["name": "lookup", "description": "Find it"],
        ]])
        let schema = mappedTools.first?["input_schema"] as? [String: Any]
        check(mappedTools.first?["name"] as? String == "lookup" && schema?["type"] as? String == "object",
              "tool schema default")

        return failures
    }
}
