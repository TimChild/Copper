import SwiftUI

// Folders, out of the groups that are already there.
//
// Arc's sidebar folders nest. Copper's groups are flat — one name, one run
// of tabs — but the name carries the nesting: `arc-import` writes a folder
// inside a folder as `Misc › BuildrFi`, and a group whose name starts with
// another group's name and the separator *is* that group's child. So the
// tree is read back out of the names rather than kept twice, and a rename
// carries its children with it (see `Groups.rename`).
//
// Nothing here owns anything. It reads a block's tabs and its groups and
// says what the column should draw, in order, with a depth on every line:
// headers for the folders, rows for the tabs, nothing at all under a folded
// folder — its children's headers included.

enum Folders {
    /// What `arc-import` puts between a folder and the one inside it.
    static let mark = " › "
    /// One step in. A tab in a top-level folder is one step; its folder's
    /// header is none; a folder inside it is one, and its tabs are two.
    static let step: CGFloat = 16

    /// `Misc › BuildrFi › Notes` → `Notes`.
    static func leaf(_ name: String) -> String {
        name.components(separatedBy: mark).last ?? name
    }

    /// Is `name` somewhere below `other`?
    static func below(_ name: String, _ other: String) -> Bool {
        name.count > other.count && name.hasPrefix(other + mark)
    }

    /// The name a folder made inside `parent` carries.
    static func inside(_ parent: TabGroup, named name: String) -> String {
        parent.name + mark + name.trimmingCharacters(in: .whitespaces)
    }
}

/// What one block of the column draws.
enum FolderRow: Identifiable {
    /// A folder's line. `depth` is how far in it sits, `label` the part of
    /// the name below its parent, `count` the tabs it hides while folded.
    case head(TabGroup, count: Int, at: Int, depth: Int, label: String)
    /// A tab's line. `depth` is how far in it sits: 0 loose, 1 in a
    /// top-level folder, 2 in a folder inside that one.
    case tab(Tab, index: Int, group: TabGroup?, depth: Int)

    var id: String {
        switch self {
        case .head(let group, _, let at, _, _): return "head-\(group.id.uuidString)-\(at)"
        case .tab(let tab, _, _, _): return "tab-\(tab.id.uuidString)"
        }
    }

    var indent: CGFloat {
        switch self {
        case .head(_, _, _, let depth, _): return CGFloat(depth) * Folders.step
        case .tab(_, _, _, let depth): return CGFloat(depth) * Folders.step
        }
    }
}

/// The nesting the groups of one block make, worked out once per draw.
///
/// "Of one block": two spaces can both hold a folder called `Misc`, and the
/// one that matters is the one whose tabs are in front of you. Only groups
/// with a tab in these rows are nodes — plus the empty folders under them,
/// so a folder you have just made inside one has somewhere to appear before
/// it holds anything.
@MainActor
struct FolderTree {
    /// Ancestors of each node, shallowest first.
    private var above: [UUID: [TabGroup]] = [:]
    /// The tabs each node holds in this block, its own only.
    private var own: [UUID: Int] = [:]
    /// The folders inside each node, in the order their names sort.
    private var inside: [UUID: [TabGroup]] = [:]
    private(set) var nodes: [TabGroup] = []

    init(tabs: [Tab], groups: Groups = Groups.shared) {
        var here: [TabGroup] = []
        var seen: Set<UUID> = []
        for tab in tabs {
            guard let id = groups.membership[tab.id], let group = groups.group(id) else { continue }
            own[id, default: 0] += 1
            if seen.insert(id).inserted { here.append(group) }
        }
        // A folder with no tabs anywhere belongs to whichever tree claims
        // its name; one with tabs elsewhere is another space's folder and
        // has no business in this block.
        let held = Set(groups.membership.values)
        let empties = groups.all.filter { group in
            !held.contains(group.id) && here.contains { Folders.below(group.name, $0.name) }
        }
        nodes = here + empties

        for node in nodes {
            let ancestors = nodes.filter { Folders.below(node.name, $0.name) }
                .sorted { $0.name.count < $1.name.count }
            above[node.id] = ancestors
            if let parent = ancestors.last {
                inside[parent.id, default: []].append(node)
            }
        }
        for key in inside.keys { inside[key]?.sort { $0.name < $1.name } }
    }

    func depth(of group: TabGroup) -> Int { above[group.id]?.count ?? 0 }

    /// What the header says: the part of the name below the deepest folder
    /// actually on screen. A child whose parent is not here keeps enough of
    /// its path to be told apart.
    func label(of group: TabGroup) -> String {
        guard let parent = above[group.id]?.last else { return group.name }
        return String(group.name.dropFirst(parent.name.count + Folders.mark.count))
    }

    /// Folded above: the folder is inside one that is shut, so neither it
    /// nor anything it holds is drawn.
    func hidden(_ group: TabGroup) -> Bool {
        above[group.id]?.contains { $0.collapsed } ?? false
    }

    /// Everything below it, its own rows and its children's — what a folded
    /// folder is holding back.
    func weight(of group: TabGroup) -> Int {
        (own[group.id] ?? 0) + (inside[group.id] ?? []).reduce(0) { $0 + weight(of: $1) }
    }

    func children(of group: TabGroup) -> [TabGroup] { inside[group.id] ?? [] }

    /// Folders inside this one that hold nothing yet, deepest last. They
    /// have no run of tabs to hang a header off, so the plan puts them
    /// directly under their parent's.
    private func emptyChildren(of group: TabGroup, at depth: Int, index: Int) -> [FolderRow] {
        var out: [FolderRow] = []
        for child in children(of: group) where (own[child.id] ?? 0) == 0 {
            out.append(.head(child, count: weight(of: child), at: index, depth: depth + 1, label: label(of: child)))
            if !child.collapsed { out += emptyChildren(of: child, at: depth + 1, index: index) }
        }
        return out
    }

    /// The whole block, top to bottom.
    static func plan(_ tabs: [Tab], groups: Groups = Groups.shared) -> [FolderRow] {
        let tree = FolderTree(tabs: tabs, groups: groups)
        var out: [FolderRow] = []
        var previous: UUID?
        for (index, tab) in tabs.enumerated() {
            let group = groups.group(of: tab)
            if let group, group.id != previous, !tree.hidden(group) {
                let depth = tree.depth(of: group)
                out.append(.head(group, count: tree.weight(of: group), at: index,
                                 depth: depth, label: tree.label(of: group)))
                if !group.collapsed { out += tree.emptyChildren(of: group, at: depth, index: index) }
            }
            previous = group?.id
            if let group, group.collapsed || tree.hidden(group) { continue }
            out.append(.tab(tab, index: index, group: group,
                            depth: group.map { tree.depth(of: $0) + 1 } ?? 0))
        }
        return out
    }
}
