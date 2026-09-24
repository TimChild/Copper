import AppKit
import Foundation

/// One-time bridges for the terminal agents that can drive Copper.
///
/// Setup writes the clients' own configuration files, so a bearer token never
/// has to travel through a copied prompt. Every write is local and atomic;
/// malformed files are reported without touching them.
struct Setup {
    static let feed = "https://forca.apps.exowatt.com"
    static let installCommand = "curl -fsSL \(feed)/downloads/copper-install.sh | sh"
    static let brewCommand = "brew install --cask exowatt-labs/copper/copper"

    enum State: String, Codable {
        case missing, stale, ready
    }

    struct Report: Codable {
        let paths: [String]
        let notes: [String]

        var dictionary: [String: Any] {
            ["paths": paths, "notes": notes]
        }
    }

    struct Status: Codable {
        var phi: State = .missing
        var claude: State = .missing
        var cli: State = .missing

        var dictionary: [String: Any] {
            ["phi": phi.rawValue, "claude": claude.rawValue, "cli": cli.rawValue]
        }
    }

    private static let marker = "<!-- copper-setup v1 -->"
    private static let fileManager = FileManager.default

    private static var home: URL {
        if let raw = ProcessInfo.processInfo.environment["HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    private static var phiConfig: URL { home.appendingPathComponent(".pi/agent/mcp.json") }
    private static var phiPrompt: URL { home.appendingPathComponent(".pi/agent/prompts/jev.md") }
    private static var claudeConfig: URL { home.appendingPathComponent(".claude.json") }
    private static var claudePrompt: URL { home.appendingPathComponent(".claude/commands/jev.md") }

    let endpoint: String
    let token: String

    init(endpoint: String, token: String) {
        self.endpoint = endpoint
        self.token = token
    }

    private var phiPromptText: String {
        """
        ---
        description: Drive Copper — my signed-in browser — with Jev; first action is the Copper call, no reconnaissance
        argument-hint: "<goal>"
        ---
        \(Self.marker)
        Copper is already bridged as MCP server `copper`. Exact Jev tool names are `mcp_copper_jev_run`, `mcp_copper_jev_observe`, and `mcp_copper_jev_extract` (if a tool is missing from the list, use `mcp_find_tools` with its exact name; or in bash the `copper` CLI: `copper run \"<goal>\"`, `copper observe`, `copper extract \"<question>\"`). Do not check configuration, do not list tabs, do not snapshot first — the FIRST action is the call that does the job, on the tab the user is looking at; multi-step → `jev_run` with the goal verbatim plus concrete values, `url` only if the goal names another page; read → `jev_observe`; values → `jev_extract`; BLOCKED → browser_* for that part then `jev_run` again; DONE is Jev's claim — verify before reporting; report briefly what happened and what is on the page now.
        Goal: $@
        """
    }

    private var claudePromptText: String {
        phiPromptText.replacingOccurrences(of: "Goal: $@", with: "Goal: $ARGUMENTS")
    }

    /// Merge one HTTP MCP server into an ordinary JSON object, retaining every
    /// unrelated key (including `_comment` keys and extra Copper settings).
    private func mergedConfig(at url: URL, toolMode: Bool) throws -> [String: Any] {
        var root: [String: Any]
        if Self.fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let parsed = object as? [String: Any]
            else {
                throw Tools.Failure(text: "Could not parse \(url.path) as JSON; nothing was changed.")
            }
            root = parsed
        } else {
            root = [:]
        }

        var servers: [String: Any]
        if let existing = root["mcpServers"] {
            guard let parsed = existing as? [String: Any] else {
                throw Tools.Failure(text: "\(url.path) has a non-object mcpServers value; nothing was changed.")
            }
            servers = parsed
        } else {
            servers = [:]
        }

        var copper: [String: Any]
        if let existing = servers["copper"] {
            guard let parsed = existing as? [String: Any] else {
                throw Tools.Failure(text: "\(url.path) has a non-object copper entry; nothing was changed.")
            }
            copper = parsed
        } else {
            copper = [:]
        }

        var headers: [String: Any]
        if let existing = copper["headers"] {
            guard let parsed = existing as? [String: Any] else {
                throw Tools.Failure(text: "\(url.path) has a non-object copper headers value; nothing was changed.")
            }
            headers = parsed
        } else {
            headers = [:]
        }
        headers["Authorization"] = "Bearer \(token)"
        copper["type"] = "http"
        copper["url"] = endpoint
        copper["headers"] = headers
        if toolMode { copper["toolMode"] = "eager" }
        servers["copper"] = copper
        root["mcpServers"] = servers
        return root
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw Tools.Failure(text: "Could not encode the terminal-agent configuration: \(error.localizedDescription)")
        }
    }

    /// Replace a file by moving a same-directory temporary file into place.
    /// Setting the mode on the temporary first avoids a readable interval.
    private static func atomicWrite(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
            let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            do {
                try data.write(to: temporary, options: [])
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
                if fileManager.fileExists(atPath: url.path) {
                    _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil,
                                                      options: .usingNewMetadataOnly)
                } else {
                    try fileManager.moveItem(at: temporary, to: url)
                }
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        } catch let failure as Tools.Failure {
            throw failure
        } catch {
            throw Tools.Failure(text: "Could not write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func writePrompt(_ text: String, to url: URL, paths: inout [String]) throws {
        try atomicWrite(Data(text.utf8), to: url)
        paths.append(url.path)
    }

    private static func writeConfig(_ object: [String: Any], to url: URL, paths: inout [String], preserveMode: Bool) throws {
        let mode: Int
        if preserveMode, let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let existing = attributes[.posixPermissions] as? NSNumber {
            mode = existing.intValue
        } else {
            mode = 0o600
        }
        try atomicWrite(try jsonData(object), to: url, mode: mode)
        paths.append(url.path)
    }

    func phi() throws -> Report {
        let object = try mergedConfig(at: Self.phiConfig, toolMode: true)
        var paths: [String] = []
        try Self.writeConfig(object, to: Self.phiConfig, paths: &paths, preserveMode: false)
        try Self.writePrompt(phiPromptText, to: Self.phiPrompt, paths: &paths)
        return Report(paths: paths, notes: ["phi now uses the eager Copper tools and the /jev command."])
    }

    func claude() throws -> Report {
        let object = try mergedConfig(at: Self.claudeConfig, toolMode: false)
        var paths: [String] = []
        try Self.writeConfig(object, to: Self.claudeConfig, paths: &paths, preserveMode: true)
        try Self.writePrompt(claudePromptText, to: Self.claudePrompt, paths: &paths)
        return Report(paths: paths, notes: ["Claude Code is registered at user scope; start a new session if it was already open."])
    }

    private static let cliDirectories: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin"),
        URL(fileURLWithPath: "/usr/local/bin"),
    ]

    private static var cliFallbackDirectory: URL { home.appendingPathComponent(".local/bin") }
    private static var cliName: String { "copper" }

    private static func writableDirectory(_ directory: URL) -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        let probe = directory.appendingPathComponent(".copper-write-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: [])
            try fileManager.removeItem(at: probe)
            return true
        } catch {
            try? fileManager.removeItem(at: probe)
            return false
        }
    }

    private static func chosenCLIDirectory() throws -> URL {
        for directory in cliDirectories where writableDirectory(directory) { return directory }
        let fallback = cliFallbackDirectory
        do {
            try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
        } catch {
            throw Tools.Failure(text: "Could not create \(fallback.path): \(error.localizedDescription)")
        }
        guard writableDirectory(fallback) else {
            throw Tools.Failure(text: "No writable Copper CLI directory was found (tried /opt/homebrew/bin, /usr/local/bin and \(fallback.path)).")
        }
        return fallback
    }

    private static func shellPath() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "echo $PATH"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            return nil
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    func cli() throws -> Report {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/copper")
        let bundledAttributes = try? Self.fileManager.attributesOfItem(atPath: bundled.path)
        guard Self.fileManager.fileExists(atPath: bundled.path),
              bundledAttributes?[.type] as? FileAttributeType == .typeRegular else {
            throw Tools.Failure(text: "Copper's bundled CLI shim is missing at \(bundled.path); rebuild Copper before installing it.")
        }
        let directory = try Self.chosenCLIDirectory()
        let destination = directory.appendingPathComponent(Self.cliName)
        if Self.fileManager.fileExists(atPath: destination.path) || (try? Self.fileManager.attributesOfItem(atPath: destination.path)) != nil {
            let attributes = try? Self.fileManager.attributesOfItem(atPath: destination.path)
            if attributes?[.type] as? FileAttributeType != .typeSymbolicLink {
                throw Tools.Failure(text: "Refusing to overwrite the existing regular file at \(destination.path).")
            }
            try Self.fileManager.removeItem(at: destination)
        }
        do {
            try Self.fileManager.createSymbolicLink(at: destination, withDestinationURL: bundled)
        } catch {
            throw Tools.Failure(text: "Could not install the Copper CLI at \(destination.path): \(error.localizedDescription)")
        }

        var notes = ["Installed the Copper CLI shim at \(destination.path)."]
        if let path = Self.shellPath() {
            let components = path.split(separator: ":").map(String.init)
            if !components.contains(directory.path) {
                notes.append("\(directory.path) is not in your shell PATH; open a new shell or add it to PATH.")
            }
        } else {
            notes.append("Could not read your shell PATH within 3 seconds; assume \(directory.path) is not in it.")
        }
        return Report(paths: [destination.path], notes: notes)
    }

    private func readRoot(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }
        return root
    }

    private func matches(_ root: [String: Any], toolMode: Bool) -> Bool {
        guard let servers = root["mcpServers"] as? [String: Any],
              let copper = servers["copper"] as? [String: Any],
              copper["type"] as? String == "http",
              copper["url"] as? String == endpoint,
              let headers = copper["headers"] as? [String: Any],
              headers["Authorization"] as? String == "Bearer \(token)"
        else { return false }
        return !toolMode || copper["toolMode"] as? String == "eager"
    }

    private static func hasMarker(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    private func configState(at config: URL, prompt: URL, toolMode: Bool) -> State {
        let configPresent = Self.fileManager.fileExists(atPath: config.path)
        let promptPresent = Self.fileManager.fileExists(atPath: prompt.path)
        guard configPresent || promptPresent else { return .missing }
        guard configPresent, promptPresent, let root = readRoot(config), matches(root, toolMode: toolMode), Self.hasMarker(prompt) else {
            return .stale
        }
        return .ready
    }

    private static func sameTarget(_ link: URL, _ target: URL, directory: URL) -> Bool {
        guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let resolved = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : directory.appendingPathComponent(raw)
        return resolved.standardizedFileURL.path == target.standardizedFileURL.path
    }

    private static func cliState() -> State {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/copper")
        for directory in cliDirectories + [cliFallbackDirectory] {
            let link = directory.appendingPathComponent(cliName)
            guard fileManager.fileExists(atPath: link.path) || (try? fileManager.attributesOfItem(atPath: link.path)) != nil else { continue }
            guard (try? fileManager.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType == .typeSymbolicLink,
                  sameTarget(link, bundled, directory: directory)
            else { return .stale }
            return .ready
        }
        return .missing
    }

    func status() -> Status {
        Status(phi: configState(at: Self.phiConfig, prompt: Self.phiPrompt, toolMode: true),
               claude: configState(at: Self.claudeConfig, prompt: Self.claudePrompt, toolMode: false),
               cli: Self.cliState())
    }
}
