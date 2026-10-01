import AppKit
import SwiftUI

// The Canvas door at the foot of the sidebar, beside Bookmarks and
// Extensions, and the card it opens: Personal, the canvases you made, the
// ones shared with you, invites waiting for an answer, and New canvas. Each
// row opens its canvas in a tab; its context menu renames, invites, lists
// members, leaves or deletes. Sharing needs Copper Cloud — signed out, the
// card says so in one line and everything cloud-shaped stays out of sight.

@MainActor
final class CanvasUI: ObservableObject {
    static let shared = CanvasUI()

    enum Mode: Equatable {
        case list
        case new
        case rename(String)
        case invite(String)
        case members(String)
        case delete(String)
    }

    @Published var popoverOpen = false {
        didSet {
            if popoverOpen, !oldValue { Canvases.shared.refreshSoon() }
            if !popoverOpen { mode = .list; note = nil }
        }
    }
    @Published var mode: Mode = .list
    /// A line under the list after something worked or didn't.
    @Published var note: String?

    /// Settings › Cloud — looked up by name, so this builds whether or not
    /// the Cloud page is in this build; without it, Settings opens as it was.
    static func openCloudSettings(in browser: Browser) {
        if let page = SettingsPanel.Page(rawValue: "cloud") { browser.openSettings(page) } else { browser.tuning = true }
    }

    /// The card drawn off screen at its own size, for `bench canvas ui picture`.
    static func picture(browser: Browser, dark: Bool) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: CanvasPopover(browser: browser)
            .padding(16)
            .background(Color(nsColor: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.9, alpha: 1)))
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

    /// "New canvas…" from ⌘K or the menu: the card, at its name field — or,
    /// with no sidebar to hang it from, an untitled canvas straight away.
    func newCanvas(in browser: Browser) {
        if browser.prefs.sidebar, !browser.folded {
            popoverOpen = true
            mode = .new
        } else {
            Task {
                if let entry = try? await Canvases.shared.create(named: "Untitled canvas") {
                    CanvasHost.show(entry.id, in: browser)
                }
            }
        }
    }
}

/// The door. A dot on it while any canvas has someone else in it.
struct CanvasDoor: View {
    @ObservedObject var browser: Browser
    let tint: SpaceTint
    @ObservedObject private var ui = CanvasUI.shared
    @ObservedObject private var presence = CanvasPresence.shared

    private var others: Int { presence.peers.values.reduce(0, +) }

    var body: some View {
        Door(icon: "scribble.variable", help: others > 0 ? "Canvas · \(others) here now   ⌘⇧O" : "Canvas   ⌘⇧O",
             size: 28, ink: tint.ink, glow: tint.hover, glyph: 14) {
            ui.popoverOpen.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if others > 0 {
                Circle().fill(Color.green).frame(width: 6, height: 6).offset(x: -4, y: 4)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("Canvas")
        .popover(isPresented: $ui.popoverOpen, arrowEdge: .top) {
            CanvasPopover(browser: browser)
        }
        .animation(Motion.quick, value: others)
    }
}

/// The card.
struct CanvasPopover: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var canvases = Canvases.shared
    @ObservedObject private var ui = CanvasUI.shared
    @ObservedObject private var presence = CanvasPresence.shared
    @ObservedObject private var cloud = Cloud.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            switch ui.mode {
            case .list, .new:
                list
            case .rename(let id):
                if let entry = canvases.entry(id) { CanvasNameForm(title: "Rename “\(entry.name)”", action: "Rename", start: entry.name) { name in
                    try await canvases.rename(id, to: name)
                    ui.note = "Renamed to “\(Canvases.clean(name))”"
                } }
            case .invite(let id):
                if let entry = canvases.entry(id) { CanvasInviteForm(entry: entry) }
            case .members(let id):
                if let entry = canvases.entry(id) { CanvasMembers(entry: entry) }
            case .delete(let id):
                if let entry = canvases.entry(id) { CanvasDeleteConfirm(entry: entry, browser: browser) }
            }
        }
        .frame(width: 320)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .animation(Motion.settle, value: ui.mode)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if ui.mode != .list && ui.mode != .new {
                Button { ui.mode = .list } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .help("Back")
                .accessibilityLabel("Back to canvases")
            }
            Text("Canvas").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer(minLength: 6)
            if canvases.busy { ProgressView().controlSize(.mini) }
            Text(status).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var status: String {
        if let account = cloud.account, canvases.cloudReady { return account.displayName.isEmpty ? account.email : account.displayName }
        return "On this Mac"
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    CanvasRow(entry: canvases.personal, browser: browser)
                    if !canvases.invites.isEmpty {
                        CanvasSection(title: "Waiting for you")
                        ForEach(canvases.invites) { invite in CanvasInviteRow(invite: invite) }
                    }
                    let mine = canvases.mine
                    if !mine.isEmpty {
                        CanvasSection(title: "My canvases")
                        ForEach(mine) { entry in CanvasRow(entry: entry, browser: browser) }
                    }
                    let shared = canvases.sharedWithMe
                    if !shared.isEmpty {
                        CanvasSection(title: "Shared with me")
                        ForEach(shared) { entry in CanvasRow(entry: entry, browser: browser) }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            if let note = ui.note ?? canvases.problem {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(canvases.problem != nil && ui.note == nil ? Color.orange : Palette.muted)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if ui.mode == .new {
                CanvasNameForm(title: nil, action: "Create", start: "") { name in
                    let entry = try await canvases.create(named: name)
                    ui.popoverOpen = false
                    CanvasHost.show(entry.id, in: browser)
                }
            } else {
                footer
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { ui.mode = .new } label: {
                Label("New canvas", systemImage: "plus").font(.system(size: 12.5)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .help(canvases.cloudReady ? "A shared canvas on your cloud — invite people to it" : "A canvas on this Mac")
            if !canvases.cloudReady {
                Button {
                    ui.popoverOpen = false
                    CanvasUI.openCloudSettings(in: browser)
                } label: {
                    (Text("Share canvases and see each other live: ") + Text("Settings › Cloud").underline())
                        .font(.system(size: 11))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct CanvasSection: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One canvas: a click opens it (switching to its tab if it has one).
struct CanvasRow: View {
    let entry: Canvases.Entry
    @ObservedObject var browser: Browser
    @ObservedObject private var presence = CanvasPresence.shared
    @ObservedObject private var canvases = Canvases.shared
    @ObservedObject private var ui = CanvasUI.shared
    @State private var hovering = false

    private var peers: Int { presence.peers[entry.id] ?? 0 }
    private var isOpen: Bool { CanvasHost.tab(showing: entry.id, in: browser) != nil }
    private var isFront: Bool { CanvasHost.active(in: browser) == entry.id }

    private var glyph: String {
        if entry.isPersonal { return "person.crop.square" }
        if entry.isShared { return "person.2" }
        return "scribble.variable"
    }

    private var detail: String {
        if entry.isPersonal { return canvases.cloudReady ? "Private · synced" : "Private · on this Mac" }
        if entry.isShared {
            if !entry.isOwner, let owner = entry.owner, !owner.isEmpty { return "From \(owner)" }
            let members = entry.members ?? 1
            return members > 1 ? "Shared · \(members) members" : "Shared · just you so far"
        }
        return "On this Mac"
    }

    var body: some View {
        Button {
            ui.popoverOpen = false
            CanvasHost.show(entry.id, in: browser)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: isFront ? .semibold : .regular))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if peers > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("\(peers)").font(.system(size: 11).monospacedDigit())
                    }
                    .foregroundStyle(Palette.muted)
                    .help("\(peers) other\(peers == 1 ? "" : "s") here now")
                } else if isOpen {
                    Text("Open").font(.system(size: 11)).foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(entry.name), \(detail)\(peers > 0 ? ", \(peers) here now" : "")")
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { ui.popoverOpen = false; CanvasHost.show(entry.id, in: browser) }
        Button("Open in Background") { CanvasHost.show(entry.id, in: browser, foreground: false) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(CanvasLinks.url(entry.id).absoluteString, forType: .string)
        }
        if !entry.isPersonal {
            Divider()
            if entry.isOwner { Button("Rename…") { ui.mode = .rename(entry.id) } }
            if entry.isShared && canvases.cloudReady {
                Button("Invite…") { ui.mode = .invite(entry.id) }
                Button("Members…") { ui.mode = .members(entry.id) }
            }
            Divider()
            if entry.isShared && !entry.isOwner {
                Button("Leave…") { ui.mode = .delete(entry.id) }.disabled(!canvases.cloudReady)
            } else {
                Button("Delete…") { ui.mode = .delete(entry.id) }.disabled(entry.isShared && !canvases.cloudReady)
            }
        }
    }
}

private struct CanvasInviteRow: View {
    let invite: Canvases.Invite
    @ObservedObject private var ui = CanvasUI.shared
    @State private var working = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash))
            VStack(alignment: .leading, spacing: 1) {
                Text(invite.canvasName).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(invite.from.isEmpty ? "Invited you" : "From \(invite.from)")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Decline") { answer(false) }
                .controlSize(.small)
                .disabled(working)
            Button("Accept") { answer(true) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(working)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func answer(_ accept: Bool) {
        working = true
        Task {
            do {
                try await Canvases.shared.answer(invite, accept: accept)
                ui.note = accept ? "Joined “\(invite.canvasName)”" : "Declined “\(invite.canvasName)”"
            } catch {
                ui.note = Canvases.explain(error)
            }
            working = false
        }
    }
}

/// A name, asked for in place: New canvas and Rename.
private struct CanvasNameForm: View {
    let title: String?
    let action: String
    let start: String
    let done: (String) async throws -> Void
    @ObservedObject private var ui = CanvasUI.shared
    @ObservedObject private var canvases = Canvases.shared
    @State private var name = ""
    @State private var working = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1) }
            TextField("Canvas name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .disabled(working)
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(2) }
            if title == nil {
                Text(canvases.cloudReady ? "Shared on your cloud — invite people once it's made." : "On this Mac. Sign in at Settings › Cloud to share.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { ui.mode = .list }
                    .keyboardShortcut(.cancelAction)
                Button(action, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            name = start
            DispatchQueue.main.async { focused = true }
        }
    }

    private func submit() {
        guard !working, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        working = true
        failure = nil
        Task {
            do {
                try await done(name)
                if ui.mode != .list { ui.mode = .list }
            } catch {
                failure = Canvases.explain(error)
            }
            working = false
        }
    }
}

private struct CanvasInviteForm: View {
    let entry: Canvases.Entry
    @ObservedObject private var ui = CanvasUI.shared
    @State private var email = ""
    @State private var working = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invite to “\(entry.name)”").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
            TextField("name@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .focused($focused)
                .onSubmit(submit)
                .disabled(working)
            Text("They'll see it under Waiting for you once they sign in to the same cloud.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(2) }
            HStack {
                Spacer()
                Button("Cancel") { ui.mode = .list }
                    .keyboardShortcut(.cancelAction)
                Button("Send Invite", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !email.contains("@"))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func submit() {
        guard !working, email.contains("@") else { return }
        working = true
        failure = nil
        Task {
            do {
                try await Canvases.shared.invite(entry.id, email: email)
                ui.note = "Invited \(email.trimmingCharacters(in: .whitespaces))"
                ui.mode = .list
            } catch {
                failure = Canvases.explain(error)
            }
            working = false
        }
    }
}

private struct CanvasMembers: View {
    let entry: Canvases.Entry
    @State private var members: [Canvases.Member] = []
    @State private var failure: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Members of “\(entry.name)”").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                .lineLimit(1).padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            if loading {
                ProgressView().controlSize(.small).padding(14)
            } else if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(Color.orange).padding(14)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(members) { member in
                            HStack(spacing: 10) {
                                Circle().fill(Color(hex: CanvasColors.stable(member.id)))
                                    .frame(width: 22, height: 22)
                                    .overlay(Text(String(member.name.prefix(1)).uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.name.isEmpty ? member.email : member.name).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                                    if !member.email.isEmpty, member.email != member.name {
                                        Text(member.email).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text(member.role.capitalized).font(.system(size: 11)).foregroundStyle(Palette.faint)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
        .task {
            do { members = try await Canvases.shared.members(entry.id) } catch { failure = Canvases.explain(error) }
            loading = false
        }
    }
}

private struct CanvasDeleteConfirm: View {
    let entry: Canvases.Entry
    @ObservedObject var browser: Browser
    @ObservedObject private var ui = CanvasUI.shared
    @State private var working = false
    @State private var failure: String?

    private var leaving: Bool { entry.isShared && !entry.isOwner }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(leaving ? "Leave “\(entry.name)”?" : "Delete “\(entry.name)”?")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
            Text(leaving ? "It stays for everyone else. Someone will have to invite you again."
                 : entry.isShared ? "It goes for every member, with everything on it." : "Everything on it goes too. This can't be undone.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(2) }
            HStack {
                Spacer()
                Button("Cancel") { ui.mode = .list }
                    .keyboardShortcut(.cancelAction)
                Button(leaving ? "Leave" : "Delete", role: .destructive) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func run() {
        working = true
        Task {
            do {
                if leaving { try await Canvases.shared.leave(entry.id) } else { try await Canvases.shared.delete(entry.id) }
                ui.note = leaving ? "Left “\(entry.name)”" : "Deleted “\(entry.name)”"
                ui.mode = .list
            } catch {
                failure = Canvases.explain(error)
            }
            working = false
        }
    }
}

private extension Color {
    /// `#rrggbb`.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
