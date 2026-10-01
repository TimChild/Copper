import Foundation

/// Lifts a Chromium browser's localStorage out of its LevelDB — the Swift
/// twin of the `arc-localstorage` script at the repo root, rule for rule, so
/// the two can be diffed against each other on the same copy of Arc.
///
/// Chromium keeps a profile's localStorage in one LevelDB under
/// "Local Storage/leveldb". There is no LevelDB on macOS to link, so this
/// reads the two file kinds itself: the write-ahead .log (what was written
/// since the last compaction) and the .ldb tables (everything older), Snappy
/// blocks included. The browser may be running and writing, so each folder is
/// copied to a temporary one first and only the copy is read.
///
/// Nothing here touches WebKit or the main actor: the move calls it from a
/// detached task and hands the result to `StorageImport`.
enum FlowLocalStorage {
    /// `{"<origin>": {"<key>": "<value>"}}`, the shape `StorageImport` takes.
    typealias Origins = [String: [String: String]]

    struct Result {
        /// Each profile folder's own origins, in the order they were read.
        var profiles: [(name: String, origins: Origins)] = []
        /// Every profile merged, a later profile winning a clash, http(s) only.
        var merged: Origins = [:]
        var partitioned = 0
        var undecoded = 0
        var warnings: [String] = []

        var keyCount: Int { merged.values.reduce(0) { $0 + $1.count } }
    }

    private static let block = 32_768

    /// Profile folders that have a localStorage database, Default first and
    /// then "Profile N" by number — the order the script merges in.
    static func profiles(in root: URL) -> [String] {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        let found = entries.filter {
            var folder: ObjCBool = false
            return files.fileExists(atPath: root.appendingPathComponent("\($0)/Local Storage/leveldb").path, isDirectory: &folder) && folder.boolValue
        }
        func order(_ name: String) -> (Int, Int) {
            if name == "Default" { return (0, 0) }
            return (1, Int(name.split(separator: " ").last ?? "") ?? 0)
        }
        // The script's sort is stable on (rank, number) over glob's order;
        // the name breaks ties here so the order does not hang on the disk.
        return found.sorted { order($0) == order($1) ? $0 < $1 : order($0) < order($1) }
    }

    static func read(root: URL, profiles wanted: [String]? = nil) -> Result {
        var result = Result()
        var warned = Set<String>()
        func warn(_ text: String) {
            if warned.insert(text).inserted { result.warnings.append(text) }
        }
        var merged: Origins = [:]
        for name in wanted ?? profiles(in: root) {
            let source = root.appendingPathComponent("\(name)/Local Storage/leveldb", isDirectory: true)
            guard FileManager.default.fileExists(atPath: source.path) else {
                warn("\(name): no Local Storage, skipped")
                continue
            }
            let origins: Origins
            do {
                origins = try withCopy(of: source) { copy in
                    storage(readLevelDB(copy, warn: warn), &result)
                }
            } catch {
                warn("\(name): \(error.localizedDescription)")
                continue
            }
            result.profiles.append((name, origins))
            for (origin, keys) in origins {
                merged[origin, default: [:]].merge(keys) { _, later in later }
            }
        }
        // chrome-extension://, file:// and such have nowhere to go in Copper.
        result.merged = merged.filter { $0.key.hasPrefix("https://") || $0.key.hasPrefix("http://") }
        result.profiles = result.profiles.map { ($0.name, $0.origins.filter { $0.key.hasPrefix("https://") || $0.key.hasPrefix("http://") }) }
        return result
    }

    /// Copies the folder (without its LOCK) somewhere private and reads that,
    /// so nothing of the browser's is ever opened, let alone for writing.
    private static func withCopy<T>(of source: URL, _ body: (URL) throws -> T) throws -> T {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("copper-ls-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        for name in try files.contentsOfDirectory(atPath: source.path) where name != "LOCK" {
            try files.copyItem(at: source.appendingPathComponent(name), to: scratch.appendingPathComponent(name))
        }
        return try body(scratch)
    }

    // MARK: - bytes

    struct Corrupt: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Bounds-checked reads. Python's indexing raises where these throw and
    /// its slices quietly come up short where `slice` does, so a damaged file
    /// gives the same partial answer in both.
    private struct Bytes {
        let b: [UInt8]
        var count: Int { b.count }

        func at(_ i: Int) throws -> UInt8 {
            guard i >= 0, i < b.count else { throw Corrupt("index out of range") }
            return b[i]
        }

        func slice(_ from: Int, _ to: Int) -> ArraySlice<UInt8> {
            let lo = min(max(from, 0), b.count), hi = min(max(to, lo), b.count)
            return b[lo..<hi]
        }

        func varint(_ start: Int) throws -> (Int, Int) {
            var result = 0, shift = 0, pos = start
            while true {
                let byte = try at(pos)
                pos += 1
                if shift < 63 { result |= Int(byte & 0x7F) << shift }
                if byte < 0x80 { return (result, pos) }
                shift += 7
            }
        }

        func little(_ start: Int, _ width: Int) throws -> UInt64 {
            guard start >= 0, start + width <= b.count else { throw Corrupt("unpack requires a buffer of \(width) bytes") }
            var value: UInt64 = 0
            for i in 0..<width { value |= UInt64(b[start + i]) << (8 * i) }
            return value
        }
    }

    /// Snappy's raw format: a varint length, then literals and back-copies.
    static func snappy(_ input: [UInt8]) throws -> [UInt8] {
        let data = Bytes(b: input)
        let (size, start) = try data.varint(0)
        var out: [UInt8] = []
        out.reserveCapacity(size)
        var pos = start
        let n = data.count
        while pos < n {
            let tag = input[pos]
            pos += 1
            let kind = tag & 3
            if kind == 0 {
                var length = Int(tag >> 2)
                if length >= 60 {
                    let extra = length - 59
                    length = Int(data.slice(pos, pos + extra).reversed().reduce(0) { $0 << 8 | Int($1) })
                    pos += extra
                }
                length += 1
                out += data.slice(pos, pos + length)
                pos += length
                continue
            }
            let length: Int, offset: Int
            if kind == 1 {
                length = Int((tag >> 2) & 7) + 4
                offset = Int(tag >> 5) << 8 | Int(try data.at(pos))
                pos += 1
            } else if kind == 2 {
                length = Int(tag >> 2) + 1
                offset = Int(try data.at(pos)) | Int(try data.at(pos + 1)) << 8
                pos += 2
            } else {
                length = Int(tag >> 2) + 1
                offset = Int(data.slice(pos, pos + 4).reversed().reduce(0) { $0 << 8 | Int($1) })
                pos += 4
            }
            if offset == 0 || offset > out.count { throw Corrupt("snappy: bad offset") }
            // Byte by byte, which also covers an overlapping copy (one that
            // repeats the last `offset` bytes); appending a slice of `out` to
            // itself would copy the whole buffer every time.
            let from = out.count - offset
            for i in 0..<length { out.append(out[from + i]) }
        }
        if out.count != size { throw Corrupt("snappy: wrong length") }
        return out
    }

    // MARK: - LevelDB

    private typealias Found = [[UInt8]: (seq: UInt64, kind: UInt8, value: [UInt8])]

    /// Keeps the newest write of each key; a deletion is a write too.
    private static func note(_ found: inout Found, _ key: [UInt8], _ seq: UInt64, _ kind: UInt8, _ value: [UInt8]) {
        if let have = found[key], seq <= have.seq { return }
        found[key] = (seq, kind, value)
    }

    private static func readLevelDB(_ folder: URL, warn: (String) -> Void) -> [[UInt8]: [UInt8]] {
        var found: Found = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let paths = names.map { folder.appendingPathComponent($0).path }.sorted()
        for path in paths where path.hasSuffix(".ldb") || path.hasSuffix(".sst") {
            do {
                try readTable(path, &found, warn: warn)
            } catch {
                warn("\((path as NSString).lastPathComponent): \(error.localizedDescription), rest of table skipped")
            }
        }
        for path in paths where path.hasSuffix(".log") {
            readLog(path, &found, warn: warn)
        }
        var live: [[UInt8]: [UInt8]] = [:]
        for (key, entry) in found where entry.kind == 1 { live[key] = entry.value }
        return live
    }

    /// The write-ahead log: 32 KB blocks of records, a record possibly split
    /// across blocks (FIRST/MIDDLE/LAST), each whole record one WriteBatch.
    private static func readLog(_ path: String, _ found: inout Found, warn: (String) -> Void) {
        guard let raw = FileManager.default.contents(atPath: path) else { return }
        let data = Bytes(b: [UInt8](raw))
        var pos = 0
        var pending: [UInt8]?
        while pos + 7 <= data.count {
            let room = block - pos % block
            if room < 7 {
                pos += room  // the tail of a block too short for a header is padding
                continue
            }
            let length = Int(data.b[pos + 4]) | Int(data.b[pos + 5]) << 8
            let kind = data.b[pos + 6]
            let body = data.slice(pos + 7, pos + 7 + length)
            pos += 7 + length
            if kind == 0 && length == 0 {
                pos += pos % block != 0 ? block - pos % block : 0
                continue
            }
            switch kind {
            case 1:
                batch(Array(body), &found, warn: warn)
                pending = nil
            case 2:
                pending = Array(body)
            case 3 where pending != nil:
                pending! += body
            case 4 where pending != nil:
                batch(pending! + body, &found, warn: warn)
                pending = nil
            default:
                break
            }
        }
    }

    private static func batch(_ body: [UInt8], _ found: inout Found, warn: (String) -> Void) {
        guard body.count >= 12 else { return }
        let data = Bytes(b: body)
        guard let seq = try? data.little(0, 8), let count = try? data.little(8, 4) else { return }
        var pos = 12
        do {
            for i in 0..<Int(count) {
                let kind = try data.at(pos)
                pos += 1
                let (size, at) = try data.varint(pos)
                let key = Array(data.slice(at, at + size))
                pos = at + size
                var value: [UInt8] = []
                if kind == 1 {
                    let (size, at) = try data.varint(pos)
                    value = Array(data.slice(at, at + size))
                    pos = at + size
                }
                note(&found, key, seq &+ UInt64(i), kind, value)
            }
        } catch {
            warn("a torn write at the end of a .log was skipped")
        }
    }

    private static func blockAt(_ data: Bytes, _ offset: Int, _ size: Int, _ name: String, warn: (String) -> Void) throws -> [UInt8]? {
        let raw = Array(data.slice(offset, offset + size))
        switch try data.at(offset + size) {
        case 0: return raw
        case 1: return try snappy(raw)
        case 2:
            // zstd is not in the system and not worth a reader of its own
            // until a browser is seen writing it; the script skips it too.
            warn("\(name): zstd blocks skipped (no zstd module)")
            return nil
        case let kind:
            warn("\(name): unknown compression \(kind), block skipped")
            return nil
        }
    }

    /// A block's key/value pairs. Keys share prefixes with the one before;
    /// the restart array at the end is for seeking, not needed to walk.
    private static func blockEntries(_ input: [UInt8], _ visit: ([UInt8], ArraySlice<UInt8>) throws -> Void) throws {
        let block = Bytes(b: input)
        let restarts = Int(try block.little(input.count - 4, 4))
        let end = input.count - 4 - 4 * restarts
        var pos = 0
        var key: [UInt8] = []
        while pos < end {
            let (shared, a) = try block.varint(pos)
            let (unshared, b) = try block.varint(a)
            let (size, c) = try block.varint(b)
            key = Array(key.prefix(shared)) + block.slice(c, c + unshared)
            pos = c + unshared
            try visit(key, block.slice(pos, pos + size))
            pos += size
        }
    }

    private static let magic: [UInt8] = [0x57, 0xFB, 0x80, 0x8B, 0x24, 0x75, 0x47, 0xDB]

    private static func readTable(_ path: String, _ found: inout Found, warn: (String) -> Void) throws {
        guard let raw = FileManager.default.contents(atPath: path) else { return }
        let data = Bytes(b: [UInt8](raw))
        let name = (path as NSString).lastPathComponent
        guard data.count >= 48, Array(data.b.suffix(8)) == magic else {
            warn("\(name): not a LevelDB table, skipped")
            return
        }
        let footer = Bytes(b: Array(data.b.suffix(48)))
        var (_, pos) = try footer.varint(0)
        (_, pos) = try footer.varint(pos)          // metaindex (the bloom filter), unused
        let (indexOffset, p1) = try footer.varint(pos)
        let (indexSize, _) = try footer.varint(p1)
        guard let index = try blockAt(data, indexOffset, indexSize, name, warn: warn) else { return }
        // Each data block is read as its index entry comes up, so a table
        // damaged part-way keeps everything before the damage, as the
        // script's generator does.
        try blockEntries(index) { _, handle in
            let h = Bytes(b: Array(handle))
            let (offset, p) = try h.varint(0)
            let (size, _) = try h.varint(p)
            guard let block = try blockAt(data, offset, size, name, warn: warn) else { return }
            try blockEntries(block) { key, value in
                guard key.count >= 8 else { return }
                let tag = try Bytes(b: Array(key.suffix(8))).little(0, 8)
                note(&found, Array(key.dropLast(8)), tag >> 8, UInt8(tag & 0xFF), Array(value))
            }
        }
    }

    // MARK: - Chromium's localStorage keys

    /// Chromium's string encoding: a leading 0 is UTF-16LE, a 1 is Latin-1.
    private static func text(_ raw: ArraySlice<UInt8>) -> String? {
        guard let first = raw.first else { return "" }
        let body = raw.dropFirst()
        if first == 0 {
            var units: [UInt16] = []
            units.reserveCapacity(body.count / 2)
            var i = body.startIndex
            while i + 1 < body.endIndex {
                units.append(UInt16(body[i]) | UInt16(body[i + 1]) << 8)
                i += 2
            }
            var decoded = String(decoding: units, as: UTF16.self)
            // A stray last byte is half a code unit; Python's "replace" makes
            // it one replacement character, so this does too.
            if body.count % 2 == 1 { decoded.append("\u{FFFD}") }
            return decoded
        }
        if first == 1 {
            return String(decoding: body.map { UInt16($0) }, as: UTF16.self)
        }
        return nil
    }

    private static func storage(_ records: [[UInt8]: [UInt8]], _ result: inout Result) -> Origins {
        var origins: Origins = [:]
        for (key, value) in records {
            guard key.first == UInt8(ascii: "_") else { continue }  // VERSION, META:, METAACCESS:
            guard let cut = key.dropFirst().firstIndex(of: 0) else { continue }
            let origin = String(decoding: key[1..<cut], as: UTF8.self)
            if origin.contains("^") {
                // A storage key with a top-level site or nonce after the
                // origin: third-party (partitioned) storage, not the site's
                // own, and nothing WebKit lets Copper put back.
                result.partitioned += 1
                continue
            }
            guard let name = text(key[(cut + 1)...]), let content = text(value[...]) else {
                result.undecoded += 1
                continue
            }
            var trimmed = Substring(origin)
            while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
            origins[String(trimmed), default: [:]][name] = content
        }
        return origins
    }

    /// The JSON `arc-localstorage` writes, for diffing the two readers.
    static func json(_ origins: Origins) throws -> Data {
        try JSONSerialization.data(withJSONObject: origins, options: [.sortedKeys])
    }
}
