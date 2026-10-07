import Foundation
import SQLite3

// Safari, read from its own files or from the zip it exports.
//
// Two ways in, and nothing here touches Copper's state — every reader is a
// pure function of bytes, tested on synthetic files in
// Tests/SearchTests/FlowSafariTests.swift.
//
// 1. Safari's export (File › Export Browsing Data to File…) is a zip of
//    plain files with a documented format ("Importing data exported from
//    Safari"): a
//    Netscape bookmark file (the Reading List is a folder with the id
//    `com.apple.ReadingList`), a passwords CSV
//    (Title,URL,Username,Password,Notes,OTPAuth), a payment-cards JSON, and
//    per profile a history JSON and an extensions JSON. The JSON files carry
//    a `metadata` object whose `data_type` is `history`, `extensions` or
//    `payment_cards`. The file names are localized ("Bookmarks.html",
//    "History - Work.json" in English), so files are told apart by what
//    they hold, never by name.
// 2. Safari's own stores, which macOS keeps behind Full Disk Access:
//    `~/Library/Safari/Bookmarks.plist` (Favorites bar, Bookmarks Menu,
//    Reading List), `~/Library/Safari/History.db` (history_items +
//    history_visits on the Core Data clock) and the container's
//    `SafariTabs.db` (windows, tab groups, pinned tabs, profiles).
//
// Bookmarks from either way come out as `FlowBookmarks.Read` in Safari's
// layout (FlowBookmarksHTML.swift), so `FlowBookmarks.take(_, from: "Safari")`
// owns the merging, exactly as it does for Chrome.

// MARK: - bookmarks

enum SafariBookmarks {
    /// Where the bookmarks came from.
    enum Origin: Equatable {
        /// `~/Library/Safari/Bookmarks.plist`.
        case library
        /// The export's bookmark file.
        case export
    }

    /// The bookmark file a move uses, its sections (for counts) and what
    /// `FlowBookmarks.take` gets.
    struct Found {
        var origin: Origin
        var sections: FlowBookmarksHTML.Sections
        var read: FlowBookmarks.Read
    }

    /// Which bookmarks a move takes. The library's own file wins over the
    /// export's (it is Safari's current state, not a snapshot); an
    /// unreadable library file falls back to the export. With no bookmark
    /// file at all the answer is nil and `take` must not run — an empty
    /// complete read would remove what the last Safari move brought. An
    /// unreadable file with nothing to fall back on is a failed read, which
    /// keeps the last move's bookmarks as they are.
    static func pick(library: URL?, exportHTML: String?) -> Found? {
        var failed: URL?
        if let file = library, FileManager.default.fileExists(atPath: file.path) {
            if let data = try? Data(contentsOf: file), let sections = try? SafariBookmarksPlist.read(data) {
                return Found(origin: .library, sections: sections,
                             read: FlowBookmarks.Read(nodes: sections.tree(.safari), failedFiles: []))
            }
            failed = file
        }
        if let html = exportHTML, FlowBookmarksHTML.isBookmarkFile(html) {
            let sections = FlowBookmarksHTML.sections(html, layout: .safari)
            return Found(origin: .export, sections: sections,
                         read: FlowBookmarks.Read(nodes: sections.tree(.safari), failedFiles: []))
        }
        guard let failed else { return nil }
        return Found(origin: .library, sections: FlowBookmarksHTML.Sections(),
                     read: FlowBookmarks.Read(nodes: [], failedFiles: [failed]))
    }
}

enum SafariBookmarksPlist {
    enum Trouble: Error { case notBookmarks }

    /// The binary plist Safari keeps: a list whose children are the History
    /// proxy (skipped), `BookmarksBar` (the Favorites bar), `BookmarksMenu`,
    /// `com.apple.ReadingList`, and anything filed loose at the top.
    static func read(_ data: Data) throws -> FlowBookmarksHTML.Sections {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let children = root["Children"] as? [[String: Any]]
        else { throw Trouble.notBookmarks }
        var sections = FlowBookmarksHTML.Sections()
        for child in children {
            let type = child["WebBookmarkType"] as? String ?? ""
            let title = child["Title"] as? String ?? ""
            if type == "WebBookmarkTypeList" && title == "BookmarksBar" {
                sections.bar = nodes(child["Children"])
            } else if type == "WebBookmarkTypeList" && title == "BookmarksMenu" {
                sections.menu = nodes(child["Children"])
            } else if type == "WebBookmarkTypeList" && title == "com.apple.ReadingList" {
                sections.readingList = nodes(child["Children"])
            } else if let node = node(child) {
                sections.other.append(node)
            }
        }
        return sections
    }

    private static func nodes(_ raw: Any?) -> [Bookmark] {
        (raw as? [[String: Any]] ?? []).compactMap(node)
    }

    private static func node(_ raw: [String: Any]) -> Bookmark? {
        switch raw["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            guard let text = raw["URLString"] as? String, let url = FlowBookmarksHTML.web(text) else { return nil }
            let uri = raw["URIDictionary"] as? [String: Any]
            let fetched = raw["ReadingListNonSync"] as? [String: Any]
            let title = (uri?["title"] as? String) ?? (fetched?["Title"] as? String) ?? ""
            return .site(title, url)
        case "WebBookmarkTypeList":
            return .folder(raw["Title"] as? String ?? "", nodes(raw["Children"]))
        default:
            // WebBookmarkTypeProxy (the History entry) and anything newer.
            return nil
        }
    }
}

// MARK: - history

/// Safari's export clock and Safari's on-disk clock.
enum SafariClock {
    /// `time_usec`: microseconds since 1970.
    static func date(usec: Double) -> Date? {
        guard usec > 0 else { return nil }
        return Date(timeIntervalSince1970: usec / 1_000_000)
    }

    /// History.db's `visit_time`: seconds since 2001-01-01 (Core Data's).
    static func date(coreData seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}

/// The header every JSON file of the export carries.
struct SafariExportMetadata: Equatable {
    var browserName: String
    var browserVersion: String
    var dataType: String
    var exportedAt: Date?
    var schemaVersion: Int

    init?(_ object: [String: Any]) {
        guard let meta = object["metadata"] as? [String: Any],
              let type = meta["data_type"] as? String
        else { return nil }
        browserName = meta["browser_name"] as? String ?? "Safari"
        browserVersion = meta["browser_version"] as? String ?? ""
        dataType = type
        exportedAt = (meta["export_time_usec"] as? NSNumber).flatMap { SafariClock.date(usec: $0.doubleValue) }
        schemaVersion = (meta["schema_version"] as? NSNumber)?.intValue ?? 0
    }
}

enum SafariHistoryJSON {
    enum Trouble: Error { case notHistory }

    static func places(_ data: Data) throws -> [Chromium.Place] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Trouble.notHistory }
        return try places(object)
    }

    /// One place per address: the most visits and the newest visit win when
    /// an address turns up more than once (redirect chains repeat them).
    /// A redirect's first hop (it has a `destination_url`) is not a place a
    /// person went, and neither is a single visit that failed to load or was
    /// a form post.
    static func places(_ object: [String: Any]) throws -> [Chromium.Place] {
        guard let items = object["history"] as? [[String: Any]] else { throw Trouble.notHistory }
        if let meta = SafariExportMetadata(object), meta.dataType != "history" { throw Trouble.notHistory }
        var byURL: [String: Chromium.Place] = [:]
        for item in items {
            guard let text = item["url"] as? String, let url = FlowBookmarksHTML.web(text) else { continue }
            if let destination = item["destination_url"] as? String, !destination.isEmpty { continue }
            let count = max(1, (item["visits_count"] as? NSNumber)?.intValue ?? 1)
            let failed = (item["latest_visit_was_load_failure"] as? Bool) == true
            let get = (item["latest_visit_was_http_get"] as? Bool) ?? true
            if count <= 1 && (failed || !get) { continue }
            let last = (item["time_usec"] as? NSNumber).flatMap { SafariClock.date(usec: $0.doubleValue) } ?? Date(timeIntervalSince1970: 0)
            let title = item["title"] as? String ?? ""
            let place = Chromium.Place(url: url, title: title, count: count, last: last)
            let key = url.absoluteString
            byURL[key] = byURL[key].map { SafariHistoryDB.combined($0, place) } ?? place
        }
        return byURL.values.sorted { $0.last > $1.last }
    }
}

/// Opens a copy of one of Safari's SQLite stores — with its -wal and -shm,
/// where the newest rows sit while Safari runs — and never the original.
enum SafariSQLite {
    enum Trouble: Error { case unreadable(String) }

    static func withCopy<T>(of file: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("copper-safari-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        try fm.copyItem(at: file, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: file.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var database: OpaquePointer?
        // Read-write on the copy, so SQLite can fold the copied WAL in.
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw Trouble.unreadable(file.lastPathComponent)
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    static func rows(_ database: OpaquePointer, _ sql: String) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        try each(database, sql) { row in
            out.append(row)
            return true
        }
        return out
    }

    /// Row by row; `body` returns false to stop early.
    static func each(_ database: OpaquePointer, _ sql: String, _ body: ([String: Any]) -> Bool) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let columns = Int(sqlite3_column_count(statement))
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<columns {
                let at = Int32(column)
                let name = String(cString: sqlite3_column_name(statement, at))
                switch sqlite3_column_type(statement, at) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, at))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, at)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, at))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, at))
                    if let bytes = sqlite3_column_blob(statement, at), count > 0 {
                        row[name] = Data(bytes: bytes, count: count)
                    }
                default: break
                }
            }
            guard body(row) else { return }
        }
    }

    static func hasTable(_ database: OpaquePointer, _ name: String) -> Bool {
        ((try? rows(database, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(name)'")) ?? []).isEmpty == false
    }
}

enum SafariHistoryDB {
    /// Every web address with at least one visit that loaded, was a plain
    /// GET and was not the first hop of a redirect, newest first, at most
    /// `limit` of them. The count is Safari's total; the title is the newest
    /// one a visit recorded. Visits synced from Safari on another device
    /// (`origin` 1) count: they are the same person's history.
    static func places(at file: URL, limit: Int = Int.max) throws -> [Chromium.Place] {
        guard limit > 0 else { return [] }
        return try SafariSQLite.withCopy(of: file) { database in
            // The web filter is in the query, and the limit is counted on
            // the places actually kept — a limit applied in SQL before the
            // filter could come back short.
            let sql = """
            SELECT i.url AS url, i.visit_count AS count, MAX(v.visit_time) AS last,
              (SELECT t.title FROM history_visits t WHERE t.history_item = i.id AND t.title IS NOT NULL AND t.title <> ''
               ORDER BY t.visit_time DESC LIMIT 1) AS title
            FROM history_items i JOIN history_visits v ON v.history_item = i.id
            WHERE (i.url LIKE 'http://%' OR i.url LIKE 'https://%')
              AND v.load_successful = 1 AND v.http_non_get = 0 AND v.redirect_destination IS NULL
            GROUP BY i.id ORDER BY last DESC
            """
            var out: [Chromium.Place] = []
            try SafariSQLite.each(database, sql) { row in
                guard let text = row["url"] as? String, let url = FlowBookmarksHTML.web(text) else { return true }
                let seconds = (row["last"] as? Double) ?? Double(row["last"] as? Int ?? 0)
                out.append(Chromium.Place(url: url, title: row["title"] as? String ?? "",
                                          count: max(1, row["count"] as? Int ?? 1),
                                          last: SafariClock.date(coreData: seconds)))
                return out.count < limit
            }
            return out
        }
    }

    /// The same address read from more than one place (the store, each
    /// profile's history, the export): the larger count and the newer visit
    /// win, as `History.take` does.
    static func merged(_ lists: [[Chromium.Place]]) -> [Chromium.Place] {
        var byURL: [String: Chromium.Place] = [:]
        for list in lists {
            for place in list {
                let key = place.url.absoluteString
                byURL[key] = byURL[key].map { combined($0, place) } ?? place
            }
        }
        return byURL.values.sorted { $0.last > $1.last }
    }

    /// Two sightings of one address: the newer one's title (when it has
    /// one), the larger count, the newer visit.
    static func combined(_ seen: Chromium.Place, _ place: Chromium.Place) -> Chromium.Place {
        let newer = place.last > seen.last
        let title = newer && !place.title.isEmpty ? place.title : (seen.title.isEmpty ? place.title : seen.title)
        return Chromium.Place(url: seen.url, title: title, count: max(seen.count, place.count), last: newer ? place.last : seen.last)
    }
}

// MARK: - SafariTabs.db

/// Safari's open windows, tab groups and pinned tabs, as Copper spaces to be.
struct SafariTabsHaul {
    /// A space with the Safari id it came from (a tab group's UUID), so a
    /// second move can tell it already arrived.
    struct Keyed {
        var key: String
        var space: FlowModel.Space
    }

    var spaces: [Keyed] = []
    var windows = 0
    var tabGroups = 0
    var pinned = 0
    var profiles: [String] = []
    /// Named tab groups with nothing in them; not made into spaces.
    var emptyGroups = 0
    var privateWindows = 0

    var tabCount: Int { spaces.reduce(0) { $0 + $1.space.tabs.count } }
}

enum SafariTabsDB {
    static let specialFolders: Set<String> = ["pinned", "privatepinned", "recentlyclosed", "recovered"]

    static func read(at file: URL) throws -> SafariTabsHaul {
        try SafariSQLite.withCopy(of: file) { database in
            try read(database)
        }
    }

    static func read(_ database: OpaquePointer) throws -> SafariTabsHaul {
        let rows = try SafariSQLite.rows(database, "SELECT * FROM bookmarks")
        var byID: [Int: [String: Any]] = [:]
        var children: [Int: [[String: Any]]] = [:]
        for row in rows {
            guard let id = row["id"] as? Int else { continue }
            byID[id] = row
            if let parent = row["parent"] as? Int { children[parent, default: []].append(row) }
        }
        func int(_ row: [String: Any], _ key: String) -> Int { row[key] as? Int ?? 0 }
        func text(_ row: [String: Any], _ key: String) -> String { row[key] as? String ?? "" }
        func plist(_ row: [String: Any], _ key: String) -> [String: Any] {
            guard let data = row[key] as? Data else { return [:] }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
        }

        // Profiles: folders of subtype 2 under the root. The default one has
        // no title and the id "DefaultProfile".
        var profileName: [Int: String] = [:]
        for row in rows where int(row, "type") == 1 && int(row, "subtype") == 2 && int(row, "deleted") == 0 {
            guard let id = row["id"] as? Int else { continue }
            let uuid = text(row, "external_uuid")
            profileName[id] = uuid == "DefaultProfile" ? "" : text(row, "title")
        }
        var haul = SafariTabsHaul()
        haul.profiles = profileName.values.filter { !$0.isEmpty }.sorted()

        func tabs(in groupID: Int, pinned: Bool, active: Int?) -> [FlowModel.Tab] {
            (children[groupID] ?? [])
                .filter { int($0, "type") == 0 && int($0, "deleted") == 0 }
                .sorted { int($0, "order_index") == int($1, "order_index") ? int($0, "id") < int($1, "id") : int($0, "order_index") < int($1, "order_index") }
                .compactMap { row in
                    let extra = plist(row, "extra_attributes")
                    let address = text(row, "url").isEmpty ? (extra["LocalURL"] as? String ?? "") : text(row, "url")
                    guard let url = FlowBookmarksHTML.web(address) else { return nil }
                    let title = text(row, "title").isEmpty ? (extra["LocalTitle"] as? String ?? "") : text(row, "title")
                    // `seen` is left nil on purpose: Copper's Today sweep
                    // archives a row nobody has looked at for a day, and a
                    // Safari tab last looked at in August would be closed
                    // the first time its space came on screen. A moved tab
                    // counts as seen at the move.
                    return FlowModel.Tab(url: url, title: title, pinned: pinned, active: row["id"] as? Int == active && active != nil)
                }
        }

        // Which tab each group had in front, from the windows' records.
        var activeTab: [Int: Int] = [:]
        if SafariSQLite.hasTable(database, "windows_tab_groups") {
            for row in try SafariSQLite.rows(database, "SELECT tab_group_id, active_tab_id FROM windows_tab_groups") {
                if let group = row["tab_group_id"] as? Int, let tab = row["active_tab_id"] as? Int { activeTab[group] = tab }
            }
        }
        func front(_ group: Int) -> Int? {
            activeTab[group] ?? (byID[group].flatMap { $0["last_selected_child"] as? Int })
        }

        // Windows, oldest first: the ones of the last session and the open
        // ones. A private window is never read.
        var windowSpaces: [SafariTabsHaul.Keyed] = []
        var unnamedByWindow: [Int: [Int]] = [:]
        if SafariSQLite.hasTable(database, "windows_unnamed_tab_groups") {
            for row in try SafariSQLite.rows(database, "SELECT window_id, tab_group_id FROM windows_unnamed_tab_groups ORDER BY id") {
                if let window = row["window_id"] as? Int, let group = row["tab_group_id"] as? Int { unnamedByWindow[window, default: []].append(group) }
            }
        }
        var profileOfGroup: [Int: Int] = [:]
        if SafariSQLite.hasTable(database, "windows_profiles") {
            for row in try SafariSQLite.rows(database, "SELECT profile_id, active_tab_group_id FROM windows_profiles") {
                if let group = row["active_tab_group_id"] as? Int, let profile = row["profile_id"] as? Int { profileOfGroup[group] = profile }
            }
        }
        let windows = SafariSQLite.hasTable(database, "windows") ? try SafariSQLite.rows(database, "SELECT * FROM windows ORDER BY id") : []
        // "Safari", "Safari 2", "Safari · Work": numbered per profile.
        var windowsNamed: [String: Int] = [:]
        for window in windows {
            let extra = plist(window, "extra_attributes")
            if (extra["IsPrivateWindow"] as? Bool) == true { haul.privateWindows += 1; continue }
            let closed = window["date_closed"] != nil
            let lastSession = int(window, "is_last_session") == 1
            guard !closed || lastSession else { continue }
            var groups: [Int] = []
            if let local = window["local_tab_group_id"] as? Int { groups.append(local) }
            groups += unnamedByWindow[int(window, "id")] ?? []
            let windowProfile = window["active_profile_id"] as? Int
            for group in groups {
                let found = tabs(in: group, pinned: false, active: front(group))
                guard !found.isEmpty else { continue }
                let profile = profileOfGroup[group] ?? windowProfile
                let suffix = profile.flatMap { profileName[$0] }.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
                let base = "Safari" + suffix
                let number = windowsNamed[base, default: 0] + 1
                windowsNamed[base] = number
                let name = number == 1 ? base : "\(base) \(number)"
                let key = byID[group].map { text($0, "external_uuid") }.flatMap { $0.isEmpty ? nil : $0 } ?? "window:\(text(window, "uuid")):\(group)"
                windowSpaces.append(.init(key: key, space: FlowModel.Space(name: name, tabs: found)))
            }
            haul.windows += 1
        }

        // Named tab groups — Safari's own spaces — whether or not a window
        // has them open: the default profile's first, then each profile's
        // in Safari's order.
        var groupSpaces: [SafariTabsHaul.Keyed] = []
        var profileOrder: [Int: Int] = [:]
        for id in profileName.keys { profileOrder[id] = byID[id].map { int($0, "order_index") } ?? 0 }
        func rank(_ row: [String: Any]) -> (Int, Int, Int) {
            let parent = row["parent"] as? Int ?? 0
            let owner = parent == 0 || profileName[parent] == "" ? -1 : (profileOrder[parent] ?? 0)
            return (owner, int(row, "order_index"), int(row, "id"))
        }
        let named = rows.filter { row in
            guard int(row, "type") == 1, int(row, "subtype") == 0, int(row, "deleted") == 0,
                  !text(row, "title").isEmpty, let parent = row["parent"] as? Int
            else { return false }
            let uuid = text(row, "external_uuid").lowercased()
            guard !specialFolders.contains(uuid), !specialFolders.contains(text(row, "title").lowercased()) else { return false }
            return parent == 0 || profileName[parent] != nil
        }.sorted { rank($0) < rank($1) }
        for group in named {
            guard let id = group["id"] as? Int else { continue }
            haul.tabGroups += 1
            let found = tabs(in: id, pinned: false, active: front(id))
            guard !found.isEmpty else { haul.emptyGroups += 1; continue }
            let key = text(group, "external_uuid").isEmpty ? "group:\(id)" : text(group, "external_uuid")
            groupSpaces.append(.init(key: key, space: FlowModel.Space(name: text(group, "title"), tabs: found)))
        }

        var spaces = windowSpaces + groupSpaces

        // Pinned tabs: the folder Safari calls "pinned" (one per profile).
        // Copper's pins belong to every space, so they ride with the first
        // space; with no space at all they make one.
        let pinFolders = rows.filter { row in
            int(row, "type") == 1 && int(row, "deleted") == 0
                && (text(row, "title").lowercased() == "pinned" || text(row, "external_uuid").lowercased() == "pinned")
        }
        var pins: [FlowModel.Tab] = []
        var seenPins = Set<String>()
        for folder in pinFolders {
            guard let id = folder["id"] as? Int else { continue }
            for tab in tabs(in: id, pinned: true, active: nil) where seenPins.insert(tab.url.absoluteString).inserted {
                pins.append(tab)
            }
        }
        haul.pinned = pins.count
        if !pins.isEmpty {
            if spaces.isEmpty {
                spaces.append(.init(key: "pins", space: FlowModel.Space(name: "Safari", tabs: pins)))
            } else {
                spaces[0].space.tabs = pins + spaces[0].space.tabs
            }
        }
        haul.spaces = spaces
        return haul
    }
}


// MARK: - Passwords.csv

// Passwords: the export's CSV is read by the one CSV module,
// `PasswordCSV` (Fork/Credentials/PasswordCSV.swift) — its header spellings
// (Safari's `Title,URL,Username,Password,Notes,OTPAuth` among them), counts
// and canonical form. Nothing here reads a password CSV of its own.

// MARK: - the export, zipped or not

/// What one Safari export holds. Passwords stay text only as long as the
/// caller keeps this value; nothing here writes them anywhere.
struct SafariExport {
    /// One profile's history file, already read.
    struct History {
        /// The file's name as the export has it ("History - Work.json").
        var file: String
        var places: [Chromium.Place]
    }

    var bookmarksHTML: String?
    /// One per profile: with several profiles Safari writes one history
    /// file each, the profile's name in the file name.
    var histories: [History] = []
    var passwordsCSV: String?
    var cardCount = 0
    /// Extension names across every profile, each once.
    var extensions: [String] = []
    var exportedAt: Date?
    var browser = "Safari"
    /// Every file looked at, by name, for the probe's notes.
    var files: [String] = []
    /// Files that said they were Safari's (history, cards, extensions) but
    /// didn't read.
    var unreadable: [String] = []

    var hasAnything: Bool {
        bookmarksHTML != nil || !histories.isEmpty || passwordsCSV != nil || cardCount > 0 || !extensions.isEmpty
    }

    /// Every profile's history as one list, each address once.
    var places: [Chromium.Place] { SafariHistoryDB.merged(histories.map(\.places)) }

    enum Trouble: LocalizedError {
        case notAnExport
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notAnExport: return "That isn't an export from Safari"
            case .unreadable(let what): return "Couldn't read \(what)"
            }
        }
    }

    /// What a file holds, judged by its first bytes — never by its name.
    enum Kind: Equatable { case json, bookmarks, passwords }

    /// How far into a file the sniff looks.
    static let sniffLength = 4096
    /// A folder is walked this deep (the export unzipped, maybe in one more
    /// folder) and only this far — a whole Downloads folder is not an export.
    static let folderDepth = 2
    static let folderFiles = 200

    static func kind(of head: Data) -> Kind? {
        guard let text = FlowBookmarksHTML.text(head) else { return nil }
        let trimmed = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        if trimmed.first == "{" { return .json }
        if FlowBookmarksHTML.isBookmarkFile(text) { return .bookmarks }
        if let header = PasswordCSV.firstRecord(String(trimmed)), PasswordCSV.columns(header) != nil {
            return .passwords
        }
        return nil
    }

    /// A `.zip` as Safari saves it, the folder it unzips to, or one of its
    /// files on its own.
    static func read(_ url: URL) throws -> SafariExport {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw Trouble.unreadable(url.lastPathComponent)
        }
        var export = SafariExport()
        if isFolder.boolValue {
            let fm = FileManager.default
            guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                throw Trouble.unreadable(url.lastPathComponent)
            }
            var seen = 0
            for case let file as URL in walk {
                if file.pathComponents.count - url.pathComponents.count > folderDepth { walk.skipDescendants(); continue }
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                seen += 1
                guard seen <= folderFiles else { break }
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let head = (try? handle.read(upToCount: sniffLength)) ?? Data()
                try? handle.close()
                export.files.append(file.lastPathComponent)
                guard let kind = kind(of: head) else { continue }
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
                    export.unreadable.append(file.lastPathComponent)
                    continue
                }
                export.take(data, kind: kind, name: file.lastPathComponent)
            }
        } else {
            let data: Data
            do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw Trouble.unreadable(url.lastPathComponent) }
            if let archive = try? SafariZip(data) {
                for entry in archive.entries {
                    let name = (entry.name as NSString).lastPathComponent
                    guard !entry.name.hasPrefix("__MACOSX/"), !name.hasPrefix("."), !entry.name.hasSuffix("/") else { continue }
                    export.files.append(name)
                    guard let body = try? archive.extract(entry) else { export.unreadable.append(name); continue }
                    guard let kind = kind(of: body.prefix(sniffLength)) else { continue }
                    export.take(body, kind: kind, name: name)
                }
            } else if let kind = kind(of: data.prefix(sniffLength)) {
                export.files.append(url.lastPathComponent)
                export.take(data, kind: kind, name: url.lastPathComponent)
            }
        }
        guard export.hasAnything else { throw Trouble.notAnExport }
        return export
    }

    /// One file, already sniffed. The first bookmark file and the first
    /// passwords file win; every history, cards and extensions file adds.
    mutating func take(_ data: Data, kind: Kind, name: String) {
        switch kind {
        case .bookmarks:
            guard bookmarksHTML == nil, let text = FlowBookmarksHTML.text(data) else { return }
            bookmarksHTML = text
        case .passwords:
            guard passwordsCSV == nil, let text = FlowBookmarksHTML.text(data) else { return }
            passwordsCSV = text
        case .json:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                unreadable.append(name)
                return
            }
            // A JSON file without Safari's metadata is someone else's.
            guard let meta = SafariExportMetadata(object) else { return }
            if exportedAt == nil { exportedAt = meta.exportedAt }
            if !meta.browserVersion.isEmpty { browser = "\(meta.browserName) \(meta.browserVersion)" }
            switch meta.dataType {
            case "history":
                guard let places = try? SafariHistoryJSON.places(object) else { unreadable.append(name); return }
                histories.append(History(file: name, places: places))
            case "payment_cards":
                cardCount += (object["payment_cards"] as? [Any])?.count ?? 0
            case "extensions":
                for item in object["extensions"] as? [[String: Any]] ?? [] {
                    let named = (item["display_name"] as? String) ?? (item["composed_identifier"] as? String) ?? ""
                    if !named.isEmpty, !extensions.contains(named) { extensions.append(named) }
                }
            default:
                return
            }
        }
    }
}

/// Just enough of the zip format to open Safari's export in this process —
/// handing the file to `ditto` or `unzip` would read it from another
/// process, which a file chosen in the open panel (or dropped) does not
/// cover. Stored and deflated entries, data descriptors and ZIP64 sizes.
struct SafariZip {
    struct Entry: Equatable {
        var name: String
        var method: Int
        var compressedSize: Int
        var size: Int
        var offset: Int
    }

    enum Trouble: Error { case notAZip, damaged, unsupported(Int), tooLarge }

    let bytes: [UInt8]
    let entries: [Entry]

    /// The most one entry may unpack to: far past any history file.
    static let ceiling = 1 << 30

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        guard bytes.count >= 22 else { throw Trouble.notAZip }
        // The end-of-central-directory record, searched from the end (a
        // comment of up to 64 KB may follow it).
        var end = -1
        var at = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while at >= floor {
            if Self.u32(bytes, at) == 0x0605_4b50 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw Trouble.notAZip }
        var count = Self.u16(bytes, end + 10)
        var directory = Self.u32(bytes, end + 16)
        if count == 0xFFFF || directory == 0xFFFF_FFFF {
            // ZIP64: the locator sits just before the record.
            let locator = end - 20
            guard locator >= 0, Self.u32(bytes, locator) == 0x0706_4b50 else { throw Trouble.damaged }
            let record = Self.u64(bytes, locator + 8)
            guard record >= 0, record + 56 <= bytes.count, Self.u32(bytes, record) == 0x0606_4b50 else { throw Trouble.damaged }
            count = Self.u64(bytes, record + 32)
            directory = Self.u64(bytes, record + 48)
        }
        var entries: [Entry] = []
        var cursor = directory
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, Self.u32(bytes, cursor) == 0x0201_4b50 else { throw Trouble.damaged }
            let method = Self.u16(bytes, cursor + 10)
            var compressed = Self.u32(bytes, cursor + 20)
            var size = Self.u32(bytes, cursor + 24)
            let nameLength = Self.u16(bytes, cursor + 28)
            let extraLength = Self.u16(bytes, cursor + 30)
            let commentLength = Self.u16(bytes, cursor + 32)
            var offset = Self.u32(bytes, cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength <= bytes.count else { throw Trouble.damaged }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            // ZIP64 extra field: the 64-bit values, in this order, for each
            // 32-bit field that was saturated.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = Self.u16(bytes, extra)
                let length = Self.u16(bytes, extra + 2)
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF, field + 8 <= extraEnd { size = Self.u64(bytes, field); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extraEnd { compressed = Self.u64(bytes, field); field += 8 }
                    if offset == 0xFFFF_FFFF, field + 8 <= extraEnd { offset = Self.u64(bytes, field) }
                }
                extra += 4 + length
            }
            entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size, offset: offset))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func extract(_ entry: Entry) throws -> Data {
        let local = entry.offset
        guard local >= 0, local + 30 <= bytes.count, Self.u32(bytes, local) == 0x0403_4b50 else { throw Trouble.damaged }
        let start = local + 30 + Self.u16(bytes, local + 26) + Self.u16(bytes, local + 28)
        guard entry.compressedSize >= 0, start + entry.compressedSize <= bytes.count else { throw Trouble.damaged }
        guard entry.size <= Self.ceiling else { throw Trouble.tooLarge }
        let raw = Data(bytes[start..<(start + entry.compressedSize)])
        switch entry.method {
        case 0:
            return raw
        case 8:
            // Foundation's .zlib is raw DEFLATE (RFC 1951) — what a zip holds.
            guard !raw.isEmpty else { return Data() }
            let out = try (raw as NSData).decompressed(using: .zlib) as Data
            guard out.count == entry.size || entry.size == 0 else { throw Trouble.damaged }
            return out
        default:
            throw Trouble.unsupported(entry.method)
        }
    }

    static func u16(_ bytes: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at + 2 <= bytes.count else { return 0 }
        var value = Int(bytes[at])
        value |= Int(bytes[at + 1]) << 8
        return value
    }

    static func u32(_ bytes: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at + 4 <= bytes.count else { return 0 }
        var value = 0
        for k in 0..<4 { value |= Int(bytes[at + k]) << (8 * k) }
        return value
    }

    static func u64(_ bytes: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at + 8 <= bytes.count else { return 0 }
        var value = 0
        for k in 0..<7 { value |= Int(bytes[at + k]) << (8 * k) }
        // A size past 2^56 is no export; keep the arithmetic in range.
        return bytes[at + 7] == 0 ? value : Int.max
    }
}
