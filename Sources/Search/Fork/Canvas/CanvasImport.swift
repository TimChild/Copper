import AppKit
import WebKit

// Easels, brought into Canvas. Copper used to have a second whiteboard,
// Easels, with a format of its own; Canvas is the one board now, and every
// easel a Mac still has becomes a local canvas the first time this build
// starts. Nothing is deleted: the easel folders stay where they were, so a
// failed or doubted import can always be run again.
//
// What an easel was on disk, under Store.file("easels"):
//
//   easels/index.json            {"easels":[{id,title,createdAt,updatedAt[,renamedFrom]}]}
//   easels/viewer.json           {"id": <uuid>} — who "you" were on every board
//   easels/<id>/doc.yjs          the whole document, Y.encodeStateAsUpdate(doc)
//   easels/<id>/files/<fileId>   pictures dropped on that board (<uuid>.png|jpg|gif|webp)
//
// and what this adds beside it:
//
//   easels/migrated.json         {"easels": {<easel id>: {canvas, done, imported, skipped, error, tries, at}}}
//
// How it goes:
//
// 1. `prepare`, at launch, before the session is restored: every easel in
//    the index that migrated.json doesn't list gets a local canvas of the same
//    name now (its row, its id, nothing on it yet), and the mapping is written
//    down — so an easel's old address in the session file, a favourite or a
//    bookmark is that canvas's from the first frame (`translate`).
// 2. `run`, a moment after the window is up: each easel not yet done is
//    loaded into its canvas's page in a view nobody sees — the same
//    configuration, bridge and CanvasHost a canvas tab uses, so every update
//    the page makes goes to the canvas's history on disk the ordinary way —
//    and the page is handed the old document and its pictures
//    (`copperCanvas.importLegacy`), which turns stickies, frames, arrows and
//    pictures into canvas shapes. The page is then checkpointed (its whole
//    document written as the snapshot), the view let go, and the easel
//    marked done. Fifteen seconds an easel at most. A failure is logged, the
//    easel stays not done, and the next launch tries again into the same
//    canvas; the page remembers what it has imported, so a retry never puts
//    a board's shapes on twice.
// 3. `copper-easel://easel/<id>` met anywhere afterwards — the session,
//    a favourite, a link, the address field — is `copper://canvas/<that
//    canvas>`; an easel that never made it is dropped from the session.

@MainActor
enum CanvasImport {
    static let scheme = "copper-easel"

    nonisolated static var folder: URL { Store.file("easels") }
    nonisolated static var indexFile: URL { folder.appendingPathComponent("index.json") }
    nonisolated static var recordFile: URL { folder.appendingPathComponent("migrated.json") }

    /// One easel's way into Canvas.
    struct Record: Codable, Equatable {
        /// The canvas it became.
        var canvas: String
        /// Its document is on the canvas.
        var done: Bool
        var imported: Int?
        var skipped: Int?
        /// What went wrong last, or what the page said was left behind.
        var error: String?
        var tries: Int
        /// Unix seconds of the last try.
        var at: Double?
    }

    private struct File: Codable { var easels: [String: Record] }
    private struct Index: Decodable { var easels: [Easel] }
    private struct Easel: Decodable {
        var id: String
        var title: String?
        var createdAt: Double?
        var updatedAt: Double?
    }

    /// Easel id → record, as migrated.json has it.
    private(set) static var records: [String: Record] = [:]
    private static var loaded = false
    private static var prepared = false
    /// `run` in progress.
    private(set) static var running = false
    /// What the last run did, for the bench and the log.
    private(set) static var lastRun: [[String: Any]] = []

    /// The longest one easel may take, page and all.
    static let cap: TimeInterval = 15

    // MARK: - addresses

    static func isLegacy(_ url: URL?) -> Bool { url?.scheme?.lowercased() == scheme }

    /// The easel an old address names: `copper-easel://easel/<id>[/]`.
    static func easel(of url: URL?) -> String? {
        guard let url, isLegacy(url), url.host()?.lowercased() == "easel" else { return nil }
        let id = url.path(percentEncoded: false).split(separator: "/").first.map { String($0).lowercased() } ?? ""
        return id.isEmpty ? nil : id
    }

    /// An easel's old address as its canvas's, or nil when that easel never
    /// became one (or the canvas has since been deleted).
    static func translate(_ url: URL) -> URL? {
        load()
        guard let id = easel(of: url), let record = records[id], Canvases.shared.entry(record.canvas) != nil else { return nil }
        return CanvasLinks.url(record.canvas)
    }

    /// For the session restore: an easel's address becomes its canvas's,
    /// an easel with nowhere to go is dropped (nil), any other address is
    /// itself.
    static func restored(_ url: URL) -> URL? {
        isLegacy(url) ? translate(url) : url
    }

    // MARK: - the record

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: recordFile) else { return }
        if let file = try? JSONDecoder().decode(File.self, from: data) { records = file.easels }
    }

    private static func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(easels: records)) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: recordFile, options: .atomic)
        } catch {
            CanvasHost.log.error("easel import: could not write migrated.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func easels() -> [Easel] {
        guard let data = try? Data(contentsOf: indexFile) else { return [] }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else {
            CanvasHost.log.error("easel import: index.json is not an easel index")
            return []
        }
        return index.easels.filter { !$0.id.isEmpty && !$0.id.contains("/") && !$0.id.contains("..") }
    }

    // MARK: - at launch

    /// Before the session is restored (Browser, the first window): every
    /// easel not yet listed has a canvas to go to, so its address in the
    /// session already means that canvas; the import itself follows.
    static func prepare() {
        guard !prepared else { return }
        prepared = true
        load()
        let all = easels()
        guard !all.isEmpty else { return }
        var changed = false
        for easel in all {
            let id = easel.id.lowercased()
            // Listed and done: its canvas is the person's now, deleted or not.
            if let record = records[id], record.done || Canvases.shared.entry(record.canvas) != nil { continue }
            // Not listed, or its canvas was deleted before the import finished:
            // a canvas of its own, named and dated as the easel was.
            let name = easel.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let entry = Canvases.shared.createLocal(named: name.isEmpty || name == "Untitled Easel" ? CanvasTabs.untitled : name,
                                                    createdAt: easel.createdAt.map { Date(timeIntervalSince1970: $0) },
                                                    updatedAt: easel.updatedAt.map { Date(timeIntervalSince1970: $0) })
            records[id] = Record(canvas: entry.id, done: false, imported: nil, skipped: nil, error: nil, tries: 0, at: nil)
            changed = true
            CanvasHost.log.info("easel import: easel \(id, privacy: .public) → canvas \(entry.id, privacy: .public)")
        }
        if changed { save() }
        guard records.values.contains(where: { !$0.done }) else { return }
        // After the first frame and the restore, with the window up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Task { await run() } }
    }

    /// Every easel not yet done, one at a time.
    static func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        load()
        var out: [[String: Any]] = []
        let known = Set(easels().map { $0.id.lowercased() })
        for (easel, record) in records.sorted(by: { $0.key < $1.key }) where !record.done && known.contains(easel) && Canvases.shared.entry(record.canvas) != nil {
            let started = Date()
            var next = record
            next.tries += 1
            next.at = Date().timeIntervalSince1970
            do {
                let result = try await migrate(easel, into: record.canvas)
                next.imported = result.imported
                next.skipped = result.skipped
                next.error = result.error
                // Done when the board came over — wholly, or as far as it
                // ever will (a picture that can't be read is said, not retried).
                next.done = result.error == nil || result.already || result.imported > 0
            } catch {
                next.error = (error as? CanvasHost.Failure)?.text ?? "\(error)"
                next.done = false
            }
            records[easel] = next
            save()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if next.done {
                CanvasHost.log.info("easel import: \(easel, privacy: .public) done — \(next.imported ?? 0) shapes, \(next.skipped ?? 0) skipped, \(ms) ms\(next.error.map { " (\($0))" } ?? "", privacy: .public)")
            } else {
                CanvasHost.log.error("easel import: \(easel, privacy: .public) failed, try \(next.tries), retried next launch: \(next.error ?? "?", privacy: .public)")
            }
            out.append(["easel": easel, "canvas": record.canvas, "done": next.done, "imported": next.imported ?? 0,
                        "skipped": next.skipped ?? 0, "error": next.error ?? "", "ms": ms])
        }
        lastRun = out
    }

    struct Result { var imported: Int; var skipped: Int; var error: String?; var already: Bool }

    /// One easel onto its canvas: the page up in a view nobody sees, the old
    /// document handed over, the canvas checkpointed, the view let go.
    private static func migrate(_ easel: String, into canvas: String) async throws -> Result {
        let deadline = Date().addingTimeInterval(cap)
        let base = folder.appendingPathComponent(easel, isDirectory: true)
        guard let doc = try? Data(contentsOf: base.appendingPathComponent("doc.yjs")), !doc.isEmpty else {
            // Made and never drawn on: an empty canvas is the whole of it.
            return Result(imported: 0, skipped: 0, error: nil, already: false)
        }
        let title = easels().first { $0.id.lowercased() == easel }?.title
        let payload: [String: Any] = ["doc": doc.base64EncodedString(), "files": pictures(in: base.appendingPathComponent("files")),
                                      "title": title ?? ""]
        guard let config = CanvasHost.configuration(for: CanvasLinks.url(canvas)) else { throw CanvasHost.Failure(text: "no canvas configuration") }
        // Nobody is looking, and the page must still run at full speed.
        config.preferences.inactiveSchedulingPolicy = .none
        let tab = Tab(bench: true, configuration: config)
        let stage = Stage(tab.web)
        defer {
            CanvasHost.forget(tab)
            tab.close()
            stage.close()
        }
        CanvasHost.mount(tab, canvas, in: Windows.main)
        guard let host = CanvasHost.host(for: tab) else { throw CanvasHost.Failure(text: "no host for the canvas page") }
        try await host.waitReady(timeout: max(1, deadline.timeIntervalSinceNow))
        let raw = try await within(max(1, deadline.timeIntervalSinceNow)) {
            try await host.call("""
                const c = window.copperCanvas;
                if (!c || typeof c.importLegacy !== 'function') throw new Error('this Copper\\'s canvas page has no importLegacy');
                const out = await c.importLegacy(payload);
                return typeof out === 'string' ? out : JSON.stringify(out);
                """, ["payload": payload])
        }
        guard let text = raw as? String, let data = text.data(using: .utf8),
              let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw CanvasHost.Failure(text: "importLegacy gave back nothing") }
        let result = Result(imported: (answer["imported"] as? NSNumber)?.intValue ?? 0, skipped: (answer["skipped"] as? NSNumber)?.intValue ?? 0,
                            error: (answer["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }, already: answer["already"] as? Bool ?? false)
        // The page's own `update` messages carry the import to the canvas's
        // log; a beat for the last of them, then the whole document as the
        // snapshot, the way a tab's lifecycle checkpoint writes it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        await host.checkpoint(within: max(0.5, min(3, deadline.timeIntervalSinceNow)))
        return result
    }

    /// The board's pictures as `data:` URLs, by file id.
    private static func pictures(in folder: URL) -> [String: String] {
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        var out: [String: String] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            guard let type = types[(name as NSString).pathExtension.lowercased()],
                  let data = try? Data(contentsOf: folder.appendingPathComponent(name)), !data.isEmpty
            else { continue }
            out[name] = "data:\(type);base64,\(data.base64EncodedString())"
        }
        return out
    }

    /// `work`, or a failure once `seconds` have gone by.
    private static func within(_ seconds: TimeInterval, _ work: @escaping @MainActor () async throws -> Any?) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            var finished = false
            func finish(_ result: Swift.Result<Any?, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated { finish(.failure(CanvasHost.Failure(text: "the import took longer than \(Int(cap)) s"))) }
            }
            Task { @MainActor in
                do { finish(.success(try await work())) } catch { finish(.failure(error)) }
            }
        }
    }

    /// A window nobody sees for the page: off every screen, see-through,
    /// out of the Window menu and ⌘`. WebKit runs a page that has a window
    /// as a page; this is only so it does.
    @MainActor private final class Stage {
        private var window: NSWindow?

        init(_ web: WKWebView) {
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1200, height: 800),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            web.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            window.contentView = web
            window.orderBack(nil)
            self.window = window
        }

        func close() {
            window?.contentView = nil
            window?.orderOut(nil)
            window?.close()
            window = nil
        }
    }

    // MARK: - the bench

    /// `bench canvas import [status|run]`.
    static func bench(_ what: String, answer: @escaping ([String: Any]) -> Void) {
        load()
        func status() -> [String: Any] {
            let list = records.sorted { $0.key < $1.key }.map { key, record -> [String: Any] in
                ["easel": key, "canvas": record.canvas, "name": Canvases.shared.entry(record.canvas)?.name ?? "", "done": record.done,
                 "imported": record.imported ?? 0, "skipped": record.skipped ?? 0, "error": record.error ?? "", "tries": record.tries]
            }
            return ["easels": easels().count, "records": list, "running": running, "lastRun": lastRun,
                    "folder": folder.path, "page": CanvasPage.file.map { (try? String(contentsOf: $0, encoding: .utf8))?.contains("importLegacy") ?? false } ?? false]
        }
        switch what {
        case "run":
            Task { @MainActor in
                prepared = false
                prepare()
                await run()
                answer(status())
            }
        default:
            answer(status())
        }
    }
}
