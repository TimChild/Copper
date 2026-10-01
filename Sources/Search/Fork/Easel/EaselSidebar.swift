import AppKit
import SwiftUI

// Easels in the sidebar, the way Arc keeps them: a board is a row you keep,
// not one of today's tabs.
//
// - Where it goes. A board's tab, the first time it loads (⌘K's New Easel,
//   File › New Easel ⌃⇧E, the New Tab row's and the foot plus's menus, a
//   space's menu, Open Easel…, its address typed or handed to Copper by an
//   agent), joins its space's Saved block at the bottom and is selected. So
//   Today's archive never takes it — and the sweep passes over a board even
//   if somebody drags it down into Today (Sections.sweep).
// - Its row. Right-click: Rename Easel… (a field on the row, as a folder's
//   rename is) and Delete Easel… (a sheet that asks first), above Copper's
//   ordinary tab items.
// - Renaming. The index takes the name at once (⌘K, the address pill), an
//   open board is told `rename {title}` so its document and its tab title
//   follow, and a sleeping one has its row retitled now and its page told on
//   its next `config` (`renamed: true`, then `rename`). See EaselStore.rename
//   for how a page that has not caught up yet is kept from undoing it.
// - Deleting. Every tab showing the board closes — in this row, a pinned
//   square, another space, another window — and its folder goes: document
//   and pictures. Its address opens nothing for the rest of the session.

extension Easels {
    /// A board's tab joining the sidebar for the first time: Saved, at the
    /// bottom of the block. Tabs the sections already know (restored,
    /// dragged into Today by hand) are left where they are.
    static func keep(_ tab: Tab) {
        guard tab.pin == nil, !tab.bench, !Sections.shared.knows(tab) else { return }
        Sections.shared.set(tab, saved: true, in: browser(of: tab))
    }

    /// Every tab showing a board, awake or asleep, in any window or space.
    static func tabs(showing id: String) -> [Tab] {
        (Windows.all.flatMap(\.tabs) + Spaces.shared.parkedTabs).filter { showing($0) == id }
    }

    /// The title a board's row comes back from the session with: Copper's,
    /// when the index has the board — a rename made while the tab slept
    /// may not have reached the session file yet.
    static func rowTitle(for url: URL, kept: String) -> String {
        guard let id = id(of: url), let easel = EaselStore.shared.easel(id) else { return kept }
        return easel.title
    }

    /// Rename Easel…, done. Nothing when the name is the same, or empty.
    static func rename(_ id: String, to title: String) {
        let store = EaselStore.shared
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              store.rename(id, to: title), let easel = store.easel(id) else { return }
        for tab in tabs(showing: id) {
            // Awake: the page takes it into its document, then its title.
            if let web = tab.built { EaselBridge.tell(web, ["type": "rename", "title": easel.title]) }
            // Asleep: the row says it now; the page hears on waking.
            if let url = tab.pending { tab.restore(url: url, title: easel.title) }
        }
    }

    /// Delete Easel…, confirmed. The index forgets it first, so the last
    /// `save` its closing page sends cannot bring it back.
    static func delete(_ id: String) {
        EaselStore.shared.delete(id)
        for owner in Windows.all {
            for tab in owner.tabs where showing(tab) == id {
                // A pinned tab is only put down by Close; it has to come out.
                if tab.pin != nil { owner.unpin(tab) }
                owner.close(tab)
            }
        }
        for tab in Spaces.shared.parkedTabs where showing(tab) == id { Spaces.shared.drop(tab) }
    }
}

// MARK: - the row's menu

/// The first items on a board's context menu — in the sidebar, a pinned
/// square and the top bar alike (TabMenu). Nothing for any other tab.
struct EaselMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        if let id = Easels.showing(tab) {
            Button("Rename Easel…") { EaselRenaming.shared.ask(tab, in: browser) }
            Button("Delete Easel…", role: .destructive) { EaselDelete.ask(id, in: browser) }
            Divider()
        }
    }
}

/// "New Tab" and "New Easel": the New Tab row's right-click, Arc's new-item
/// menu.
struct NewItemMenu: View {
    @ObservedObject var browser: Browser

    var body: some View {
        Button("New Tab") { browser.launch() }
            .keyboardShortcut("t")
        Button("New Easel") { Easels.newEasel(in: browser) }
            .keyboardShortcut("e", modifiers: [.control, .shift])
    }
}

// MARK: - renaming

/// Which board row is showing its name field, and where the rows that can
/// show one are. A row that is not on screen (a pinned square, the top bar)
/// gets a sheet instead.
@MainActor
final class EaselRenaming: ObservableObject {
    static let shared = EaselRenaming()

    @Published var target: Tab.ID?
    /// Board rows on screen, by tab, in window points from the top left.
    var rows: [Tab.ID: CGRect] = [:]

    func ask(_ tab: Tab, in browser: Browser) {
        guard let id = Easels.showing(tab) else { return }
        guard rows[tab.id] != nil else { return EaselRenameSheet.ask(id, in: browser) }
        // After the menu has gone: a popover asked for while the context
        // menu is still closing is dropped.
        DispatchQueue.main.async { self.target = tab.id }
    }
}

/// On SideRow: the name field a board's row shows, and the row's place for
/// `ask` and the bench. Every row wears it; only a board's ever opens.
struct EaselRow: ViewModifier {
    @ObservedObject var tab: Tab
    @ObservedObject private var renaming = EaselRenaming.shared

    func body(content: Content) -> some View {
        content
            .popover(isPresented: Binding(get: { renaming.target == tab.id },
                                          set: { if !$0, renaming.target == tab.id { renaming.target = nil } }),
                     arrowEdge: .trailing) {
                EaselRenameField(tab: tab)
            }
            .background { if Easels.showing(tab) != nil { EaselRowSpot(id: tab.id) } }
    }
}

private struct EaselRowSpot: View {
    let id: Tab.ID

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { EaselRenaming.shared.rows[id] = $0 }
            .onDisappear { EaselRenaming.shared.rows[id] = nil }
    }
}

/// The field itself: the name as it is, selected, Return to keep the new one
/// and Escape (or a click away) to leave it — a folder's rename, for a board.
private struct EaselRenameField: View {
    let tab: Tab
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Easel name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .padding(8)
            .focused($focused)
            .onAppear {
                draft = Easels.showing(tab).flatMap { EaselStore.shared.easel($0)?.title } ?? tab.title
                focused = true
            }
            .onSubmit {
                if let id = Easels.showing(tab) { Easels.rename(id, to: draft) }
                EaselRenaming.shared.target = nil
            }
    }
}

/// Rename Easel… where there is no row to hang a field from.
@MainActor
enum EaselRenameSheet {
    static func ask(_ id: String, in browser: Browser) {
        let alert = NSAlert()
        alert.messageText = "Rename Easel"
        let field = NSTextField(string: EaselStore.shared.easel(id)?.title ?? EaselStore.untitled)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            Easels.rename(id, to: field.stringValue)
        }
        DispatchQueue.main.async {
            if let window = Windows.window(of: browser) ?? Links.window, window.isVisible {
                alert.beginSheetModal(for: window, completionHandler: decide)
            } else {
                decide(alert.runModal())
            }
        }
    }
}

// MARK: - deleting

/// Delete Easel… asks first: the board's notes and pictures go with it.
@MainActor
enum EaselDelete {
    /// The sheet while it is up, so `bench easels answer` can press a button.
    private(set) static var asking: NSAlert?
    /// What the last sheet did, for the bench.
    private(set) static var last = ""

    static var describe: [String: Any] {
        guard let alert = asking else { return ["last": last] }
        return ["message": alert.messageText, "detail": alert.informativeText, "buttons": alert.buttons.map(\.title), "last": last]
    }

    static func ask(_ id: String, in browser: Browser) {
        let title = EaselStore.shared.easel(id)?.title ?? Easels.tabs(showing: id).first?.title ?? EaselStore.untitled
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = "Its notes and pictures are removed from this Mac."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            asking = nil
            if response == .alertFirstButtonReturn {
                Easels.delete(id)
                last = "deleted"
            } else {
                last = "cancelled"
            }
        }
        asking = alert
        DispatchQueue.main.async {
            if let window = Windows.window(of: browser) ?? Links.window, window.isVisible {
                alert.beginSheetModal(for: window, completionHandler: decide)
            } else {
                decide(alert.runModal())
            }
        }
    }

    /// `bench easels answer delete|cancel`: that button, pressed.
    static func answer(_ choice: String) -> Bool {
        guard let alert = asking else { return false }
        let wanted = choice == "delete" ? "Delete" : "Cancel"
        guard let button = alert.buttons.first(where: { $0.title == wanted }) else { return false }
        button.performClick(nil)
        return true
    }
}
