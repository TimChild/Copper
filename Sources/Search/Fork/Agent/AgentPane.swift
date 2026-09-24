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
            Text(agent.modelName).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            if servers.readyTools > 0 {
                Text("+\(servers.readyTools) tools").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .help(servers.all.filter(\.ready).map { "\($0.name): \($0.tools.count)" }.joined(separator: "\n"))
            }
            Spacer()
            if agent.busy {
                Button { agent.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Stop")
            } else if !agent.items.isEmpty {
                Button { agent.clear() } label: { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Clear the conversation")
            }
            Button { agent.open = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Close (⌘E)")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

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
            Text(agent.ready ? "Ask about this page, or tell it what to do here. It has the same hands as an agent on the MCP — and your other servers, from mcp.json."
                             : "Needs a router key first: Settings › Intelligence › Router. That is the model the agent talks to.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if agent.ready, let tab = browser.active, !tab.isBlank {
                ForEach(["Summarise this page", "What can I do here?", "Find the main links on this page and list them"], id: \.self) { s in
                    Button { agent.ask(s, in: browser) } label: {
                        Text(s).font(.system(size: 11.5)).foregroundStyle(Palette.ink)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Palette.wash, in: Capsule())
                    }
                    .buttonStyle(.plain)
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
            TextField(agent.ready ? "Ask, or say what to do…" : "Add a router key in Settings › Intelligence", text: $agent.draft, axis: .vertical)
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
