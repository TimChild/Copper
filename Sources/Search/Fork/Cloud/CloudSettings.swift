import AppKit
import SwiftUI

// Settings › Cloud: three steps, in order, each one only when the one before
// is done — connect to an instance, sign in (or create the account), choose
// what syncs. A pairing code from another signed-in Mac does all three on
// one press; signed in, the page offers to make one (Pair another Mac).
// Nothing happens until a button is pressed. Drawn with the same cards,
// lines, pills and switches as every other page.

struct CloudPage: View {
    @ObservedObject var browser: Browser
    /// What the Connect field starts with (the bench's `cloud picture … CODE`).
    var draft = ""
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var sync = CloudSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CloudSteps(cloud: cloud, sync: sync)
            if !cloud.isLinked {
                CloudConnectCard(draft: draft)
            } else if !cloud.isSignedIn {
                CloudInstanceCard(cloud: cloud, sync: sync, compact: true)
                CloudAccountForm()
            } else {
                CloudSyncCard(sync: sync, cloud: cloud)
                if sync.on, !sync.otherDevices.isEmpty { CloudDevicesCard(sync: sync) }
                CloudAccountCard(cloud: cloud)
                CloudPairCard(pairing: CloudPairing.shared)
                CloudInstanceCard(cloud: cloud, sync: sync, compact: false)
                CloudLogCard(sync: sync)
            }
        }
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
            Text("Your spaces, settings, bookmarks and history on every Mac — through a Copper Cloud instance you or your team runs, not a service in between.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                mark(1, "Connect")
                bar(done: step > 1)
                mark(2, "Account")
                bar(done: step > 2)
                mark(3, sync.on ? "Syncing" : "Sync")
            }
        }
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
                    Line("Address", "host:port, or https://…") { field("cloud.example.com:443", text: $host, width: 200) }
                    Rule()
                    Line("Key", "The k= part of the link code: the instance key, or your access key") { field("key", text: $key, width: 200, secure: true) }
                    Rule()
                    Line("Certificate fingerprint", "SHA-256, for a self-signed instance. Empty trusts the Mac's own roots.") { field("optional", text: $fingerprint, width: 200) }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste a link code or a pairing code").font(.system(size: 13)).foregroundStyle(Palette.ink)
                        Text("A link code comes from the server (`copper-cloud link-code`) or its admin, and holds the address, a key and the certificate's fingerprint. A pairing code comes from a Mac already signed in — Settings › Cloud › Pair another Mac.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            TextField("copper-cloud://host:port/#k=…  or  #p=…", text: $code, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1...3)
                                .autocorrectionDisabled()
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
                        Text(Cloud.pairs(unknown.seen))
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
            }
            .onChange(of: code) { _, _ in problem = nil }
            if let message = problem ?? hint {
                CloudProblem(message)
            }
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
    Text(pairs)
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
                Line("Email") { field("you@example.com", text: $email, width: 220) }
                Rule()
                Line("Password", mode == .create ? "At least \(Cloud.minimumPassword) characters" : nil) {
                    field(mode == .create ? "10 or more characters" : "password", text: $password, width: 220, secure: true, submit: go)
                }
                if mode == .create {
                    Rule()
                    Line("Your name", "Shown beside your cursor on shared canvases") { field("Name", text: $name, width: 220) }
                }
                Rule()
                HStack {
                    Text(mode == .create ? "The first account on an instance is its admin." : "Same email and password as on your other Macs.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Pill(working ? "…" : (mode == .create ? "Create account" : "Sign in"), filled: ready && !working, action: go)
                        .disabled(!ready || working)
                        .opacity(ready ? 1 : 0.5)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .onChange(of: mode) { _, _ in problem = nil }
            if let problem { CloudProblem(problem) }
        }
    }

    private func go() {
        guard ready, !working else { return }
        if mode == .create, password.count < Cloud.minimumPassword {
            problem = "Use at least \(Cloud.minimumPassword) characters for the password"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(sync.on ? "Sync" : "3 · Choose what syncs")
            Card {
                ForEach(Array(CloudSync.Domain.allCases.enumerated()), id: \.element) { index, domain in
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
                Rule()
                if sync.on {
                    Line("Status", statusLine) {
                        HStack(spacing: 8) {
                            Circle().fill(dot).frame(width: 7, height: 7)
                            Pill("Sync now") { Task { await sync.syncNow() } }
                                .disabled(sync.state == .syncing)
                        }
                    }
                    Rule()
                    Line("Pause sync", "Stops sending and receiving. What is already on the cloud stays there.") {
                        Pill("Turn off") { sync.turnOff() }
                    }
                } else {
                    HStack {
                        Text(chosen.isEmpty ? "Pick at least one. Nothing leaves this Mac until you turn sync on." : "\(chosen.count) chosen — the first sync merges this Mac with what the cloud has.")
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
            }
        }
    }

    private var statusLine: String {
        let state = sync.state.text
        guard let last = sync.lastSync else { return state }
        let ago = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
        return sync.state == .idle ? "Up to date · last synced \(ago)" : "\(state) · last synced \(ago)"
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
                                Text("\(device.tabs.count) tab\(device.tabs.count == 1 ? "" : "s")\(device.updated.map { " · " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "")")
                                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
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
                Line("Used — the other Mac is signed in", "It's connected to this instance as you. Make another code for the next Mac.") {
                    Pill(pairing.working ? "…" : "New code", action: pairing.make).disabled(pairing.working)
                }
            case .revoked?:
                Line("Revoked", "Nobody can use that code now.") {
                    Pill(pairing.working ? "…" : "New code", action: pairing.make).disabled(pairing.working)
                }
            case .none where left <= 0:
                Line("That code expired", "Codes last 10 minutes. Make a new one when the other Mac is ready.") {
                    Pill(pairing.working ? "…" : "New code", filled: !pairing.working, action: pairing.make).disabled(pairing.working)
                }
            case .none:
                live(code, left: left)
            }
        } else {
            Line("One-time pairing code", "Connects another Mac to this instance and signs it in as you — no link code or password to type there. Good once, for 10 minutes.") {
                Pill(pairing.working ? "Making…" : "Make a code", filled: !pairing.working, action: pairing.make)
                    .disabled(pairing.working)
            }
        }
    }

    private func live(_ code: Cloud.MintedPairing, left: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On the other Mac, open Copper › Settings › Cloud and paste this into Connect — one press there links it, signs it in and starts syncing.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
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
                    Pill("Revoke", tint: Color.red.opacity(0.85)) { confirmRevoke = true }
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

/// The pairing code whole, large and monospaced, the `cp_…` part in ink and
/// the address and fingerprint around it quieter — selectable, and copied
/// whole by the button beside it.
private struct CloudCodeBox: View {
    let link: String
    let secret: String

    var body: some View {
        styled
            .font(.system(size: 14, design: .monospaced))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var styled: Text {
        guard let range = link.range(of: secret) else { return Text(link).foregroundColor(Palette.ink) }
        return Text(link[..<range.lowerBound]).foregroundColor(Palette.muted)
            + Text(link[range]).foregroundColor(Palette.ink).fontWeight(.semibold)
            + Text(link[range.upperBound...]).foregroundColor(Palette.muted)
    }
}

// MARK: - the instance

private struct CloudInstanceCard: View {
    @ObservedObject var cloud: Cloud
    @ObservedObject var sync: CloudSync
    let compact: Bool
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(compact ? "1 · Connected" : "Instance")
            Card {
                Line(cloud.link?.host ?? "—", detail) {
                    Circle().fill(cloud.reachable ? Color.green.opacity(0.8) : Palette.faint).frame(width: 7, height: 7)
                        .help(cloud.reachable ? "Reachable" : "Not reached yet")
                }
                if !compact, let pairs = cloud.link?.fingerprintPairs {
                    Text(pairs)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                }
                Rule()
                Line("Disconnect", "Signs out and forgets this instance. Your data here and on the cloud stays as it is.") {
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

    private var detail: String {
        guard let link = cloud.link else { return "" }
        if link.url.scheme == "http" { return "Plain HTTP on this Mac (development)" }
        return link.fingerprint == nil ? "Public certificate" : "Pinned certificate"
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
