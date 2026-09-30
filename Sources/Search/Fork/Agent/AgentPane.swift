import AppKit
import SwiftUI

// The pane beside the page: the conversation above, the question below.
// Drawn with the sidebar's palette so it reads as part of the window, not a
// chat app pasted in. Tool calls are chips — the name, the arguments that
// matter, the first line of what came back — so you can see the agent's
// hands without reading JSON.

struct AgentPane: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent = Agent.shared
    @ObservedObject var brain = Intelligence.shared
    @ObservedObject private var account = ClaudeAccount.shared
    @ObservedObject var servers = Servers.shared
    @FocusState private var focused: Bool
    @State private var copiedJev = false

    static let width: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            transcript
            Rectangle().fill(Palette.hairline).frame(height: 1)
            composer
        }
        .frame(width: AgentPane.width)
        .background(Palette.ground)
        .onAppear { focused = true }
        .onChange(of: agent.focusTick) { _, _ in focused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
            Text("Agent").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
            Menu {
                ForEach(Intelligence.Tier.allCases) { tier in
                    Button {
                        brain.keys.tier = tier
                    } label: {
                        HStack {
                            Text("\(tier.title) — \(tier.blurb)")
                            if tier == brain.tier {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Text(brain.accessLine)
                Button("Model access…") { browser.openSettings(.intelligence) }
            } label: {
                HStack(spacing: 3) {
                    Text(brain.tier.title)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
            }
            // The label draws its own small chevron; the button style's
            // indicator would sit in front of the word (SpaceHeader does the same).
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Model — \(brain.accessLine)")
            if servers.readyTools > 0 {
                Text("+\(servers.readyTools) tools").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .help(servers.all.filter(\.ready).map { "\($0.name): \($0.tools.count)" }.joined(separator: "\n"))
            }
            Spacer()
            // Real doors, not bare glyphs: a square each, washed under the
            // pointer (PaneDoor). "Close all" only shows beside a second pane.
            HStack(spacing: 2) {
                if agent.busy {
                    PaneDoor(icon: "stop.fill", help: "Stop") { agent.stop() }
                } else if !agent.items.isEmpty {
                    PaneDoor(icon: "trash", help: "Clear the conversation") { agent.clear() }
                }
                if several {
                    PaneDoor(icon: "xmark.square", help: "Close all panes (⌘⌥E)") { Panes.closeAll(in: browser) }
                }
                PaneDoor(icon: "xmark", help: "Close (⌘E)") { agent.open = false }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    /// Whether another pane is open beside this one — read off the two other
    /// objects so the header redraws as they change.
    @ObservedObject private var trace = Drive.shared
    @ObservedObject private var split = Split.shared
    private var several: Bool { (trace.paneOpen ? 1 : 0) + (split.on ? 1 : 0) > 0 }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.items.isEmpty { empty }
                    ForEach(agent.items) { item in
                        row(item).id(item.id)
                    }
                    if agent.busy {
                        HStack(spacing: 6) {
                            Ring(size: 10)
                            Text(agent.status).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                        .padding(.horizontal, 4)
                        .id("busy")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: agent.items.count) { _, _ in
                withAnimation(Motion.quick) {
                    if agent.busy { proxy.scrollTo("busy", anchor: .bottom) }
                    else if let last = agent.items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: agent.status) { _, _ in
                if agent.busy { proxy.scrollTo("busy", anchor: .bottom) }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            if agent.ready {
                Text("Ask about this page, or tell it what to do here. It has the same hands as an agent on the MCP — and your other servers, from mcp.json.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let tab = browser.active, !tab.isBlank {
                    ForEach(["Summarise this page", "What can I do here?", "Find the main links on this page and list them"], id: \.self) { s in
                        Button { agent.ask(s, in: browser) } label: {
                            Text(s).font(.system(size: 11.5)).foregroundStyle(Palette.ink)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Palette.wash, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Not set up yet. Sign in with your Claude account, or add an API key for a gateway.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Pill("Sign in with Claude", filled: true) { account.signIn(in: browser) }
                    Pill("Use an API key") { browser.openSettings(.intelligence) }
                }
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func row(_ item: Agent.Item) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            Text(LocalizedStringKey(item.text))
                .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 20)
        case .tool:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(item.ok ? Color.green.opacity(0.75) : Color.orange.opacity(0.85)).frame(width: 6, height: 6)
                    Text(item.tool).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ink)
                    Spacer()
                    if item.ms > 0 { Text(String(format: "%.0f ms", item.ms)).font(.system(size: 10)).foregroundStyle(Palette.faint) }
                }
                if !item.text.isEmpty {
                    Text(item.text).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .lineLimit(4).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Palette.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        case .note:
            Text(item.text)
                .font(.system(size: 11)).foregroundStyle(item.ok ? Palette.muted : Color.orange.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(agent.ready ? "Ask, or say what to do…" : "Sign in with Claude or add a key — Settings › Intelligence", text: $agent.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...6)
                .focused($focused)
                .disabled(!agent.ready)
                .onSubmit { agent.send(in: browser) }
            Button {
                let goal = agent.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MCP.jevCommand(goal: goal.isEmpty ? nil : goal), forType: .string)
                copiedJev = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedJev = false }
            } label: {
                Text(copiedJev ? "Copied" : "→ /jev")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .help("Copy this goal as a /jev command")
            Button { agent.send(in: browser) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canSend ? Palette.ground : Palette.muted)
                    .frame(width: 24, height: 24)
                    .background(canSend ? Palette.ink : Palette.wash, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var canSend: Bool { agent.ready && !agent.busy && !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
