import AppKit
import SwiftUI

/// The Flow sheet is deliberately a sheet: importing is a single decision,
/// not another permanent browser pane.
///
/// It is the whole sheet, edge to edge — no card of its own inside the
/// system's — and its size is the presenter's (`FlowPresenter`), never its
/// content's: a header, a middle that scrolls when the window is short, and
/// a footer pinned to the bottom. A change of phase redraws the middle in
/// place; nothing moves, nothing animates from one layout to the next.
struct FlowSheet: View {
    @ObservedObject var browser: Browser
    @ObservedObject var flow = Flow.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 16)
            ScrollView(.vertical) {
                middle
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            footer
                .padding(.horizontal, 26)
                .padding(.top, 14)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.ground)
        // A sheet that comes up while something else animates (Settings
        // closing) must not animate its own first layout, and a new phase
        // replaces the old one outright: nothing morphs.
        .transaction { $0.animation = nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Move in")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { flow.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .background(Palette.wash, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close")
            }
            Text("Everything Chrome or Arc has — open tabs, spaces, bookmarks, history, passwords, Google Password Manager passkeys, signed-in state, local storage, extensions — into Copper, in one go.")
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var middle: some View {
        switch flow.phase {
        case .moving(let lines): moving(lines)
        case .done(let report): done(report)
        default: picker
        }
    }

    @ViewBuilder
    private var picker: some View {
        if !flow.sourcesKnown {
            // The look for browsers lands in a moment; say nothing until it
            // does rather than "none found".
            Color.clear.frame(height: 1)
        } else if flow.sources.isEmpty {
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
                    .accessibilityLabel("\(source.name), \(profileLine(source))")
                    .accessibilityAddTraits(flow.selected?.id == source.id ? .isSelected : [])
                }
            }
        }
    }

    private func profileLine(_ source: FlowSource) -> String {
        "\(source.profileCount) profile\(source.profileCount == 1 ? "" : "s")"
    }

    private func sourceCard(_ source: FlowSource) -> some View {
        HStack(spacing: 9) {
            Image(systemName: source.glyph)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Text(profileLine(source))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(flow.selected?.id == source.id ? Palette.wash : Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(flow.selected?.id == source.id ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
                        .fixedSize(horizontal: false, vertical: true)
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
            row("Signed-in state", hint: "cookies — asks macOS once", binding: binding(\.cookies))
            Rule()
            row("Local storage", hint: "what sites keep in the page — settings, drafts, workspaces; no prompt", binding: binding(\.localStorage))
            Rule()
            row("Extensions", hint: extensionHint, binding: binding(\.extensions))
        }
        .padding(.horizontal, 13)
        .background(Palette.wash.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .disabled(flow.selected == nil)
    }

    private func row(_ title: String, hint: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                if !hint.isEmpty {
                    Text(hint).font(.system(size: 11)).foregroundStyle(Palette.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Switch(on: binding)
                // The switch is drawn, not a control: say what it is.
                .accessibilityElement()
                .accessibilityLabel(title)
                .accessibilityValue(binding.wrappedValue ? "On" : "Off")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { binding.wrappedValue.toggle() }
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
        guard case .preview(let haul) = flow.phase else { return countingHint }
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
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                }
            }
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch flow.phase {
        case .done:
            HStack(spacing: 14) {
                Button("Undo the tabs") { flow.undo() }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer()
                primary("Done") { flow.close() }
            }
        case .moving:
            Text("You can close this; the move keeps going.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 12) {
                if flow.choice.passwords || flow.choice.passkeys || flow.choice.cookies,
                   let source = flow.selected {
                    Text("macOS will ask once for \(source.name)'s keychain key (“\(source.source.service)”) — it unlocks passwords, passkeys and signed-in state. Say Allow; the window keeps working while it asks.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let source = flow.selected, let date = flow.movedAt[source.name], !flow.moveAgain {
                    // A move is one-time: once a browser is in, say when, and
                    // make running it again a choice rather than the big button.
                    HStack {
                        Image(systemName: "checkmark.circle").font(.system(size: 13)).foregroundStyle(Palette.ink)
                        Text("Moved in from \(source.name) on \(date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 13)).foregroundStyle(Palette.ink)
                        Spacer()
                        primary("Move in again") { flow.moveAgain = true }
                    }
                } else {
                    HStack {
                        Spacer()
                        primary("Bring it all over", disabled: !flow.canMove) {
                            guard let source = flow.selected else { return }
                            Task { await flow.move(source, into: browser) }
                        }
                    }
                }
            }
        }
    }

    /// The one button Return presses, in every state.
    private func primary(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ground)
            .padding(.horizontal, 17).padding(.vertical, 10)
            .background(Palette.ink.opacity(disabled ? 0.35 : 1), in: Capsule())
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
    }
}
