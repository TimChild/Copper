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
        default:
            if let source = flow.exporting { export(source) } else { picker }
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
                // Under the switches it is about, in the part that scrolls,
                // so a short window keeps its room for the list.
                if flow.choice.passwords || flow.choice.passkeys || flow.choice.cookies,
                   let source = flow.selected {
                    Text("macOS will ask once for \(source.name)'s keychain key (“\(source.source.service)”) — it unlocks passwords, passkeys and signed-in state. Say Allow; the window keeps working while it asks.")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var sourceCards: some View {
        if flow.sources.count == 1, let only = flow.sources.first {
            card(only)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top),
                                GridItem(.flexible(), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 8) {
                ForEach(flow.sources) { card($0) }
            }
        }
    }

    @ViewBuilder
    private func card(_ source: FlowSource) -> some View {
        if source.locked {
            lockedCard(source)
        } else if source.empty {
            emptyCard(source)
        } else {
            Button { flow.scan(source) } label: {
                sourceCard(source)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(source.name), \(profileLine(source))")
            .accessibilityAddTraits(flow.selected?.id == source.id ? .isSelected : [])
        }
    }

    private func profileLine(_ source: FlowSource) -> String {
        "\(source.profileCount) profile\(source.profileCount == 1 ? "" : "s")"
    }

    private func cardHead(_ source: FlowSource, _ line: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: source.glyph)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Text(line)
                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceCard(_ source: FlowSource) -> some View {
        cardHead(source, profileLine(source))
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(flow.selected?.id == source.id ? Palette.wash : Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(flow.selected?.id == source.id ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// macOS keeps the folder private. One sentence, one way to let Copper
    /// in, one way around it; Copper looks again as soon as it is back in
    /// front, so there is nothing to reopen.
    private func lockedCard(_ source: FlowSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHead(source, "macOS needs your OK before Copper can read \(source.name).")
            // Side by side when the card is wide; one above the other in
            // half a sheet, never a pill broken over two lines.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { lockedButtons(source) }
                VStack(alignment: .leading, spacing: 8) { lockedButtons(source) }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func lockedButtons(_ source: FlowSource) -> some View {
        Button("Allow in System Settings…") { flow.allow(source) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Palette.ground)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Palette.ink, in: Capsule())
            .accessibilityHint("Opens Privacy & Security, Files & Folders")
        Button("Use an export instead…") { flow.showExport(for: source) }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Palette.ink)
    }

    /// Installed, but it has never been opened: nothing to read yet.
    private func emptyCard(_ source: FlowSource) -> some View {
        cardHead(source, "Open \(source.name) once, then come back.")
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .opacity(0.6)
            .accessibilityElement(children: .combine)
    }

    // MARK: - the export pane

    @State private var dropping = false

    private func export(_ source: FlowSource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bring in a file \(source.name) exported")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.ink)
                Text("A file brings only bookmarks or passwords — no open tabs, history or sign-ins.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                if flow.fileBusy {
                    ProgressView().controlSize(.small)
                    Text("Reading the file…")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                } else {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Palette.muted)
                    Text("Drop the file here")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(dropping ? Palette.wash : Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropping ? Palette.ink.opacity(0.5) : Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard !flow.fileBusy, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { flow.takeFile(url, from: source.name, into: browser) }
                }
                return true
            }
            .accessibilityLabel("Drop a bookmarks or passwords file here")
            VStack(alignment: .leading, spacing: 8) {
                if source.name == "Chrome" {
                    howTo("Bookmarks", "in Chrome, ⋮ › Bookmarks and lists › Bookmark manager, then ⋮ › Export bookmarks")
                    howTo("Passwords", "in Chrome, ⋮ › Passwords and autofill › Password Manager › Settings › Export passwords")
                } else {
                    howTo("Bookmarks", "export them from \(source.name)'s bookmark manager")
                    howTo("Passwords", "export them from \(source.name)'s password settings")
                }
            }
            if let result = flow.fileResult {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: result.ok ? "checkmark" : "minus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(result.ok ? Palette.ink : Palette.muted)
                        .frame(width: 12)
                    Text(result.text)
                        .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func howTo(_ what: String, _ path: String) -> some View {
        (Text(what).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.ink)
            + Text(" — " + path).font(.system(size: 12)).foregroundColor(Palette.muted))
            .fixedSize(horizontal: false, vertical: true)
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
        .opacity(flow.selected == nil ? 0.5 : 1)
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
        }
        .padding(.vertical, 9)
    }

    /// Hints are counts; before there are any, "counting…" or nothing.
    private var countingHint: String {
        flow.phase == .scanning ? "counting…" : ""
    }

    private var tabHint: String {
        guard case .preview(let haul) = flow.phase else { return countingHint }
        let open = haul.spaces.filter { !$0.tabs.isEmpty }.count
        let unit = flow.selected?.isArc == true ? "space" : "window"
        return haul.tabCount == 0 ? "none open" : "\(FlowSummary.plural(haul.tabCount, "tab")) in \(FlowSummary.plural(open, unit))"
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
            Text(report.title)
                .font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.summary, id: \.category) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: line.ok ? "checkmark" : "minus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(line.ok ? Palette.ink : Palette.muted)
                            .frame(width: 12)
                        Text(line.text)
                            .font(.system(size: 13)).foregroundStyle(line.ok ? Palette.ink : Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if report.undone {
                Text("Took back the tabs and spaces this move added.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            if flow.guide == .failed {
                Text("Couldn't open the Chrome guide.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            ForEach(report.notes.filter { $0.contains("still installing") }, id: \.self) { note in
                Text(note.prefix(1).uppercased() + note.dropFirst() + ".")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch flow.phase {
        case .done(let report):
            HStack(spacing: 16) {
                if flow.canUndo {
                    Button("Undo the tabs") { flow.undo() }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                }
                if report.guideOffered, flow.guide != .opened {
                    Button(flow.guide == .opening ? "Opening the guide…" : "Open the Chrome guide") {
                        Task { await flow.openGuide() }
                    }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    .disabled(flow.guide == .opening)
                }
                Spacer()
                primary("Done") { flow.finish() }
            }
        case .moving:
            Text("You can close this; the move keeps going.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            if let source = flow.exporting {
                HStack(spacing: 14) {
                    Button("Back") { flow.exporting = nil; flow.fileResult = nil }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                    Spacer()
                    primary("Choose a file…", disabled: flow.fileBusy) { flow.chooseFile(from: source.name, into: browser) }
                }
            } else {
                pickerFooter
            }
        }
    }

    private var pickerFooter: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
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
