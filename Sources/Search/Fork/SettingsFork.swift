import AppKit
import SwiftUI

// Two pages of Settings that upstream doesn't have: Intelligence (the keys
// and what they're for) and Agents (the MCP server). Drawn with upstream's
// own cards and lines so they read as part of the same panel.

// MARK: - Intelligence

struct IntelligencePage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var brain = Intelligence.shared
    @ObservedObject var account = ClaudeAccount.shared

    @State private var testing = false
    @State private var verdict: String?
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection("Model access") {
                Line("Use", "Sign in with your Claude account (Pro, Max, Team or Enterprise), or paste a key for an OpenAI-compatible gateway such as LiteLLM.") {
                    Segmented(options: Intelligence.Lane.allCases.map { ($0, $0.title) }, selection: $brain.keys.lane)
                }
                .settingsAnchor("intelligence.lane")
                Rule()
                laneRows
                Rule()
                Line("Model", modelDetail) {
                    Segmented(options: Intelligence.Tier.allCases.map { ($0, $0.title) }, selection: $brain.keys.tier)
                }
                .settingsAnchor("intelligence.tier")
                Rule()
                Line("Model names", brain.keys.lane == .claude ? "What Haiku, Sonnet and Opus are called at Anthropic" : "What Haiku, Sonnet and Opus are called on your gateway") {
                    modelNames
                }
                .settingsAnchor("intelligence.names")
                Rule()
                Line("Check", verdict ?? "One question each way, so you know before a tab does") {
                    if testing { Ring(size: 12) } else { Pill("Test") { test() } }
                }
                .settingsAnchor("intelligence.check")
            }

            SettingsSection("Jev — the fast lane", note: brain.cloud == nil
                 ? "Keys and the Claude sign-in are kept in intelligence.json and claude.json beside your session, readable by you alone."
                 : "Keys and the Claude sign-in are kept in intelligence.json and claude.json beside your session, readable by you alone. Keys from Copper Cloud stay in cloud-intelligence.json and go when you sign out of the cloud; a key typed here always wins.") {
                Line("Jev", brain.cloudLine("jevKey", brain.cloud?.jev?.key) ?? "TypeSafe's System One: answers a typed question — which of these, how likely — in a fifth of a second, with a confidence. The fast lane.") {
                    KeyField(text: $brain.keys.jevKey, placeholder: brain.cloudPlaceholder("jevKey", brain.cloud?.jev?.key, otherwise: "ts-…"), ready: brain.jevReady)
                }
                .settingsAnchor("intelligence.jev")
            }
        }
    }

    @ViewBuilder
    private var laneRows: some View {
        if brain.keys.lane == .claude {
            Line("Claude account", accountDetail) {
                accountControl
            }
            .settingsAnchor("intelligence.account")
        } else {
            Line("API key", brain.cloudLine("routerKey", brain.cloud?.router?.key) ?? "For an OpenAI-compatible gateway — LiteLLM, or anything that speaks /v1/chat/completions") {
                KeyField(text: $brain.keys.routerKey, placeholder: brain.cloudPlaceholder("routerKey", brain.cloud?.router?.key, otherwise: "sk-…"), ready: brain.routerReady)
            }
            .settingsAnchor("intelligence.key")
            Rule()
            Line("Gateway address", brain.sources["routerURL"] == "cloud"
                 ? "Provided by Copper Cloud (\(brain.cloud?.host ?? "your cloud"))"
                 : "Where the gateway lives") {
                TextField(brain.sources["routerURL"] == "cloud" ? brain.effective.routerURL : "https://…", text: routerURLBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 220)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .settingsAnchor("intelligence.gateway")
        }
    }

    /// The address field. While Copper Cloud supplies the address it reads
    /// empty, the cloud's address as its placeholder; typing one overrides
    /// it, and clearing it goes back to the cloud's (or the default).
    private var routerURLBinding: Binding<String> {
        Binding(
            get: {
                let local = brain.keys.routerURL
                return brain.sources["routerURL"] == "cloud" && local.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")) == Intelligence.Keys().routerURL ? "" : local
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                brain.keys.routerURL = trimmed.isEmpty && brain.sources["routerKey"] == "cloud" ? Intelligence.Keys().routerURL : value
            }
        )
    }

    /// The tier, the name sent for it, and the model the last answer named.
    private var modelDetail: String {
        let line = "\(brain.tier.title) — \(brain.tier.blurb). Sends \(brain.modelName)"
        if let answered = brain.answeredModel, answered != brain.modelName { return line + "; answered by \(answered)." }
        return line + ". Also in the agent pane's header."
    }

    private var accountDetail: String {
        if account.signedIn {
            var detail = "Signed in as \(account.who)"
            if let organization = account.credential?.organization, !organization.isEmpty {
                detail += " · \(organization)"
            }
            return detail
        }
        switch account.phase {
        case .idle:
            return "One click. Copper opens claude.ai in a tab; sign in there and come back."
        case .waiting:
            return "Finish in the tab that opened. If it did not come back on its own, paste what claude.ai shows here."
        case .exchanging:
            return "Finishing…"
        case .failed(let text):
            return text
        }
    }

    @ViewBuilder
    private var accountControl: some View {
        if account.signedIn {
            Pill("Sign out") { account.signOut() }
        } else {
            switch account.phase {
            case .idle:
                Pill("Sign in", filled: true) { account.signIn(in: browser) }
            case .waiting:
                HStack(spacing: 6) {
                    Ring(size: 12)
                    TextField("code or the address it sent you to", text: $pasted)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 190)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onSubmit(completePasted)
                    Pill("Cancel") { account.cancel() }
                }
            case .exchanging:
                Ring(size: 12)
            case .failed:
                Pill("Try again", filled: true) { account.signIn(in: browser) }
            }
        }
    }

    /// Three short rows, not three fields side by side: the card is not
    /// wide enough for that beside a title, and a name is easier to read
    /// next to the size it stands for.
    private var modelNames: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Intelligence.Tier.allCases) { tier in
                HStack(spacing: 6) {
                    Text(tier.title).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .lineLimit(1).fixedSize()
                    TextField(defaultModel(for: tier), text: modelBinding(tier))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 150)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private func defaultModel(for tier: Intelligence.Tier) -> String {
        let defaults = brain.keys.lane == .claude ? Intelligence.Keys.defaultClaudeModels : Intelligence.Keys.defaultRouterModels
        return defaults[tier.rawValue] ?? tier.rawValue
    }

    private func modelBinding(_ tier: Intelligence.Tier) -> Binding<String> {
        Binding(
            get: {
                let map = brain.keys.lane == .claude ? brain.keys.claudeModels : brain.keys.routerModels
                return map[tier.rawValue] ?? defaultModel(for: tier)
            },
            set: { value in
                if brain.keys.lane == .claude {
                    brain.keys.claudeModels[tier.rawValue] = value
                } else {
                    brain.keys.routerModels[tier.rawValue] = value
                }
            }
        )
    }

    private func completePasted() {
        let value = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        pasted = ""
        account.complete(pasted: value)
    }

    private func test() {
        testing = true
        verdict = nil
        let keys = brain.effective
        Task { @MainActor in
            var lines: [String] = []
            if brain.jevReady {
                do {
                    let a = try await Jev.ask(state: ["word": "apple"], questions: ["kind": Jev.choice("What is `word`?", ["fruit": "a fruit", "tool": "a tool"])], keys: keys)
                    lines.append(String(format: "Jev ✓ %.0f ms", a.latencyMs))
                } catch { lines.append("Jev ✗ \(error.localizedDescription)") }
            } else { lines.append("Jev — no key") }
            let lane = brain.keys.lane
            let label = lane == .claude ? "Claude" : "Gateway"
            if brain.modelReady {
                do {
                    let r = try await Router.ask(system: "Reply with JSON only.", user: "{\"ping\": true} → reply {\"pong\": true}", keys: keys, timeout: 15, maxTokens: 20)
                    lines.append(String(format: "%@ ✓ %@ %.0f ms", label, r.model, r.latencyMs))
                } catch { lines.append("\(label) ✗ \(error.localizedDescription)") }
            } else {
                lines.append(lane == .claude ? "Claude — not signed in" : "Gateway — no key")
            }
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

// MARK: - Updates

struct UpdatesPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var updates = Updates.shared

    private var isDevBuild: Bool {
        Fork.version == "dev" || Fork.version.split(separator: ".").count == 2
    }

    private var currentLine: String {
        "You have \(Updater.version) (build \(Updater.build))" + (isDevBuild ? " · dev build" : "")
    }

    private var latestLine: String {
        if let error = updates.error { return "Couldn't check: \(error)" }
        guard let latest = updates.latest else { return "Couldn't check: Not checked yet." }
        guard updates.available else { return "Up to date" }
        let date = Self.publishedDate(latest.publishedAt)
        return "Latest Copper \(latest.version) · \(date)"
    }

    private var installLine: String {
        "Updates come from \(updates.feedHost)" + (updates.managedByBrew ? " · installed via Homebrew" : "")
    }

    /// What the last update left behind, in one sentence. A failure stays
    /// here until the next update, next to the button that retries it.
    private var outcomeLine: (title: String, detail: String)? {
        guard let outcome = updates.outcome else { return nil }
        let when = outcome.at.formatted(.relative(presentation: .named))
        if outcome.ok { return ("Updated to \(outcome.detail)", when) }
        return ("The last update didn’t finish", "\(outcome.detail) · \(when)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSection("This Copper") {
                Line(currentLine, latestLine) {
                    if updates.checking {
                        Ring(size: 12)
                    } else {
                        Pill("Check now") { updates.check(force: true) }
                    }
                }
                .settingsAnchor("updates.check")
                if updates.available, let version = updates.latest?.version {
                    Rule()
                    // The three states of a newer release: on its way, ready
                    // (the only one with an Update button), or not obtained —
                    // with the reason, and a way to try again.
                    Group {
                    if updates.downloading {
                        Line("Getting Copper \(version) ready", "Downloading from \(updates.feedHost) and verifying the bundle") {
                            Ring(size: 12)
                        }
                    } else if updates.ready {
                        Line("Copper \(version) is ready", "Downloaded and verified. Update backs up your tabs, swaps in the new Copper and relaunches — a few seconds.") {
                            Pill(updates.state == .upgrading ? "Updating…" : "Update", filled: true) {
                                updates.upgrade()
                            }
                            .disabled(updates.state == .upgrading)
                        }
                    } else {
                        Line("Copper \(version) isn’t downloaded yet", updates.stageError ?? "It downloads on its own after a check; Download gets it now.") {
                            Pill(updates.stageError == nil ? "Download" : "Retry") { updates.stage(force: true) }
                        }
                    }
                    }
                    .settingsAnchor("updates.install")
                }
                if let outcome = outcomeLine, updates.outcome?.ok == false {
                    Rule()
                    Line(outcome.title, outcome.detail) {
                        Pill("Open log") { NSWorkspace.shared.open(Updates.log) }
                    }
                }
            }
            // Why an update could not start in this process ("not downloaded
            // yet", "no longer there"). A refusal that was recorded as the
            // outcome is already in the card above, so it is not repeated.
            if let problem = updates.problem, updates.outcome?.detail != problem {
                SettingsNote(problem)
            }
            VStack(alignment: .leading, spacing: 4) {
                SettingsNote(installLine)
                if let outcome = outcomeLine, updates.outcome?.ok == true {
                    SettingsNote("\(outcome.title) · \(outcome.detail)")
                }
                if let checked = updates.checkedAt {
                    SettingsNote("Last checked \(checked.formatted(.relative(presentation: .named)))")
                }
            }
            .settingsAnchor("updates.source")
        }
    }

    private static func publishedDate(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: raw) else { return raw }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Agents

struct AgentsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var mcp = MCP.shared
    @ObservedObject var brain = Intelligence.shared
    @ObservedObject var chat = Agent.shared
    @ObservedObject var servers = Servers.shared
    @ObservedObject var links = AgentLinks.shared
    @State private var copied: String?
    @State private var setupStatus = Setup.Status()
    @State private var setupResult: [String: String] = [:]

    private var serversLine: String {
        if let trouble = servers.trouble { return trouble }
        if servers.all.isEmpty { return "The mcp.json shape Claude Code and phi use — http servers with headers, or a command to run. ${VAR} is filled from the environment." }
        return "\(servers.all.filter(\.ready).count) of \(servers.all.count) connected · \(servers.readyTools) tools"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection("MCP server") {
                Line("Let agents drive this window", "An MCP server on this Mac only (127.0.0.1). Claude Code, phi, Cursor and the rest see your open tabs and act in them — the same tools as Playwright MCP, on the browser you're already signed into.") {
                    Switch(on: $mcp.config.enabled)
                }
                .settingsAnchor("agents.server")
                Rule()
                Line("Status", status) {
                    Circle().fill(mcp.running ? Color.green.opacity(0.8) : Palette.faint).frame(width: 8, height: 8)
                }
                .settingsAnchor("agents.status")
                Rule()
                Line("Say what the agent does", "Each tool call, in the line at the bottom of the window") {
                    Switch(on: $mcp.config.announces)
                }
                .settingsAnchor("agents.announce")
                Rule()
                Line("Port", "Change it if something else has \(mcp.config.port)") {
                    TextField("4123", value: $mcp.config.port, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 60)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .settingsAnchor("agents.port")
            }

            SettingsSection("Jev mode — ultrafast") {
                Line("Let the agent hand Copper a goal", "Adds jev_run, jev_step, jev_observe and jev_extract — browser-use's jev-ultrafast loop, run in this window. Jev picks an operation and an element every ~200 ms; Copper does it with real clicks and keys until the goal is done. Seconds, not a round trip per step.") {
                    Switch(on: $mcp.config.jev)
                }
                .settingsAnchor("agents.jev")
                if mcp.config.jev {
                    Rule()
                    Line("Jev key", brain.cloudLine("jevKey", brain.cloud?.jev?.key) ?? (brain.jevReady ? "TypeSafe System One — the same key as Intelligence" : "Needed. A TypeSafe key (ts-…) — typesafe.ai. Shared with Settings › Intelligence.")) {
                        KeyField(text: $brain.keys.jevKey, placeholder: brain.cloudPlaceholder("jevKey", brain.cloud?.jev?.key, otherwise: "ts-…"), ready: brain.jevReady)
                    }
                    .settingsAnchor("agents.jevkey")
                    Rule()
                    Line("Text model", brain.modelReady ? "Writes what gets typed and answers jev_extract. Small and fast is the point — empty means the model you picked (\(brain.modelName))." : "TYPE_TEXT and jev_extract need a model — Settings › Intelligence › Model access") {
                        HStack(spacing: 8) {
                            Circle().fill(brain.modelReady ? Color.green.opacity(0.8) : Color.orange.opacity(0.8)).frame(width: 8, height: 8)
                            TextField(brain.modelName, text: $brain.keys.textModel)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 120)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                    .settingsAnchor("agents.textmodel")
                    if !mcp.jevNote.isEmpty {
                        Rule()
                        Line("Last run", mcp.jevNote) { EmptyView() }
                    }
                }
            }

            SettingsSection("Your agents — let them use this browser", carded: false) {
                ForEach(links.all) { link in
                    LinkCard(link: link)
                }
                Card {
                    Line("Add an agents app", "Paste its address and a personal token") {
                        Pill("Add…", filled: true) { links.addEmpty() }
                    }
                    .settingsAnchor("agents.add")
                }
            }
            .settingsAnchor("agents.links", card: true)

            SettingsSection("The agent in the window — ⌘E") {
                Line("Page in front of every question", "The current tab's address, title and the first 3000 characters of its text. Off, it still has the tools to look.") {
                    Switch(on: $chat.config.pageContext)
                }
                .settingsAnchor("agents.context")
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
                .settingsAnchor("agents.servers")
                ForEach(servers.all) { server in
                    Rule()
                    ServerRow(server: server)
                }
            }

            SettingsSection("Terminal agents") {
                terminalRow(.phi)
                    .settingsAnchor("agents.phi")
                Rule()
                terminalRow(.claude)
                    .settingsAnchor("agents.claude")
                Rule()
                terminalRow(.cli)
                    .settingsAnchor("agents.cli")
                Rule()
                Line("Copy /jev", "A goal-first command for the agent in your terminal") {
                    Pill(copied == "jev" ? "Copied" : "Copy /jev", filled: true) { copy(MCP.jevCommand(goal: nil), "jev") }
                }
                .settingsAnchor("agents.copyjev")
                Rule()
                Line("Copy prompt", mcp.config.jev ? "Jev-first instructions for this mode" : "Snapshot-first instructions for this mode") {
                    Pill(copied == "prompt" ? "Copied" : "Copy prompt", filled: true) {
                        copy(mcp.config.jev ? mcp.jevPrompt : mcp.agentPrompt, "prompt")
                    }
                }
                .settingsAnchor("agents.prompt")
                Rule()
                Line("Copy config", "The current HTTP config for a client that is not set up yet") {
                    Pill(copied == "http" ? "Copied" : "Copy config") { copy(mcp.clientConfig, "http") }
                }
                .settingsAnchor("agents.config")
                Rule()
                VStack(alignment: .leading, spacing: 4) {
                    Line("Copy install command", "The one-liner for the Copper CLI") {
                        Pill(copied == "install" ? "Copied" : "Copy install") { copy(Setup.installCommand, "install") }
                    }
                    Text(Setup.installCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SettingsInk.detail)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                    Text("Alternative: \(Setup.brewCommand)")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsInk.detail)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                .settingsAnchor("agents.install")
            }

            VStack(alignment: .leading, spacing: 10) {
            SettingsSection("The key") {
                Line("Bearer token", "Every request must carry it. Kept in agent.json, readable by you alone. Rotate it and every client's config goes stale — on purpose.") {
                    HStack(spacing: 8) {
                        Text(String(mcp.config.token.prefix(8)) + "…")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
                        Pill(copied == "token" ? "Copied" : "Copy") { copy(mcp.config.token, "token") }
                        Pill("Rotate") { mcp.rotateToken() }
                    }
                }
                .settingsAnchor("agents.token")
            }
            VStack(alignment: .leading, spacing: 4) {
                if mcp.calls > 0 {
                    SettingsNote("\(mcp.calls) tool call\(mcp.calls == 1 ? "" : "s") this session — last: \(mcp.lastTool)")
                }
                SettingsNote("Agents act as you: whatever you are signed into, they are too. Turn this off when you don't need it.")
            }
            }
        }
        .onAppear { setupStatus = Setup(endpoint: mcp.endpoint, token: mcp.config.token).status() }
    }

    private enum TerminalAgent: String {
        case phi, claude, cli

        var title: String {
            switch self {
            case .phi: return "phi"
            case .claude: return "Claude Code"
            case .cli: return "copper CLI"
            }
        }

        var detail: String {
            switch self {
            case .phi: return "User-scoped ~/.pi/agent/mcp.json and /jev prompt"
            case .claude: return "User-scoped ~/.claude.json and /jev command"
            case .cli: return "The bundled copper command in your PATH"
            }
        }
    }

    @ViewBuilder
    private func terminalRow(_ agent: TerminalAgent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Line(agent.title, setupResult[agent.rawValue] ?? agent.detail) {
                HStack(spacing: 8) {
                    Text(stateTitle(state(for: agent)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                    Pill(actionTitle(for: agent), filled: state(for: agent) != .ready) {
                        runSetup(agent)
                    }
                }
            }
            if let result = setupResult[agent.rawValue] {
                Text(result)
                    .font(.system(size: 10.5))
                    .foregroundStyle(result.hasPrefix("Error") ? Color.orange.opacity(0.9) : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
    }

    private func state(for agent: TerminalAgent) -> Setup.State {
        switch agent {
        case .phi: return setupStatus.phi
        case .claude: return setupStatus.claude
        case .cli: return setupStatus.cli
        }
    }

    private func stateTitle(_ state: Setup.State) -> String {
        switch state {
        case .missing: return "Not set up"
        case .stale: return "Update"
        case .ready: return "Ready"
        }
    }

    private func actionTitle(for agent: TerminalAgent) -> String {
        switch agent {
        case .phi, .claude: return state(for: agent) == .missing ? "Set up" : "Update"
        case .cli: return "Install"
        }
    }

    private func runSetup(_ agent: TerminalAgent) {
        do {
            let report: Setup.Report
            let setup = Setup(endpoint: mcp.endpoint, token: mcp.config.token)
            switch agent {
            case .phi: report = try setup.phi()
            case .claude: report = try setup.claude()
            case .cli: report = try setup.cli()
            }
            setupResult[agent.rawValue] = (report.paths + report.notes).joined(separator: "\\n")
        } catch {
            let text = (error as? Tools.Failure)?.text ?? error.localizedDescription
            setupResult[agent.rawValue] = "Error: \(text)"
        }
        setupStatus = Setup(endpoint: mcp.endpoint, token: mcp.config.token).status()
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


// MARK: - agents

/// The agent link (Fork/MCP/Link.swift): on or off, where, the token, and
/// — once linked — who may use it and what they did.
struct LinkCard: View {
    @ObservedObject var link: AgentLink
    @State private var confirmRevoke = false
    @State private var confirmRemove = false

    private var linked: Bool { link.config.enabled && link.config.linkId != nil }

    private var ungranted: [AgentLink.Bot] {
        let granted = Set(link.grants.map(\.botId))
        return link.bots.filter { !granted.contains($0.id) }
    }

    private var dot: Color {
        switch link.status {
        case .online: return Color.green.opacity(0.8)
        case .connecting: return Color.yellow.opacity(0.8)
        case .offline, .tokenRejected, .revoked: return Color.orange.opacity(0.85)
        case .off: return Palette.faint
        }
    }

    private var grantsLine: String {
        if let error = link.lastError, link.status.isOnline { return error }
        if link.grants.isEmpty { return "None yet. A bot sees nothing here until you grant it." }
        let on = link.grants.filter(\.enabled).count
        return "\(on) of \(link.grants.count) on · switch one off to pause it"
    }

    private var placementLine: String {
        link.placement == "remote" ? "Remote headless" : "This Mac — your own browser"
    }

    var body: some View {
        Card {
            Line("Connect this browser", "An agents app gets these same tools, through its own service. Each bot only after you grant it, and you see every call here.") {
                Switch(on: $link.config.enabled)
            }
            Rule()
            Line("App address", "Shown at Agents › Connect in your agents app") {
                TextField("https://…", text: $link.config.api)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 220)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            Rule()
            Line("App name", "Optional nickname used in announcements") {
                TextField("optional", text: $link.config.label)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 140)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            Rule()
            Line("Link name", link.config.name) { EmptyView() }
            Rule()
            Line("Placement", placementLine) { EmptyView() }
            if let servedBy = link.servedBy?.device {
                Rule()
                Line("Served by", servedBy) { EmptyView() }
                if !link.servingHere {
                    Text("Another Copper (\(servedBy)) is serving this link")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                }
            }
            Rule()
            Line("Personal token", "Mint one at Agents › Connect; it stays in a file only you can read") {
                KeyField(text: $link.config.token, placeholder: "fxb_…", ready: link.tokenReady)
            }
            Rule()
            Line("Status", link.status.text) {
                Circle().fill(dot).frame(width: 8, height: 8)
            }
            if linked {
                Rule()
                Line("Bots with access", grantsLine) {
                    Menu {
                        if ungranted.isEmpty {
                            Text(link.bots.isEmpty ? "No bots found" : "Every bot has access")
                        }
                        ForEach(ungranted) { bot in
                            Button(bot.name.isEmpty ? "@\(bot.handle)" : "@\(bot.handle) · \(bot.name)") {
                                Task { try? await link.setGrant(bot.id, enabled: true) }
                            }
                        }
                        Divider()
                        Button("Refresh") { Task { await load() } }
                    } label: {
                        Text("Grant a bot…").font(.system(size: 11.5))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                ForEach(link.grants) { grant in
                    Rule()
                    GrantRow(grant: grant, link: link)
                }
                if !link.recentCalls.isEmpty {
                    Rule()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Recent calls").font(.system(size: 13)).foregroundStyle(Palette.ink)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(link.recentCalls.prefix(8)) { call in
                                    Text("@\(call.handle) · \(call.tool) · \(LinkWire.duration(call.ms)) · \(LinkWire.ago(context.date.timeIntervalSince(call.at)))")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(call.ok ? Palette.muted : Color.red.opacity(0.85))
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(call.error ?? "")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }
                Rule()
                Line("Revoke link", "Every bot loses these tools now; Copper disconnects.") {
                    Pill("Revoke link", tint: Color.red.opacity(0.85)) { confirmRevoke = true }
                }
                .confirmationDialog("Revoke this link?", isPresented: $confirmRevoke) {
                    Button("Revoke link", role: .destructive) { Task { try? await link.revokeLink() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every bot loses these tools now; Copper disconnects.")
                }
            }
            Rule()
            Line("Remove this app", "Forget this app and its connection") {
                Pill("Remove", tint: Color.red.opacity(0.7)) { confirmRemove = true }
            }
            .confirmationDialog("Remove this app?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { Task { await AgentLinks.shared.remove(link) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Copper will forget this app and revoke it when possible.")
            }
        }
        .task(id: link.config.linkId.map { "\($0)\(link.config.enabled)" }) { await load() }
    }

    private func load() async {
        guard linked else { return }
        _ = try? await link.refreshGrants()
        _ = try? await link.listBots()
    }
}

/// One bot with access: who, on or off, and the × that takes it away.
private struct GrantRow: View {
    let grant: AgentLink.Grant
    @ObservedObject var link: AgentLink

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(grant.enabled ? Color.green.opacity(0.8) : Palette.faint).frame(width: 6, height: 6)
            Text("@\(grant.handle.isEmpty ? grant.botId : grant.handle)")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
            if !grant.name.isEmpty {
                Text("· \(grant.name)").font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            if !grant.toolAllowlist.isEmpty {
                Text("· \(grant.toolAllowlist.count) tool\(grant.toolAllowlist.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .help(grant.toolAllowlist.joined(separator: ", "))
            }
            Spacer()
            Switch(on: Binding(
                get: { grant.enabled },
                set: { on in Task { try? await link.setGrant(grant.botId, enabled: on) } }
            ))
            Button { Task { try? await link.removeGrant(grant.botId) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help("Take away @\(grant.handle)'s access")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
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


/// The small Settings doorway to the full Flow sheet.
struct FlowSettingsLine: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Line("Move in from another browser", "Open tabs, spaces, bookmarks and signed-in state from Chrome or Arc") {
            Pill("Flow…", filled: true) {
                browser.tuning = false
                Flow.shared.open = true
            }
        }
    }
}

/// A small, direct doorway for the part of Flow the address field can use on
/// its own. The read is off-main; this line only reports its quiet progress.
struct HistorySettingsLine: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var flow = Flow.shared

    var body: some View {
        Line("Arc history", detail) {
            if case .reading = flow.historyImport {
                Text("Reading…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
            } else {
                Pill("Bring in", filled: true) {
                    flow.importHistory(preferred: "Arc", in: browser)
                }
            }
        }
    }

    private var detail: String {
        let count = browser.history.visitCount
        // A fresh probe can retain Flow's last status while its history file
        // has been deliberately cleared; the row should describe what is
        // actually available to complete from, not that stale status.
        if count == 0 { return "Typed addresses complete from Arc or Chrome history" }
        if let detail = flow.historyImport.detail { return detail }
        return "\(count.formatted()) places kept — typed addresses complete from them"
    }
}

extension Browser {
    /// Settings, opened on one page. Spaces and Extensions are pages of it
    /// like any other: every "Edit Space…" and "Manage Extensions…" — the
    /// pill's puzzle piece, the foot's doors, the menus, ⌘K — lands here.
    func openSettings(_ page: SettingsPanel.Page) {
        settingsPage = page
        Store.settings.set(page.rawValue, forKey: "settings.page")
        tuning = true
    }
}

/// A page of Settings drawn off screen at the page's own width and laid out
/// whole, on Settings' ground — for the bench's `spaces picture` and
/// `ext-manager picture`, which get every row this way rather than the top
/// of a scroll.
@MainActor
enum SettingsPicture {
    static func draw<Page: View>(_ page: Page, dark: Bool) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: page
            .frame(width: SpacePage.width, alignment: .topLeading)
            .padding(22)
            .background(Palette.ground)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: picture)
        return picture
    }
}
