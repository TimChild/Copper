import Foundation

/// Chromium's account and local files have the same tree shape. Account wins
/// each duplicate; local-only sites and folders follow it, profile by profile.
enum FlowBookmarks {
    static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    static func bookmarks(in profiles: [URL]) -> [Bookmark] {
        var bar: [Bookmark] = []
        var other: [Bookmark] = []
        var mobile: [Bookmark] = []
        for profile in profiles {
            for filename in ["AccountBookmarks", "Bookmarks"] {
                let file = profile.appendingPathComponent(filename)
                guard let data = try? Data(contentsOf: file),
                      let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let roots = top["roots"] as? [String: Any]
                else { continue }
                merge(nodes(in: children(of: "bookmark_bar", roots: roots)), into: &bar)
                merge(nodes(in: children(of: "other", roots: roots)), into: &other)
                merge(nodes(in: children(of: "synced", roots: roots)), into: &mobile)
            }
        }
        if !other.isEmpty { bar.append(.folder("Other", other)) }
        if !mobile.isEmpty { bar.append(.folder("Mobile", mobile)) }
        return bar
    }

    private static func children(of key: String, roots: [String: Any]) -> [[String: Any]] {
        (roots[key] as? [String: Any])?["children"] as? [[String: Any]] ?? []
    }

    private static func nodes(in raw: [[String: Any]]) -> [Bookmark] {
        raw.compactMap { entry in
            let name = entry["name"] as? String ?? ""
            switch entry["type"] as? String {
            case "folder": return .folder(name, nodes(in: entry["children"] as? [[String: Any]] ?? []))
            case "url":
                guard let text = entry["url"] as? String, let url = URL(string: text),
                      url.scheme == "http" || url.scheme == "https", url.host != nil
                else { return nil }
                return .site(name, url)
            default: return nil
            }
        }
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

    /// Only untouched top-level nodes from our last import are replaced. A
    /// person's edits (or moves into their folders) are never our property.
    @MainActor static func take(_ found: [Bookmark], from source: String, into bookmarks: Bookmarks) {
        guard !found.isEmpty else { return }
        let file = Store.file("flow-bookmarks-\(source.lowercased()).json")
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
        var roots = bookmarks.roots.filter { root in
            !previous.contains { $0.id == root.id && $0 == root }
        }
        var imported: [Bookmark] = []
        for var node in found {
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
