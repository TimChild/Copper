import Foundation

// A Netscape bookmark file: what Chrome's Bookmark Manager › Export bookmarks
// writes, and the `Bookmarks.html` inside Safari's File › Export Browsing Data
// to File… zip. Pure — bytes in, Copper's `Bookmark` tree out, shaped as a
// `FlowBookmarks.Read` so `FlowBookmarks.take(_, from:)` merges it exactly as
// it merges a direct read (re-imports replace only untouched roots).
//
// The format: `<DT><H3 …>Title</H3>` opens a folder whose contents are the
// next `<DL>`…`</DL>`; `<DT><A HREF="…">Title</A>` is a site. A `<DL>` with
// no folder title before it (a file's outer list) is see-through.
//
// - Chrome wraps everything in one outer `<DL>`, files the bookmarks bar in a
//   folder marked `PERSONAL_TOOLBAR_FOLDER="true"`, and writes the contents of
//   "Other bookmarks" and "Mobile bookmarks" loose at the top level.
// - Safari writes Favorites, Bookmarks Menu and the Reading List as top-level
//   folders (titles localized; the Reading List also carries
//   `id="com.apple.ReadingList"`), with or without an outer `<DL>`.
//
// Only pages a browser can open again are kept: http and https with a host.
// Bookmarklets, `file:`, `place:`, `chrome://` and the like are dropped.

enum FlowBookmarksHTML {
    /// One entry as the file has it, attributes (lowercased names) and all.
    struct Node: Equatable {
        var title: String
        var url: String?
        var attributes: [String: String] = [:]
        var children: [Node] = []
        var isFolder: Bool { url == nil }
    }

    /// How a browser files its bookmarks, so the tree lands in Copper the way
    /// that browser's direct read would land it.
    enum Layout {
        /// The bookmarks bar's contents loose at the top, everything else in
        /// one "Other" folder — the shape `FlowBookmarks.bookmarks(in:)` builds
        /// from Chrome's own `Bookmarks` file.
        case chromium
        /// Favorites loose at the top, then "Bookmarks Menu", the other
        /// top-level entries and "Reading List"; folders holding no site at
        /// all are left out.
        case safari
    }

    /// A file's top level, sorted into the sections browsers file under.
    struct Sections: Equatable {
        /// The bookmarks bar (Chrome) or Favorites (Safari).
        var bar: [Bookmark] = []
        /// Safari's Bookmarks Menu.
        var menu: [Bookmark] = []
        /// Everything else at the top, in file order.
        var other: [Bookmark] = []
        /// Safari's Reading List.
        var readingList: [Bookmark] = []

        /// Sites outside the Reading List.
        var bookmarkCount: Int { FlowBookmarks.count(bar) + FlowBookmarks.count(menu) + FlowBookmarks.count(other) }
        var readingListCount: Int { FlowBookmarks.count(readingList) }
        var count: Int { bookmarkCount + readingListCount }
        var isEmpty: Bool { count == 0 }

        /// Copper's tree, as `layout`'s browser would land it.
        func tree(_ layout: Layout) -> [Bookmark] {
            switch layout {
            case .chromium:
                var out = FlowBookmarksHTML.merged(bar)
                var rest = menu.isEmpty ? [] : [Bookmark.folder("Bookmarks Menu", menu)]
                rest += other
                if !readingList.isEmpty { rest.append(.folder("Reading List", readingList)) }
                let folded = FlowBookmarksHTML.merged(rest)
                if !folded.isEmpty { out.append(.folder("Other", folded)) }
                return out
            case .safari:
                var out = bar
                if !menu.isEmpty { out.append(.folder("Bookmarks Menu", menu)) }
                out += other
                if !readingList.isEmpty { out.append(.folder("Reading List", readingList)) }
                return FlowBookmarksHTML.merged(FlowBookmarksHTML.pruned(out))
            }
        }
    }

    // MARK: reading

    /// The file at `file`, ready for `FlowBookmarks.take`. A file that can't
    /// be read or isn't a bookmark file comes back as a failed read, so the
    /// merger keeps whatever an earlier import brought.
    static func read(contentsOf file: URL, layout: Layout) -> FlowBookmarks.Read {
        guard let data = try? Data(contentsOf: file) else { return FlowBookmarks.Read(nodes: [], failedFiles: [file]) }
        return read(data, layout: layout, file: file)
    }

    static func read(_ data: Data, layout: Layout, file: URL) -> FlowBookmarks.Read {
        guard let text = text(data), isBookmarkFile(text) else { return FlowBookmarks.Read(nodes: [], failedFiles: [file]) }
        return FlowBookmarks.Read(nodes: sections(text, layout: layout).tree(layout), failedFiles: [])
    }

    /// Sorts the top level. Chrome's bar is found by its attribute; Safari's
    /// sections also by their (English) titles, since only the Reading List
    /// carries an id. Under `.chromium` a person's own folder named
    /// "Favorites" stays an ordinary folder.
    static func sections(_ html: String, layout: Layout) -> Sections {
        var out = Sections()
        for node in parse(html) {
            let id = (node.attributes["id"] ?? "").lowercased()
            let title = node.title.trimmingCharacters(in: .whitespaces).lowercased()
            let toolbar = node.attributes["personal_toolbar_folder"]?.lowercased() == "true"
            let titled = layout == .safari
            if node.isFolder && (id == readingListID || (titled && (title == "reading list" || title == readingListID))) {
                out.readingList += node.children.compactMap(bookmark)
            } else if node.isFolder && (toolbar || (titled && barTitles.contains(title))) {
                out.bar += node.children.compactMap(bookmark)
            } else if node.isFolder && titled && menuTitles.contains(title) {
                out.menu += node.children.compactMap(bookmark)
            } else if let made = bookmark(node) {
                out.other.append(made)
            }
        }
        return out
    }

    static let readingListID = "com.apple.readinglist"
    static let barTitles: Set<String> = ["favorites", "favourites", "favorites bar", "favourites bar", "bookmarksbar", "bookmarks bar"]
    static let menuTitles: Set<String> = ["bookmarks menu", "bookmarksmenu"]

    /// Is this text a bookmark file? The doctype every exporter writes, or —
    /// for a hand-made file without one — the list-and-entry markup itself.
    static func isBookmarkFile(_ text: String) -> Bool {
        let head = text.prefix(4096)
        if head.range(of: "NETSCAPE-Bookmark-file", options: .caseInsensitive) != nil { return true }
        let lowered = head.lowercased()
        return lowered.contains("<dl") && lowered.contains("<dt") && (lowered.contains("<a href") || lowered.contains("<h3"))
    }

    /// UTF-8 (with or without a byte-order mark), UTF-16 with one, or — for
    /// an old file in a single-byte encoding — Latin-1, which never fails.
    static func text(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            return String(data: data, encoding: .utf16)
        }
        let body = bytes.count == 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? data.dropFirst(3) : data
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1)
    }

    /// Copper's node for a file node: http(s) sites only; folders keep their
    /// place even when nothing in them survives (as Chrome's direct read).
    static func bookmark(_ node: Node) -> Bookmark? {
        if node.isFolder { return .folder(node.title, node.children.compactMap(bookmark)) }
        guard let text = node.url, let url = web(text) else { return nil }
        return .site(node.title, url)
    }

    /// Only pages a browser can open again: http and https with a host.
    static func web(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Folders with no site anywhere inside them are left out.
    static func pruned(_ nodes: [Bookmark]) -> [Bookmark] {
        nodes.compactMap { node in
            guard node.isFolder else { return node }
            let kids = pruned(node.children ?? [])
            guard !kids.isEmpty else { return nil }
            var copy = node
            copy.children = kids
            return copy
        }
    }

    /// One level folded the way `FlowBookmarks` folds Chrome's files: a
    /// folder whose name is already at this level merges into it, and the
    /// same address with the same title is kept once (a different title is
    /// a separate bookmark). Nested levels are left as the file has them.
    static func merged(_ nodes: [Bookmark]) -> [Bookmark] {
        var result: [Bookmark] = []
        fold(nodes, into: &result)
        return result
    }

    /// Indexed by name and by address + title, so a level of thousands of
    /// loose bookmarks folds in one pass.
    private static func fold(_ incoming: [Bookmark], into result: inout [Bookmark]) {
        var folders: [String: Int] = [:]
        var sites = Set<String>()
        for (index, node) in result.enumerated() {
            if node.isFolder {
                if folders[node.title] == nil { folders[node.title] = index }
            } else {
                sites.insert(siteKey(node))
            }
        }
        for node in incoming {
            if node.isFolder {
                if let index = folders[node.title] {
                    var children = result[index].children ?? []
                    fold(node.children ?? [], into: &children)
                    result[index].children = children
                } else {
                    folders[node.title] = result.count
                    result.append(node)
                }
            } else if sites.insert(siteKey(node)).inserted {
                result.append(node)
            }
        }
    }

    private static func siteKey(_ node: Bookmark) -> String {
        (node.url ?? "") + "\u{1}" + node.title
    }

    // MARK: parsing

    /// The file's tree, entries in file order, see-through lists flattened.
    static func parse(_ html: String) -> [Node] {
        let bytes = Array(html.utf8)
        var frames: [[Node]] = [[]]
        var owners: [Node?] = [nil] // nil = a see-through list
        var pending: Node?
        var at = 0

        func flushPending() {
            if let folder = pending {
                frames[frames.count - 1].append(folder)
                pending = nil
            }
        }

        func closeFrame() {
            let finished = frames.removeLast()
            let owner = owners.removeLast()
            if var folder = owner {
                folder.children = finished
                frames[frames.count - 1].append(folder)
            } else {
                frames[frames.count - 1] += finished
            }
        }

        while at < bytes.count {
            guard bytes[at] == 60 else { at += 1; continue } // <
            if matches(bytes, at: at, Array("<!--".utf8), wholeName: false) {
                at = skipComment(bytes, from: at)
                continue
            }
            guard let tag = readTag(bytes, from: at) else { at += 1; continue }
            at = tag.end
            switch tag.name {
            case "h3":
                flushPending()
                let inner = readInner(bytes, from: at, closing: "h3")
                at = inner.end
                pending = Node(title: decode(inner.text), url: nil, attributes: tag.attributes, children: [])
            case "a":
                flushPending()
                let inner = readInner(bytes, from: at, closing: "a")
                at = inner.end
                if let href = tag.attributes["href"] {
                    frames[frames.count - 1].append(Node(title: decode(inner.text), url: decode(href), attributes: tag.attributes))
                }
            case "dl":
                frames.append([])
                owners.append(pending)
                pending = nil
            case "/dl":
                flushPending()
                if frames.count > 1 { closeFrame() }
            default:
                continue
            }
        }
        flushPending()
        while frames.count > 1 { closeFrame() }
        return frames[0]
    }

    private struct Tag {
        var name: String
        var attributes: [String: String]
        var end: Int
    }

    /// `<name attr="v" attr='v' attr=v attr>` starting at the `<`, names
    /// lowercased, values raw (entities decoded by the caller).
    private static func readTag(_ bytes: [UInt8], from start: Int) -> Tag? {
        var at = start + 1
        var nameBytes: [UInt8] = []
        if at < bytes.count, bytes[at] == 47 { nameBytes.append(47); at += 1 } // /
        while at < bytes.count, isNameByte(bytes[at]) {
            nameBytes.append(lower(bytes[at]))
            at += 1
        }
        guard nameBytes.count > (nameBytes.first == 47 ? 1 : 0) else { return nil }
        var attributes: [String: String] = [:]
        while at < bytes.count, bytes[at] != 62 { // >
            if isSpace(bytes[at]) || bytes[at] == 47 { at += 1; continue }
            var key: [UInt8] = []
            while at < bytes.count, !isSpace(bytes[at]), bytes[at] != 61, bytes[at] != 62 {
                key.append(lower(bytes[at]))
                at += 1
            }
            while at < bytes.count, isSpace(bytes[at]) { at += 1 }
            var value: [UInt8] = []
            if at < bytes.count, bytes[at] == 61 { // =
                at += 1
                while at < bytes.count, isSpace(bytes[at]) { at += 1 }
                if at < bytes.count, bytes[at] == 34 || bytes[at] == 39 { // " or '
                    let quote = bytes[at]
                    at += 1
                    while at < bytes.count, bytes[at] != quote {
                        value.append(bytes[at])
                        at += 1
                    }
                    at += 1
                } else {
                    while at < bytes.count, !isSpace(bytes[at]), bytes[at] != 62 {
                        value.append(bytes[at])
                        at += 1
                    }
                }
            }
            if !key.isEmpty, attributes[String(decoding: key, as: UTF8.self)] == nil {
                attributes[String(decoding: key, as: UTF8.self)] = String(decoding: value, as: UTF8.self)
            }
        }
        return Tag(name: String(decoding: nameBytes, as: UTF8.self), attributes: attributes, end: min(at + 1, bytes.count))
    }

    /// The text up to `</closing>`, tags inside it dropped. A new entry or
    /// list before the closer means the file left this one open.
    private static func readInner(_ bytes: [UInt8], from start: Int, closing: String) -> (text: String, end: Int) {
        let closer = Array("</\(closing)".utf8)
        let entry = Array("<dt".utf8)
        let list = Array("<dl".utf8)
        let listEnd = Array("</dl".utf8)
        var at = start
        var text: [UInt8] = []
        var inTag = false
        while at < bytes.count {
            if bytes[at] == 60 {
                if matches(bytes, at: at, closer) {
                    var end = at
                    while end < bytes.count, bytes[end] != 62 { end += 1 }
                    return (String(decoding: text, as: UTF8.self), min(end + 1, bytes.count))
                }
                if matches(bytes, at: at, entry) || matches(bytes, at: at, list) || matches(bytes, at: at, listEnd) {
                    return (String(decoding: text, as: UTF8.self), at)
                }
                inTag = true
            } else if bytes[at] == 62 && inTag {
                inTag = false
            } else if !inTag {
                text.append(bytes[at])
            }
            at += 1
        }
        return (String(decoding: text, as: UTF8.self), at)
    }

    /// Past the `-->` that ends a comment starting at `start`.
    private static func skipComment(_ bytes: [UInt8], from start: Int) -> Int {
        var at = start + 4
        while at + 2 < bytes.count {
            if bytes[at] == 45 && bytes[at + 1] == 45 && bytes[at + 2] == 62 { return at + 3 } // -->
            at += 1
        }
        return bytes.count
    }

    /// `needle` (lowercase) at `at`, case-insensitively; with `wholeName`,
    /// only when the name ends there (`<dt` doesn't match `<dtx`).
    private static func matches(_ bytes: [UInt8], at: Int, _ needle: [UInt8], wholeName: Bool = true) -> Bool {
        guard at + needle.count <= bytes.count else { return false }
        for k in 0..<needle.count where lower(bytes[at + k]) != needle[k] { return false }
        guard wholeName, at + needle.count < bytes.count else { return true }
        return !isNameByte(bytes[at + needle.count])
    }

    /// Letters, digits, `_` and `-`.
    private static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 65...90, 97...122, 48...57, 95, 45: return true
        default: return false
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }

    private static func lower(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }

    /// The entities bookmark files use: the five named ones, `&nbsp;` and
    /// numeric references (decimal and hex). Unknown ones are left as text.
    /// Surrounding whitespace (the file's indentation) is trimmed.
    static func decode(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("&") else { return trimmed }
        var out = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let c = trimmed[index]
            guard c == "&", let semi = trimmed[index...].firstIndex(of: ";"),
                  trimmed.distance(from: index, to: semi) <= 10
            else {
                out.append(c)
                index = trimmed.index(after: index)
                continue
            }
            let name = String(trimmed[trimmed.index(after: index)..<semi])
            var replaced: String?
            switch name.lowercased() {
            case "amp": replaced = "&"
            case "lt": replaced = "<"
            case "gt": replaced = ">"
            case "quot": replaced = "\""
            case "apos": replaced = "'"
            case "nbsp": replaced = "\u{00A0}"
            default:
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replaced = UInt32(name.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    replaced = UInt32(name.dropFirst()).flatMap(UnicodeScalar.init).map { String(Character($0)) }
                }
            }
            if let replaced {
                out += replaced
                index = trimmed.index(after: semi)
            } else {
                out.append(c)
                index = trimmed.index(after: index)
            }
        }
        return out
    }
}
