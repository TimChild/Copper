import SwiftUI
import WebKit

// Spaces: several canonical rows of tabs, one projected into each window at
// a time.
//
// A browser keeps working on one array, `tabs` — the row it is looking at.
// Spaces keeps every row and publishes changes to all windows on that space;
// switching swaps only that browser's projection. Nothing that draws or
// walks `tabs` (the column, the strip, ⌘1–9, ⌘W, drag to reorder) needs to
// know where the canonical row lives.

struct Space: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// A hue, 0…1, or nil for the plain grey. The picker offers the named
    /// palette below; a hue from an import or an older build stays as it is.
    var hue: Double?
    /// Which cookie jar its tabs use: nil for the one every space shares, or
    /// a name — spaces with the same name sign in together.
    var profile: String? = nil
    /// What stands for the space in the column: an emoji, or an SF symbol
    /// name behind `sf:`. Nil draws the name's first letter — or the emoji
    /// the name starts with, as Arc's imported spaces nearly all do. New in
    /// this shape; optional so yesterday's session.json still reads, and
    /// unknown to older builds, which ignore it.
    var icon: String? = nil
    /// Its look: a colour, a gradient or a picture (see `SpaceTheme`). Nil
    /// is the hue alone, as every space had before themes; optional so
    /// older session files read.
    var theme: SpaceTheme? = nil

    /// What the column is washed in: the theme, or the hue made into one.
    var look: SpaceTheme { theme ?? hue.map(SpaceTheme.hue) ?? .copper }

    var tint: Color { hue == nil ? Palette.muted : SpaceTint(hue: hue, dark: false).dot }

    /// The SF symbol, when the icon is one.
    var symbol: String? {
        guard let icon, icon.hasPrefix("sf:") else { return nil }
        return String(icon.dropFirst(3))
    }

    /// The emoji the space shows: its own, or the one its name begins with.
    var emoji: String? {
        if let icon, !icon.hasPrefix("sf:"), !icon.isEmpty { return icon }
        guard let first = name.unicodeScalars.first, first.properties.isEmojiPresentation else { return nil }
        return String(Character(first))
    }

    /// The name without the emoji the glyph already shows, so a header does
    /// not read "🏠 🏠 Home".
    var title: String {
        guard icon == nil || icon?.isEmpty == true, let first = name.unicodeScalars.first,
              first.properties.isEmojiPresentation else { return name }
        let rest = name.dropFirst().trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    /// The letter a space with neither emoji nor symbol wears.
    var letter: String { String(title.prefix(1)).uppercased() }
}

/// The colours a space can be, by name. Nine hues and a grey, chosen so no
/// two neighbours read as the same colour at the strength the column washes
/// them in; the menu, the editor and the strip all speak these names rather
/// than degrees.
enum SpaceColour: String, CaseIterable, Identifiable {
    case graphite, copper, orange, yellow, green, teal, blue, indigo, pink, red

    var id: String { rawValue }
    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var hue: Double? {
        switch self {
        case .graphite: return nil
        case .copper: return 0.07
        case .orange: return 0.10
        case .yellow: return 0.14
        case .green: return 0.36
        case .teal: return 0.48
        case .blue: return 0.60
        case .indigo: return 0.70
        case .pink: return 0.90
        case .red: return 0.99
        }
    }

    /// The colour a hue is nearest to — an imported 0.33 is "Green".
    static func nearest(_ hue: Double?) -> SpaceColour {
        guard let hue else { return .graphite }
        return allCases.filter { $0 != .graphite }.min { a, b in distance(a.hue!, hue) < distance(b.hue!, hue) } ?? .graphite
    }

    /// Around the wheel, so 0.99 and 0.02 are neighbours.
    private static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    /// The first real colour no space is wearing; when every one is taken,
    /// the one worn by the fewest. Never grey — grey is a choice, not a default.
    static func unused(among spaces: [Space]) -> SpaceColour {
        let worn = spaces.map { nearest($0.hue) }
        let colours = allCases.filter { $0 != .graphite }
        if let free = colours.first(where: { !worn.contains($0) }) { return free }
        return colours.min { a, b in worn.filter { $0 == a }.count < worn.filter { $0 == b }.count } ?? .copper
    }
}

@MainActor
final class Spaces: ObservableObject {
    static let shared = Spaces()

    @Published private(set) var all: [Space]
    /// The main/front window's space, retained as a compatibility convenience.
    /// Window-aware callers use `current(in:)` so two windows can differ.
    @Published private(set) var current: UUID

    /// Canonical tab rows. A browser's `tabs` is only a projection of one row;
    /// the Tab objects (and their single WKWebViews) live here exactly once.
    private(set) var rows: [UUID: [Tab]] = [:]
    private var currentByBrowser: [ObjectIdentifier: UUID] = [:]
    private var activeByBrowserSpace: [ObjectIdentifier: [UUID: Tab.ID]] = [:]
    private var updating = 0
    private weak var mainBrowser: Browser?
    private var browserRefs: [ObjectIdentifier: WeakBrowser] = [:]
    private final class WeakBrowser { weak var value: Browser?; init(_ value: Browser) { self.value = value } }

    private var browsers: [Browser] { browserRefs.values.compactMap(\.value) }

    var parkedTabs: [Tab] { rows.filter { $0.key != current }.flatMap(\.value) }
    func parkedRow(_ id: UUID) -> [Tab]? { rows[id] }
    func row(_ id: UUID) -> [Tab] { rows[id] ?? [] }
    func current(in browser: Browser) -> UUID { currentByBrowser[ObjectIdentifier(browser)] ?? current }
    func space(in browser: Browser) -> Space { all.first { $0.id == current(in: browser) } ?? all[0] }
    func spaceID(of tab: Tab) -> UUID? { rows.first { $0.value.contains { $0.id == tab.id } }?.key }

    private init() {
        let home = Space(name: "Home")
        all = [home]
        current = home.id
        rows[home.id] = []
    }

    var space: Space { all.first { $0.id == current } ?? all[0] }

    /// Register a window and hand it the row for its current space.
    @discardableResult
    func register(_ browser: Browser, at requested: UUID? = nil) -> UUID {
        let id = requested.flatMap { candidate in all.contains(where: { $0.id == candidate }) ? candidate : nil } ?? current
        let chosen = all.contains(where: { $0.id == id }) ? id : all[0].id
        currentByBrowser[ObjectIdentifier(browser)] = chosen
        activeByBrowserSpace[ObjectIdentifier(browser)] = activeByBrowserSpace[ObjectIdentifier(browser)] ?? [:]
        browserRefs[ObjectIdentifier(browser)] = WeakBrowser(browser)
        if mainBrowser == nil || browser.primary { mainBrowser = browser; current = chosen }
        rows[chosen, default: []] = rows[chosen] ?? []
        return chosen
    }

    func unregister(_ browser: Browser) {
        currentByBrowser.removeValue(forKey: ObjectIdentifier(browser))
        activeByBrowserSpace.removeValue(forKey: ObjectIdentifier(browser))
        browserRefs.removeValue(forKey: ObjectIdentifier(browser))
    }

    func dropBlank(_ tab: Tab) {
        guard let id = spaceID(of: tab) else { return }
        rows[id]?.removeAll { $0.id == tab.id }
        publish(id)
    }

    func frontChanged(_ browser: Browser) {
        guard currentByBrowser[ObjectIdentifier(browser)] != nil else { return }
        current = current(in: browser)
        objectWillChange.send()
    }

    func activeChanged(_ browser: Browser) {
        guard let space = currentByBrowser[ObjectIdentifier(browser)] else { return }
        if let active = browser.activeID {
            activeByBrowserSpace[ObjectIdentifier(browser), default: [:]][space] = active
        } else {
            activeByBrowserSpace[ObjectIdentifier(browser)]?.removeValue(forKey: space)
        }
        if !browser.primary { Windows.keep(browser) }
    }

    /// Called by Browser.tabs' didSet. The guard prevents publishing a row
    /// back into the browser that originated the change.
    func tabsChanged(_ browser: Browser) {
        guard updating == 0, let id = currentByBrowser[ObjectIdentifier(browser)] else { return }
        rows[id] = browser.tabs
        objectWillChange.send()
        publish(id, except: browser)
        Session.write(now: false, shape(visible: browser.tabs, active: browser.activeID))
        if !browser.primary { Windows.keep(browser) }
    }

    private func publish(_ id: UUID, except source: Browser? = nil) {
        let row = rows[id] ?? []
        updating += 1
        defer { updating -= 1 }
        for browser in browsers where browser !== source && current(in: browser) == id {
            if !row.contains(where: { $0.id == browser.activeID }) {
                browser.activeID = row.first?.id
            }
            browser.tabs = row
        }
    }

    private func setProjection(_ tabs: [Tab], in browser: Browser) {
        updating += 1
        browser.tabs = tabs
        updating -= 1
    }

    /// A tab may have only one visible StageView. When another window selects
    /// it, the old window falls back to its most recent other tab in that row.
    func claim(_ tab: Tab, for browser: Browser) {
        for other in browsers where other !== browser && other.activeID == tab.id {
            let fallback = other.tabs.filter { $0.id != tab.id }.max { $0.touched < $1.touched }
            other.activeID = fallback?.id
        }
    }

    // MARK: - keeping

    /// The browser the rows belong to, from the restore at launch — so an
    /// edit to a space (a name, a colour, an icon, the order) reaches the
    /// session file without a tab having to change first. The browser's own
    /// writer runs on tab changes and is unchanged.
    private weak var browser: Browser?
    private var keeping: DispatchWorkItem?

    /// Write the session soon. A rename arrives a keystroke at a time, so
    /// this waits for the typing to stop.
    private func keep() {
        keeping?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let browser else { return }
            Session.write(now: false, shape(visible: browser.tabs, active: browser.activeID))
        }
        keeping = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: - switching

    func select(_ id: UUID, in browser: Browser) {
        guard id != current(in: browser), let to = all.firstIndex(where: { $0.id == id }) else { return }
        let from = all.firstIndex { $0.id == current(in: browser) } ?? to
        // The column on screen is pictured before anything changes, and the
        // new row goes in with animations off: the slide is the one motion,
        // not every old row leaving and every new one arriving (SpaceSlide).
        // With no column on screen — the tab bar, a folded sidebar — the
        // switch is what it always was.
        guard SpaceSlide.shared.begin(forward: to > from, in: browser) else { return swap(to: id, in: browser) }
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) { swap(to: id, in: browser) }
    }

    private func swap(to id: UUID, in browser: Browser) {
        let key = ObjectIdentifier(browser)
        let old = current(in: browser)
        rows[old] = browser.tabs
        if let active = browser.activeID { activeByBrowserSpace[key, default: [:]][old] = active }
        currentByBrowser[key] = id
        if browser.primary { current = id }
        let next = rows[id] ?? []
        setProjection(next, in: browser)
        if next.isEmpty {
            browser.newTab()
        } else {
            let remembered = activeByBrowserSpace[key]?[id]
            guard let active = next.first(where: { $0.id == remembered }) ?? next.first else { return }
            browser.activeID = nil
            browser.select(active)
        }
        Recent.shared.rebuild(from: browser.tabs)
        Sections.shared.sweep(in: browser)
        Windows.keep(browser)
        Session.write(now: false, shape(visible: browser.tabs, active: browser.activeID))
    }

    func step(_ by: Int, in browser: Browser) {
        guard let here = all.firstIndex(where: { $0.id == current(in: browser) }) else { return }
        select(all[(here + by + all.count) % all.count].id, in: browser)
    }

    func select(index: Int, in browser: Browser) {
        guard all.indices.contains(index) else { return }
        select(all[index].id, in: browser)
    }

    // MARK: - editing

    /// A new space, in a colour no other space is wearing, made current.
    @discardableResult
    func add(named name: String = "", in browser: Browser) -> UUID {
        let space = Space(name: name.isEmpty ? "Space \(all.count + 1)" : name, hue: SpaceColour.unused(among: all).hue)
        all.append(space)
        rows[space.id] = []
        select(space.id, in: browser)
        objectWillChange.send()
        return space.id
    }

    func icon(_ id: UUID, _ icon: String?) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].icon = icon?.isEmpty == true ? nil : icon
        keep()
    }

    /// Reorder: the space to another place in the row of spaces.
    func move(_ id: UUID, to index: Int) {
        guard let from = all.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, index), all.count - 1)
        guard from != to else { return }
        let space = all.remove(at: from)
        all.insert(space, at: to)
        keep()
    }

    /// One place left or right; the ends stay put.
    func nudge(_ id: UUID, by: Int) {
        guard let from = all.firstIndex(where: { $0.id == id }) else { return }
        move(id, to: from + by)
    }

    /// How many tabs a space holds, on screen or parked.
    func count(of id: UUID, in browser: Browser) -> Int {
        rows[id]?.count ?? 0
    }

    /// The space a deleted one's tabs would go to: its neighbour to the
    /// left, or to the right for the first.
    func neighbour(of id: UUID) -> Space? {
        guard all.count > 1, let i = all.firstIndex(where: { $0.id == id }) else { return nil }
        return all[i == 0 ? 1 : i - 1]
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = all.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        all[i].name = name
        keep()
    }

    /// A named colour: the hue alone, and any theme it had goes.
    func tint(_ id: UUID, hue: Double?) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].hue = hue
        // Graphite is a choice of its own, grey; no colour at all is the
        // copper default, which only a space never given one wears.
        all[i].theme = hue == nil ? .plain : nil
        keep()
    }

    /// A theme of its own — colour, gradient or picture. The hue follows it,
    /// so the dot, the picker and the split's outline stay in step.
    func theme(_ id: UUID, _ theme: SpaceTheme?) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].theme = theme
        if let hue = theme?.hue { all[i].hue = hue }
        keep()
    }

    /// Its tabs close for good — or, given another space, move to the end of
    /// that space's row instead. The last space cannot be removed.
    func remove(_ id: UUID, in browser: Browser, movingTabsTo destination: UUID? = nil) {
        guard all.count > 1, let i = all.firstIndex(where: { $0.id == id }) else { return }
        let row = rows.removeValue(forKey: id) ?? []
        if let destination, destination != id, all.contains(where: { $0.id == destination }) {
            rows[destination, default: []].append(contentsOf: row)
            publish(destination)
        } else {
            row.forEach { $0.close() }
        }
        all.remove(at: i)
        let affected = Windows.all.filter { current(in: $0) == id }
        for other in affected {
            let neighbor = all[min(i, all.count - 1)].id
            currentByBrowser[ObjectIdentifier(other)] = neighbor
            if other.primary { current = neighbor }
            setProjection(rows[neighbor] ?? [], in: other)
            if other.tabs.isEmpty { other.newTab() }
            else { other.activeID = other.tabs.first?.id }
        }
        keep()
    }

    /// Move a tab to another canonical row. All windows currently viewing
    /// either row receive the same projection.
    func move(_ tab: Tab, to id: UUID, in browser: Browser) {
        guard let from = spaceID(of: tab), id != from, all.contains(where: { $0.id == id }) else { return }
        rows[from]?.removeAll { $0.id == tab.id }
        rows[id, default: []].append(tab)
        publish(from)
        publish(id)
        if browser.activeID == tab.id {
            if browser.tabs.isEmpty { browser.newTab() }
            else if let first = browser.tabs.first { browser.activeID = first.id }
        }
        Session.write(now: false, shape(visible: browser.tabs, active: browser.activeID))
    }

    // MARK: - Flow import

    /// Append imported spaces without replacing the space on screen. Every
    /// restored tab stays asleep until the person visits its new space.
    func adopt(_ imported: [FlowModel.Space], in browser: Browser) -> (spaces: [UUID], tabs: Int, groups: Int) {
        adopt(imported, in: browser, sourceName: "Chrome", sourceIsArc: false)
    }

    func adopt(_ imported: [FlowModel.Space], in browser: Browser, sourceName: String, sourceIsArc: Bool) -> (spaces: [UUID], tabs: Int, groups: Int) {
        guard !imported.isEmpty else { return ([], 0, 0) }
        SessionGuard.beginRestore()
        defer { SessionGuard.finishRestore() }
        var made: [UUID] = []
        var tabCount = 0
        var groupCount = 0
        var names = Set(all.map { $0.name.lowercased() })
        for incoming in imported {
            var name = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = sourceName }
            let original = name
            if names.contains(name.lowercased()) {
                let suffix = " (\(sourceIsArc ? "Arc" : "Chrome"))"
                name = original + suffix
                var n = 2
                while names.contains(name.lowercased()) {
                    name = "\(original)\(suffix) \(n)"
                    n += 1
                }
            }
            names.insert(name.lowercased())
            var space = Space(name: name, hue: incoming.theme?.hue ?? incoming.hue, profile: incoming.profile)
            space.theme = incoming.theme
            space.icon = incoming.icon
            all.append(space)
            made.append(space.id)

            var groups: [UUID: TabGroup] = [:]
            for incomingGroup in incoming.groups {
                // Always a folder of its own, under its own name: the nesting
                // lives in the names and the tree is read per space, so two
                // spaces' `Misc` stay apart without a suffix — and a suffix
                // on `Misc` would cut `Misc › BuildrFi` loose from it.
                let group = Groups.shared.adding(named: incomingGroup.name, hue: incomingGroup.hue)
                Groups.shared.imported(group.id, collapsed: incomingGroup.collapsed,
                                       space: incomingGroup.slot == nil ? nil : space.id, slot: incomingGroup.slot)
                groups[incomingGroup.id] = group
                groupCount += 1
            }
            var tabs: [Tab] = []
            var splits: [UUID: [Tab.ID]] = [:]
            for incomingTab in incoming.tabs {
                let tab = building(for: space.id) { Tab() }
                browser.prepare(tab)
                tab.restore(url: incomingTab.url, title: incomingTab.title)
                tab.pin = incomingTab.pinned ? (tab.monogram.isEmpty ? "•" : tab.monogram) : nil
                Sections.shared.restore(tab, saved: incomingTab.saved || incomingTab.pinned, seen: incomingTab.seen)
                if let groupID = incomingTab.group, let group = groups[groupID] {
                    Groups.shared.restore(tab, group: group.id)
                }
                if let token = incomingTab.split { splits[token, default: []].append(tab.id) }
                tabs.append(tab)
                tabCount += 1
            }
            Split.shared.keep(splits)
            rows[space.id] = tabs
        }
        objectWillChange.send()
        return (made, tabCount, groupCount)
    }

    /// Fold tabs written by the pre-shared-spaces windows.json format into
    /// the space this window is opening on. The entries are appended exactly
    /// as written; migration deliberately does not deduplicate anything.
    func foldLegacy(_ entries: [Session.Entry], active index: Int?, into browser: Browser, space id: UUID) {
        guard all.contains(where: { $0.id == id }) else { return }
        var row = rows[id] ?? []
        for entry in entries {
            guard let url = URL(string: entry.url) else { continue }
            let tab = building(for: id) { Tab() }
            browser.prepare(tab)
            tab.restore(url: url, title: entry.title)
            tab.pin = entry.pin
            row.append(tab)
        }
        rows[id] = row
        publish(id)
        if let index, row.indices.contains(index), current(in: browser) == id {
            browser.activeID = row[index].id
        }
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
        keep()
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
            return store(forProfile: name)
        }
    }

    /// A profile's jar by name, whether or not a space wears it yet (the
    /// storage import fills one ahead of time).
    nonisolated static func store(forProfile name: String) -> WKWebsiteDataStore {
        // A fixed id per name, so the jar is the same one next launch.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let text = String(format: "C0FFEE00-%04X-4000-8000-%012llX", UInt16(truncatingIfNeeded: hash >> 48), hash & 0xFFFF_FFFF_FFFF)
        return WKWebsiteDataStore(forIdentifier: UUID(uuidString: text)!)
    }

    // MARK: - session

    /// Every canonical row, in one shape upstream can still read: a flat list
    /// of tabs and the main window's active index.
    func shape(visible: [Tab], active: Tab.ID?) -> Session.Shape {
        var entries: [Session.Entry] = []
        var activeIndex = 0
        let alive = Set(rows.values.flatMap { $0 }.map(\.id))
        let main = mainBrowser ?? Windows.main
        let mainSpace = current(in: main)
        let mainActive = main.activeID
        func put(_ tabs: [Tab], _ id: UUID, _ activeID: Tab.ID?, visible: Bool) {
            for tab in tabs {
                guard var entry = Session.Entry(tab) else { continue }
                entry.space = id
                entry.group = Groups.shared.membership[tab.id]
                entry.saved = tab.pin == nil ? Sections.shared.isSaved(tab) : nil
                entry.seen = Sections.shared.lastSeen(tab).timeIntervalSince1970
                entry.active = tab.id == activeID ? true : nil
                entry.split = Split.shared.token(for: tab.id, alive: alive)
                if visible, entry.active == true { activeIndex = entries.count }
                entries.append(entry)
            }
        }
        for space in all {
            let row = rows[space.id] ?? []
            put(row, space.id, space.id == mainSpace ? mainActive : nil, visible: space.id == mainSpace)
        }
        return .init(tabs: entries, active: activeIndex, spaces: all, space: mainSpace)
    }

    /// Yesterday's rows become canonical rows. The main browser receives the
    /// projection for its own current space; other windows attach later.
    func restore(_ saved: Session.Shape, into browser: Browser) {
        self.browser = browser
        SessionGuard.beginRestore()
        defer { SessionGuard.finishRestore() }
        if let spaces = saved.spaces, !spaces.isEmpty {
            all = spaces
            rows = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, []) })
            current = saved.space.flatMap { c in spaces.first { $0.id == c }?.id } ?? spaces[0].id
        }
        _ = register(browser, at: current)
        var restored: [UUID: (tabs: [Tab], active: Tab.ID?)] = [:]
        var splits: [UUID: [Tab.ID]] = [:]
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
            if let token = entry.split { splits[token, default: []].append(tab.id) }
            var row = restored[id] ?? ([], nil)
            row.tabs.append(tab)
            // Upstream's file has no `active` flag — its `active` index does.
            if entry.active == true || (entry.space == nil && i == saved.active) { row.active = tab.id }
            restored[id] = row
        }
        for space in all { rows[space.id] = restored[space.id]?.tabs ?? [] }
        Split.shared.restore(splits)
        let mine = restored[current] ?? ([], nil)
        setProjection(mine.tabs, in: browser)
        Recent.shared.rebuild(from: browser.tabs)
        Sections.shared.begin(in: browser) // Fork: the archive sweep, at launch and every half hour
        guard let first = mine.tabs.first else { return }
        let active = mine.tabs.first { $0.id == mine.active } ?? first
        browser.activeID = active.id
        Recent.shared.rebuild(from: browser.tabs)
        Sections.shared.note(active.id)
        _ = active.wake()
        Split.shared.resume(in: browser)
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

/// Everything Copper adds to the menu bar, in one Commands so upstream's
/// `.commands {}` gains a single line (the builder takes ten at most).
struct ForkCommands: Commands {
    @ObservedObject var browser: Browser
    @ObservedObject var spaces = Spaces.shared
    @ObservedObject var split = Split.shared
    @ObservedObject var agent = Agent.shared
    @ObservedObject var trace = Drive.shared

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Move in from Another Browser…") { Flow.shared.open = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button(split.on ? "Close Split View" : "Split View") { split.toggle(in: browser) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(agent.open ? "Close Agent" : "Agent") { agent.toggle() }
                .keyboardShortcut("e", modifiers: [.command])
            Button("Ask About This Page") { agent.askOnPage(in: browser) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            // Jev's timeline had no way back once closed; and with two or
            // three panes open there was no one move that put them all away.
            Button(trace.paneOpen ? "Close Driver Timeline" : "Driver Timeline") { trace.paneOpen.toggle() }
                .keyboardShortcut("j", modifiers: [.command, .option])
            // Never disabled: a menu item's enabled state is decided when the
            // menu is built, and ⌘⌥E pressed with two panes open did nothing
            // because the item still remembered a window with none. Closing
            // nothing is harmless.
            Button("Close All Panes") { Panes.closeAll(in: browser) }
                .keyboardShortcut("e", modifiers: [.command, .option])
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
    /// `spaces next`, `spaces prev`, `spaces move N|NAME` (the active tab),
    /// `spaces icon N|NAME EMOJI|sf:symbol|none`, `spaces colour N|NAME
    /// Teal|…|graphite`, `spaces reorder N|NAME M`, `spaces remove N|NAME
    /// [--keep]` (the tabs go to the neighbour instead of closing),
    /// `spaces page [N|NAME|close]` (the Space page; `edit` is the old name
    /// for it), `spaces tap N|NAME` (a click on that chip at the foot, by the
    /// chip's own door: another space switches, the current one opens its
    /// page) and `spaces tap header` (the title row's icon), `spaces delete
    /// N|NAME` (the sheet) and `spaces answer close|move|cancel` (its
    /// buttons), `spaces profile NAME`, `spaces theme N|NAME colors|intensity|
    /// grain|image|blur|tone|motion|speed|clear …` (see `benchTheme`),
    /// `spaces slide [at X|off]` (the last switch's timings; hold the next
    /// slides at X for a picture — see `SpaceSlide.bench`).
    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        func find(_ key: String) -> UUID? {
            if let n = Int(key), all.indices.contains(n) { return all[n].id }
            return all.first { $0.name.lowercased() == key.lowercased() }?.id
        }
        let arg = request["arg"] as? String ?? ""
        let words = arg.split(separator: " ").map(String.init)
        // `icon Side Project sf:hammer`: the last word is the value, the rest
        // the space's name (or index).
        let value = words.last ?? ""
        let key = words.dropLast().joined(separator: " ")
        switch request["op"] as? String ?? "" {
        case "new": add(named: arg, in: browser)
        case "next": step(1, in: browser)
        case "prev": step(-1, in: browser)
        case "select": guard let id = find(arg) else { return ["error": "no space \(arg)"] }; select(id, in: browser)
        case "move":
            guard let id = find(arg) else { return ["error": "no space \(arg)"] }
            guard let tab = browser.active else { return ["error": "no active tab"] }
            move(tab, to: id, in: browser)
        case "remove":
            let keep = words.contains("--keep")
            guard let key = words.first(where: { $0 != "--keep" }), let id = find(key) else { return ["error": "no space \(arg)"] }
            remove(id, in: browser, movingTabsTo: keep ? neighbour(of: id)?.id : nil)
        case "icon":
            guard words.count >= 2, let id = find(key) else { return ["error": "spaces icon N|NAME EMOJI|sf:symbol|none"] }
            icon(id, value == "none" ? nil : value)
        case "colour", "color":
            guard words.count >= 2, let id = find(key) else { return ["error": "spaces colour N|NAME \(SpaceColour.allCases.map(\.name).joined(separator: "|"))"] }
            guard let colour = SpaceColour(rawValue: value.lowercased()) ?? (value.lowercased() == "none" ? .graphite : nil) else {
                return ["error": "no colour \(value)"]
            }
            tint(id, hue: colour.hue)
        case "reorder":
            guard words.count >= 2, let id = find(key), let to = Int(value) else { return ["error": "spaces reorder N|NAME M"] }
            move(id, to: to)
        case "edit", "page":
            if arg == "close" { SpaceEditing.shared.close(); return ["page": ""] }
            let id = words.isEmpty ? current : (find(arg) ?? UUID())
            guard all.contains(where: { $0.id == id }) else { return ["error": "no space \(arg)"] }
            SpaceEditing.shared.open(id)
            return ["page": all.first { $0.id == id }?.name ?? ""]
        case "tap":
            if arg == "header" {
                SpaceEditing.shared.open(current)
            } else {
                guard let id = find(arg) else { return ["error": "spaces tap N|NAME|header"] }
                SpaceEditing.shared.pressed(id, in: browser)
            }
            return ["page": SpaceEditing.shared.space.flatMap { id in all.first { $0.id == id }?.name } ?? "",
                    "current": all.first { $0.id == current }?.name ?? ""]
        case "delete":
            // The sheet, as Delete Space… shows it; `answer` presses a button.
            guard let id = find(arg) else { return ["error": "no space \(arg)"] }
            SpaceDelete.ask(id, in: browser)
            return ["sheet": SpaceDelete.describe]
        case "answer":
            guard SpaceDelete.answer(arg) else { return ["error": "no sheet up, or no \(arg) button on it"] }
            return ["answered": arg, "did": SpaceDelete.last]
        case "slide": return ["slide": SpaceSlide.shared.bench(arg)]
        case "profile": profile(current, named: arg)
        case "theme":
            if let error = benchTheme(words, find: find) { return ["error": error] }
        case "picture":
            // `picture N PATH [light|dark]`: the Space page as a PNG, drawn
            // off screen and laid out whole, not scrolled.
            var rest = words
            let look = ["light", "dark"].contains(rest.last ?? "") ? rest.removeLast() : nil
            guard rest.count >= 2, let id = find(rest.dropLast().joined(separator: " ")) else { return ["error": "spaces picture N|NAME PATH [light|dark]"] }
            let value = rest.last ?? ""
            guard let png = SpaceEditing.picture(of: id, in: browser, dark: look.map { $0 == "dark" })?
                .representation(using: .png, properties: [:]) else {
                return ["error": "no picture"]
            }
            do { try png.write(to: URL(fileURLWithPath: value)) } catch { return ["error": "\(error)"] }
            return ["path": value]
        default: break
        }
        return ["spaces": all.enumerated().map { i, s in
            ["index": i, "name": s.name, "current": s.id == current, "profile": s.profile ?? "shared",
             "tabs": count(of: s.id, in: browser), "hue": s.hue ?? -1, "colour": SpaceColour.nearest(s.hue).name,
             "icon": s.icon ?? "", "theme": s.theme.map(Spaces.describe) ?? "hue"] as [String: Any]
        }]
    }

    /// A theme in one line, for the bench's list.
    private static func describe(_ theme: SpaceTheme) -> String {
        var line = theme.colors.map(\.hex).joined(separator: ",")
            + String(format: " intensity %.2f grain %.2f", theme.intensity, theme.grain)
        if let image = theme.image { line += " image \(image)" }
        if let motion = theme.motion { line += String(format: " motion %@ speed %.2f", motion.style, motion.speed) }
        if theme.blur > 0 { line += String(format: " blur %.2f", theme.blur) }
        if theme.tone != 0 { line += String(format: " tone %+.2f", theme.tone) }
        return line
    }

    /// `spaces theme N|NAME colors #hex[,#hex,#hex] | intensity X | grain X
    /// | image PATH|none | blur X | tone X | motion STYLE|none | speed X |
    /// clear`: what the Space page does, by the same
    /// doors — `theme(_:_:)` for every change, `SpaceTheme.adopt` for a
    /// picture — so a picture can be tried without an open panel. A space
    /// on a plain hue starts from that hue's theme, as the editor does.
    /// Nil when it worked, or what was wrong.
    private func benchTheme(_ words: [String], find: (String) -> UUID?) -> String? {
        let usage = "spaces theme N|NAME colors #hex[,#hex..]|intensity X|grain X|image PATH|none|blur X|tone X|motion STYLE|none|speed X|clear"
        let verbs: Set = ["colors", "colours", "intensity", "grain", "image", "blur", "tone", "motion", "speed", "clear"]
        guard let at = words.firstIndex(where: { verbs.contains($0) }), at > 0,
              let id = find(words[..<at].joined(separator: " ")),
              let space = all.first(where: { $0.id == id }) else { return usage }
        // The value is the rest of the line, spaces and all — a path in
        // Desktop Pictures has them.
        let value = words[(at + 1)...].joined(separator: " ")
        var look = space.look
        switch words[at] {
        case "clear":
            theme(id, nil)
            return nil
        case "colors", "colours":
            let stops = value.split(separator: ",").compactMap { SpaceTheme.Stop(hex: String($0)) }
            guard (1...3).contains(stops.count) else { return "one to three colours, as #rrggbb,#rrggbb" }
            look.colors = stops
        case "intensity", "grain":
            guard let x = Double(value) else { return usage }
            if words[at] == "intensity" { look.intensity = min(1, max(0.2, x)) } else { look.grain = min(1, max(0, x)) }
        case "blur":
            guard let x = Double(value) else { return usage }
            look.blur = min(1, max(0, x))
        case "tone":
            guard let x = Double(value) else { return usage }
            look.tone = min(1, max(-1, x))
        case "motion":
            if value == "none" {
                look.motion = nil
            } else {
                guard AnimatedBackdrop.styles.contains(where: { $0.id == value }) else {
                    return "no scene \(value); one of \(AnimatedBackdrop.styles.map(\.id).joined(separator: "|"))|none"
                }
                look.motion = SpaceTheme.Motion(style: value, speed: look.motion?.speed ?? 1)
            }
        case "speed":
            guard let x = Double(value) else { return usage }
            guard look.motion != nil else { return "no scene to speed up — spaces theme N motion STYLE first" }
            look.motion?.speed = min(2, max(0, x))
        default:
            if value == "none" {
                look.image = nil
            } else {
                let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else { return "no file at \(url.path)" }
                guard let name = SpaceTheme.adopt(image: url) else { return "could not copy \(url.path) in" }
                look.image = name
            }
        }
        theme(id, look)
        return nil
    }
}
