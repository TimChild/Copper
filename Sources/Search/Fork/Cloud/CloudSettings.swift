import AppKit
import SwiftUI

// Settings › Cloud: three steps, in order, each one only when the one before
// is done — connect to an instance, sign in (or create the account), choose
// what syncs. A pairing code from another signed-in Mac does all three on
// one press; signed in, the page offers to make one (Pair another Mac).
// Nothing happens until a button is pressed. Drawn with the same cards,
// lines, pills and switches as every other page.
//
// The step in front keeps its form and its button together inside the
// panel (760×640 window, 500-point panel): a finished step folds to one
// line, a field that takes focus or goes wrong is scrolled to, and — the
// Settings scroll view shows no scroller — a page longer than the panel
// fades at the bottom edge while there is more below.

struct CloudPage: View {
    @ObservedObject var browser: Browser
    /// What the Connect field starts with (the bench's `cloud picture … CODE`).
    var draft = ""
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var sync = CloudSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CloudSteps(cloud: cloud, sync: sync)
                .settingsAnchor("cloud.steps", card: true) // Fork (settings-revamp): search anchors
            if !cloud.isLinked {
                CloudConnectCard(draft: draft)
                    .settingsAnchor("cloud.connect", card: true)
            } else if !cloud.isSignedIn {
                CloudConnection(cloud: cloud, sync: sync, opener: "Change…", lead: "Connected to")
                    .settingsAnchor("cloud.instance", card: true)
                CloudAccountForm()
                    .settingsAnchor("cloud.signin", card: true)
            } else {
                CloudSyncCard(sync: sync, cloud: cloud)
                    .settingsAnchor("cloud.sync", card: true)
                if sync.on, !sync.otherDevices.isEmpty {
                    CloudDevicesCard(sync: sync)
                        .settingsAnchor("cloud.devices", card: true)
                }
                CloudAccountCard(cloud: cloud)
                    .settingsAnchor("cloud.account", card: true)
                CloudPairCard(pairing: CloudPairing.shared)
                    .settingsAnchor("cloud.pair", card: true)
                VStack(alignment: .leading, spacing: 8) {
                    Caption("Instance")
                    CloudConnection(cloud: cloud, sync: sync, opener: "Details")
                }
                .settingsAnchor("cloud.instance", card: true)
                CloudLogCard(sync: sync)
            }
        }
        .modifier(CloudMoreBelow())
        .task { if cloud.isLinked { await cloud.ping() } }
    }
}

// MARK: - where you are

private struct CloudSteps: View {
    @ObservedObject var cloud: Cloud
    @ObservedObject var sync: CloudSync

    private var step: Int { !cloud.isLinked ? 1 : (!cloud.isSignedIn ? 2 : 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browser sync — spaces, settings, bookmarks, history — and shared canvases, through a Copper Cloud instance you or your team runs.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                mark(1, "Connect")
                bar(done: step > 1)
                mark(2, "Account")
                bar(done: step > 2)
                mark(3, third)
            }
        }
    }

    /// "Sync on" once it is — the status line says how it's doing —
    /// and "Syncing…" only while a sync is actually under way.
    private var third: String {
        guard sync.on else { return "Sync" }
        return sync.state == .syncing ? "Syncing…" : "Sync on"
    }

    private func mark(_ n: Int, _ title: String) -> some View {
        let done = n < step || (n == 3 && sync.on)
        let here = n == step
        return HStack(spacing: 6) {
            ZStack {
                Circle().fill(done ? Palette.ink : (here ? Palette.ground : Palette.wash))
                Circle().strokeBorder(here && !done ? Palette.ink : Palette.hairline, lineWidth: 1)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.ground)
                } else {
                    Text("\(n)").font(.system(size: 10, weight: .semibold)).foregroundStyle(here ? Palette.ink : Palette.muted)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 12, weight: here ? .medium : .regular))
                .foregroundStyle(here || done ? Palette.ink : Palette.muted)
        }
    }

    private func bar(done: Bool) -> some View {
        Rectangle().fill(done ? Palette.ink.opacity(0.5) : Palette.hairline).frame(width: 22, height: 1)
    }
}

// MARK: - 1. connect

/// One field for either code: a link code (`#k=`, the instance's key or a
/// person's access key) connects and leaves signing in for step 2; a pairing
/// code (`#p=`, from Pair another Mac on a Copper already signed in) connects,
/// signs in and turns on sync, all on one press.
private struct CloudConnectCard: View {
    enum Field: Hashable { case code, host, key, fingerprint }

    @FocusState private var focus: Field?
    @State private var code = ""
    @State private var advanced = false
    @State private var host = ""
    @State private var key = ""
    @State private var fingerprint = ""
    @State private var connecting = false
    @State private var problem: String?
    /// A pairing code's instance showed a certificate this Mac doesn't trust
    /// and the code had no fingerprint: this is the one it showed, for a
    /// person to compare and trust on first use.
    @State private var unknown: (code: Cloud.PairingCode, seen: String)?

    init(draft: String = "") {
        _code = State(initialValue: draft)
    }

    private var parsed: Cloud.Code? {
        advanced ? Cloud.link(address: host, key: key, fingerprint: fingerprint).map(Cloud.Code.link) : Cloud.parseCode(code)
    }

    private var hint: String? {
        if advanced {
            if host.isEmpty || key.isEmpty { return nil }
            return parsed == nil ? "Check the address, the key and the fingerprint (64 hex characters, or leave it empty for a public certificate)" : nil
        }
        let typed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty || parsed != nil { return nil }
        if Cloud.isBarePairingCode(typed) {
            return "That's the pairing code without its address — copy the whole code, from copper-cloud:// to the end"
        }
        return "That isn't a link code or a pairing code — both start copper-cloud://, a link code has #k= in it and a pairing code #p="
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("1 · Connect to an instance")
            Card {
                if advanced {
                    Line("Address", "host:port, or https://…") {
                        field("cloud.example.com:443", text: $host, width: 200).focused($focus, equals: .host)
                    }
                    .cloudAnchor("cloud.connect.host")
                    Rule()
                    Line("Key", "The k= part of the link code: the instance key, or your access key") {
                        field("key", text: $key, width: 200, secure: true).focused($focus, equals: .key)
                    }
                    .cloudAnchor("cloud.connect.key")
                    Rule()
                    Line("Certificate fingerprint", "SHA-256, for a self-signed instance. Empty trusts the Mac's own roots.") {
                        field("optional", text: $fingerprint, width: 200).focused($focus, equals: .fingerprint)
                    }
                    .cloudAnchor("cloud.connect.fingerprint")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste the link code from your Copper Cloud administrator — or a pairing code from a Mac that is already signed in.")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Running your own server? `copper-cloud link-code` prints one.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            TextField("copper-cloud://host:port/#k=…  or  #p=…", text: $code, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1...3)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .code)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .onSubmit(go)
                            Button {
                                if let pasted = NSPasteboard.general.string(forType: .string) { code = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                            } label: {
                                Image(systemName: "doc.on.clipboard").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            .buttonStyle(.plain)
                            .help("Paste")
                        }
                        if let parsed { kind(parsed) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .cloudAnchor("cloud.connect.code")
                }
                if let parsed {
                    Rule()
                    Line("Instance", trust(parsed)) {
                        Text(host(parsed)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                    }
                    if let pairs = pairs(parsed) {
                        fingerprintText(pairs)
                            .help("Compare with `copper-cloud doctor` on the server")
                    }
                }
                if let unknown, case .pairing(let now)? = parsed, now == unknown.code {
                    Rule()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This Mac doesn't trust the instance's certificate, and the pairing code has no fingerprint to pin it by. Its certificate's fingerprint is:")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(cloudPairLines(Cloud.pairs(unknown.seen)))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Compare it with `copper-cloud doctor` on the server. Trusting it pins this instance to that certificate from now on.")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                Rule()
                HStack(spacing: 8) {
                    Button(advanced ? "Paste a code instead" : "Enter it by hand") {
                        withAnimation(Motion.settle) { advanced.toggle(); problem = nil; unknown = nil }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    Spacer()
                    if connecting { ProgressView().controlSize(.small) }
                    Pill(buttonTitle, filled: parsed != nil && !connecting, action: go)
                        .disabled(parsed == nil || connecting)
                        .opacity(parsed == nil ? 0.5 : 1)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .cloudAnchor("cloud.connect.submit")
            }
            .onChange(of: code) { _, _ in problem = nil }
            if let message = problem ?? hint {
                CloudProblem(message).cloudAnchor("cloud.connect.problem")
            }
        }
        .onChange(of: focus) { _, field in
            if let field { cloudReveal(Self.anchor(field)) }
        }
        // Something wrong, or a certificate to confirm: the message and the
        // button it is about, in view.
        .onChange(of: problem ?? hint) { _, message in
            if message != nil { cloudReveal("cloud.connect.problem") }
        }
        .onChange(of: parsed != nil) { _, ready in
            if ready { cloudReveal("cloud.connect.submit") }
        }
    }

    private static func anchor(_ field: Field) -> String {
        switch field {
        case .code: return "cloud.connect.code"
        case .host: return "cloud.connect.host"
        case .key: return "cloud.connect.key"
        case .fingerprint: return "cloud.connect.fingerprint"
        }
    }

    private var trusting: Bool {
        if let unknown, case .pairing(let now)? = parsed { return now == unknown.code }
        return false
    }

    private var buttonTitle: String {
        switch parsed {
        case .pairing?:
            if connecting { return "Pairing…" }
            return trusting ? "Trust and pair" : "Pair this Mac"
        default:
            return connecting ? "Connecting…" : "Connect"
        }
    }

    /// Which code it is, and what pressing the button will do with it.
    @ViewBuilder
    private func kind(_ parsed: Cloud.Code) -> some View {
        let pairing: Bool = { if case .pairing = parsed { return true }; return false }()
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: pairing ? "person.badge.key" : "link")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(pairing ? "Pairing code — links this Mac and signs you in" : "Link code — connects to the instance; you sign in next")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                if pairing {
                    Text("Good once, for 10 minutes. Sync turns on for everything — switch any of it off after.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }

    private func host(_ parsed: Cloud.Code) -> String {
        switch parsed {
        case .link(let link): return link.host
        case .pairing(let code): return code.host
        }
    }

    private func pairs(_ parsed: Cloud.Code) -> String? {
        switch parsed {
        case .link(let link): return link.fingerprintPairs
        case .pairing(let code): return code.fingerprintPairs
        }
    }

    private func trust(_ parsed: Cloud.Code) -> String {
        let (url, pinned): (URL, Bool) = {
            switch parsed {
            case .link(let link): return (link.url, link.fingerprint != nil)
            case .pairing(let code): return (code.url, code.fingerprint != nil)
            }
        }()
        if url.scheme == "http" { return "Plain HTTP — this Mac only, for development" }
        return pinned ? "Pinned to this certificate" : "Trusted by its public certificate"
    }

    private func go() {
        guard let parsed, !connecting else { return }
        connecting = true
        problem = nil
        Task {
            do {
                switch parsed {
                case .link(let link):
                    try await Cloud.shared.connect(link)
                case .pairing(let pairing):
                    let confirmed = unknown.flatMap { $0.code == pairing ? $0.seen : nil }
                    try await CloudPairing.pairAndSync(pairing, trusting: confirmed)
                    unknown = nil
                }
            } catch let failure as Cloud.Failure where failure.code == "untrusted" {
                if case .pairing(let pairing) = parsed, let seen = failure.seen { unknown = (pairing, seen) }
                problem = failure.message
            } catch {
                problem = error.localizedDescription
            }
            connecting = false
        }
    }
}

private func fingerprintText(_ pairs: String) -> some View {
    Text(cloudPairLines(pairs))
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(Palette.muted)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.bottom, 10)
}

// MARK: - 2. account

private struct CloudAccountForm: View {
    enum Mode: Hashable { case signIn, create }
    enum Field: Hashable { case email, password, name }

    @FocusState private var focus: Field?
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var name = NSFullUserName()
    @State private var working = false
    @State private var problem: String?

    private var ready: Bool {
        !email.isEmpty && !password.isEmpty && (mode == .signIn || (password.count >= Cloud.minimumPassword && !name.trimmingCharacters(in: .whitespaces).isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("2 · Your account on this instance")
            Card {
                Segmented(options: [(Mode.signIn, "Sign in"), (Mode.create, "Create account")], selection: $mode, wide: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                Rule()
                Line("Email") {
                    field("you@example.com", text: $email, width: 220, submit: next).focused($focus, equals: .email)
                }
                .cloudAnchor("cloud.account.email")
                Rule()
                Line("Password", mode == .create ? "At least \(Cloud.minimumPassword) characters" : nil) {
                    field(mode == .create ? "10 or more characters" : "password", text: $password, width: 220, secure: true, submit: mode == .create ? next : go)
                        .focused($focus, equals: .password)
                }
                .cloudAnchor("cloud.account.password")
                if mode == .create {
                    Rule()
                    Line("Your name", "Shown beside your cursor on shared canvases") {
                        field("Name", text: $name, width: 220, submit: go).focused($focus, equals: .name)
                    }
                    .cloudAnchor("cloud.account.name")
                }
                Rule()
                HStack {
                    Text(mode == .create ? "The first account on an instance is its admin." : "Same email and password as on your other Macs.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Pill(working ? "…" : (mode == .create ? "Create account" : "Sign in"), filled: ready && !working, action: go)
                        .disabled(!ready || working)
                        .opacity(ready ? 1 : 0.5)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .cloudAnchor("cloud.account.submit")
            }
            .onChange(of: mode) { _, mode in
                problem = nil
                // Create account grows the form by a field: keep its button in view.
                if mode == .create { cloudReveal("cloud.account.submit") }
            }
            if let problem { CloudProblem(problem).cloudAnchor("cloud.account.problem") }
        }
        .onChange(of: focus) { _, field in
            if let field { cloudReveal(Self.anchor(field)) }
        }
        .onChange(of: problem) { _, problem in
            if problem != nil { cloudReveal("cloud.account.problem") }
        }
    }

    private static func anchor(_ field: Field) -> String {
        switch field {
        case .email: return "cloud.account.email"
        case .password: return "cloud.account.password"
        case .name: return "cloud.account.name"
        }
    }

    /// Return in a field that isn't the last: on to the next one.
    private func next() {
        switch focus {
        case .email?: focus = .password
        case .password? where mode == .create: focus = .name
        default: go()
        }
    }

    private func go() {
        guard ready, !working else { return }
        if mode == .create, password.count < Cloud.minimumPassword {
            problem = "Use at least \(Cloud.minimumPassword) characters for the password"
            focus = .password
            return
        }
        working = true
        problem = nil
        Task {
            do {
                if mode == .create {
                    try await Cloud.shared.signUp(email: email, password: password, displayName: name)
                } else {
                    try await Cloud.shared.signIn(email: email, password: password)
                }
                password = ""
            } catch {
                problem = error.localizedDescription
                // Most refusals are about the password: back to it, in view.
                focus = .password
            }
            working = false
        }
    }
}

// MARK: - 3. sync

private struct CloudSyncCard: View {
    @ObservedObject var sync: CloudSync
    @ObservedObject var cloud: Cloud
    @State private var chosen: Set<CloudSync.Domain>
    @State private var starting = false

    /// The switches start as they were last left: a Mac signed out and in
    /// again is offered the same choice, still off until "Turn on sync".
    init(sync: CloudSync, cloud: Cloud) {
        self.sync = sync
        self.cloud = cloud
        _chosen = State(initialValue: sync.enabled)
    }

    /// The Personal canvas switch, once CloudSync has it (`case canvas`).
    /// It is shown apart from the browser's switches — the board isn't the
    /// browser — and every word below that promises what stays on this Mac
    /// counts it in only when it is there to switch.
    private static let canvas = CloudSync.Domain(rawValue: "canvas")

    /// Browser sync — every domain but the canvas — then the canvas, if any.
    private var sections: [(caption: String, domains: [CloudSync.Domain])] {
        var out = [(caption: sync.on ? "Browser sync" : "3 · Browser sync",
                    domains: CloudSync.Domain.allCases.filter { $0 != Self.canvas })]
        if let canvas = Self.canvas { out.append((caption: "Canvas", domains: [canvas])) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if sync.on {
                VStack(alignment: .leading, spacing: 8) {
                    Caption("Sync")
                    Card { status }
                }
            }
            let all = sections
            ForEach(Array(all.enumerated()), id: \.offset) { index, section in
                VStack(alignment: .leading, spacing: 8) {
                    group(section.caption, section.domains)
                    // Until sync is on, "Turn on sync" sits under the last of them.
                    if !sync.on, index == all.count - 1 { Card { start } }
                }
            }
        }
    }

    private func group(_ caption: String, _ domains: [CloudSync.Domain]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(caption)
            Card {
                ForEach(Array(domains.enumerated()), id: \.element) { index, domain in
                    if index > 0 { Rule() }
                    Line(domain.title, domain.detail) {
                        Switch(on: Binding(
                            get: { sync.on ? sync.enabled.contains(domain) : chosen.contains(domain) },
                            set: { value in
                                if sync.on { sync.set(domain, value) }
                                else if value { chosen.insert(domain) } else { chosen.remove(domain) }
                            }
                        ))
                    }
                }
            }
        }
    }

    /// How it is doing, and since when — re-read every few seconds so
    /// "just now" grows into "2 minutes ago" while the page is open.
    @ViewBuilder
    private var status: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Line(statusTitle, statusDetail(now: context.date)) {
                HStack(spacing: 8) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Pill("Sync now") { Task { await sync.syncNow() } }
                        .disabled(sync.state == .syncing)
                }
            }
        }
        Rule()
        Line("Pause sync", Self.canvas != nil
             ? "Pauses browser sync and the Personal canvas. Shared canvases stay live."
             : "Pauses browser sync. Canvases aren't affected.") {
            Pill("Turn off") { sync.turnOff() }
        }
    }

    private var start: some View {
        HStack {
            Text(chosen.isEmpty
                 ? (Self.canvas != nil ? "Pick at least one. Nothing leaves this Mac until you turn sync on." : "Pick at least one. Browser data stays on this Mac until you turn sync on.")
                 : "\(chosen.count) chosen — the first sync merges this Mac with what the cloud has.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if starting { ProgressView().controlSize(.small) }
            Pill("Turn on sync", filled: !chosen.isEmpty) {
                guard !chosen.isEmpty, !starting else { return }
                starting = true
                Task { await sync.turnOn(chosen); starting = false }
            }
            .disabled(chosen.isEmpty || starting)
            .opacity(chosen.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Never "Up to date" before a sync has finished, and "Syncing…" only
    /// while one is under way — the same words as the steps above.
    private var statusTitle: String {
        switch sync.state {
        case .idle: return sync.lastSync == nil ? "Sync on" : "Up to date"
        case .syncing: return "Syncing…"
        case .offline: return "Can't reach the cloud"
        case .error: return "Couldn't sync"
        }
    }

    private func statusDetail(now: Date) -> String {
        let last = sync.lastSync.map { "Last synced " + cloudAgo($0, now: now) }
        switch sync.state {
        case .idle, .syncing: return last ?? "Not synced yet"
        case .offline: return ["Will retry", last].compactMap { $0 }.joined(separator: " · ")
        case .error(let message): return [message, last].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var dot: Color {
        switch sync.state {
        case .idle: return Color.green.opacity(0.8)
        case .syncing: return Color.yellow.opacity(0.85)
        case .offline: return Color.orange.opacity(0.85)
        case .error: return Color.red.opacity(0.8)
        }
    }
}

// MARK: - other devices

private struct CloudDevicesCard: View {
    @ObservedObject var sync: CloudSync
    @State private var open: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("On your other devices")
            Card {
                ForEach(Array(sync.otherDevices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Rule() }
                    Button {
                        withAnimation(Motion.settle) { if open.contains(device.id) { open.remove(device.id) } else { open.insert(device.id) } }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "laptopcomputer").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.system(size: 13)).foregroundStyle(Palette.ink)
                                TimelineView(.periodic(from: .now, by: 15)) { context in
                                    Text("\(device.tabs.count) tab\(device.tabs.count == 1 ? "" : "s")\(device.updated.map { " · Updated " + cloudAgo($0, now: context.date) } ?? "")")
                                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                                }
                            }
                            Spacer()
                            Image(systemName: open.contains(device.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if open.contains(device.id) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(device.tabs.prefix(60).enumerated()), id: \.offset) { _, tab in
                                CloudTabRow(tab: tab) { sync.open(tab) }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
            }
        }
    }
}

private struct CloudTabRow: View {
    let tab: CloudDocs.Tabs.Open
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: tab.active == true ? "circle.inset.filled" : "globe")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).frame(width: 14)
                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(URL(string: tab.url)?.host() ?? "")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .padding(.leading, 26)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.space.map { "\(tab.url) — in \($0)" } ?? tab.url)
    }
}

// MARK: - account

private struct CloudAccountCard: View {
    @ObservedObject var cloud: Cloud
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Account")
            Card {
                Line(cloud.account?.displayName ?? "Signed in", cloud.account?.email) {
                    Pill("Sign out") {
                        Task {
                            await CloudSync.shared.signingOut()
                            await Cloud.shared.signOut()
                        }
                    }
                }
                Rule()
                Line("This Mac", "The name your other devices see it by") {
                    TextField("Device name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 170)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onSubmit(rename)
                }
            }
            if let problem { CloudProblem(problem) }
        }
        .onAppear { name = cloud.deviceName }
        .onDisappear(perform: rename)
    }

    private func rename() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != cloud.deviceName else { return }
        Task {
            do { try await Cloud.shared.renameDevice(clean) } catch { problem = error.localizedDescription }
        }
    }
}

// MARK: - pair another Mac

/// A one-time code for another Mac: made here, pasted there, and that Mac is
/// connected, signed in as this account and syncing. Shown big, copyable,
/// counted down, revocable — and noticed when it is used.
private struct CloudPairCard: View {
    @ObservedObject var pairing: CloudPairing
    @State private var confirmRevoke = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Pair another Mac")
            Card {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(now: context.date)
                }
            }
            if let problem = pairing.problem { CloudProblem(problem) }
        }
        // While a code is open, look every few seconds for the other Mac
        // having used it.
        .task(id: pairing.live?.id) {
            guard pairing.live != nil else { return }
            while !Task.isCancelled, pairing.live != nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                await pairing.check()
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let code = pairing.current {
            let left = code.expiresAt.timeIntervalSince(now)
            switch pairing.outcome {
            case .used?:
                Line("Used — the other Mac is signed in", "Make another code for the next Mac.") {
                    Pill(pairing.working ? "…" : "New code", action: pairing.make).disabled(pairing.working)
                }
            case .revoked?:
                Line("Code revoked", "Nobody can use it now.") {
                    Pill(pairing.working ? "…" : "New code", action: pairing.make).disabled(pairing.working)
                }
            case .none where left <= 0:
                Line("Code expired", "Make a new one when the other Mac is ready.") {
                    Pill(pairing.working ? "…" : "New code", filled: !pairing.working, action: pairing.make).disabled(pairing.working)
                }
            case .none:
                live(code, left: left)
            }
        } else {
            Line("One-time code", "Signs another Mac in as you with one paste. Works once, for 10 minutes.") {
                Pill(pairing.working ? "Making…" : "Make a code", action: pairing.make)
                    .disabled(pairing.working)
            }
        }
    }

    private func live(_ code: Cloud.MintedPairing, left: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste this into Settings › Cloud on the other Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            CloudCodeBox(link: code.link, secret: code.code)
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.wash)
                        Capsule().fill(left < 60 ? Color.orange.opacity(0.85) : Palette.ink.opacity(0.55))
                            .frame(width: max(3, box.size.width * min(1, max(0, left / CloudPairing.lifetime))))
                    }
                }
                .frame(height: 3)
                HStack(spacing: 8) {
                    Text("Expires in \(CloudPairing.left(left)) · works once")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(left < 60 ? Color.orange.opacity(0.95) : Palette.muted)
                    Spacer()
                    if pairing.working { ProgressView().controlSize(.small) }
                    CloudQuietButton("Revoke", tint: Color.red.opacity(0.85)) { confirmRevoke = true }
                        .disabled(pairing.working)
                    Pill(pairing.copied ? "Copied" : "Copy", filled: true, action: pairing.copy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .confirmationDialog("Revoke this pairing code?", isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) { Task { await pairing.revoke() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nobody will be able to use it. A Mac already paired with it stays signed in.")
        }
    }
}

/// The pairing code whole and monospaced, in three lines that wrap inside
/// the box — the address, the `cp_…` part large and in ink on a line of its
/// own (never broken at its hyphen), the fingerprint small and quiet.
/// Selectable as one piece; the line breaks are whitespace, which a pasted
/// code ignores (`Cloud.parseCode`). Copy copies the code without them.
private struct CloudCodeBox: View {
    let link: String
    let secret: String

    var body: some View {
        styled
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var styled: Text {
        guard let range = link.range(of: secret) else {
            return Text(link).font(.system(size: 13, design: .monospaced)).foregroundColor(Palette.ink)
        }
        let head = link[..<range.lowerBound]
        let tail = link[range.upperBound...]
        var text = Text(head).font(.system(size: 11.5, design: .monospaced)).foregroundColor(Palette.muted)
            + Text("\n")
            + Text(link[range]).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundColor(Palette.ink)
        if !tail.isEmpty {
            text = text + Text("\n") + Text(tail).font(.system(size: 10.5, design: .monospaced)).foregroundColor(Palette.muted)
        }
        return text
    }
}

// MARK: - the instance

/// The instance this Mac is linked to, in one line: where, how its
/// certificate is trusted, and a way into the details. Disconnect lives in
/// the details — it is how to change instance, and too final to sit
/// between a finished step and the next one.
private struct CloudConnection: View {
    @ObservedObject var cloud: Cloud
    @ObservedObject var sync: CloudSync
    /// What opens the details: "Change…" while signing in is still to do,
    /// "Details" after.
    let opener: String
    /// Said before the host when there is no caption over the line.
    var lead: String?
    @State private var open = false
    @State private var confirm = false

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Circle().fill(cloud.reachable ? Color.green.opacity(0.8) : Palette.faint).frame(width: 7, height: 7)
                    .help(cloud.reachable ? "Reachable" : "Not reached yet")
                if let lead {
                    Text(lead).font(.system(size: 12.5)).foregroundStyle(Palette.muted).fixedSize()
                }
                Text(cloud.link?.host ?? "—")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.middle)
                if let link = cloud.link { CloudTrustPill(link: link) }
                Spacer(minLength: 8)
                Button(open ? "Hide" : opener) {
                    withAnimation(Motion.settle) { open.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if open {
                Rule()
                VStack(alignment: .leading, spacing: 4) {
                    Text(trust).font(.system(size: 11.5)).foregroundStyle(Palette.ink)
                    if let pairs = cloud.link?.fingerprintPairs {
                        Text(cloudPairLines(pairs))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Compare it with `copper-cloud doctor` on the server.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rule()
                Line("Disconnect", "Signs out and forgets this instance, to connect to another. Nothing is deleted.") {
                    Pill("Disconnect", tint: Color.red.opacity(0.85)) { confirm = true }
                }
                .confirmationDialog("Disconnect from \(cloud.link?.host ?? "this instance")?", isPresented: $confirm) {
                    Button("Disconnect", role: .destructive) {
                        sync.turnOff()
                        Cloud.shared.disconnect()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Copper signs out, stops syncing and forgets the instance. Nothing is deleted.")
                }
            }
        }
    }

    private var trust: String {
        guard let link = cloud.link else { return "" }
        if link.url.scheme == "http" { return "Plain HTTP — this Mac only, for development" }
        return link.fingerprint == nil ? "Trusted by its public certificate" : "Pinned to this certificate (SHA-256):"
    }
}

/// How the instance's certificate is trusted, small enough to sit beside
/// the host: the start of a pinned fingerprint, or what trusts it instead.
private struct CloudTrustPill: View {
    let link: Cloud.Link

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            Text(label).font(.system(size: 10.5, design: link.fingerprint == nil ? .default : .monospaced))
        }
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Palette.wash, in: Capsule())
        .help(help)
    }

    private var symbol: String {
        if link.url.scheme == "http" { return "exclamationmark.triangle" }
        return link.fingerprint == nil ? "checkmark.seal" : "lock.fill"
    }

    private var label: String {
        if link.url.scheme == "http" { return "Plain HTTP" }
        guard let pairs = link.fingerprintPairs else { return "Public certificate" }
        return String(pairs.prefix(11)) + "…"
    }

    private var help: String {
        if link.url.scheme == "http" { return "Plain HTTP on this Mac (development)" }
        guard let pairs = link.fingerprintPairs else { return "Trusted by the Mac's own certificate roots" }
        return "Pinned certificate — SHA-256 " + pairs
    }
}

// MARK: - the log

private struct CloudLogCard: View {
    @ObservedObject var sync: CloudSync
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.settle) { open.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Caption("Log")
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Card {
                    VStack(alignment: .leading, spacing: 3) {
                        if sync.log.isEmpty {
                            Text("Nothing yet").font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        }
                        ForEach(sync.log.suffix(60).reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.at, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.muted)
                                Text(entry.text).font(.system(size: 11.5)).foregroundStyle(Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
    }
}

// MARK: - bits

/// Scroll the Settings page just far enough to show the view marked `id`
/// (`cloudAnchor`) whole — a field taking focus, a problem appearing, a
/// button pushed down by the form growing. After the layout the change
/// brings; nothing when it is in view already.
@MainActor
fileprivate func cloudReveal(_ id: String) {
    DispatchQueue.main.async {
        guard let mark = CloudAnchor.mark(id) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            _ = mark.scrollToVisible(mark.bounds.insetBy(dx: 0, dy: -6))
        }
    }
}

extension View {
    /// Marks this view as somewhere `cloudReveal(id)` can scroll to.
    fileprivate func cloudAnchor(_ id: String) -> some View {
        background(CloudAnchor(id: id))
    }
}

/// An empty AppKit view the size of the view it sits behind, kept by id, so
/// the scroll view around the page (an NSScrollView) can be asked to show
/// it. Several can share an id — `cloud picture` lays out a second page off
/// screen — and the one in a window on screen wins.
private struct CloudAnchor: NSViewRepresentable {
    let id: String

    final class Mark: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class Weak { weak var mark: Mark?; init(_ mark: Mark) { self.mark = mark } }
    @MainActor private static var marks: [String: [Weak]] = [:]

    func makeNSView(context: Context) -> Mark {
        let mark = Mark()
        CloudAnchor.marks[id, default: []].append(Weak(mark))
        return mark
    }

    func updateNSView(_ mark: Mark, context: Context) {}

    @MainActor static func mark(_ id: String) -> Mark? {
        let alive = (marks[id] ?? []).filter { $0.mark != nil }
        marks[id] = alive
        return alive.lazy.compactMap(\.mark).first { $0.window?.isVisible == true && $0.enclosingScrollView != nil }
    }
}

/// A fingerprint's 32 pairs as two lines of 16, so it never breaks inside a
/// pair. The break is whitespace, which every fingerprint field ignores.
fileprivate func cloudPairLines(_ pairs: String) -> String {
    let all = pairs.split(separator: ":")
    guard all.count > 16 else { return pairs }
    return all.prefix(16).joined(separator: ":") + ":\n" + all.dropFirst(16).joined(separator: ":")
}

/// When something last happened, in the past tense whatever the clocks say:
/// "just now" for the first 45 seconds (and for a date a skewed clock puts
/// a little ahead), then "2 minutes ago", "3 hours ago".
fileprivate func cloudAgo(_ date: Date, now: Date = Date()) -> String {
    guard now.timeIntervalSince(date) >= 45 else { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
}

/// A destructive action that isn't the point of the card: red words, no
/// outline, a wash under the pointer.
private struct CloudQuietButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, tint: Color, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(tint.opacity(enabled ? 1 : 0.5))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(hovering && enabled ? Palette.hover : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// The Settings scroll view draws no scroller, so a page taller than the
/// panel says so itself: while more of it is below the bottom edge, that
/// edge fades into the ground with a small chevron. Gone once the end is in
/// view, and never drawn off screen (`cloud picture`), where nothing scrolls.
private struct CloudMoreBelow: ViewModifier {
    /// The scroll view's visible height.
    @State private var viewport: CGFloat = 0
    /// The page, in the scroll view's visible coordinates (`minY` goes
    /// negative as it scrolls up).
    @State private var page: CGRect = .zero
    private let fade: CGFloat = 30

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                Color.clear
                    .frame(width: 1)
                    .containerRelativeFrame(.vertical)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
                    .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { page = $0 }
            .overlay(alignment: .top) {
                // The visible bottom edge, in the page's own coordinates.
                let bottom = viewport - page.minY
                let more = viewport > 160 && page.height - bottom > 6
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [SettingsInk.content.opacity(0), SettingsInk.content], startPoint: .top, endPoint: .bottom) // Fork (settings-revamp): Settings' ground
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.bottom, 1)
                }
                .frame(height: fade)
                .offset(y: bottom - fade)
                .opacity(more ? 1 : 0)
                .animation(Motion.quick, value: more)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct CloudProblem: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 11))
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.red.opacity(0.85))
        .padding(.leading, 2)
    }
}

@ViewBuilder
private func field(_ placeholder: String, text: Binding<String>, width: CGFloat, secure: Bool = false, submit: (() -> Void)? = nil) -> some View {
    Group {
        if secure {
            SecureField(placeholder, text: text)
        } else {
            TextField(placeholder, text: text)
        }
    }
    .textFieldStyle(.plain)
    .font(.system(size: 12))
    .autocorrectionDisabled()
    .frame(width: width)
    .padding(.horizontal, 8).padding(.vertical, 4)
    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .onSubmit { submit?() }
}
