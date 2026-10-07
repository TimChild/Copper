import Foundation

/// Chromium's account and local files have the same tree shape. Account wins
/// each duplicate; local-only sites and folders follow it, profile by profile.
enum FlowBookmarks {
    static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    struct Read {
        let nodes: [Bookmark]
        let failedFiles: [URL]
        var complete: Bool { failedFiles.isEmpty }
    }

    static func bookmarks(in profiles: [URL]) -> Read {
        var bar: [Bookmark] = []
        var other: [Bookmark] = []
        var mobile: [Bookmark] = []
        var failed: [URL] = []
        for profile in profiles {
            for filename in ["AccountBookmarks", "Bookmarks"] {
                let file = profile.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                guard let data = try? Data(contentsOf: file),
                      let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let roots = top["roots"] as? [String: Any],
                      roots.keys.contains(where: { ["bookmark_bar", "other", "synced"].contains($0) }),
                      let barNodes = children(of: "bookmark_bar", roots: roots),
                      let otherNodes = children(of: "other", roots: roots),
                      let mobileNodes = children(of: "synced", roots: roots),
                      let parsedBar = nodes(in: barNodes),
                      let parsedOther = nodes(in: otherNodes),
                      let parsedMobile = nodes(in: mobileNodes)
                else { failed.append(file); continue }
                merge(parsedBar, into: &bar)
                merge(parsedOther, into: &other)
                merge(parsedMobile, into: &mobile)
            }
        }
        if !other.isEmpty { bar.append(.folder("Other", other)) }
        if !mobile.isEmpty { bar.append(.folder("Mobile", mobile)) }
        return Read(nodes: bar, failedFiles: failed)
    }

    private static func children(of key: String, roots: [String: Any]) -> [[String: Any]]? {
        guard roots[key] != nil else { return [] }
        guard let root = roots[key] as? [String: Any],
              let children = root["children"] as? [[String: Any]] else { return nil }
        return children
    }

    private static func nodes(in raw: [[String: Any]]) -> [Bookmark]? {
        var found: [Bookmark] = []
        for entry in raw {
            guard let name = entry["name"] as? String else { return nil }
            switch entry["type"] as? String {
            case "folder":
                guard let rawChildren = entry["children"] as? [[String: Any]],
                      let children = nodes(in: rawChildren) else { return nil }
                found.append(.folder(name, children))
            case "url":
                guard let text = entry["url"] as? String else { return nil }
                guard let url = URL(string: text), (url.scheme == "http" || url.scheme == "https"),
                      url.host != nil else { continue }
                found.append(.site(name, url))
            default: return nil
            }
        }
        return found
    }

    /// Merge matching folders in place and identical URL + title at the same
    /// level; a different title for the same URL is a separate bookmark.
    private static func merge(_ incoming: [Bookmark], into result: inout [Bookmark]) {
        for node in incoming {
            if node.isFolder {
                if let index = result.firstIndex(where: { $0.isFolder && $0.title == node.title }) {
                    var children = result[index].children ?? []
                    merge(node.children ?? [], into: &children)
                    result[index].children = children
                } else {
                    result.append(node)
                }
            } else if !result.contains(where: { !$0.isFolder && $0.url == node.url && $0.title == node.title }) {
                result.append(node)
            }
        }
    }

    /// A direct user mutation relinquishes its top-level root, even when a
    /// move back to the top changes only position (not Bookmark's value).
    @MainActor static func relinquish(touching ids: [Bookmark.ID], in roots: [Bookmark]) {
        let touched = Set(roots.filter { root in ids.contains { contains($0, in: root) } }.map(\.id))
        guard !touched.isEmpty else { return }
        for source in Chromium.known {
            let file = Store.file("flow-bookmarks-\(source.name.lowercased()).json")
            guard let data = try? Data(contentsOf: file),
                  var owned = try? JSONDecoder().decode([Bookmark].self, from: data) else { continue }
            let before = owned.count
            owned.removeAll { touched.contains($0.id) }
            if owned.count != before, let data = try? JSONEncoder().encode(owned) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    private static func contains(_ id: Bookmark.ID, in node: Bookmark) -> Bool {
        node.id == id || (node.children ?? []).contains { contains(id, in: $0) }
    }

    /// A complete (including empty) read replaces only untouched owned roots.
    /// An unreadable present file cannot authorize deleting any old roots.
    @MainActor static func take(_ read: Read, from source: String, into bookmarks: Bookmarks) {
        if !read.complete {
            NSLog("Copper: Flow %@ bookmarks: %d unreadable file(s); keeping previous roots: %@",
                  source, read.failedFiles.count, read.failedFiles.map(\.path).joined(separator: ", "))
        }
        let file = Store.file("flow-bookmarks-\(source.lowercased()).json")
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
        var roots = bookmarks.roots.filter { root in
            !read.complete || !previous.contains { $0.id == root.id && $0 == root }
        }
        var imported = read.complete ? [] : previous.filter { old in roots.contains(old) }
        for var node in read.nodes {
            if !read.complete, let index = roots.firstIndex(where: { root in
                previous.contains(root) && root.isFolder && node.isFolder &&
                (root.title == node.title || root.title == "\(node.title) (\(source))" ||
                 root.title.hasPrefix("\(node.title) (\(source)) "))
            }) {
                var children = roots[index].children ?? []
                merge(node.children ?? [], into: &children)
                roots[index].children = children
                if let owned = imported.firstIndex(where: { $0.id == roots[index].id }) {
                    imported[owned] = roots[index]
                }
                continue
            }
            if node.isFolder {
                if roots.contains(where: { $0.isFolder && $0.title == node.title }) {
                    node.title += " (\(source))"
                }
                // A person's same-named folder is still theirs, even if a
                // past imported folder with that name was moved or edited.
                var name = node.title
                var number = 2
                while roots.contains(where: { $0.isFolder && $0.title == name }) {
                    name = "\(node.title) \(number)"
                    number += 1
                }
                node.title = name
            } else if roots.contains(where: { !$0.isFolder && $0.url == node.url && $0.title == node.title }) {
                continue
            }
            roots.append(node)
            imported.append(node)
        }
        bookmarks.replace(roots)
        if let data = try? JSONEncoder().encode(imported) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
