import AppKit
import Foundation

// An easel: a FigJam-style board in a Copper tab. The board is a web app
// bundled with Copper (`Fork/Easel/web`), served from copper-easel://easel/<id>
// by EaselScheme and talking to this side through EaselBridge. This file is
// what an easel is on disk, and the few things that can be done to one.
//
// P1 is local. Anyone can make one, nobody signs in, and nothing leaves the
// Mac; sharing (P4) is an upgrade of an easel that already works here, never
// a condition of having one. The contract the web bundle builds against is
// docs/plans/2026-10-01-easels-p1-local.md.
//
// On disk, under Store.file("easels"), so a SEARCH_PROBE world keeps easels
// of its own and a test can never write over a real board:
//
//   easels/index.json            {"easels":[{id,title,createdAt,updatedAt}]}
//   easels/viewer.json           {"id": <uuid>} — who "you" are on every board
//   easels/<id>/doc.yjs          the whole document, Y.encodeStateAsUpdate(doc)
//   easels/<id>/files/<fileId>   pictures dropped on that board
//
// Every write is atomic and goes through one serial queue, so a save and the
// read that answers the next `ready` can never pass each other: a board that
// reloads a moment after it saved reads what it saved.

struct Easel: Codable, Identifiable, Equatable {
    /// A lowercase UUID; the last part of the board's address.
    let id: String
    var title: String
    /// Unix seconds.
    let createdAt: Double
    var updatedAt: Double
}

@MainActor
final class EaselStore: ObservableObject {
    static let shared = EaselStore()

    /// What a board is called until somebody calls it something else. The
    /// page keeps its document.title equal to this, so the tab says it too.
    nonisolated static let untitled = "Untitled Easel"

    /// Newest change first, which is the order ⌘K offers them in.
    @Published private(set) var all: [Easel] = []

    /// Boards deleted this session. A page on its way out may still send a
    /// last save after its board is gone; it is not let bring it back.
    private var deleted: Set<String> = []

    /// Disk work, in the order it was asked for.
    nonisolated static let disk = DispatchQueue(label: "copper.easels.disk", qos: .userInitiated)

    nonisolated static var folder: URL { Store.file("easels") }
    nonisolated static func folder(of id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }
    nonisolated static func document(of id: String) -> URL { folder(of: id).appendingPathComponent("doc.yjs") }
    nonisolated static func files(of id: String) -> URL { folder(of: id).appendingPathComponent("files", isDirectory: true) }
    private nonisolated static var indexFile: URL { folder.appendingPathComponent("index.json") }
    private nonisolated static var viewerFile: URL { folder.appendingPathComponent("viewer.json") }

    private struct Index: Codable { var easels: [Easel] }

    private init() {
        // Small, and wanted before the first row is drawn: read here, once.
        guard let data = try? Data(contentsOf: Self.indexFile) else { return }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else {
            // Set aside rather than written over: the boards themselves are
            // still there, one folder each, and the next save puts each one
            // back in a fresh index.
            Store.quarantine(Self.indexFile)
            return
        }
        all = index.easels.sorted { $0.updatedAt > $1.updatedAt }
    }

    func easel(_ id: String) -> Easel? { all.first { $0.id == id } }

    /// A new board, in the index straight away so ⌘K can find it before its
    /// page has said a word. Its document comes with its first save.
    @discardableResult
    func create(title: String = EaselStore.untitled) -> Easel {
        let now = Date().timeIntervalSince1970
        let easel = Easel(id: UUID().uuidString.lowercased(), title: title, createdAt: now, updatedAt: now)
        all.insert(easel, at: 0)
        keepIndex()
        return easel
    }

    /// The page's whole document and its title. An id the index has never
    /// heard of — a board whose index entry was lost, or an address typed in
    /// by hand — comes into being here rather than being refused: the page
    /// is already showing it, and refusing would only lose what was drawn.
    func save(_ id: String, state: Data, title: String, then done: (() -> Void)? = nil) {
        guard !deleted.contains(id) else { return }
        let now = Date().timeIntervalSince1970
        let title = EaselStore.tidy(title)
        if let i = all.firstIndex(where: { $0.id == id }) {
            var easel = all.remove(at: i)
            easel.title = title
            easel.updatedAt = now
            all.insert(easel, at: 0)
        } else {
            all.insert(Easel(id: id, title: title, createdAt: now, updatedAt: now), at: 0)
        }
        let file = EaselStore.document(of: id)
        EaselStore.disk.async {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try state.write(to: file, options: .atomic)
            } catch {
                NSLog("easel: could not save %@: %@", id, error.localizedDescription)
            }
            if let done { DispatchQueue.main.async(execute: done) }
        }
        keepIndex()
    }

    /// The document as last saved, or nil for a board that has never been
    /// saved. Read on the disk queue, behind any save still on its way.
    func state(_ id: String, _ done: @escaping (Data?) -> Void) {
        let file = EaselStore.document(of: id)
        EaselStore.disk.async {
            let data = try? Data(contentsOf: file)
            DispatchQueue.main.async { done(data) }
        }
    }

    /// A picture for a board: its bytes, already checked, under a fresh id.
    func keep(picture data: Data, ext: String, for id: String, _ done: @escaping (Result<String, Error>) -> Void) {
        guard !deleted.contains(id) else {
            return done(.failure(NSError(domain: "Easel", code: 410, userInfo: [NSLocalizedDescriptionKey: "This board has been deleted."])))
        }
        let fileId = UUID().uuidString.lowercased() + "." + ext
        let file = EaselStore.files(of: id).appendingPathComponent(fileId)
        EaselStore.disk.async {
            let result = Result<String, Error> {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                return fileId
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Gone, document, pictures and all. Not on any menu yet: the bench is
    /// the only way to it until there is an undo to put beside it.
    func delete(_ id: String) {
        deleted.insert(id)
        all.removeAll { $0.id == id }
        let folder = EaselStore.folder(of: id)
        EaselStore.disk.async { try? FileManager.default.removeItem(at: folder) }
        keepIndex()
    }

    /// Waits for every write already asked for. Quitting does this, so the
    /// process does not end under a save that is half way to the disk.
    nonisolated static func drain() { disk.sync {} }

    private func keepIndex() {
        let snapshot = Index(easels: all)
        let file = EaselStore.indexFile
        EaselStore.disk.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// One line, not too long, never empty.
    static func tidy(_ title: String) -> String {
        let line = title.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return untitled }
        return line.count <= 200 ? line : String(line.prefix(200))
    }

    // MARK: - who is looking

    /// Who "you" are on a board. The id is made once and kept, so a cursor
    /// keeps its colour from one launch to the next, and in P4 the same
    /// person is the same person on somebody else's Mac.
    struct Viewer {
        let id: String
        let name: String
        let color: String

        var json: [String: Any] { ["id": id, "name": name, "color": color] }
    }

    /// The board's cursor colours, Copper's red-orange first. The page
    /// draws presence in whatever it is handed; picking from the id keeps a
    /// person's colour stable without anyone choosing it.
    static let cursorColors = ["#ff5a36", "#3b82f6", "#10b981", "#a855f7", "#f59e0b", "#ec4899", "#14b8a6", "#6366f1"]

    lazy var viewer: Viewer = {
        struct Kept: Codable { var id: String }
        let file = EaselStore.viewerFile
        var id = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Kept.self, from: $0) }?.id ?? ""
        if UUID(uuidString: id) == nil {
            id = UUID().uuidString.lowercased()
            if let data = try? JSONEncoder().encode(Kept(id: id)) {
                EaselStore.disk.async {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }
            }
        }
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let color = EaselStore.cursorColors[Int(hash % UInt32(EaselStore.cursorColors.count))]
        let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        return Viewer(id: id, name: name, color: color)
    }()

    // MARK: - pictures

    /// The pictures a board takes, by MIME type, and the extension each is
    /// kept under. SVG is deliberately not one: it is a document that can
    /// carry script, served from the board's own origin.
    static let pictures: [String: String] = [
        "image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/gif": "gif", "image/webp": "webp",
    ]

    /// The file's own first bytes say what it is; the name and the MIME
    /// type the page sends are only what it believes.
    static func sniff(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        func starts(_ bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "gif" }
        if head.count == 12, starts(Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) { return "webp" }
        return nil
    }

    /// The largest picture a board takes, decoded.
    static let pictureLimit = 15 * 1024 * 1024
    /// The largest document. Far past anything a person draws; there so a
    /// page in a loop cannot fill the disk one save at a time.
    static let documentLimit = 64 * 1024 * 1024
}
