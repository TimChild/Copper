import SwiftUI

// Tab groups: a name and a colour over a run of tabs in the column.
//
// The row stays one flat array. A group is a label some tabs carry, kept
// here by tab id rather than on the Tab, so upstream's Tab never learns the
// word. Members are kept next to each other in the row — joining a group
// moves the tab to the end of that group's run — and the column draws one
// header wherever a run starts. Which tab is in which group travels in the
// session as one optional field on each entry (see Spaces.shape/restore).

struct TabGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// A hue, 0…1, or nil for the plain grey — the same wheel as a Space.
    var hue: Double?
    var collapsed = false

    var tint: Color { hue.map { Color(hue: $0, saturation: 0.55, brightness: 0.75) } ?? Palette.muted }
}

/// A site that always lands in a group, before any model is asked.
/// `pattern` is a host — `github.com` — or a glob over one — `*.atlassian.net`
/// — or, with a slash in it, a prefix of the address.
struct GroupRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var pattern: String
    var group: String

    func matches(_ url: URL) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !pattern.isEmpty else { return false }
        if pattern.contains("/") {
            return url.absoluteString.lowercased().hasPrefix(pattern) || url.absoluteString.lowercased().contains(pattern)
        }
        guard let host = url.host()?.lowercased() else { return false }
        if pattern.hasPrefix("*.") {
            let bare = String(pattern.dropFirst(2))
            return host == bare || host.hasSuffix("." + bare)
        }
        return host == pattern || host.hasSuffix("." + pattern)
    }
}

@MainActor
final class Groups: ObservableObject {
    static let shared = Groups()

    @Published private(set) var all: [TabGroup] = []
    @Published var rules: [GroupRule] = [] { didSet { save() } }
    /// Which group each tab is in. Tabs that have gone are pruned as the
    /// column redraws; nothing else has to remember to tell us.
    @Published private(set) var membership: [Tab.ID: UUID] = [:]

    private struct File: Codable {
        var groups: [TabGroup]
        var rules: [GroupRule]
    }

    private static var file: URL { Store.file("groups.json") }

    private init() {
        if let data = try? Data(contentsOf: Groups.file),
           let saved = try? JSONDecoder().decode(File.self, from: data) {
            all = saved.groups
            rules = saved.rules
        }
    }

    private func save() {
        let file = Groups.file
        guard let data = try? JSONEncoder().encode(File(groups: all, rules: rules)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - reading

    func group(_ id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    func group(of tab: Tab) -> TabGroup? { group(membership[tab.id]) }

    func group(named name: String) -> TabGroup? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.name.lowercased() == wanted }
    }

    /// A folder by whichever half of its name you have: the whole path
    /// (`Misc › BuildrFi`) or, when only one folder answers to it, the last
    /// part on its own (`BuildrFi`).
    func group(matching name: String) -> TabGroup? {
        if let exact = group(named: name) { return exact }
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let leaves = all.filter { Folders.leaf($0.name).lowercased() == wanted }
        return leaves.count == 1 ? leaves[0] : nil
    }

    /// The tabs in a group, in row order, across the visible row and the
    /// parked spaces.
    func members(of id: UUID, in browser: Browser) -> [Tab] {
        (browser.tabs + Spaces.shared.parkedTabs).filter { membership[$0.id] == id }
    }

    /// The groups with at least one tab in this row, in the order their
    /// first tab appears.
    func present(in tabs: [Tab]) -> [TabGroup] {
        var seen: Set<UUID> = []
        var out: [TabGroup] = []
        for tab in tabs {
            guard let id = membership[tab.id], !seen.contains(id), let group = group(id) else { continue }
            seen.insert(id)
            out.append(group)
        }
        return out
    }

    // MARK: - editing

    @discardableResult
    func create(named name: String, hue: Double? = nil) -> TabGroup {
        if let existing = group(named: name) { return existing }
        let clean = name.trimmingCharacters(in: .whitespaces)
        let group = TabGroup(name: clean.isEmpty ? "Group \(all.count + 1)" : clean, hue: hue ?? Double(all.count % 8) / 8)
        all.append(group)
        save()
        return group
    }

    /// Into the group, and next to the rest of it: the tab moves to the end
    /// of the group's run in its row, so the header covers all of them. A
    /// pinned tab keeps its place in the pin block and is only labelled.
    func assign(_ tab: Tab, to group: TabGroup, in browser: Browser) {
        guard all.contains(where: { $0.id == group.id }) else { return }
        membership[tab.id] = group.id
        if let i = all.firstIndex(where: { $0.id == group.id }), all[i].collapsed { all[i].collapsed = false; save() }
        guard tab.pin == nil, let here = browser.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // The last member that isn't this tab, in this row.
        let others = browser.tabs.enumerated().filter { $0.element.id != tab.id && membership[$0.element.id] == group.id && $0.element.pin == nil }
        guard let last = others.last?.offset else { return }
        let target = last < here ? last + 1 : last
        if target != here { browser.move(tab, to: target) }
    }

    func remove(_ tab: Tab) {
        membership[tab.id] = nil
    }

    /// Renaming a folder renames the folders inside it, since the nesting
    /// lives in the names: `Misc` → `Odds` takes `Misc › lula` with it. Not
    /// when two folders share the name, though — then there is no telling
    /// whose children they are, and only the one folder is renamed.
    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let i = all.firstIndex(where: { $0.id == id }) else { return }
        let was = all[i].name
        all[i].name = clean
        if all.filter({ $0.name == was }).isEmpty {
            for j in all.indices where Folders.below(all[j].name, was) {
                all[j].name = clean + Folders.mark + String(all[j].name.dropFirst(was.count + Folders.mark.count))
            }
        }
        save()
    }

    /// A folder inside another one, which is only a name: `<parent> › <name>`.
    /// It takes the parent's colour and the parent opens to show it.
    @discardableResult
    func createInside(_ parent: TabGroup, named name: String) -> TabGroup? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        let made = create(named: Folders.inside(parent, named: clean), hue: parent.hue)
        // A folder inside a plain one is plain too: both wear the space's
        // colour, and `create` would otherwise deal it one off the wheel.
        if parent.hue == nil { tint(made.id, hue: nil) }
        if let i = all.firstIndex(where: { $0.id == parent.id }), all[i].collapsed {
            all[i].collapsed = false
            save()
        }
        return group(made.id) ?? made
    }

    func tint(_ id: UUID, hue: Double?) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].hue = hue
        save()
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].collapsed.toggle()
        save()
    }

    /// The label goes; the tabs stay where they are.
    func dissolve(_ id: UUID) {
        membership = membership.filter { $0.value != id }
        all.removeAll { $0.id == id }
        save()
    }

    /// Every tab in it closes, and then the group.
    func closeAll(_ id: UUID, in browser: Browser) {
        for tab in members(of: id, in: browser) where browser.tabs.contains(where: { $0.id == tab.id }) {
            browser.close(tab)
        }
        dissolve(id)
    }

    /// After a drag: between two tabs of one group means in it; out on your
    /// own means out of it.
    func settle(_ tab: Tab, in browser: Browser) {
        let loose = browser.tabs.filter { $0.pin == nil }
        guard let here = loose.firstIndex(where: { $0.id == tab.id }) else { return }
        let before = here > 0 ? membership[loose[here - 1].id] : nil
        let after = here + 1 < loose.count ? membership[loose[here + 1].id] : nil
        let mine = membership[tab.id]
        if let before, before == after, before != mine {
            membership[tab.id] = before
        } else if let mine, before != mine, after != mine {
            membership[tab.id] = nil
        }
    }

    /// Restoring a session: the entry said which group; the group has to
    /// still exist to count.
    func restore(_ tab: Tab, group id: UUID?) {
        guard let id, all.contains(where: { $0.id == id }) else { return }
        membership[tab.id] = id
    }

    /// Tabs that no longer exist anywhere drop out of the map.
    func prune(keeping tabs: [Tab]) {
        let alive = Set(tabs.map(\.id))
        let stale = membership.keys.filter { !alive.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { membership[id] = nil }
    }

    // MARK: - the bench

    /// `./bench groups` lists; `groups new NAME`; `groups assign TAB NAME`;
    /// `groups remove TAB`; `groups suggest TAB`; `groups dissolve NAME`;
    /// `groups toggle NAME` folds or opens a folder; `groups inside PARENT
    /// NAME` makes one inside another.
    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let arg = request["arg"] as? String ?? ""
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        func tab(_ key: String) -> Tab? { browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) } }
        switch request["op"] as? String ?? "" {
        case "new": create(named: arg)
        case "assign":
            guard words.count == 2, let t = tab(words[0]) else { return ["error": "assign TAB NAME"] }
            assign(t, to: create(named: words[1]), in: browser)
        case "remove":
            guard let t = tab(arg) else { return ["error": "no tab \(arg)"] }
            remove(t)
        case "suggest":
            guard let t = tab(arg) else { return ["error": "no tab \(arg)"] }
            Grouper.shared.suggest(for: t, in: browser, forced: true)
        case "dissolve":
            guard let g = group(matching: arg) else { return ["error": "no group \(arg)"] }
            dissolve(g.id)
        case "toggle":
            // `groups toggle Misc` shuts or opens a folder, by its whole
            // name or by its last part when that is unambiguous.
            guard let g = group(matching: arg) else { return ["error": "no folder \(arg)"] }
            toggleCollapsed(g.id)
        case "inside":
            guard words.count == 2, let parent = group(matching: words[0]) else { return ["error": "inside PARENT NAME"] }
            createInside(parent, named: words[1])
        default: break
        }
        let rows: [[String: Any]] = all.map { g in
            ["id": String(g.id.uuidString.prefix(8)).lowercased(), "name": g.name,
             "label": Folders.leaf(g.name), "collapsed": g.collapsed,
             "tabs": members(of: g.id, in: browser).map { String($0.id.uuidString.prefix(8)).lowercased() }]
        }
        var out: [String: Any] = ["groups": rows]
        if let s = Grouper.shared.suggestion {
            out["suggestion"] = ["tab": String(s.tab.uuidString.prefix(8)).lowercased(), "name": s.name, "source": s.source, "reason": s.reason] as [String: Any]
        }
        return out
    }
}
