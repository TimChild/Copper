import Foundation
import CommonCrypto
import SQLite3
import WebKit

/// Reads Chromium's cookie jar without touching the browser's live database.
enum FlowCookies {
    private static let limit = 20_000

    /// Reads current cookies for the requested Chromium profiles.
    static func read(_ source: Chromium.Source, key: [UInt8], profiles: [String]? = nil) throws -> [FlowModel.Cookie] {
        let selected = profiles ?? FlowCookies.profiles(of: source)
        let now = Date()
        var found: [(cookie: FlowModel.Cookie, lastAccess: Date)] = []

        for profile in selected {
            let folder = source.root.appendingPathComponent(profile, isDirectory: true)
            let candidates = [
                folder.appendingPathComponent("Cookies"),
                folder.appendingPathComponent("Network/Cookies"),
            ]
            var visited = Set<String>()
            for file in candidates where FileManager.default.fileExists(atPath: file.path) {
                guard visited.insert(file.standardizedFileURL.path).inserted else { continue }
                for row in try rows(in: file) {
                    guard !row.host.isEmpty else { continue }
                    let expiry = FlowModel.date(chromium: row.expires)
                    if let expiry, expiry <= now { continue }

                    let value: String?
                    if !row.plainValue.isEmpty {
                        value = row.plainValue
                    } else {
                        guard !row.encryptedValue.isEmpty else { continue }
                        value = cookieValue(row.encryptedValue, host: row.host, key: key)
                    }
                    guard let value else { continue }

                    found.append((
                        FlowModel.Cookie(
                            domain: row.host,
                            name: row.name,
                            value: value,
                            path: row.path.isEmpty ? "/" : row.path,
                            expires: expiry,
                            secure: row.secure,
                            httpOnly: row.httpOnly,
                            sameSite: sameSite(row.sameSite),
                            profile: profile
                        ),
                        lastAccess: FlowModel.date(chromium: row.lastAccess) ?? .distantPast
                    ))
                }
            }
        }

        return found
            .sorted { $0.lastAccess > $1.lastAccess }
            .prefix(limit)
            .map(\.cookie)
    }

    /// Finds profile folders without assuming that a browser has a Default profile.
    static func profiles(of source: Chromium.Source) -> [String] {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(
            at: source.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var names = entries.compactMap { folder -> String? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  files.fileExists(atPath: folder.appendingPathComponent("Preferences").path)
            else { return nil }
            return folder.lastPathComponent
        }
        names.sort { left, right in
            if left == "Default" { return right != "Default" }
            if right == "Default" { return false }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return names
    }

    /// Converts a reader row to the Foundation cookie used by WebKit.
    static func httpCookie(_ cookie: FlowModel.Cookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: cookie.domain,
            .name: cookie.name,
            .value: cookie.value,
            .path: cookie.path,
            .secure: cookie.secure,
            HTTPCookiePropertyKey("HttpOnly"): cookie.httpOnly,
        ]
        if let expires = cookie.expires { properties[.expires] = expires }
        if let sameSite = cookie.sameSite {
            properties[.sameSitePolicy] = sameSite
        }
        return HTTPCookie(properties: properties)
    }

    /// Installs in order so a later row cannot race an earlier cookie update.
    @MainActor
    static func install(_ cookies: [FlowModel.Cookie], into store: WKHTTPCookieStore) async -> Int {
        var count = 0
        for cookie in cookies {
            guard let value = httpCookie(cookie) else { continue }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                store.setCookie(value) { done.resume() }
            }
            count += 1
        }
        return count
    }

    private struct Row {
        let host: String
        let name: String
        let plainValue: String
        let encryptedValue: Data
        let path: String
        let expires: Int64
        let secure: Bool
        let httpOnly: Bool
        let sameSite: Int
        let lastAccess: Int64
    }

    private static func rows(in file: URL) throws -> [Row] {
        let files = FileManager.default
        let temp = files.temporaryDirectory
            .appendingPathComponent("office-import-\(UUID().uuidString).db")
        try files.copyItem(at: file, to: temp)
        defer { try? files.removeItem(at: temp) }

        var database: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_close(database) }

        let query = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc,
               is_secure, is_httponly, samesite, last_access_utc
        FROM cookies
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_finalize(statement) }

        var result: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var encrypted = Data()
            if let bytes = sqlite3_column_blob(statement, 3) {
                encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
            }
            result.append(Row(
                host: sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                name: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                plainValue: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                encryptedValue: encrypted,
                path: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "/",
                expires: sqlite3_column_int64(statement, 5),
                secure: sqlite3_column_int(statement, 6) != 0,
                httpOnly: sqlite3_column_int(statement, 7) != 0,
                sameSite: Int(sqlite3_column_int(statement, 8)),
                lastAccess: sqlite3_column_int64(statement, 9)
            ))
        }
        return result
    }

    private static func sameSite(_ value: Int) -> String? {
        switch value {
        case 0: return "None"
        case 1: return "Lax"
        case 2: return "Strict"
        default: return nil
        }
    }

    /// Chromium's cookie hash prefix is checked as bytes, not guessed from UTF-8.
    private static func cookieValue(_ blob: Data, host: String, key: [UInt8]) -> String? {
        guard let unwrapped = Chromium.unwrap(blob, key: key) else { return nil }
        let bytes = Array(unwrapped.utf8)
        let hostBytes = Array(host.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        hostBytes.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        if bytes.count >= digest.count,
           Array(bytes.prefix(digest.count)) == digest,
           let withoutPrefix = String(bytes: bytes.dropFirst(digest.count), encoding: .utf8)
        {
            return withoutPrefix
        }
        return unwrapped
    }
}

extension Chromium {
    /// Gets the one stretched key shared by password and cookie imports.
    static func key(for source: Source) throws -> [UInt8] {
        guard let passphrase = safeStorage(source) else { throw Trouble.noPassphrase }
        return stretch(passphrase)
    }
}
