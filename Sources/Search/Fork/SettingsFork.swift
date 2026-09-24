import AppKit
import SwiftUI

// Two pages of Settings that upstream doesn't have: Intelligence (the keys
// and what they're for) and Agents (the MCP server). Drawn with upstream's
// own cards and lines so they read as part of the same panel.

// MARK: - Intelligence

struct IntelligencePage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var brain = Intelligence.shared
    @ObservedObject var groups = Groups.shared
    @ObservedObject var grouper = Grouper.shared

    @State private var testing = false
    @State private var verdict: String?
    @State private var newPattern = ""
    @State private var newGroup = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Caption("Keys")
            Card {
                Line("Jev", "TypeSafe's System One: answers a typed question — which of these, how likely — in a fifth of a second, with a confidence. The fast lane.") {
                    KeyField(text: $brain.keys.jevKey, placeholder: "ts-…", ready: brain.jevReady)
                }
                Rule()
                Line("Router", "An OpenAI-compatible gateway (LiteLLM). Used when Jev is unsure, and whenever something has to be named.") {
                    KeyField(text: $brain.keys.routerKey, placeholder: "sk-…", ready: brain.routerReady)
                }
                Rule()
                Line("Router address", "Where the gateway lives") {
                    TextField("https://…", text: $brain.keys.routerURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 220)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Rule()
                Line("Router model", "The model name the gateway routes on — sonnet, luna, auto…") {
                    TextField("sonnet", text: $brain.keys.routerModel)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 120)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Rule()
                Line("Check the keys", verdict ?? "One question each way, so you know before a tab does") {
                    if testing { Ring(size: 12) } else { Pill("Test") { test() } }
                }
            }

            Caption("Tab groups")
            Card {
                Line("Group new tabs", "A second after a page lands, Copper weighs it against the groups you have. Ask puts a line under the tab; Automatic just does it.") {
                    Segmented(options: Intelligence.GroupingMode.allCases.map { ($0, $0.title) }, selection: $brain.keys.grouping)
                }
                Rule()
                Line("Take Jev's word from", String(format: "%.0f%% confidence. Below it the router is asked, or nothing happens.", brain.keys.threshold * 100)) {
                    Slider(value: $brain.keys.threshold, in: 0.3...0.95, step: 0.05).frame(width: 140)
                }
                Rule()
                Line("Last decision", grouper.lastNote.isEmpty ? "Nothing weighed yet" : grouper.lastNote) {
                    Pill("Ask about this tab") {
                        guard let tab = browser.active else { return }
                        browser.tuning = false
                        grouper.suggest(for: tab, in: browser, forced: true)
                    }
                    .disabled(browser.active?.isBlank ?? true)
                }
            }

            Caption("Rules — these sites always go here, no model asked")
            Card {
                ForEach(groups.rules) { rule in
                    HStack(spacing: 10) {
                        Text(rule.pattern).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Palette.faint)
                        Text(rule.group).font(.system(size: 12)).foregroundStyle(Palette.ink)
                        Spacer()
                        Button { groups.rules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    Rule()
                }
                HStack(spacing: 8) {
                    TextField("github.com or *.atlassian.net", text: $newPattern)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Palette.faint)
                    TextField("Group name", text: $newGroup)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .frame(width: 140)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onSubmit(addRule)
                    Pill("Add", filled: true, action: addRule)
                        .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty || newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
            }

            Text("Keys are kept in intelligence.json beside your session, readable by you alone. Only a tab's address and title, and the names and sites of your groups, are sent — never page contents.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addRule() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        let group = newGroup.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !group.isEmpty else { return }
        groups.rules.append(GroupRule(pattern: pattern, group: group))
        newPattern = ""
        newGroup = ""
    }

    private func test() {
        testing = true
        verdict = nil
        let keys = brain.keys
        Task { @MainActor in
            var lines: [String] = []
            if brain.jevReady {
                do {
                    let a = try await Jev.ask(state: ["word": "apple"], questions: ["kind": Jev.choice("What is `word`?", ["fruit": "a fruit", "tool": "a tool"])], keys: keys)
                    lines.append(String(format: "Jev ✓ %.0f ms", a.latencyMs))
                } catch { lines.append("Jev ✗ \(error.localizedDescription)") }
            } else { lines.append("Jev — no key") }
            if brain.routerReady {
                do {
                    let r = try await Router.ask(system: "Reply with JSON only.", user: "{\"ping\": true} → reply {\"pong\": true}", keys: keys, timeout: 15, maxTokens: 20)
                    lines.append(String(format: "Router ✓ %@ %.0f ms", r.model, r.latencyMs))
                } catch { lines.append("Router ✗ \(error.localizedDescription)") }
            } else { lines.append("Router — no key") }
            verdict = lines.joined(separator: " · ")
            testing = false
        }
    }
}

/// A secret, shown as dots until you want to see it, with a paste button so
/// setting a key is one click.
struct KeyField: View {
    @Binding var text: String
    let placeholder: String
    let ready: Bool
    @State private var shown = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ready ? Color.green.opacity(0.8) : Palette.faint).frame(width: 6, height: 6)
            Group {
                if shown {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 200)
            Button { shown.toggle() } label: {
                Image(systemName: shown ? "eye.slash" : "eye").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help(shown ? "Hide" : "Show")
            Button {
                if let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
                    text = pasted
                }
            } label: {
                Image(systemName: "doc.on.clipboard").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help("Paste")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - Agents

struct AgentsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var mcp = MCP.shared
    @ObservedObject var brain = Intelligence.shared
    @ObservedObject var chat = Agent.shared
    @ObservedObject var servers = Servers.shared
    @State private var copied: String?

    private var serversLine: String {
        if let trouble = servers.trouble { return trouble }
        if servers.all.isEmpty { return "The mcp.json shape Claude Code and phi use — http servers with headers, or a command to run. ${VAR} is filled from the environment." }
        return "\(servers.all.filter(\.ready).count) of \(servers.all.count) connected · \(servers.readyTools) tools"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Let agents drive this window", "An MCP server on this Mac only (127.0.0.1). Claude Code, phi, Cursor and the rest see your open tabs and act in them — the same tools as Playwright MCP, on the browser you're already signed into.") {
                    Switch(on: $mcp.config.enabled)
                }
                Rule()
                Line("Status", status) {
                    Circle().fill(mcp.running ? Color.green.opacity(0.8) : Palette.faint).frame(width: 8, height: 8)
                }
                Rule()
                Line("Say what the agent does", "Each tool call, in the line at the bottom of the window") {
                    Switch(on: $mcp.config.announces)
                }
                Rule()
                Line("Port", "Change it if something else has \(mcp.config.port)") {
                    TextField("4123", value: $mcp.config.port, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 60)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }

            Caption("Jev mode — ultrafast")
            Card {
                Line("Let the agent hand Copper a goal", "Adds jev_run, jev_step, jev_observe and jev_extract — browser-use's jev-ultrafast loop, run in this window. Jev picks an operation and an element every ~200 ms; Copper does it with real clicks and keys until the goal is done. Seconds, not a round trip per step.") {
                    Switch(on: $mcp.config.jev)
                }
                if mcp.config.jev {
                    Rule()
                    Line("Jev key", brain.jevReady ? "TypeSafe System One — the same key as Intelligence" : "Needed. A TypeSafe key (ts-…) — typesafe.ai. Shared with Settings › Intelligence.") {
                        KeyField(text: $brain.keys.jevKey, placeholder: "ts-…", ready: brain.jevReady)
                    }
                    Rule()
                    Line("Text model", brain.routerReady ? "Writes what gets typed and answers jev_extract, through the router. Small and fast is the point — empty means the router model (\(brain.keys.routerModel))." : "TYPE_TEXT and jev_extract need the router — add a key under Settings › Intelligence") {
                        HStack(spacing: 8) {
                            Circle().fill(brain.routerReady ? Color.green.opacity(0.8) : Color.orange.opacity(0.8)).frame(width: 8, height: 8)
                            TextField(brain.keys.routerModel, text: $brain.keys.textModel)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 120)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                    Rule()
                    Line("Prompt for your agent", "One paragraph: how to connect, and to hand over goals with jev_run. Paste it into the chat.") {
                        Pill(copied == "jevprompt" ? "Copied" : "Copy prompt", filled: true) { copy(mcp.jevPrompt, "jevprompt") }
                    }
                    if !mcp.jevNote.isEmpty {
                        Rule()
                        Line("Last run", mcp.jevNote) { EmptyView() }
                    }
                }
            }

            Caption("The agent in the window — ⌘E")
            Card {
                Line("Model", brain.routerReady ? "Through the router. Empty means the router model (\(brain.keys.routerModel)); it needs tool calling." : "Needs the router key — Settings › Intelligence") {
                    TextField(brain.keys.routerModel, text: $chat.config.model)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 120)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Rule()
                Line("Page in front of every question", "The current tab's address, title and the first 3000 characters of its text. Off, it still has the tools to look.") {
                    Switch(on: $chat.config.pageContext)
                }
                Rule()
                Line("Your other MCP servers", serversLine) {
                    HStack(spacing: 8) {
                        Pill("Open mcp.json") {
                            if !FileManager.default.fileExists(atPath: Servers.file.path) {
                                try? Servers.example.data(using: .utf8)?.write(to: Servers.file, options: .atomic)
                            }
                            NSWorkspace.shared.open(Servers.file)
                        }
                        Pill("Reload", filled: true) { Task { await servers.reload() } }
                    }
                }
                ForEach(servers.all) { server in
                    Rule()
                    ServerRow(server: server)
                }
            }

            Caption("Connect a client")
            Card {
                Line("Prompt for your agent", "One paragraph: where Copper listens, the token, and the Playwright-shaped tools it has. Paste it into the chat.") {
                    Pill(copied == "prompt" ? "Copied" : "Copy prompt", filled: true) { copy(mcp.agentPrompt, "prompt") }
                }
                Rule()
                Line("Claude Code / phi / Cursor (HTTP)", "Paste into ~/.claude.json, ~/.pi/agent/mcp.json or the editor's MCP settings") {
                    Pill(copied == "http" ? "Copied" : "Copy config") { copy(mcp.clientConfig, "http") }
                }
                Rule()
                Line("Claude Desktop and other stdio clients", "Runs this app with --mcp-stdio as a pipe to the running window; launches Copper if it isn't up") {
                    Pill(copied == "stdio" ? "Copied" : "Copy config") { copy(mcp.stdioConfig, "stdio") }
                }
                Rule()
                Line("One-liner for Claude Code", "claude mcp add --transport http copper …") {
                    Pill(copied == "cli" ? "Copied" : "Copy") {
                        copy("claude mcp add --transport http copper \(mcp.endpoint) --header \"Authorization: Bearer \(mcp.config.token)\"", "cli")
                    }
                }
            }

            Caption("The key")
            Card {
                Line("Bearer token", "Every request must carry it. Kept in agent.json, readable by you alone. Rotate it and every client's config goes stale — on purpose.") {
                    HStack(spacing: 8) {
                        Text(String(mcp.config.token.prefix(8)) + "…")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
                        Pill(copied == "token" ? "Copied" : "Copy") { copy(mcp.config.token, "token") }
                        Pill("Rotate") { mcp.rotateToken() }
                    }
                }
            }

            if mcp.calls > 0 {
                Text("\(mcp.calls) tool call\(mcp.calls == 1 ? "" : "s") this session — last: \(mcp.lastTool)")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Text("Agents act as you: whatever you are signed into, they are too. Turn this off when you don't need it.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: String {
        if let trouble = mcp.trouble { return trouble }
        if mcp.running { return "Listening at \(mcp.endpoint)" }
        return mcp.config.enabled ? "Starting…" : "Off"
    }

    private func copy(_ text: String, _ tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == tag { copied = nil } }
    }
}


/// One configured server: name, where it is, and whether it answered.
struct ServerRow: View {
    @ObservedObject var server: Server

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(colour).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                Text(server.spec.line).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(server.ready ? "\(server.tools.count) tool\(server.tools.count == 1 ? "" : "s")" : server.state)
                .font(.system(size: 11)).foregroundStyle(server.state.hasPrefix("failed") ? Color.orange : Palette.muted)
                .lineLimit(2).frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var colour: Color {
        if server.ready { return Color.green.opacity(0.8) }
        if server.state == "connecting" { return Color.yellow.opacity(0.8) }
        if server.state.hasPrefix("failed") { return Color.orange.opacity(0.85) }
        return Palette.faint
    }
}
