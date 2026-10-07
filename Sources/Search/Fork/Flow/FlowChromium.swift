import Foundation
import SQLite3

/// Root-aware copies of the small Chromium readers Flow needs for a selected
/// folder. Chromium's upstream `Source.files` discovers profiles through
/// Login Data; a read-only fallback copy may deliberately contain only the
/// session, history and bookmark files, so those paths are walked directly.
enum FlowChromium {
    static func bookmarks(in source: FlowSource) -> [Bookmark] {
        let profiles = source.profiles.map { source.root.appendingPathComponent($0, isDirectory: true) }
        return FlowBookmarks.bookmarks(in: profiles)
    }

    static func places(in source: FlowSource, limit: Int = Int.max) -> [Chromium.Place] {
        guard source.rootOverride != nil else { return Chromium.places(in: source.readerSource, limit: limit) }
        var out: [Chromium.Place] = []
        for profile in source.profiles {
            let file = source.root.appendingPathComponent(profile, isDirectory: true)
                .appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: file.path),
                  let rows = try? placeRows(in: file, limit: limit)
            else { continue }
            out += rows
        }
        return Array(out.sorted { $0.last > $1.last }.prefix(limit))
    }

    private static func placeRows(in file: URL, limit: Int) throws -> [Chromium.Place] {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-history-\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: file, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var database: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_close(database) }

        let query = """
        SELECT url, title, visit_count, last_visit_time FROM urls
        WHERE hidden = 0 AND visit_count > 0
        ORDER BY last_visit_time DESC LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_finalize(statement) }

        var out: [Chromium.Place] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let url = URL(string: String(cString: raw))
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            let stamp = sqlite3_column_int64(statement, 3)
            let last = stamp > 0
                ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600)
                : Date()
            out.append(Chromium.Place(url: url, title: title, count: max(1, count), last: last))
        }
        return out
    }
}

extension Browser {
    /// Same bookmark merge as the normal importer, but rooted at Flow's
    /// selected copy when Login Data is absent from that copy.
    @discardableResult
    @MainActor
    func takeBookmarks(from source: FlowSource) -> Int {
        let found = FlowChromium.bookmarks(in: source)
        bookmarks.take(found, from: source.name)
        let count = Bookmarks.count(found)
        announce(count == 0 ? "No bookmarks in \(source.name)" : "\(count) bookmarks from \(source.name)")
        guard source.rootOverride == nil else { return count }
        let urls = Bookmarks.urls(found)
        DispatchQueue.global(qos: .utility).async {
            let icons = Chromium.icons(in: source.readerSource, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return count
    }
}
