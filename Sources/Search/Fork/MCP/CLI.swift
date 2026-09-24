import AppKit
import Foundation

// `Copper --cli …`: a small, synchronous shell client for the MCP server in
// the browser already open on this Mac. It deliberately uses the same tool
// names and arguments as the HTTP server, so an agent can move between the
// command line and MCP without learning a second API.

enum CLI {
    private struct Config: Decodable {
        var enabled: Bool
        var port: UInt16
        var token: String
        private enum CodingKeys: String, CodingKey { case enabled, port, token }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 4123
            token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        }
    }

    private struct HTTPResult {
        var data: Data
        var status: Int
        var error: String?
    }

    private struct RequestSpec {
        var request: [String: Any]?
        var health = false
        var toolsCommand = false
        var imagePath: String?
        var imageCommand = false
    }

    /// Called from SearchApp.init before SwiftUI creates a window. It returns
    /// immediately for an ordinary app launch and exits for a CLI invocation.
    static func runIfAsked() {
        guard let marker = CommandLine.arguments.firstIndex(of: "--cli") else { return }
        let raw = Array(CommandLine.arguments.dropFirst(marker + 1))
        exit(Int32(run(raw)))
    }

    private static func run(_ raw: [String]) -> Int {
        var args = raw
        let json = args.contains("--json")
        let dryRun = args.contains("--dry-run")
        args.removeAll { $0 == "--json" || $0 == "--dry-run" }

        guard let command = args.first else {
            print(usage)
            return 0
        }
        if command == "help" || command == "-h" || command == "--help" {
            print(usage)
            return 0
        }
        if command == "setup" {
            return runSetup(Array(args.dropFirst()), json: json)
        }

        guard let spec = makeRequest(command, Array(args.dropFirst())) else { return 2 }
        if dryRun {
            if let request = spec.request { printJSON(request) }
            else if spec.health { print("GET /health") }
            return 0
        }

        guard var config = readConfig() else {
            error("open Copper → Settings › Agents › Let agents drive this window")
            return 2
        }
        guard config.enabled, !config.token.isEmpty else {
            error("open Copper → Settings › Agents › Let agents drive this window")
            return 2
        }
        guard ensureRunning(&config) else { return 2 }

        if spec.health {
            return doHealth(config, json: json)
        }
        guard let request = spec.request else {
            error("could not construct request")
            return 2
        }
        let name = ((request["params"] as? [String: Any])?["name"] as? String) ?? ""
        let timeout: TimeInterval = name == "jev_run" ? 240 : 60
        guard let response = post(request, config: config, timeout: timeout) else { return 2 }
        return render(response, spec: spec, json: json)
    }

    // MARK: - command mapping

    private static func rpc(_ method: String, _ params: [String: Any] = [:], imagePath: String? = nil, imageCommand: Bool = false) -> RequestSpec {
        RequestSpec(request: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ], toolsCommand: method == "tools/list", imagePath: imagePath, imageCommand: imageCommand)
    }

    private static func call(_ name: String, _ arguments: [String: Any] = [:], imagePath: String? = nil, imageCommand: Bool = false) -> RequestSpec {
        rpc("tools/call", ["name": name, "arguments": arguments], imagePath: imagePath, imageCommand: imageCommand)
    }

    private static func makeRequest(_ command: String, _ input: [String]) -> RequestSpec? {
        var args = input
        switch command {
        case "tabs":
            guard args.isEmpty else { return bad("tabs takes no arguments") }
            return call("browser_tabs", ["action": "list"])
        case "open":
            guard args.count == 1, let url = args.first else { return bad("open needs URL") }
            return call("browser_tabs", ["action": "new", "url": url])
        case "go":
            guard args.count == 1, let url = args.first else { return bad("go needs URL") }
            return call("browser_navigate", ["url": url])
        case "observe":
            var arguments: [String: Any] = [:]
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--no-text": arguments["text"] = false
                case "-n", "--limit":
                    guard let value = next(&args, &i), let number = Int(value), number >= 0 else { return bad("observe -n needs a non-negative number") }
                    arguments["limit"] = number
                default: return bad("unknown observe option: \(args[i])")
                }
                i += 1
            }
            return call("jev_observe", arguments)
        case "run":
            var goal: [String] = []
            var arguments: [String: Any] = [:]
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--url":
                    guard let value = next(&args, &i), !value.isEmpty else { return bad("run --url needs URL") }
                    arguments["url"] = value
                case "--new-tab": arguments["newTab"] = true
                case "--max":
                    guard let value = next(&args, &i), let number = Int(value), number >= 0 else { return bad("run --max needs a non-negative number") }
                    arguments["maxSteps"] = number
                case "--no-elements": arguments["elements"] = false
                default:
                    if args[i].hasPrefix("-") { return bad("unknown run option: \(args[i])") }
                    goal.append(args[i])
                }
                i += 1
            }
            guard !goal.isEmpty else { return bad("run needs a goal") }
            arguments["goal"] = goal.joined(separator: " ")
            return call("jev_run", arguments)
        case "step":
            guard !args.isEmpty else { return bad("step needs a goal") }
            guard !args.contains(where: { $0.hasPrefix("-") }) else { return bad("step takes a goal, not options") }
            return call("jev_step", ["goal": args.joined(separator: " ")])
        case "extract":
            var instruction: [String] = []
            var arguments: [String: Any] = [:]
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--full": arguments["full"] = true
                case "--schema":
                    guard let value = next(&args, &i), let schema = jsonValue(value) else { return bad("extract --schema needs valid JSON") }
                    arguments["schema"] = schema
                default:
                    if args[i].hasPrefix("-") { return bad("unknown extract option: \(args[i])") }
                    instruction.append(args[i])
                }
                i += 1
            }
            guard !instruction.isEmpty else { return bad("extract needs an instruction") }
            arguments["instruction"] = instruction.joined(separator: " ")
            return call("jev_extract", arguments)
        case "snapshot":
            var arguments: [String: Any] = [:]
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--interactive": arguments["interactive"] = true
                case "-n", "--limit":
                    guard let value = next(&args, &i), let number = Int(value), number >= 0 else { return bad("snapshot -n needs a non-negative number") }
                    arguments["limit"] = number
                case "--selector":
                    guard let value = next(&args, &i), !value.isEmpty else { return bad("snapshot --selector needs CSS") }
                    arguments["selector"] = value
                default: return bad("unknown snapshot option: \(args[i])")
                }
                i += 1
            }
            return call("browser_snapshot", arguments)
        case "text":
            guard args.isEmpty else { return bad("text takes no arguments") }
            return call("browser_get_text")
        case "find":
            guard !args.isEmpty else { return bad("find needs text") }
            guard !args.contains(where: { $0.hasPrefix("-") }) else { return bad("find text cannot be an option") }
            return call("browser_find", ["text": args.joined(separator: " ")])
        case "shot":
            var path: String?
            var arguments: [String: Any] = ["type": "png"]
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--full": arguments["fullPage"] = true
                case "--jpeg": arguments["type"] = "jpeg"
                default:
                    guard !args[i].hasPrefix("-"), path == nil else { return bad("shot takes one optional PATH") }
                    path = args[i]
                }
                i += 1
            }
            let suffix = (arguments["type"] as? String) == "jpeg" ? "jpg" : "png"
            let output = path ?? "/tmp/copper-\(Int(Date().timeIntervalSince1970)).\(suffix)"
            arguments["filename"] = output
            return call("browser_take_screenshot", arguments, imagePath: output, imageCommand: true)
        case "eval":
            guard args.count == 1, let function = args.first else { return bad("eval needs JavaScript") }
            return call("browser_evaluate", ["function": function])
        case "click":
            guard !args.isEmpty else { return bad("click needs REF or --selector CSS") }
            if args[0] == "--selector" {
                guard args.count == 2 else { return bad("click --selector needs CSS") }
                return call("browser_click", ["selector": args[1]])
            }
            guard args.count == 1 else { return bad("click takes one REF or --selector CSS") }
            return call("browser_click", ["ref": args[0]])
        case "type":
            guard args.count >= 2 else { return bad("type needs REF TEXT") }
            let ref = args.removeFirst()
            var submit = false
            var text: [String] = []
            for arg in args {
                if arg == "--submit" { submit = true } else { text.append(arg) }
            }
            guard !text.isEmpty else { return bad("type needs TEXT") }
            return call("browser_type", ["ref": ref, "text": text.joined(separator: " "), "submit": submit])
        case "key":
            guard args.count == 1 else { return bad("key needs KEY") }
            return call("browser_press_key", ["key": args[0]])
        case "tools":
            guard args.isEmpty else { return bad("tools takes no arguments") }
            return rpc("tools/list")
        case "health":
            guard args.isEmpty else { return bad("health takes no arguments") }
            return RequestSpec(request: nil, health: true)
        case "call":
            guard let name = args.first, !name.isEmpty else { return bad("call needs TOOL") }
            let rawJSON = Array(args.dropFirst()).joined(separator: " ")
            guard args.count <= 1 || !rawJSON.isEmpty else { return bad("call JSON-ARGS is empty") }
            let arguments: [String: Any]
            if rawJSON.isEmpty {
                arguments = [:]
            } else if let object = jsonValue(rawJSON) as? [String: Any] {
                arguments = object
            } else {
                return bad("call JSON-ARGS must be a JSON object")
            }
            let imagePath = (name == "browser_take_screenshot" ? arguments["filename"] as? String : nil)
            return call(name, arguments, imagePath: imagePath)
        // EXTENSION POINT: the ship agent will add `copper setup …` here.
        default:
            return bad("unknown command: \(command)")
        }
    }

    // MARK: - terminal-agent setup

    private static func runSetup(_ input: [String], json: Bool) -> Int {
        guard input.count <= 1 else {
            error("setup takes one target: phi, claude, cli or status")
            return 2
        }
        let target = input.first ?? "status"
        guard ["phi", "claude", "cli", "status"].contains(target) else {
            error("unknown setup target: \(target) (use phi, claude, cli or status)")
            return 2
        }

        let configuration = readConfig()
        if target == "cli" {
            do {
                let report = try Setup(endpoint: endpoint(from: configuration), token: configuration?.token ?? "").cli()
                if json { printJSON(report.dictionary) }
                else { print((report.paths + report.notes).joined(separator: "\n")) }
                return 0
            } catch {
                Self.error((error as? Tools.Failure)?.text ?? error.localizedDescription)
                return 2
            }
        }
        guard let configuration, !configuration.token.isEmpty else {
            error("open Copper → Settings › Agents › Let agents drive this window")
            return 2
        }
        let setup = Setup(endpoint: endpoint(from: configuration), token: configuration.token)
        if target == "status" {
            let status = setup.status()
            if json { printJSON(status.dictionary) }
            else {
                print("phi: \(status.phi.rawValue)")
                print("claude: \(status.claude.rawValue)")
                print("cli: \(status.cli.rawValue)")
            }
            return 0
        }
        do {
            let report: Setup.Report
            switch target {
            case "phi": report = try setup.phi()
            case "claude": report = try setup.claude()
            default: return 2
            }
            if json { printJSON(report.dictionary) }
            else { print((report.paths + report.notes).joined(separator: "\n")) }
            return 0
        } catch {
            Self.error((error as? Tools.Failure)?.text ?? error.localizedDescription)
            return 2
        }
    }

    private static func endpoint(from config: Config?) -> String {
        "http://127.0.0.1:\(config?.port ?? 4123)/mcp"
    }

    private static func next(_ args: inout [String], _ index: inout Int) -> String? {
        index += 1
        guard args.indices.contains(index) else { return nil }
        return args[index]
    }

    private static func jsonValue(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func bad(_ text: String) -> RequestSpec? {
        error(text)
        return nil
    }

    // MARK: - app discovery and HTTP

    private static func readConfig() -> Config? {
        guard let data = try? Data(contentsOf: Store.file("agent.json")) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    private static func ensureRunning(_ config: inout Config) -> Bool {
        if health(config.port)?.running != true {
            launch()
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if health(config.port)?.running == true { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if let fresh = readConfig() { config = fresh }
        }
        guard config.enabled, !config.token.isEmpty else {
            error("open Copper → Settings › Agents › Let agents drive this window")
            return false
        }
        guard health(config.port)?.running == true else {
            error("Copper did not answer on its agent port")
            return false
        }
        return true
    }

    private static func launch() {
        // The CLI executable is inside Copper.app when invoked through bin/copper.
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in }
    }

    private static func health(_ port: UInt16) -> (object: [String: Any], running: Bool)? {
        guard let response = http(method: "GET", url: URL(string: "http://127.0.0.1:\(port)/health")!, token: nil, timeout: 1), response.status == 200,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else { return nil }
        return (object, (object["running"] as? Bool) ?? false)
    }

    private static func post(_ request: [String: Any], config: Config, timeout: TimeInterval) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let response = http(method: "POST", url: URL(string: "http://127.0.0.1:\(config.port)/mcp")!, token: config.token, body: data, timeout: timeout),
              (200..<300).contains(response.status),
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else {
            error("could not reach Copper")
            return nil
        }
        if let rpcError = object["error"] as? [String: Any], let message = rpcError["message"] as? String {
            error(message)
            return nil
        }
        guard object["result"] is [String: Any] else {
            error("Copper returned an invalid JSON-RPC response")
            return nil
        }
        return object
    }

    private static func http(method: String, url: URL, token: String?, body: Data? = nil, timeout: TimeInterval) -> HTTPResult? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        final class Box: @unchecked Sendable {
            var data = Data()
            var status = 0
            var error: String?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data ?? Data()
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.error = error?.localizedDescription
            done.signal()
        }.resume()
        done.wait()
        guard box.error == nil else { return nil }
        return HTTPResult(data: box.data, status: box.status, error: box.error)
    }

    // MARK: - response rendering

    private static func doHealth(_ config: Config, json: Bool) -> Int {
        guard let got = health(config.port) else {
            error("Copper did not answer on its agent port")
            return 2
        }
        let initialize = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "copper-cli", "version": Fork.version]],
        ] as [String: Any]
        guard post(initialize, config: config, timeout: 10) != nil else { return 2 }
        let toolsList = [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:],
        ] as [String: Any]
        guard let response = post(toolsList, config: config, timeout: 10),
              let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return 2 }
        let jev = tools.contains { ($0["name"] as? String) == "jev_run" }
        if json {
            printJSON(["health": got.object, "jev": jev])
        } else {
            let version = got.object["version"] as? String
            let versionSuffix = version.map { " · version: \($0)" } ?? ""
            print("Copper health: running: \(got.running) (port \(config.port))\(versionSuffix)")
            print("Jev mode: \(jev ? "on" : "off")")
        }
        return 0
    }

    private static func render(_ response: [String: Any], spec: RequestSpec, json: Bool) -> Int {
        guard var result = response["result"] as? [String: Any] else {
            error("Copper returned no result")
            return 2
        }
        if spec.toolsCommand, !json {
            guard let tools = result["tools"] as? [[String: Any]] else {
                error("Copper returned no tool catalogue")
                return 2
            }
            for tool in tools {
                guard let name = tool["name"] as? String else { continue }
                let description = tool["description"] as? String ?? ""
                let first = description.split(separator: ".", maxSplits: 1).first.map(String.init) ?? description
                print("\(name) — \(first)")
            }
            return 0
        }
        let isError = (result["isError"] as? Bool) ?? false
        var paths: [String] = []
        var text: [String] = []
        if var content = result["content"] as? [[String: Any]] {
            var transformed: [[String: Any]] = []
            for (index, item) in content.enumerated() {
                guard let type = item["type"] as? String else { continue }
                if type == "text", let value = item["text"] as? String {
                    text.append(value)
                    transformed.append(item)
                } else if type == "image", let encoded = item["data"] as? String, let data = Data(base64Encoded: encoded) {
                    let mime = item["mimeType"] as? String
                    let path = imagePath(for: spec, mime: mime, index: index)
                    do {
                        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: file)
                    } catch let writeError {
                        _ = writeError
                        error("could not write screenshot to \(path)")
                        return 2
                    }
                    paths.append(path)
                    transformed.append(["type": "image", "path": path])
                } else {
                    transformed.append(item)
                }
            }
            content = transformed
            result["content"] = content
        }

        if json {
            printJSON(result)
        } else if isError {
            for line in text { error(line) }
        } else if !paths.isEmpty {
            for path in paths { print(path) }
            if !spec.imageCommand { for line in text { writeOut(line) } }
        } else {
            for line in text { writeOut(line) }
        }
        return isError ? 1 : 0
    }

    private static func imagePath(for spec: RequestSpec, mime: String?, index: Int) -> String {
        if let preferred = spec.imagePath {
            if index == 0 { return preferred }
            let url = URL(fileURLWithPath: preferred)
            return url.deletingPathExtension().path + "-\(index)." + url.pathExtension
        }
        let suffix = mime == "image/jpeg" ? "jpg" : "png"
        return "/tmp/copper-\(Int(Date().timeIntervalSince1970))\(index == 0 ? "" : "-\(index)").\(suffix)"
    }

    // MARK: - output

    private static func printJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            error("could not encode JSON")
            return
        }
        writeOut(String(decoding: data, as: UTF8.self) + "\n")
    }

    private static func writeOut(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func error(_ text: String) {
        FileHandle.standardError.write(Data(("copper: " + text + "\n").utf8))
    }

    private static let usage = """
    Usage: copper [--json] <command> [arguments]

      tabs                                      list open tabs
      open URL                                  open URL in a new tab
      go URL                                    navigate the current tab
      observe [--no-text] [-n N]                fast Jev observation
      run "GOAL…" [--url URL] [--new-tab] [--max N] [--no-elements]
      step "GOAL…"                              supervise one Jev decision
      extract "INSTRUCTION…" [--full] [--schema JSON]
      snapshot [--interactive] [-n N] [--selector CSS]
      text                                      read page text
      find TEXT                                 find matching page elements
      shot [PATH] [--full] [--jpeg]             save a screenshot
      eval 'JS'                                 evaluate JavaScript
      click REF | --selector CSS                click an element
      type REF TEXT [--submit]                  type into an element
      key KEY                                   press a key
      tools                                     list available tools
      health                                    check the agent server and Jev mode
      setup [phi|claude|cli|status]              install terminal-agent setup (default: status)
      call TOOL [JSON-ARGS]                     call any MCP tool
      help                                      show this help

    Use --json for the raw JSON-RPC result. (Hidden: --dry-run prints the request.)
    """
}
