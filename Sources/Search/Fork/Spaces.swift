import SwiftUI
import WebKit

// Spaces: several rows of tabs, one on screen at a time.
//
// The browser keeps working on one array, `tabs` — the row you are looking
// at. The other spaces' rows are parked here, and switching swaps the whole
// row and its active tab in one move. Nothing that draws or walks `tabs`
// (the column, the strip, ⌘1–9, ⌘W, drag to reorder) knows spaces exist.

struct Space: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// A hue, 0…1, or nil for the plain grey.
    var hue: Double?
    /// Which cookie jar its tabs use: nil for the one every space shares, or
    /// a name — spaces with the same name sign in together.
    var profile: String? = nil

    var tint: Color { hue.map { Color(hue: $0, saturation: 0.55, brightness: 0.75) } ?? Palette.muted }
}

@MainActor
final class Spaces: ObservableObject {
    static let shared = Spaces()

    @Published private(set) var all: [Space]
    @Published private(set) var current: UUID

    /// The rows not on screen, by space.
    private var parked: [UUID: (tabs: [Tab], active: Tab.ID?)] = [:]
    var parkedTabs: [Tab] { parked.values.flatMap(\.tabs) }
    func parkedRow(_ id: UUID) -> [Tab]? { parked[id]?.tabs }

    private init() {
        let home = Space(name: "Home")
        all = [home]
        current = home.id
    }

    var space: Space { all.first { $0.id == current } ?? all[0] }

    // MARK: - switching

    func select(_ id: UUID, in browser: Browser) {
        guard id != current, all.contains(where: { $0.id == id }) else { return }
        parked[current] = (browser.tabs, browser.activeID)
        let next = parked.removeValue(forKey: id) ?? ([], nil)
        current = id
        browser.tabs = next.tabs
        if next.tabs.isEmpty {
            browser.newTab()
        } else if let active = next.tabs.first(where: { $0.id == next.active }) ?? next.tabs.first {
            browser.activeID = nil
            browser.select(active)
        }
        // A row is only ever swept while it is the one on screen, so the
        // archive never runs on a space behind your back. (Fork: sections)
        Sections.shared.sweep(in: browser)
    }

    func step(_ by: Int, in browser: Browser) {
        guard let here = all.firstIndex(where: { $0.id == current }) else { return }
        select(all[(here + by + all.count) % all.count].id, in: browser)
    }

    func select(index: Int, in browser: Browser) {
        guard all.indices.contains(index) else { return }
        select(all[index].id, in: browser)
    }

    // MARK: - editing

    func add(named name: String = "", in browser: Browser) {
        let space = Space(name: name.isEmpty ? "Space \(all.count + 1)" : name, hue: Double(all.count % 8) / 8)
        all.append(space)
        select(space.id, in: browser)
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = all.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        all[i].name = name
    }

    func tint(_ id: UUID, hue: Double?) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].hue = hue
    }

    /// Its tabs close for good. The last space cannot be removed.
    func remove(_ id: UUID, in browser: Browser) {
        guard all.count > 1, let i = all.firstIndex(where: { $0.id == id }) else { return }
        if id == current { step(i == 0 ? 1 : -1, in: browser) }
        parked.removeValue(forKey: id)?.tabs.forEach { $0.close() }
        all.remove(at: i)
    }

    /// Move the active tab to another space; it lands at that row's end and
    /// this row moves on, as if the tab had been closed.
    func move(_ tab: Tab, to id: UUID, in browser: Browser) {
        guard id != current, all.contains(where: { $0.id == id }) else { return }
        var row = parked[id] ?? ([], nil)
        row.tabs.append(tab)
        parked[id] = row
        browser.tabs.removeAll { $0.id == tab.id }
        if browser.tabs.isEmpty { browser.newTab() }
        else if browser.activeID == tab.id { browser.activeID = nil; browser.select(browser.tabs[0]) }
    }

    // MARK: - profiles

    /// The space a tab is being built for — the current one, unless a
    /// restore is building another space's row.
    private var buildingFor: UUID?

    func building<T>(for id: UUID, _ make: () -> T) -> T {
        buildingFor = id
        defer { buildingFor = nil }
        return make()
    }

    func profile(_ id: UUID, named name: String?) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].profile = name?.isEmpty == true ? nil : name
    }

    var profiles: [String] { Array(Set(all.compactMap(\.profile))).sorted() }

    /// The store for the space a tab is being built for, or nil for the
    /// shared one. Read from Store.websites, which WebKit asks off the main
    /// actor as well; a space's profile only ever changes on it.
    nonisolated static var profileStore: WKWebsiteDataStore? {
        MainActor.assumeIsolated {
            let spaces = Spaces.shared
            let id = spaces.buildingFor ?? spaces.current
            guard let name = spaces.all.first(where: { $0.id == id })?.profile else { return nil }
            // A fixed id per name, so the jar is the same one next launch.
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            let text = String(format: "C0FFEE00-%04X-4000-8000-%012llX", UInt16(truncatingIfNeeded: hash >> 48), hash & 0xFFFF_FFFF_FFFF)
            return WKWebsiteDataStore(forIdentifier: UUID(uuidString: text)!)
        }
    }

    // MARK: - session

    /// Every row, on screen or parked, in one shape upstream can still read:
    /// a flat list of tabs and the index of the one on screen.
    func shape(visible: [Tab], active: Tab.ID?) -> Session.Shape {
        var entries: [Session.Entry] = []
        var activeIndex = 0
        func put(_ tabs: [Tab], _ id: UUID, _ activeID: Tab.ID?, visible: Bool) {
            for tab in tabs {
                guard var entry = Session.Entry(tab) else { continue }
                entry.space = id
                entry.group = Groups.shared.membership[tab.id]
                entry.saved = tab.pin == nil ? Sections.shared.isSaved(tab) : nil
                entry.seen = Sections.shared.lastSeen(tab).timeIntervalSince1970
                entry.active = tab.id == activeID ? true : nil
                if visible, entry.active == true { activeIndex = entries.count }
                entries.append(entry)
            }
        }
        put(visible, current, active, visible: true)
        for (id, row) in parked { put(row.tabs, id, row.active, visible: false) }
        return .init(tabs: entries, active: activeIndex, spaces: all, space: current)
    }

    /// Yesterday's rows. The visible one lands in `browser.tabs` (built,
    /// nothing fetched); the rest are parked the same way.
    func restore(_ saved: Session.Shape, into browser: Browser) {
        if let spaces = saved.spaces, !spaces.isEmpty {
            all = spaces
            current = saved.space.flatMap { c in spaces.first { $0.id == c }?.id } ?? spaces[0].id
        }
        var rows: [UUID: (tabs: [Tab], active: Tab.ID?)] = [:]
        Sections.shared.clear()
        for (i, entry) in saved.tabs.enumerated() {
            guard let url = URL(string: entry.url) else { continue }
            let id = entry.space.flatMap { s in all.first { $0.id == s }?.id } ?? current
            let tab = building(for: id) { Tab() }
            browser.prepare(tab)
            tab.restore(url: url, title: entry.title)
            tab.pin = entry.pin
            // No flag at all is an upstream-shaped file: everything in it is
            // something you kept, so the whole column comes back as Saved.
            Sections.shared.restore(tab, saved: entry.saved ?? true, seen: entry.seen)
            Groups.shared.restore(tab, group: entry.group)
            var row = rows[id] ?? ([], nil)
            row.tabs.append(tab)
            // Upstream's file has no `active` flag — its `active` index does.
            if entry.active == true || (entry.space == nil && i == saved.active) { row.active = tab.id }
            rows[id] = row
        }
        let mine = rows.removeValue(forKey: current) ?? ([], nil)
        parked = rows
        browser.tabs = mine.tabs
        Sections.shared.begin(in: browser) // Fork: the archive sweep, at launch and every half hour
        guard let first = mine.tabs.first else { return }
        let active = mine.tabs.first { $0.id == mine.active } ?? first
        browser.activeID = active.id
        Sections.shared.note(active.id)
        _ = active.wake()
    }
}

extension Session.Entry {
    /// What the row needs to draw the tab again, or nil for a tab that is not
    /// worth keeping: private, the bench's, or not yet on a real page.
    @MainActor init?(_ tab: Tab) {
        guard !tab.shy, !tab.bench else { return nil }
        // A sleeping tab holds its address in `pending`; asking for it there
        // too means a pin can never be written out of existence by whatever
        // its web view happens to be showing.
        guard let url = tab.pending ?? tab.address, url.scheme?.hasPrefix("http") == true else { return nil }
        self.init(url: url.absoluteString, title: tab.title, pin: tab.pin)
    }
}

// MARK: - the strip at the foot of the column

struct SpaceStrip<Tools: View>: View {
    @ObservedObject var browser: Browser
    /// The column's own small doors — bookmarks, extensions. They used to sit
    /// on a row of their own under this one, where a single glyph read as
    /// something left behind; the foot is one line now, the way Arc's is.
    @ViewBuilder var tools: () -> Tools
    @ObservedObject var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @State private var renaming: UUID?
    @State private var profiling: UUID?
    @State private var draft = ""
    @State private var hovering: UUID?

    private var tint: SpaceTint { SpaceTint(hue: spaces.space.hue, dark: scheme == .dark) }

    /// Arc's foot: the space you are in, named, on the left; every other
    /// space as a dot in its own colour on the right; a plus at the end.
    var body: some View {
        HStack(spacing: 2) {
            here
            Spacer(minLength: 4)
            ForEach(spaces.all.filter { $0.id != spaces.current }) { space in
                dot(space)
            }
            plus
            tools()
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 7)
        .animation(Motion.glide, value: spaces.current)
    }

    private var here: some View {
        let space = spaces.space
        return Button { spaces.select(space.id, in: browser) } label: {
            HStack(spacing: 6) {
                badge(space, size: 15)
                Text(space.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.pill))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint.ink)
        .help(space.name)
        // The name is the one thing in this row that must stay readable;
        // the dots give up their air before it gives up a letter.
        .layoutPriority(1)
        .modifier(menus(for: space))
    }

    /// A space's emoji if its name starts with one — Arc's spaces nearly all
    /// do — and its colour as a small rounded chip if it doesn't.
    @ViewBuilder
    private func badge(_ space: Space, size: CGFloat) -> some View {
        if let first = space.name.unicodeScalars.first, first.properties.isEmojiPresentation {
            Text(String(Character(first)))
                .font(.system(size: size * 0.8))
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(SpaceTint(hue: space.hue, dark: scheme == .dark).dot)
                .frame(width: size * 0.6, height: size * 0.6)
                .frame(width: size, height: size)
        }
    }

    private func dot(_ space: Space) -> some View {
        Button { spaces.select(space.id, in: browser) } label: {
            Circle()
                .fill(SpaceTint(hue: space.hue, dark: scheme == .dark).dot)
                .frame(width: 8, height: 8)
                .opacity(hovering == space.id ? 1 : 0.65)
                .frame(width: 14, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in hovering = over ? space.id : (hovering == space.id ? nil : hovering) }
        .help(space.name)
        .modifier(menus(for: space))
    }

    private var plus: some View {
        Button { spaces.add(in: browser) } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.faint)
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Space")
    }

    /// The right-click menu and the two little name fields, on whichever
    /// shape stands for the space — the named chip or the dot.
    private func menus(for space: Space) -> some ViewModifier {
        SpaceMenus(
            menu: AnyView(menu(for: space)),
            renaming: Binding(get: { renaming == space.id }, set: { if !$0 { renaming = nil } }),
            profiling: Binding(get: { profiling == space.id }, set: { if !$0 { profiling = nil } }),
            draft: $draft,
            rename: { spaces.rename(space.id, to: draft); renaming = nil },
            profile: { spaces.profile(space.id, named: draft); profiling = nil }
        )
    }

    private struct SpaceMenus: ViewModifier {
        let menu: AnyView
        @Binding var renaming: Bool
        @Binding var profiling: Bool
        @Binding var draft: String
        let rename: () -> Void
        let profile: () -> Void

        func body(content: Content) -> some View {
            content
                .contextMenu { menu }
                .popover(isPresented: $renaming) {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .padding(8)
                        .onSubmit(rename)
                }
                .popover(isPresented: $profiling) {
                    TextField("Profile name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .padding(8)
                        .onSubmit(profile)
                }
        }
    }

    @ViewBuilder
    private func menu(for space: Space) -> some View {
        Button("Rename…") { draft = space.name; renaming = space.id }
        Menu("Colour") {
            Button("Grey") { spaces.tint(space.id, hue: nil) }
            ForEach(Array(stride(from: 0.0, to: 1.0, by: 0.125)), id: \.self) { hue in
                Button { spaces.tint(space.id, hue: hue) } label: {
                    Label { Text(String(format: "%.0f°", hue * 360)) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 0.75))
                    }
                }
            }
        }
        Menu("Profile") {
            Button { spaces.profile(space.id, named: nil) } label: {
                Label("Shared", systemImage: space.profile == nil ? "checkmark" : "")
            }
            ForEach(spaces.profiles, id: \.self) { name in
                Button { spaces.profile(space.id, named: name) } label: {
                    Label(name, systemImage: space.profile == name ? "checkmark" : "")
                }
            }
            Divider()
            Button("New Profile…") { draft = ""; profiling = space.id }
        }
        if let tab = browser.active, space.id != spaces.current {
            Button("Move Current Tab Here") { spaces.move(tab, to: space.id, in: browser) }
        }
        if spaces.all.count > 1 {
            Divider()
            Button("Remove Space", role: .destructive) { spaces.remove(space.id, in: browser) }
        }
    }
}

/// Everything Copper adds to the menu bar, in one Commands so upstream's
/// `.commands {}` gains a single line (the builder takes ten at most).
struct ForkCommands: Commands {
    @ObservedObject var browser: Browser
    @ObservedObject var spaces = Spaces.shared
    @ObservedObject var split = Split.shared
    @ObservedObject var agent = Agent.shared

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(split.on ? "Close Split View" : "Split View") { split.toggle(in: browser) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(agent.open ? "Close Agent" : "Agent") { agent.toggle() }
                .keyboardShortcut("e", modifiers: [.command])
            Button("Ask About This Page") { agent.askOnPage(in: browser) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Spaces") {
            Button("New Space") { spaces.add(in: browser) }
                .keyboardShortcut("n", modifiers: [.control])
            Divider()
            Button("Previous Space") { spaces.step(-1, in: browser) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
            Button("Next Space") { spaces.step(1, in: browser) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
            Divider()
            ForEach(Array(spaces.all.prefix(9).enumerated()), id: \.element.id) { i, space in
                Button(space.name) { spaces.select(space.id, in: browser) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.control])
            }
        }
        // The Groups menu lives in GroupsUI.swift; it rides here because
        // App.swift's .commands builder is at its cap of ten.
        GroupCommands(browser: browser)
    }
}

// MARK: - the bench

extension Spaces {
    /// `./bench spaces` lists; `spaces new [NAME]`, `spaces select N|NAME`,
    /// `spaces next`, `spaces prev`, `spaces move N|NAME` (the active tab).
    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        func find(_ key: String) -> UUID? {
            if let n = Int(key), all.indices.contains(n) { return all[n].id }
            return all.first { $0.name.lowercased() == key.lowercased() }?.id
        }
        let arg = request["arg"] as? String ?? ""
        switch request["op"] as? String ?? "" {
        case "new": add(named: arg, in: browser)
        case "next": step(1, in: browser)
        case "prev": step(-1, in: browser)
        case "select": guard let id = find(arg) else { return ["error": "no space \(arg)"] }; select(id, in: browser)
        case "move":
            guard let id = find(arg) else { return ["error": "no space \(arg)"] }
            guard let tab = browser.active else { return ["error": "no active tab"] }
            move(tab, to: id, in: browser)
        case "remove": guard let id = find(arg) else { return ["error": "no space \(arg)"] }; remove(id, in: browser)
        case "profile": profile(current, named: arg)
        default: break
        }
        return ["spaces": all.enumerated().map { i, s in
            ["index": i, "name": s.name, "current": s.id == current, "profile": s.profile ?? "shared",
             "tabs": s.id == current ? browser.tabs.count : (parked[s.id]?.tabs.count ?? 0)] as [String: Any]
        }]
    }
}
