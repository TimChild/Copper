import AppKit
import SwiftUI

/// The Flow sheet is deliberately a sheet: importing is a single decision,
/// not another permanent browser pane.
struct FlowSheet: View {
    @ObservedObject var browser: Browser
    @ObservedObject var flow = Flow.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch flow.phase {
                case .moving(let lines): moving(lines)
                case .done(let report): done(report)
                default: picker
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(26)
        .frame(width: 560)
        .background(Palette.ground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 32, y: 12)
        .onAppear { flow.refreshSources() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard flow.open else { return }
            flow.refreshSources()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Move in")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Button { flow.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .background(Palette.wash, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
            Text("Everything Chrome or Arc has — open tabs, spaces, bookmarks, history, passwords, Google Password Manager passkeys, signed-in state, extensions — into Copper, in one go.")
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var picker: some View {
        if flow.sources.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("No other browser found on this Mac")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.muted)
                Button("Passwords from a CSV…") { browser.importPasswords() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                sourceCards
                checklist
                if case .scanning = flow.phase {
                    HStack(spacing: 8) { Ring(size: 12); Text("Looking through it…").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                }
            }
        }
    }

    private var sourceCards: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(flow.sources) { source in
                if source.locked {
                    lockedCard(source)
                } else {
                    Button { flow.scan(source) } label: {
                        sourceCard(source)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sourceCard(_ source: FlowSource) -> some View {
        HStack(spacing: 9) {
            Image(systemName: source.glyph)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Text("\(source.profileCount) profile\(source.profileCount == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(flow.selected?.id == source.id ? Palette.wash : Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(flow.selected?.id == source.id ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1))
    }

    private func lockedCard(_ source: FlowSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: source.glyph)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                    Text("macOS keeps \(source.name)'s data private")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            Button("Choose folder…") { flow.chooseFolder(for: source) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text("Or allow Copper under System Settings › Privacy & Security › App Data (or Files & Folders), then reopen.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Open tabs, spaces and pins", hint: tabHint, binding: binding(\.tabs))
            Rule()
            row("Bookmarks", hint: bookmarkHint, binding: binding(\.bookmarks))
            Rule()
            row("History", hint: placeHint, binding: binding(\.history))
            Rule()
            row("Passwords", hint: "asks macOS once", binding: binding(\.passwords))
            Rule()
            row("Passkeys", hint: passkeyHint, binding: binding(\.passkeys))
            Rule()
            row("Signed-in state", hint: "asks macOS once", binding: binding(\.cookies))
            Rule()
            row("Extensions", hint: extensionHint, binding: binding(\.extensions))
        }
        .padding(.horizontal, 13)
        .background(Palette.wash.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private func row(_ title: String, hint: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                if !hint.isEmpty { Text(hint).font(.system(size: 11)).foregroundStyle(Palette.faint) }
            }
            Spacer()
            Switch(on: binding)
        }
        .padding(.vertical, 9)
    }

    private var countingHint: String {
        flow.phase == .scanning ? "counting…" : "choose a browser"
    }

    private var tabHint: String {
        guard case .preview(let haul) = flow.phase else { return countingHint }
        return "\(haul.tabCount) tabs in \(haul.spaces.count) spaces"
    }

    private var passkeyHint: String {
        guard case .preview(let haul) = flow.phase else { return flow.phase == .scanning ? "counting…" : "choose a browser" }
        return haul.passkeyCount == 0 ? "none found" : "\(haul.passkeyCount.formatted()) passkeys — asks macOS once"
    }

    private var extensionHint: String {
        guard case .preview(let haul) = flow.phase else { return "reinstalled from the store" }
        return haul.extensions.isEmpty ? "none found" : "\(haul.extensions.count) found"
    }

    private var bookmarkHint: String {
        guard case .preview(let haul) = flow.phase else { return countingHint }
        return haul.bookmarkCount == 0 ? "none found" : "\(haul.bookmarkCount.formatted()) bookmarks"
    }

    private var placeHint: String {
        guard case .preview(let haul) = flow.phase else { return countingHint }
        return haul.placeCount == 0 ? "none found" : "\(haul.placeCount.formatted()) places"
    }

    private func binding(_ keyPath: WritableKeyPath<FlowModel.Choice, Bool>) -> Binding<Bool> {
        Binding(get: { flow.choice[keyPath: keyPath] }, set: { flow.choice[keyPath: keyPath] = $0 })
    }

    @ViewBuilder
    private func moving(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bringing it over…")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text(line).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    }
                }
            }
            if lines.isEmpty { Ring(size: 14) }
        }
    }

    private func done(_ report: Flow.Report) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("All set")
                .font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.ink)
            Text(report.line)
                .font(.system(size: 13.5)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(report.notes, id: \.self) { note in
                Text(note).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 14) {
                Button("Undo the tabs") { flow.undo() }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer()
                Pill("Done", filled: true) { flow.close() }
            }
            .padding(.top, 5)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case .done = flow.phase {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if flow.choice.passwords || flow.choice.passkeys || flow.choice.cookies,
                   let source = flow.selected {
                    Text("macOS will ask once to hand over \(source.name)'s key — say Allow.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Bring it all over") {
                        guard let source = flow.selected else { return }
                        flow.move(source, into: browser)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 17).padding(.vertical, 10)
                    .background(Palette.ink, in: Capsule())
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.selected == nil || flow.selected?.locked == true || flow.sources.isEmpty || flow.phase == .scanning)
                }
            }
            .padding(.top, 19)
        }
    }
}
