import Foundation
import SQLite3
import Testing
@testable import Search

// Safari's formats (Fork/Flow/FlowSafariFormats.swift), each on a synthetic
// file built here: an export's bookmark file, history JSON (one per
// profile), passwords CSV (several headers), the zip itself under English
// and localized names, and Safari's own Bookmarks.plist, History.db and
// SafariTabs.db. No real browsing data is in this repo. The bookmark-file
// parser itself is tested in FlowBookmarksHTMLTests.swift.

/// A folder of its own per test, gone when the test is.
final class SafariScratch {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("copper-safari-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ text: String, _ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}

private func titles(_ nodes: [Bookmark]) -> [String] { nodes.map(\.title) }

// MARK: - fixtures

/// Synthetic Safari files, shared with the Move-in source's tests.
enum SafariFixture {
    /// Safari's export as Safari writes it: the Favorites bar, the menu, a
    /// nested folder, the Reading List by its id, entities, a bookmarklet.
    static let bookmarksHTML = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    \t<HTML>
    \t<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    \t<Title>Bookmarks</Title>
    \t<H1>Bookmarks</H1>
    \t<DT><H3 FOLDED>Favorites</H3>
    \t<DL><p>
    \t\t<DT><A HREF="https://example.com/">Example &amp; Co</A>
    \t\t<DT><H3 FOLDED>Work</H3>
    \t\t<DL><p>
    \t\t\t<DT><A HREF="https://docs.example.org/guide?a=1&amp;b=2">Guide &#8212; part 1</A>
    \t\t\t<DT><A HREF="javascript:alert(1)">Bookmarklet</A>
    \t\t</DL><p>
    \t</DL><p>
    \t<DT><H3 FOLDED>Bookmarks Menu</H3>
    \t<DL><p>
    \t\t<DT><A HREF="https://menu.example.net/">Menu item</A>
    \t</DL><p>
    \t<DT><H3>Empty</H3>
    \t<DL><p>
    \t</DL><p>
    \t<DT><A HREF="https://loose.example.com/" ADD_DATE="1700000000">Loose</A>
    \t<DT><H3 FOLDED id="com.apple.ReadingList">Reading List</H3>
    \t<DL><p>
    \t\t<DT><A HREF="https://read.example.com/one">Read one</A>
    \t\t<DD>A preview line
    \t\t<DT><A HREF="https://read.example.com/two">Read two</A>
    \t</DL><p>
    </HTML>
    """

    static func historyJSON(_ items: String, type: String = "history") -> String {
        """
        {"metadata":{"browser_name":"Safari","browser_version":"18.2","data_type":"\(type)","export_time_usec":1759840000000000,"schema_version":1},
         "\(type)":[\(items)]}
        """
    }

    static let historyItems = """
    {"url":"https://maps.example.com/","time_usec":1722367302951213,"destination_url":"https://www.example.com/maps/","destination_time_usec":1722367302951310,"visits_count":1},
    {"url":"https://www.example.com/maps/","time_usec":1722367302951310,"title":"Maps","source_url":"https://maps.example.com/","source_time_usec":1722367302951213,"visits_count":4},
    {"url":"https://www.example.com/maps/","time_usec":1722000000000000,"title":"Old maps","visits_count":9},
    {"url":"https://broken.example.com/","time_usec":1722367300000000,"visits_count":1,"latest_visit_was_load_failure":true},
    {"url":"https://form.example.com/post","time_usec":1722367300000000,"visits_count":1,"latest_visit_was_http_get":false},
    {"url":"https://twice.example.com/","time_usec":1722367300000000,"visits_count":2,"latest_visit_was_load_failure":true},
    {"url":"file:///Users/someone/page.html","time_usec":1722367300000000,"visits_count":3},
    {"url":"https://notitle.example.com/","time_usec":1722367000000000,"visits_count":1}
    """

    /// A second profile's history: one address of its own, and the maps
    /// page again — visited later, fewer times.
    static let workHistoryItems = """
    {"url":"https://work-only.example.com/","time_usec":1722367400000000,"title":"Work","visits_count":3},
    {"url":"https://www.example.com/maps/","time_usec":1722367500000000,"title":"Maps at work","visits_count":2}
    """

    static let passwordsCSV = "Title,URL,Username,Password,Notes,OTPAuth\nexample.com,https://example.com/,a,b,,\n"

    static let cardsJSON = """
    {"metadata":{"browser_name":"Safari","browser_version":"18.2","data_type":"payment_cards","export_time_usec":1759840000000000,"schema_version":1},
     "payment_cards":[{"card_number":"0000000000000000","card_name":"Test card"},{"card_number":"1111111111111111"}]}
    """

    static func extensionsJSON(_ name: String) -> String {
        """
        {"metadata":{"browser_name":"Safari","browser_version":"18.2","data_type":"extensions","export_time_usec":1759840000000000,"schema_version":1},
         "extensions":[{"composed_identifier":"com.example.blocker.extension (AB12CD34EF)","developer_name":"Example","display_name":"\(name)","marketplace_lookup":{"store_identifier":"123"}}]}
        """
    }

    /// An export of two profiles under the English names Safari uses.
    static func exportFolder(in scratch: SafariScratch) throws -> URL {
        let folder = try scratch.folder("Safari Export 2026-10-07")
        try scratch.write(bookmarksHTML, "Bookmarks.html", in: folder)
        try scratch.write(historyJSON(historyItems), "History.json", in: folder)
        try scratch.write(historyJSON(workHistoryItems), "History - Work.json", in: folder)
        try scratch.write(passwordsCSV, "Passwords.csv", in: folder)
        try scratch.write(cardsJSON, "PaymentCards.json", in: folder)
        try scratch.write(extensionsJSON("Example Blocker"), "Extensions.json", in: folder)
        try scratch.write(extensionsJSON("Example Blocker"), "Extensions - Work.json", in: folder)
        return folder
    }

    /// Safari's Bookmarks.plist: the History proxy, the bar with a nested
    /// folder and a bookmarklet, the menu, the Reading List (one item with
    /// only a fetched title) and a loose item.
    static func bookmarksPlist() throws -> Data {
        func leaf(_ url: String, _ title: String?, reading: Bool = false) -> [String: Any] {
            var node: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url,
                                       "WebBookmarkUUID": UUID().uuidString, "ReadingListNonSync": ["neverFetchMetadata": false]]
            if let title { node["URIDictionary"] = ["title": title] }
            if reading {
                node["ReadingList"] = ["DateAdded": Date(timeIntervalSince1970: 1_700_000_000), "PreviewText": "preview"]
                if title == nil { node["ReadingListNonSync"] = ["Title": "Fetched title", "neverFetchMetadata": false] }
            }
            return node
        }
        func list(_ title: String, _ children: [[String: Any]]) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "WebBookmarkUUID": UUID().uuidString, "Children": children]
        }
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList", "Title": "", "WebBookmarkFileVersion": 1,
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History", "WebBookmarkIdentifier": "History Bookmark Proxy Identifier"],
                list("BookmarksBar", [leaf("https://bar.example.com/", "Bar"), list("Folder", [leaf("https://deep.example.com/", "Deep"), leaf("javascript:void(0)", "JS")])]),
                list("BookmarksMenu", [leaf("https://menu.example.com/", "Menu")]),
                list("com.apple.ReadingList", [leaf("https://read.example.com/1", "One", reading: true), leaf("https://read.example.com/2", nil, reading: true)]),
                leaf("https://top.example.com/", "Top"),
            ],
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    static func exec(_ db: OpaquePointer, _ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        if status != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "\(status)"
            sqlite3_free(error)
            Issue.record("sqlite: \(message) in \(sql.prefix(80))")
        }
    }

    static func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileReadUnknown) }
        return db
    }

    /// 2026-08-01 12:00 UTC on the Core Data clock.
    static let august: Double = 807_278_400

    /// History.db in WAL mode, left open (the caller closes it). Three web
    /// places survive the filters; the newest rows are not web pages.
    static func historyDB(at url: URL) throws -> OpaquePointer {
        let db = try open(url)
        exec(db, "PRAGMA journal_mode=WAL")
        exec(db, """
        CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT,url TEXT NOT NULL UNIQUE,domain_expansion TEXT NULL,visit_count INTEGER NOT NULL,daily_visit_counts BLOB NOT NULL,weekly_visit_counts BLOB NULL,autocomplete_triggers BLOB NULL,should_recompute_derived_visit_counts INTEGER NOT NULL,visit_count_score INTEGER NOT NULL,status_code INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT,history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,visit_time REAL NOT NULL,title TEXT NULL,load_successful BOOLEAN NOT NULL DEFAULT 1,http_non_get BOOLEAN NOT NULL DEFAULT 0,synthesized BOOLEAN NOT NULL DEFAULT 0,redirect_source INTEGER NULL UNIQUE REFERENCES history_visits(id) ON DELETE CASCADE,redirect_destination INTEGER NULL UNIQUE REFERENCES history_visits(id) ON DELETE CASCADE,origin INTEGER NOT NULL DEFAULT 0,generation INTEGER NOT NULL DEFAULT 0,attributes INTEGER NOT NULL DEFAULT 0,score INTEGER NOT NULL DEFAULT 0);
        """)
        let rows: [(Int, String, Int)] = [
            (1, "https://news.example.com/", 12),
            (2, "http://short.example/abc", 1),        // only ever a redirect's first hop
            (3, "https://landing.example.com/", 1),
            (4, "https://down.example.com/", 1),       // only a failed load
            (5, "https://form.example.com/submit", 1), // only a POST
            (6, "favorites://", 3),                    // not a web page, and the newest visit
            (7, "https://synced.example.com/", 5),     // visited on another device
            (8, "https:///no-host", 2),                // looks like the web, isn't
        ]
        for (id, url, count) in rows {
            exec(db, "INSERT INTO history_items (id, url, visit_count, daily_visit_counts, should_recompute_derived_visit_counts, visit_count_score) VALUES (\(id), '\(url)', \(count), x'00', 0, 0)")
        }
        exec(db, """
        INSERT INTO history_visits (id, history_item, visit_time, title) VALUES (1, 1, \(august - 86400), 'Older news title');
        INSERT INTO history_visits (id, history_item, visit_time, title) VALUES (2, 1, \(august), 'News');
        INSERT INTO history_visits (id, history_item, visit_time, title) VALUES (3, 1, \(august + 60), NULL);
        INSERT INTO history_visits (id, history_item, visit_time, title, redirect_destination) VALUES (4, 2, \(august + 100), NULL, 5);
        INSERT INTO history_visits (id, history_item, visit_time, title, redirect_source) VALUES (5, 3, \(august + 100.5), 'Landing', 4);
        INSERT INTO history_visits (id, history_item, visit_time, title, load_successful) VALUES (6, 4, \(august + 200), 'Down', 0);
        INSERT INTO history_visits (id, history_item, visit_time, title, http_non_get) VALUES (7, 5, \(august + 300), 'Thanks', 1);
        INSERT INTO history_visits (id, history_item, visit_time, title) VALUES (8, 6, \(august + 400), 'Favorites');
        INSERT INTO history_visits (id, history_item, visit_time, title, origin) VALUES (9, 7, \(august - 500), 'Synced', 1);
        INSERT INTO history_visits (id, history_item, visit_time, title) VALUES (10, 8, \(august + 500), 'No host');
        """)
        return db
    }

    /// A store shaped like Safari 18–26's: the root, two profiles (default and
    /// "Work"), the special folders, three windows (one private, one closed),
    /// a local tab group per window, named tab groups (one with its start-page
    /// favourites list, one empty, one in the Work profile) and pinned tabs.
    static func tabsDB(at url: URL) throws {
        let db = try open(url)
        defer { sqlite3_close(db) }
        exec(db, """
        CREATE TABLE bookmarks (id INTEGER PRIMARY KEY AUTOINCREMENT,special_id INTEGER DEFAULT 0,parent INTEGER, type INTEGER,title TEXT,url TEXT COLLATE NOCASE,num_children INTEGER DEFAULT 0,editable INTEGER DEFAULT 1,deletable INTEGER DEFAULT 1,hidden INTEGER DEFAULT 0,hidden_ancestor_count INTEGER DEFAULT 0,order_index INTEGER NOT NULL,external_uuid TEXT UNIQUE,read INTEGER DEFAULT NULL,last_modified REAL DEFAULT NULL,server_id TEXT, sync_key TEXT,sync_data BLOB,added INTEGER DEFAULT 1,deleted INTEGER DEFAULT 0,extra_attributes BLOB DEFAULT NULL,local_attributes BLOB DEFAULT NULL,fetched_icon BOOL DEFAULT 0, icon BLOB DEFAULT NULL,dav_generation INTEGER DEFAULT 0,locally_added BOOL DEFAULT 0,archive_status INTEGER DEFAULT 0,syncable BOOL DEFAULT 1,web_filter_status INTEGER DEFAULT 0, modified_attributes UNSIGNED BIG INT DEFAULT 0, date_closed REAL DEFAULT NULL, last_selected_child INTEGER DEFAULT NULL, subtype INTEGER DEFAULT 0, cookies_uuid TEXT DEFAULT NULL, local_storage_uuid TEXT DEFAULT NULL, session_storage_uuid TEXT DEFAULT NULL, is_marked_for_expiration INTEGER, topic_title TEXT, feature_text TEXT, fetched_feature_text BOOL DEFAULT 0);
        CREATE TABLE windows (id INTEGER PRIMARY KEY,active_tab_group_id INTEGER DEFAULT NULL,active_profile_id INTEGER DEFAULT NULL,date_closed REAL DEFAULT NULL,extra_attributes BLOB DEFAULT NULL,is_last_session INTEGER DEFAULT 0,local_tab_group_id INTEGER DEFAULT NULL,private_tab_group_id INTEGER DEFAULT NULL,scene_id TEXT DEFAULT NULL,uuid TEXT NOT NULL UNIQUE,restoration_archive BLOB DEFAULT NULL);
        CREATE TABLE windows_tab_groups (id INTEGER PRIMARY KEY,active_tab_id INTEGER DEFAULT NULL,tab_group_id INTEGER NOT NULL,window_id INTEGER NOT NULL,UNIQUE (tab_group_id, window_id));
        CREATE TABLE windows_profiles (id INTEGER PRIMARY KEY,active_tab_group_id INTEGER DEFAULT NULL,profile_id INTEGER NOT NULL,window_id INTEGER NOT NULL,UNIQUE (profile_id, window_id));
        CREATE TABLE windows_unnamed_tab_groups (id INTEGER PRIMARY KEY,tab_group_id INTEGER NOT NULL,window_id INTEGER NOT NULL,UNIQUE (tab_group_id, window_id));
        """)
        func folder(_ id: Int, parent: String, title: String, uuid: String, subtype: Int = 0, hidden: Int = 0, order: Int = 0, lastSelected: String = "NULL") {
            exec(db, "INSERT INTO bookmarks (id, parent, type, subtype, title, external_uuid, hidden, order_index, last_selected_child) VALUES (\(id), \(parent), 1, \(subtype), '\(title)', '\(uuid)', \(hidden), \(order), \(lastSelected))")
        }
        func tab(_ id: Int, parent: Int, url: String, title: String, order: Int, deleted: Int = 0) {
            exec(db, "INSERT INTO bookmarks (id, parent, type, title, url, order_index, external_uuid, deleted) VALUES (\(id), \(parent), 0, '\(title)', '\(url)', \(order), '\(UUID().uuidString)', \(deleted))")
        }
        folder(0, parent: "NULL", title: "Root", uuid: "Root")
        folder(1, parent: "NULL", title: "Recovered", uuid: "11111111-0000-0000-0000-000000000001", hidden: 1)
        folder(2, parent: "NULL", title: "pinned", uuid: "pinned", hidden: 1)
        folder(3, parent: "NULL", title: "privatePinned", uuid: "privatePinned", hidden: 1)
        folder(4, parent: "NULL", title: "recentlyClosed", uuid: "recentlyClosed", hidden: 1)
        folder(5, parent: "0", title: "", uuid: "DefaultProfile", subtype: 2)
        folder(6, parent: "0", title: "Work", uuid: "22222222-0000-0000-0000-000000000006", subtype: 2, order: 1)
        // Window 1's local tab group, its three tabs (one deleted, one not a web page).
        folder(38, parent: "NULL", title: "Local", uuid: "AAAAAAAA-0000-0000-0000-000000000038", hidden: 1)
        tab(100, parent: 38, url: "https://one.example.com/", title: "One", order: 0)
        tab(101, parent: 38, url: "https://two.example.com/", title: "Two", order: 1)
        tab(102, parent: 38, url: "https://gone.example.com/", title: "Gone", order: 2, deleted: 1)
        tab(103, parent: 38, url: "favorites://", title: "Start Page", order: 3)
        // Window 2 is private: its group is never read.
        folder(39, parent: "NULL", title: "Private", uuid: "AAAAAAAA-0000-0000-0000-000000000039", hidden: 1)
        tab(110, parent: 39, url: "https://secret.example.com/", title: "Secret", order: 0)
        // Window 3 shows the Work profile; its unnamed group is in windows_unnamed_tab_groups.
        folder(41, parent: "NULL", title: "Local", uuid: "AAAAAAAA-0000-0000-0000-000000000041", hidden: 1)
        tab(120, parent: 41, url: "https://work.example.com/", title: "Work home", order: 0)
        // Window 4 was closed before the last session ended.
        folder(42, parent: "NULL", title: "Local", uuid: "AAAAAAAA-0000-0000-0000-000000000042", hidden: 1)
        tab(130, parent: 42, url: "https://closed.example.com/", title: "Closed", order: 0)
        // Named tab groups.
        folder(50, parent: "0", title: "Research", uuid: "BBBBBBBB-0000-0000-0000-000000000050", order: 2, lastSelected: "141")
        tab(140, parent: 50, url: "https://paper.example.org/", title: "Paper", order: 0)
        tab(141, parent: 50, url: "https://data.example.org/", title: "Data", order: 1)
        folder(51, parent: "50", title: "TopScopedBookmarkList", uuid: "CCCCCCCC-0000-0000-0000-000000000051", subtype: 1)
        tab(150, parent: 51, url: "https://startpage-favourite.example.org/", title: "Start-page favourite", order: 0)
        folder(52, parent: "0", title: "Empty group", uuid: "BBBBBBBB-0000-0000-0000-000000000052", order: 3)
        folder(53, parent: "6", title: "Errands", uuid: "BBBBBBBB-0000-0000-0000-000000000053", order: 0)
        tab(160, parent: 53, url: "https://shop.example.com/", title: "Shop", order: 0)
        // Pinned tabs, one twice; a private pinned tab and a recently closed tab, never read.
        tab(170, parent: 2, url: "https://mail.example.com/", title: "Mail", order: 0)
        tab(171, parent: 2, url: "https://cal.example.com/", title: "Calendar", order: 1)
        tab(172, parent: 2, url: "https://mail.example.com/", title: "Mail again", order: 2)
        tab(180, parent: 3, url: "https://private-pin.example.com/", title: "Private pin", order: 0)
        tab(190, parent: 4, url: "https://closed-tab.example.com/", title: "Closed tab", order: 0)

        let privateExtra = try PropertyListSerialization.data(fromPropertyList: ["IsPrivateWindow": true], format: .binary, options: 0)
        let plainExtra = try PropertyListSerialization.data(fromPropertyList: ["IsPrivateWindow": false], format: .binary, options: 0)
        func window(_ id: Int, local: Int, profile: Int, extra: Data, closed: Bool, last: Int) {
            var statement: OpaquePointer?
            let sql = "INSERT INTO windows (id, active_tab_group_id, active_profile_id, date_closed, extra_attributes, is_last_session, local_tab_group_id, uuid) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_int(statement, 1, Int32(id))
            sqlite3_bind_int(statement, 2, Int32(local))
            sqlite3_bind_int(statement, 3, Int32(profile))
            if closed { sqlite3_bind_double(statement, 4, august) } else { sqlite3_bind_null(statement, 4) }
            _ = extra.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(extra.count), transient) }
            sqlite3_bind_int(statement, 6, Int32(last))
            sqlite3_bind_int(statement, 7, Int32(local))
            sqlite3_bind_text(statement, 8, "WINDOW-\(id)", -1, transient)
            sqlite3_step(statement)
        }
        window(1, local: 38, profile: 5, extra: plainExtra, closed: false, last: 1)
        window(2, local: 39, profile: 5, extra: privateExtra, closed: false, last: 1)
        window(3, local: 0, profile: 6, extra: plainExtra, closed: true, last: 1)
        window(4, local: 42, profile: 5, extra: plainExtra, closed: true, last: 0)
        exec(db, """
        UPDATE windows SET local_tab_group_id = NULL WHERE id = 3;
        INSERT INTO windows_unnamed_tab_groups (tab_group_id, window_id) VALUES (41, 3);
        INSERT INTO windows_profiles (profile_id, window_id, active_tab_group_id) VALUES (6, 3, 41);
        INSERT INTO windows_tab_groups (tab_group_id, window_id, active_tab_id) VALUES (38, 1, 101);
        """)
    }
}

// MARK: - bookmarks

@Suite struct SafariBookmarksTests {
    @Test func plistReadsBarMenuReadingListAndTheRest() throws {
        let sections = try SafariBookmarksPlist.read(try SafariFixture.bookmarksPlist())
        #expect(titles(sections.bar) == ["Bar", "Folder"])
        #expect(sections.bar[1].children?.map(\.title) == ["Deep"])
        #expect(titles(sections.menu) == ["Menu"])
        #expect(titles(sections.readingList) == ["One", "Fetched title"])
        #expect(titles(sections.other) == ["Top"])
        #expect(sections.bookmarkCount == 4)
        #expect(sections.readingListCount == 2)
    }

    @Test func plistLandsInSafarisLayout() throws {
        let tree = try SafariBookmarksPlist.read(try SafariFixture.bookmarksPlist()).tree(.safari)
        #expect(titles(tree) == ["Bar", "Folder", "Bookmarks Menu", "Top", "Reading List"])
    }

    @Test func plistRefusesSomethingElse() {
        #expect(throws: (any Error).self) { try SafariBookmarksPlist.read(Data("not a plist".utf8)) }
        #expect(throws: (any Error).self) {
            try SafariBookmarksPlist.read(try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0))
        }
    }

    @Test func theLibraryFileWinsOverTheExport() throws {
        let scratch = try SafariScratch()
        let plist = scratch.root.appendingPathComponent("Bookmarks.plist")
        try SafariFixture.bookmarksPlist().write(to: plist)
        let found = try #require(SafariBookmarks.pick(library: plist, exportHTML: SafariFixture.bookmarksHTML))
        #expect(found.origin == .library)
        #expect(found.read.complete)
        #expect(titles(found.read.nodes) == ["Bar", "Folder", "Bookmarks Menu", "Top", "Reading List"])
        #expect(found.sections.bookmarkCount == 4)
    }

    @Test func withoutTheLibraryTheExportIsRead() throws {
        let scratch = try SafariScratch()
        let absent = scratch.root.appendingPathComponent("Bookmarks.plist")
        for library in [nil, absent] {
            let found = try #require(SafariBookmarks.pick(library: library, exportHTML: SafariFixture.bookmarksHTML))
            #expect(found.origin == .export)
            #expect(found.read.complete)
            #expect(titles(found.read.nodes) == ["Example & Co", "Work", "Bookmarks Menu", "Loose", "Reading List"])
            #expect(found.sections.bookmarkCount == 4)
            #expect(found.sections.readingListCount == 2)
        }
    }

    @Test func aDamagedLibraryFileFallsBackToTheExport() throws {
        let scratch = try SafariScratch()
        let plist = try scratch.write("not a plist", "Bookmarks.plist")
        let found = try #require(SafariBookmarks.pick(library: plist, exportHTML: SafariFixture.bookmarksHTML))
        #expect(found.origin == .export)
        #expect(found.read.complete)
    }

    @Test func noBookmarkFileMeansNoTake() throws {
        // A passwords-only export: nothing to hand FlowBookmarks.take, so the
        // last Safari move's bookmarks are left alone.
        let scratch = try SafariScratch()
        #expect(SafariBookmarks.pick(library: nil, exportHTML: nil) == nil)
        #expect(SafariBookmarks.pick(library: scratch.root.appendingPathComponent("Bookmarks.plist"), exportHTML: nil) == nil)
        #expect(SafariBookmarks.pick(library: nil, exportHTML: "Title,URL,Username,Password\n") == nil)
    }

    @Test func aDamagedLibraryFileAloneIsAFailedRead() throws {
        let scratch = try SafariScratch()
        let plist = try scratch.write("not a plist", "Bookmarks.plist")
        let found = try #require(SafariBookmarks.pick(library: plist, exportHTML: nil))
        #expect(!found.read.complete)
        #expect(found.read.failedFiles == [plist])
        #expect(found.read.nodes.isEmpty)
    }
}

// MARK: - History.json

@Suite struct SafariHistoryJSONTests {
    @Test func readsPlacesSkippingRedirectHopsFailuresAndPosts() throws {
        let places = try SafariHistoryJSON.places(Data(SafariFixture.historyJSON(SafariFixture.historyItems).utf8))
        let byURL = Dictionary(uniqueKeysWithValues: places.map { ($0.url.absoluteString, $0) })
        #expect(Set(byURL.keys) == ["https://www.example.com/maps/", "https://twice.example.com/", "https://notitle.example.com/"])
        let maps = try #require(byURL["https://www.example.com/maps/"])
        #expect(maps.count == 9) // the larger of the two rows
        #expect(maps.title == "Maps") // the newer row's title
        #expect(abs(maps.last.timeIntervalSince1970 - 1_722_367_302.951310) < 0.001)
        #expect(byURL["https://notitle.example.com/"]?.title == "")
        #expect(places.first?.url.absoluteString == "https://www.example.com/maps/") // newest first
    }

    @Test func readsTheMetadata() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(SafariFixture.historyJSON("").utf8)) as? [String: Any])
        let meta = try #require(SafariExportMetadata(object))
        #expect(meta.browserVersion == "18.2")
        #expect(meta.dataType == "history")
        #expect(meta.schemaVersion == 1)
        #expect(meta.exportedAt.map { Int($0.timeIntervalSince1970) } == 1_759_840_000)
    }

    @Test func refusesAnotherKindOfFile() {
        #expect(throws: (any Error).self) { try SafariHistoryJSON.places(Data(SafariFixture.historyJSON("", type: "extensions").utf8)) }
        #expect(throws: (any Error).self) { try SafariHistoryJSON.places(Data("[1,2]".utf8)) }
    }
}

// MARK: - Passwords.csv

/// Safari's passwords CSV through the one CSV module, `PasswordCSV`
/// (Fork/Credentials/PasswordCSV.swift): Move in reads no CSV of its own.
@Suite struct SafariPasswordsCSVTests {
    /// Safari's header, with a byte-order mark, CRLF line ends, a quoted
    /// comma, a doubled quote, a newline inside a note, a code, and two rows
    /// that cannot be kept (no password; no site).
    let safari = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\n"
        + "example.com (a@example.com),https://example.com/login,a@example.com,\"p,ss\"\"word\",\"line one\r\nline two\",otpauth://totp/x?secret=ABC\r\n"
        + "www.example.org,https://www.example.org/,bob,hunter2,,\r\n"
        + "nopass.example.com,https://nopass.example.com/,carol,,,\r\n"
        + "no site,,dave,secret,,\r\n"

    @Test func readsSafarisHeader() {
        let summary = PasswordCSV.summary(safari)
        #expect(summary.understood)
        #expect(summary.logins == 2)
        #expect(summary.skipped == 2)
        #expect(summary.withCodes == 1)
        #expect(summary.withNotes == 1)
        #expect(PasswordCSV.accounts(safari) == ["example.com\u{1}a@example.com", "example.org\u{1}bob"])
    }

    @Test func parsesQuotesAndNewlines() {
        let rows = PasswordCSV.parse(safari)
        #expect(rows.count == 5)
        #expect(rows[0].first == "Title") // the mark is gone
        #expect(rows[1][3] == "p,ss\"word")
        #expect(rows[1][4] == "line one\r\nline two")
    }

    @Test func understandsOtherHeaders() {
        let headers: [(String, Bool)] = [
            ("name,url,username,password,note", true),                                       // Chrome's
            ("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes", true),       // a password manager's
            ("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp", true),
            ("\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\"", true),
            ("Title,Web Site,User Name,Password", true),
            ("Title,Web Address,Email Address,Password", true),
            ("site,secret", false),
        ]
        for (header, understood) in headers {
            let columns = PasswordCSV.columns(PasswordCSV.parse(header).first ?? [])
            #expect((columns != nil) == understood, "\(header)")
        }
        let manager = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"
            + ",,login,Example,,,0,https://example.com,alice,pw1,otpauth://totp/a?secret=B\n"
        let summary = PasswordCSV.summary(manager)
        #expect(summary.logins == 1)
        #expect(summary.withCodes == 1)
    }

    @Test func canonicalFormIsWhatTheVaultImportReads() throws {
        let canonical = try #require(PasswordCSV.canonical(safari))
        let rows = PasswordCSV.parse(canonical)
        #expect(rows.first == ["url", "username", "password"])
        #expect(rows.count == 3)
        #expect(rows[1] == ["https://example.com/login", "a@example.com", "p,ss\"word"])
        #expect(PasswordCSV.canonical("site,secret\na,b\n") == nil)
    }
}

// MARK: - History.db

@Suite struct SafariHistoryDBTests {
    @Test func readsPlacesFromACopyIncludingTheWAL() throws {
        let scratch = try SafariScratch()
        let file = scratch.root.appendingPathComponent("History.db")
        let db = try SafariFixture.historyDB(at: file)
        // Still open: the rows sit in History.db-wal, as they do while Safari runs.
        defer { sqlite3_close(db) }
        #expect(FileManager.default.fileExists(atPath: file.path + "-wal"))
        let places = try SafariHistoryDB.places(at: file)
        #expect(places.map(\.url.absoluteString) == ["https://landing.example.com/", "https://news.example.com/", "https://synced.example.com/"])
        let news = try #require(places.first { $0.url.host() == "news.example.com" })
        #expect(news.count == 12)
        #expect(news.title == "News") // newest visit with a title
        #expect(abs(news.last.timeIntervalSinceReferenceDate - (SafariFixture.august + 60)) < 0.001)
    }

    @Test func theLimitCountsWebPagesOnly() throws {
        // The two newest rows aren't web pages; a limit taken before the web
        // filter came back empty.
        let scratch = try SafariScratch()
        let file = scratch.root.appendingPathComponent("History.db")
        let db = try SafariFixture.historyDB(at: file)
        defer { sqlite3_close(db) }
        #expect(try SafariHistoryDB.places(at: file, limit: 1).map(\.url.absoluteString) == ["https://landing.example.com/"])
        #expect(try SafariHistoryDB.places(at: file, limit: 2).count == 2)
        #expect(try SafariHistoryDB.places(at: file, limit: 99).count == 3)
        #expect(try SafariHistoryDB.places(at: file, limit: 0).isEmpty)
    }

    @Test func leavesTheOriginalUntouched() throws {
        let scratch = try SafariScratch()
        let file = scratch.root.appendingPathComponent("History.db")
        sqlite3_close(try SafariFixture.historyDB(at: file))
        let before = try Data(contentsOf: file)
        _ = try SafariHistoryDB.places(at: file)
        #expect(try Data(contentsOf: file) == before)
        #expect(throws: (any Error).self) { try SafariHistoryDB.places(at: scratch.root.appendingPathComponent("nope.db")) }
    }

    @Test func mergesListsByAddress() {
        let url = URL(string: "https://a.example.com/")!
        let old = Chromium.Place(url: url, title: "Old", count: 9, last: Date(timeIntervalSince1970: 100))
        let new = Chromium.Place(url: url, title: "New", count: 2, last: Date(timeIntervalSince1970: 200))
        let untitled = Chromium.Place(url: url, title: "", count: 1, last: Date(timeIntervalSince1970: 300))
        let merged = SafariHistoryDB.merged([[old], [new], [untitled]])
        #expect(merged.count == 1)
        #expect(merged[0].count == 9)
        #expect(merged[0].title == "New") // the newest visit had no title
        #expect(merged[0].last == Date(timeIntervalSince1970: 300))
    }
}

// MARK: - SafariTabs.db

@Suite struct SafariTabsDBTests {
    @Test func readsWindowsTabGroupsAndPins() throws {
        let scratch = try SafariScratch()
        let file = scratch.root.appendingPathComponent("SafariTabs.db")
        try SafariFixture.tabsDB(at: file)
        let haul = try SafariTabsDB.read(at: file)

        #expect(haul.spaces.map(\.space.name) == ["Safari", "Safari · Work", "Research", "Errands"])
        #expect(haul.spaces.map(\.key) == ["AAAAAAAA-0000-0000-0000-000000000038", "AAAAAAAA-0000-0000-0000-000000000041",
                                           "BBBBBBBB-0000-0000-0000-000000000050", "BBBBBBBB-0000-0000-0000-000000000053"])
        let first = haul.spaces[0].space
        // Pins ride with the first space, each address once.
        #expect(first.tabs.map(\.title) == ["Mail", "Calendar", "One", "Two"])
        #expect(first.tabs.map(\.pinned) == [true, true, false, false])
        #expect(first.tabs.first { $0.title == "Two" }?.active == true)
        #expect(first.tabs.allSatisfy { $0.seen == nil })
        #expect(haul.spaces[1].space.tabs.map(\.title) == ["Work home"])
        #expect(haul.spaces[2].space.tabs.map(\.title) == ["Paper", "Data"])
        #expect(haul.spaces[2].space.tabs.last?.active == true)
        #expect(haul.spaces[3].space.tabs.map(\.title) == ["Shop"])
        #expect(haul.pinned == 2)
        #expect(haul.windows == 2)
        #expect(haul.privateWindows == 1)
        #expect(haul.tabGroups == 3)
        #expect(haul.emptyGroups == 1)
        #expect(haul.profiles == ["Work"])
        #expect(haul.tabCount == 8)
        let everything = haul.spaces.flatMap(\.space.tabs).map { $0.url.host() ?? "" }
        for never in ["secret.example.com", "gone.example.com", "closed.example.com", "private-pin.example.com",
                      "closed-tab.example.com", "startpage-favourite.example.org"] {
            #expect(!everything.contains(never), "\(never)")
        }
    }

    @Test func onlyPinsStillMakeASpace() throws {
        let scratch = try SafariScratch()
        let file = scratch.root.appendingPathComponent("SafariTabs.db")
        let db = try SafariFixture.open(file)
        SafariFixture.exec(db, """
        CREATE TABLE bookmarks (id INTEGER PRIMARY KEY, parent INTEGER, type INTEGER, subtype INTEGER DEFAULT 0, title TEXT, url TEXT, order_index INTEGER NOT NULL, external_uuid TEXT, deleted INTEGER DEFAULT 0, last_selected_child INTEGER, extra_attributes BLOB);
        INSERT INTO bookmarks (id, parent, type, title, order_index, external_uuid) VALUES (2, NULL, 1, 'pinned', 0, 'pinned');
        INSERT INTO bookmarks (id, parent, type, title, url, order_index, external_uuid) VALUES (3, 2, 0, 'Mail', 'https://mail.example.com/', 0, 'X');
        """)
        sqlite3_close(db)
        let haul = try SafariTabsDB.read(at: file)
        #expect(haul.spaces.map(\.space.name) == ["Safari"])
        #expect(haul.spaces.first?.key == "pins")
        #expect(haul.pinned == 1)
    }
}

// MARK: - the export, zipped and not

private func run(_ tool: String, _ arguments: [String], in folder: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Suite struct SafariExportTests {
    private func check(_ export: SafariExport) {
        #expect(export.bookmarksHTML != nil)
        #expect(export.histories.count == 2)
        #expect(export.passwordsCSV != nil)
        #expect(export.cardCount == 2)
        #expect(export.extensions == ["Example Blocker"]) // one per profile, named once
        #expect(export.browser == "Safari 18.2")
        #expect(export.exportedAt.map { Int($0.timeIntervalSince1970) } == 1_759_840_000)
        #expect(export.unreadable.isEmpty)
    }

    @Test func readsTheUnzippedFolder() throws {
        let scratch = try SafariScratch()
        check(try SafariExport.read(try SafariFixture.exportFolder(in: scratch)))
    }

    @Test func readsADeflatedZipWithAFolderInside() throws {
        let scratch = try SafariScratch()
        let folder = try SafariFixture.exportFolder(in: scratch)
        let zip = scratch.root.appendingPathComponent("Safari Export.zip")
        // ditto writes deflated entries with data descriptors.
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path], in: scratch.root)
        let archive = try SafariZip(try Data(contentsOf: zip))
        #expect(archive.entries.contains { $0.method == 8 })
        check(try SafariExport.read(zip))
    }

    @Test func readsAStoredZip() throws {
        let scratch = try SafariScratch()
        let folder = try SafariFixture.exportFolder(in: scratch)
        let zip = scratch.root.appendingPathComponent("stored.zip")
        try run("/usr/bin/zip", ["-0", "-q", "-r", zip.path, "."], in: folder)
        let archive = try SafariZip(try Data(contentsOf: zip))
        #expect(archive.entries.allSatisfy { $0.method == 0 || $0.name.hasSuffix("/") })
        check(try SafariExport.read(zip))
    }

    @Test func everyProfilesHistoryIsReadAndMerged() throws {
        let scratch = try SafariScratch()
        let export = try SafariExport.read(try SafariFixture.exportFolder(in: scratch))
        #expect(Set(export.histories.map(\.file)) == ["History.json", "History - Work.json"])
        let places = export.places
        let byURL = Dictionary(uniqueKeysWithValues: places.map { ($0.url.absoluteString, $0) })
        #expect(places.count == 4)
        #expect(byURL["https://work-only.example.com/"]?.count == 3)
        let maps = try #require(byURL["https://www.example.com/maps/"])
        #expect(maps.count == 9)                 // the larger count, from the default profile
        #expect(maps.title == "Maps at work")    // the newer visit, from Work
        #expect(places.first?.url.absoluteString == "https://www.example.com/maps/")
    }

    @Test func filesAreKnownByWhatTheyHoldNotTheirNames() throws {
        // A German export: localized names, one with no extension at all, plus
        // things that aren't Safari's (a JSON without metadata, a text file,
        // a CSV that isn't passwords) under names that sound like they are.
        let scratch = try SafariScratch()
        let folder = try scratch.folder("Safari-Export")
        try scratch.write(SafariFixture.bookmarksHTML, "Lesezeichen.html", in: folder)
        try scratch.write(SafariFixture.historyJSON(SafariFixture.historyItems), "Verlauf.json", in: folder)
        try scratch.write(SafariFixture.historyJSON(SafariFixture.workHistoryItems), "Verlauf – Arbeit.json", in: folder)
        try scratch.write(SafariFixture.passwordsCSV, "Passwörter", in: folder)
        try scratch.write(SafariFixture.cardsJSON, "Zahlungskarten.json", in: folder)
        try scratch.write(SafariFixture.extensionsJSON("Example Blocker"), "Erweiterungen.json", in: folder)
        try scratch.write("{\"history\":[{\"url\":\"https://not-safari.example.com/\"}]}", "History.json", in: folder)
        try scratch.write("just some notes", "Bookmarks.html", in: folder)
        try scratch.write("a,b,c\n1,2,3\n", "Passwords.csv", in: folder)
        let zip = scratch.root.appendingPathComponent("Safari-Export.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path], in: scratch.root)
        for source in [folder, zip] {
            let export = try SafariExport.read(source)
            #expect(export.bookmarksHTML?.contains("Reading List") == true, "\(source.lastPathComponent)")
            #expect(Set(export.histories.map(\.file)) == ["Verlauf.json", "Verlauf – Arbeit.json"], "\(source.lastPathComponent)")
            #expect(export.passwordsCSV == SafariFixture.passwordsCSV, "\(source.lastPathComponent)")
            #expect(export.cardCount == 2)
            #expect(export.extensions == ["Example Blocker"])
            #expect(export.files.count == 9)
        }
    }

    @Test func oneFileOnItsOwnIsAnExportOfThatFile() throws {
        let scratch = try SafariScratch()
        let bookmarks = try scratch.write(SafariFixture.bookmarksHTML, "Bookmarks.html")
        let alone = try SafariExport.read(bookmarks)
        #expect(alone.bookmarksHTML != nil)
        #expect(alone.passwordsCSV == nil && alone.histories.isEmpty)
        let passwords = try scratch.write(SafariFixture.passwordsCSV, "Passwords.csv")
        let only = try SafariExport.read(passwords)
        #expect(only.passwordsCSV != nil)
        // A passwords-only export has no bookmark file: no bookmarks take.
        #expect(SafariBookmarks.pick(library: nil, exportHTML: only.bookmarksHTML) == nil)
    }

    @Test func aHistoryFileThatDoesNotReadIsNamed() throws {
        let scratch = try SafariScratch()
        let folder = try scratch.folder("export")
        try scratch.write(SafariFixture.bookmarksHTML, "Bookmarks.html", in: folder)
        try scratch.write("{\"metadata\":{\"data_type\":\"history\"},\"history\":7}", "History.json", in: folder)
        try scratch.write("{\"metadata\":{\"data_type\":\"history\"},\"history\":[", "History - Work.json", in: folder)
        let export = try SafariExport.read(folder)
        #expect(export.histories.isEmpty)
        #expect(Set(export.unreadable) == ["History.json", "History - Work.json"])
    }

    @Test func refusesWhatIsNotAnExport() throws {
        let scratch = try SafariScratch()
        let folder = try scratch.folder("stuff")
        try scratch.write("hello", "notes.txt", in: folder)
        try scratch.write("{\"a\":1}", "data.json", in: folder)
        let zip = scratch.root.appendingPathComponent("stuff.zip")
        try run("/usr/bin/ditto", ["-c", "-k", folder.path, zip.path], in: scratch.root)
        #expect(throws: SafariExport.Trouble.self) { try SafariExport.read(zip) }
        #expect(throws: SafariExport.Trouble.self) { try SafariExport.read(folder) }
        #expect(throws: SafariExport.Trouble.self) { try SafariExport.read(try scratch.write("not a zip at all", "fake.zip")) }
        #expect(throws: SafariExport.Trouble.self) { try SafariExport.read(scratch.root.appendingPathComponent("missing.zip")) }
        #expect(throws: (any Error).self) { try SafariZip(Data("not a zip at all, not even close".utf8)) }
    }

    @Test func sniffsKinds() {
        #expect(SafariExport.kind(of: Data("  \n{\"metadata\":{}}".utf8)) == .json)
        #expect(SafariExport.kind(of: Data("\u{FEFF}{}".utf8)) == .json)
        #expect(SafariExport.kind(of: Data(SafariFixture.bookmarksHTML.utf8)) == .bookmarks)
        #expect(SafariExport.kind(of: Data(("\u{FEFF}" + SafariFixture.passwordsCSV).utf8)) == .passwords)
        #expect(SafariExport.kind(of: Data("a,b,c\n".utf8)) == nil)
        #expect(SafariExport.kind(of: Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF])) == nil)
        #expect(SafariExport.kind(of: Data()) == nil)
    }
}
