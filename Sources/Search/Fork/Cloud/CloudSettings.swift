import AppKit
import SwiftUI

// Settings › Cloud: three steps, in order, each one only when the one before
// is done — connect to an instance, sign in (or create the account), choose
// what syncs. Nothing happens until a button is pressed. Drawn with the same
// cards, lines, pills and switches as every other page.

struct CloudPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var sync = CloudSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CloudSteps(cloud: cloud, sync: sync)
            if !cloud.isLinked {
                CloudConnectCard()
            } else if !cloud.isSignedIn {
                CloudInstanceCard(cloud: cloud, sync: sync, compact: true)
                CloudAccountForm()
            } else {
                CloudSyncCard(sync: sync, cloud: cloud)
                if sync.on, !sync.otherDevices.isEmpty { CloudDevicesCard(sync: sync) }
                CloudAccountCard(cloud: cloud)
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

private struct CloudConnectCard: View {
    @State private var code = ""
    @State private var advanced = false
    @State private var host = ""
    @State private var key = ""
    @State private var fingerprint = ""
    @State private var connecting = false
    @State private var problem: String?

    private var link: Cloud.Link? {
        advanced ? Cloud.link(address: host, key: key, fingerprint: fingerprint) : Cloud.parseLinkCode(code)
    }

    private var hint: String? {
        if advanced {
            if host.isEmpty || key.isEmpty { return nil }
            return link == nil ? "Check the address, the key and the fingerprint (64 hex characters, or leave it empty for a public certificate)" : nil
        }
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return link == nil ? "That isn't a link code — it starts copper-cloud:// and has #k= in it" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("1 · Connect to an instance")
            Card {
                if advanced {
                    Line("Address", "host:port, or https://…") { field("cloud.example.com:443", text: $host, width: 200) }
                    Rule()
                    Line("Instance key", "The k= part of the link code") { field("key", text: $key, width: 200, secure: true) }
                    Rule()
                    Line("Certificate fingerprint", "SHA-256, for a self-signed instance. Empty trusts the Mac's own roots.") { field("optional", text: $fingerprint, width: 200) }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Link code").font(.system(size: 13)).foregroundStyle(Palette.ink)
                        Text("`copper-cloud link-code` prints it on the server, and the installer did when it finished. It holds the address, the instance's key, and its certificate's fingerprint.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            TextField("copper-cloud://host:port/#k=…&fp=…", text: $code, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1...3)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Button {
                                if let pasted = NSPasteboard.general.string(forType: .string) { code = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                            } label: {
                                Image(systemName: "doc.on.clipboard").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            .buttonStyle(.plain)
                            .help("Paste")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }
                if let link {
                    Rule()
                    Line("Instance", link.url.scheme == "http" ? "Plain HTTP — this Mac only, for development" : (link.fingerprint == nil ? "Trusted by its public certificate" : "Pinned to this certificate")) {
                        Text(link.host).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                    }
                    if let pairs = link.fingerprintPairs {
                        Text(pairs)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.bottom, 10)
                            .help("Compare with `copper-cloud doctor` on the server")
                    }
                }
                Rule()
                HStack(spacing: 8) {
                    Button(advanced ? "Use a link code" : "Enter it by hand") {
                        withAnimation(Motion.settle) { advanced.toggle(); problem = nil }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    Spacer()
                    if connecting { ProgressView().controlSize(.small) }
                    Pill(connecting ? "Connecting…" : "Connect", filled: link != nil && !connecting) {
                        guard let link, !connecting else { return }
                        connecting = true
                        problem = nil
                        Task {
                            do { try await Cloud.shared.connect(link) } catch { problem = error.localizedDescription }
                            connecting = false
                        }
                    }
                    .disabled(link == nil || connecting)
                    .opacity(link == nil ? 0.5 : 1)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            if let message = problem ?? hint {
                CloudProblem(message)
            }
        }
    }
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
