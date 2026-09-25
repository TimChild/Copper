import SwiftUI

/// Settings controls for the optional Bitwarden backend. The card intentionally
/// owns only UI state; Bitwarden keeps the CLI session and metadata cache.
struct BitwardenCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var bitwarden = Bitwarden.shared

    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var busy = false
    @State private var error: String?
    @State private var autolock = 15

    var body: some View {
        Card {
            stateContent
            if let error {
                Rule()
                Line("Bitwarden error", firstLine(error)) {
                    Pill("Retry") { retry() }
                }
                .foregroundStyle(.red.opacity(0.78))
            }
        }
        .onAppear {
            server = bitwarden.serverURL
            autolock = storedAutolock
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch bitwarden.state {
        case .missing:
            Line("Bitwarden", "Install the Bitwarden CLI to connect an existing vault") {
                HStack(spacing: 8) {
                    Text("brew install bitwarden-cli")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Pill("Copy") { copyInstallCommand() }
                }
            }
        case .unauthenticated:
            signInLines
        case .locked(let account):
            Line("Bitwarden", account.map { "Locked · \($0)" } ?? "Locked") {
                Text("Locked")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            Rule()
            Line("Master password") {
                HStack(spacing: 8) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    actionPill("Unlock") { unlock() }
                }
            }
        case .unlocked(_, let lastSync):
            Line("Bitwarden", "Unlocked · synced \(relative(lastSync))") {
                HStack(spacing: 8) {
                    actionPill("Sync now") { sync() }
                    Pill("Lock") { lock() }
                }
            }
            Rule()
            Line("Save new passwords to Bitwarden", "New save offers use Bitwarden; fills still include both sources") {
                Switch(on: Binding(
                    get: { browser.prefs.passwordsBackend == .bitwarden },
                    set: { browser.prefs.passwordsBackend = $0 ? .bitwarden : .keychain }
                ))
            }
            Rule()
            Line("Auto-lock", "Lock the local Bitwarden session after inactivity") {
                Picker("Auto-lock", selection: Binding(
                    get: { autolock },
                    set: {
                        autolock = $0
                        Store.settings.set($0, forKey: "bitwarden.autolockMinutes")
                    }
                )) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("60 minutes").tag(60)
                    Text("Never").tag(0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
            }
        }
    }

    @ViewBuilder
    private var signInLines: some View {
        Line("Bitwarden server", "Use bitwarden.com, EU, or a self-hosted Vaultwarden server") {
            TextField("https://vault.bitwarden.com", text: $server)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        Rule()
        Line("Email") {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        Rule()
        Line("Master password") {
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        Rule()
        Line("Two-factor code", "Optional — leave blank when the account has no 2FA") {
            TextField("Code", text: $otp)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
        }
        Rule()
        Line("Connect") {
            actionPill("Sign in") { signIn() }
        }
    }

    @ViewBuilder
    private func actionPill(_ title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if busy { Ring(size: 10) }
            Pill(busy ? "Working…" : title, filled: !busy, action: action)
                .disabled(busy)
        }
    }

    private var storedAutolock: Int {
        guard let value = Store.settings.object(forKey: "bitwarden.autolockMinutes") as? NSNumber else {
            return 15
        }
        let minutes = value.intValue
        return [0, 5, 15, 60].contains(minutes) ? minutes : 15
    }

    private func signIn() {
        guard !busy else { return }
        busy = true
        error = nil
        let server = self.server
        let email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = self.password
        let otp = self.otp.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { busy = false }
            do {
                try await bitwarden.configure(server: server)
                try await bitwarden.login(email: email, password: password,
                                          otp: otp.isEmpty ? nil : otp)
                self.password = ""
                self.otp = ""
            } catch {
                self.error = firstLine(error)
            }
        }
    }

    private func unlock() {
        guard !busy else { return }
        busy = true
        error = nil
        let password = self.password
        Task { @MainActor in
            defer { busy = false }
            do {
                try await bitwarden.unlock(password: password)
                self.password = ""
            } catch {
                self.error = firstLine(error)
            }
        }
    }

    private func lock() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await bitwarden.lock()
            busy = false
            password = ""
        }
    }

    private func sync() {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await bitwarden.sync()
            } catch {
                self.error = firstLine(error)
            }
        }
    }

    private func retry() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await bitwarden.refreshStatus()
            busy = false
            error = nil
        }
    }

    private func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install bitwarden-cli", forType: .string)
        browser.announce("Install command copied")
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "not yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func firstLine(_ error: Error) -> String {
        firstLine(error.localizedDescription)
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first.map(String.init) ?? text
    }
}

/// The user's explicit agent-sharing policy. Nothing here reads a secret;
/// rows are stripped metadata from the keychain and Bitwarden cache only.
struct AgentAccessCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var bitwarden = Bitwarden.shared

    @FocusState private var huntFocused: Bool
    @State private var hunt = ""
    @State private var shareAll = AgentAccess.shareAll
    @State private var policyRevision = 0

    private var credentials: [Credential] { Credentials.all() }

    private var filtered: [Credential] {
        let needle = hunt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return credentials }
        return credentials.filter {
            $0.name.lowercased().contains(needle)
                || $0.host.lowercased().contains(needle)
                || $0.user.lowercased().contains(needle)
        }
    }

    var body: some View {
        Card {
            Line("Share every saved account with agents", "Agents can use saved sign-ins in Copper without receiving the password") {
                Switch(on: Binding(
                    get: { shareAll },
                    set: {
                        shareAll = $0
                        AgentAccess.shareAll = $0
                        policyRevision += 1
                    }
                ))
            }
            Rule()
            VStack(alignment: .leading, spacing: 10) {
                Hunt(text: $hunt, prompt: "Search saved accounts", focus: $huntFocused)
                if filtered.isEmpty {
                    Nothing("Nothing kept yet — sign in somewhere or connect Bitwarden.")
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, credential in
                                if index > 0 { Rule(inset: 0) }
                                AgentCredentialRow(
                                    credential: credential,
                                    shareAll: shareAll,
                                    allowed: AgentAccess.isAllowed(credential),
                                    setAllowed: { value in
                                        AgentAccess.set(credential, allowed: value)
                                        policyRevision += 1
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 400)
                }
            }
            .padding(12)
            .id(policyRevision)
        }
        .onAppear {
            shareAll = AgentAccess.shareAll
            huntFocused = true
        }
        // Bitwarden publishes lock/unlock/cache changes; keeping this observed
        // makes the union list redraw without a manual refresh button.
        .onChange(of: bitwarden.state) { _, _ in policyRevision += 1 }
    }

    private struct AgentCredentialRow: View {
        let credential: Credential
        let shareAll: Bool
        let allowed: Bool
        let setAllowed: (Bool) -> Void

        private var denied: Bool { credential.agentHint == .deny }
        private var sourceSymbol: String { credential.source == .bitwarden ? "shield" : "key" }

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: sourceSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(credential.name.isEmpty ? credential.host : credential.name) · \(credential.host)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(credential.user.isEmpty ? "No username" : credential.user)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if credential.agentHint == .allow { badge("Agents folder") }
                        if denied { badge("denied in Bitwarden", tint: .red.opacity(0.72)) }
                    }
                }
                Spacer(minLength: 8)
                Switch(on: Binding(
                    get: { allowed },
                    set: setAllowed
                ))
                .allowsHitTesting(!shareAll && !denied)
                .accessibilityLabel("Share \(credential.name) account \(credential.user) with agents")
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 8)
        }

        private func badge(_ text: String, tint: Color = Palette.muted) -> some View {
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.wash, in: Capsule())
        }
    }
}
