import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

/// A detected Chromium profile root shown in the Flow picker.
struct FlowSource: Identifiable, Hashable {
    let source: Chromium.Source
    let profiles: [String]
    let isArc: Bool
    var locked: Bool
    /// A user-selected copy or folder, kept in memory for this session only.
    let rootOverride: URL?

    var id: String { source.name }
    var name: String { source.name }
    var glyph: String { isArc ? "a.circle" : "globe" }
    var profileCount: Int { profiles.count }
    var root: URL { rootOverride ?? source.root }

    /// Chromium's readers already accept a Source. Point that Source at a
    /// selected folder without changing the upstream importer or the browser's
    /// known source metadata (service and account still belong to this browser).
    var readerSource: Chromium.Source {
        guard let rootOverride else { return source }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.path
        let target = rootOverride.standardizedFileURL.path
        let baseParts = support.split(separator: "/").map(String.init)
        let targetParts = target.split(separator: "/").map(String.init)
        var common = 0
        while common < baseParts.count, common < targetParts.count,
              baseParts[common] == targetParts[common] { common += 1 }
        let components = Array(repeating: "..", count: baseParts.count - common)
            + targetParts.dropFirst(common)
        let folder = components.isEmpty ? "." : components.joined(separator: "/")
        return Chromium.Source(name: source.name, folder: folder, service: source.service, account: source.account)
    }
}

/// The one-button move from a Chromium browser into Copper.
@MainActor
final class Flow: ObservableObject {
    static let shared = Flow()

    /// Folder choices are session-only: a panel grant should not become a
    /// hidden new source in the next launch.
    @MainActor static var roots: [String: URL] = [:]

    struct Report: Equatable {
        var tabs = 0
        var spaces = 0
        var groups = 0
        var bookmarks = 0
        var places = 0
        var passwords = 0
        var cookies = 0
        var passkeys = 0
        var extensions = 0
        /// Sites whose localStorage came over, and how many keys in all.
        var storageSites = 0
        var storageKeys = 0
        /// Keys WebKit actually took, across every store (a profile's store
        /// counts its keys again).
        var storageKeysSet = 0
        var notes: [String] = []

        var line: String {
            "\(tabs) tabs in \(spaces) spaces · \(groups) groups · \(bookmarks) bookmarks · \(places) places · \(passwords) passwords · \(cookies) cookies · local storage for \(storageSites) sites · \(passkeys) passkeys · \(extensions) extensions"
        }
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case preview(FlowModel.Haul)
        case moving([String])
        case done(Report)
    }

    enum HistoryImportState: Equatable {
        case idle
        case reading(String, Int)
        case done(String, Int, Date)
        case failed(String)

        var detail: String? {
            switch self {
            case .idle: return nil
            case .reading(let source, let count): return "Reading \(source)… \(count.formatted()) places"
            case .done(let source, let count, let date):
                let ago = Int(max(0, Date().timeIntervalSince(date)))
                let when = ago < 60 ? "just now" : "\(ago / 60)m ago"
                return "Brought in \(count.formatted()) places from \(source) · \(when)"
            case .failed(let message): return message
            }
        }
    }

    /// A source may be read for history without opening the full Flow sheet.
    /// This is also what the quiet first-launch nudge checks.
    static func hasHistorySource(_ name: String? = nil) -> Bool {
        let wanted = name.map { $0.lowercased() }
        return Chromium.known.contains { source in
            guard wanted == nil || wanted == source.name.lowercased() else { return false }
            return historyFiles(in: source.root).isEmpty == false
        }
    }

    private static func historyFiles(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let walk = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return [] }
        var found: [URL] = []
        for case let url as URL in walk where url.lastPathComponent == "History" {
            found.append(url)
        }
        return found
    }

    @Published var open = false
    @Published private(set) var sources: [FlowSource] = []
    @Published var choice = FlowModel.Choice()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selected: FlowSource?
    @Published private(set) var historyImport: HistoryImportState = .idle
    /// When Arc was last moved in. A move is a one-time thing, so once this is
    /// set the sheet says so and wants "Move again" before it will run.
    @Published private(set) var arcMovedAt: Date? = Flow.arcMovedAtSetting
    @Published var moveAgain = false

    private static let arcMovedKey = "flow.arcMovedAt"
    private static var arcMovedAtSetting: Date? {
        let stamp = Store.settings.double(forKey: arcMovedKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    private var lastHaul = FlowModel.Haul()
    private var createdSpaces: [UUID] = []
    private weak var browserForUndo: Browser?

    private init() {
        refreshSources(autoScan: false)
    }

    /// Makes one real directory-list attempt before declaring a source locked.
    /// On a Dock launch this is also the operation that lets macOS show its
    /// App Data prompt; test worlds receive the denial and keep the card.
    func refreshSources(autoScan: Bool = true) {
        let fm = FileManager.default
        sources = Chromium.known.compactMap { source in
            let override = Self.roots[source.name].flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
            let root = override ?? source.root
            guard fm.fileExists(atPath: root.path) else { return nil }

            do {
                _ = try fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                return FlowSource(source: source, profiles: [], isArc: source.name == "Arc", locked: true, rootOverride: override)
            }

            let readerSource = FlowSource(
                source: source, profiles: [], isArc: source.name == "Arc", locked: false, rootOverride: override
            ).readerSource
            let profiles = FlowChromeTabs.profiles(of: readerSource)
            let hasPreferences = profiles.contains { profile in
                let folder = profile.isEmpty ? root : root.appendingPathComponent(profile)
                return fm.fileExists(atPath: folder.appendingPathComponent("Preferences").path)
            }
            guard hasPreferences else { return nil }
            return FlowSource(source: source, profiles: profiles, isArc: source.name == "Arc", locked: false, rootOverride: override)
        }

        if let previous = selected {
            selected = sources.first { $0.id == previous.id }
        }
        guard autoScan, selected == nil else { return }
        let readable = sources.filter { !$0.locked }
        guard readable.count == 1, let only = readable.first else { return }
        scan(only)
    }

    /// Reads the cheap, non-secret parts off the main actor.
    func scan(_ source: FlowSource) {
        guard !source.locked else { return }
        selected = source
        phase = .scanning
        Task.detached(priority: .userInitiated) { [source] in
            let haul = Flow.read(source)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastHaul = haul
                self.phase = .preview(haul)
            }
        }
    }

    /// Synchronous form used by the local bench. The bench is already on the
    /// main actor and must answer one request with one JSON object.
    @discardableResult
    func scanNow(_ source: FlowSource) -> FlowModel.Haul {
        guard !source.locked else { return FlowModel.Haul() }
        selected = source
        let haul = Flow.read(source)
        lastHaul = haul
        phase = .preview(haul)
        return haul
    }

    private nonisolated static func read(_ source: FlowSource) -> FlowModel.Haul {
        var haul = FlowModel.Haul()
        do {
            haul.spaces = source.isArc ? try FlowArc.read() : try FlowChromeTabs.read(source.readerSource)
        } catch {
            haul.notes.append(error.localizedDescription)
        }
        haul.extensions = FlowExtensions.read(source.readerSource, profiles: source.profiles)
        haul.passkeyCount = FlowPasskeys.count(source.readerSource, profiles: source.profiles)
        haul.bookmarkCount = FlowBookmarks.count(FlowChromium.bookmarks(in: source))
        haul.placeCount = FlowChromium.places(in: source).count
        haul.notes.append("\(haul.bookmarkCount) bookmarks")
        haul.notes.append("\(haul.placeCount) places")
        return haul
    }

    var moving: Bool { if case .moving = phase { return true } else { return false } }

    /// Performs each choice independently. A failure is a line in the report,
    /// never a reason to abandon the remaining data.
    ///
    /// Async so the window stays live the whole way: everything that reads
    /// another browser's files, and the keychain call that can sit behind
    /// macOS's "allow" prompt for as long as the person takes, runs in a
    /// detached task; only the merges into Copper's own state come back here.
    func move(_ source: FlowSource, into browser: Browser) async {
        guard !source.locked, !moving else { return }
        browserForUndo = browser
        selected = source
        var report = Report()
        var lines: [String] = []
        phase = .moving(lines)
        // A haul with no spaces and no note is one that was never scanned (or
        // whose scan is stale); read again rather than move nothing.
        let haul = lastHaul.spaces.isEmpty
            ? await Task.detached(priority: .userInitiated) { Flow.read(source) }.value
            : lastHaul
        let choice = self.choice
        let reader = source.readerSource
        NSLog("Copper: Flow moving from %@ — %d spaces, %d tabs read; notes: %@",
              source.name, haul.spaces.count, haul.tabCount, haul.notes.joined(separator: "; "))

        if choice.tabs {
            let adopted = Spaces.shared.adopt(haul.spaces, in: browser, sourceName: source.name, sourceIsArc: source.isArc)
            createdSpaces = adopted.spaces
            report.tabs = adopted.tabs
            report.spaces = adopted.spaces.count
            report.groups = adopted.groups
            lines.append("\(report.tabs) tabs in \(report.spaces) spaces")
            phase = .moving(lines)
            // The new spaces are the one thing that cannot be re-fetched from
            // the store or re-read later: write them down now, before the
            // keychain prompt, cookie decryption and extension downloads that
            // follow, so a quit or a hang during those keeps them.
            Session.write(now: true, Spaces.shared.shape(visible: browser.tabs, active: browser.activeID))
            NSLog("Copper: Flow adopted %d tabs in %d spaces (%d groups) and saved the session",
                  report.tabs, report.spaces, report.groups)
            if haul.spaces.isEmpty {
                report.notes.append("\(source.name) had no spaces or tabs Copper could read")
            }
        }

        if choice.bookmarks {
            let count = browser.takeBookmarks(from: source)
            report.bookmarks = count
            lines.append("\(count) bookmarks")
            phase = .moving(lines)
        }

        if choice.history {
            let places = await Task.detached(priority: .userInitiated) { FlowChromium.places(in: source) }.value
            for place in places {
                browser.history.take(place.url, title: place.title, count: place.count, last: place.last)
            }
            browser.history.settle()
            report.places = places.count
            lines.append("\(report.places) places")
            phase = .moving(lines)
        }

        if choice.passwords || choice.cookies || choice.passkeys {
            lines.append("asking macOS for \(source.name)'s key…")
            phase = .moving(lines)
            // The keychain read, the decryption and the SQLite copies all
            // happen off the main actor; this is where the old path froze the
            // window behind macOS's prompt.
            let unlocked = await Task.detached(priority: .userInitiated) { () -> Result<Unlocked, Error> in
                Result {
                    let key = try Chromium.key(for: reader)
                    var found = Unlocked()
                    if choice.passwords { found.logins = try Chromium.read(reader, key: key) }
                    if choice.cookies { found.cookies = try FlowCookies.read(reader, key: key, profiles: source.profiles) }
                    if choice.passkeys { found.passkeys = try FlowPasskeys.read(reader, key: key, profiles: source.profiles) }
                    return found
                }
            }.value
            lines.removeLast()
            switch unlocked {
            case .success(let found):
                if let logins = found.logins {
                    for login in logins.logins where Vault.save(host: login.host, user: login.user, password: login.password, used: login.used) {
                        report.passwords += 1
                    }
                    var never = Vault.never
                    logins.never.forEach { never.insert($0) }
                    Vault.never = never
                    browser.relist()
                    lines.append("\(report.passwords) passwords")
                }
                if let cookies = found.cookies {
                    report.cookies = cookies.count
                    Task { [cookies] in
                        let store = Store.websites.httpCookieStore
                        _ = await FlowCookies.install(cookies, into: store)
                    }
                    lines.append("\(report.cookies) cookies")
                }
                if let passkeys = found.passkeys {
                    report.passkeys = FlowPasskeys.install(passkeys, from: source.name)
                    lines.append("\(report.passkeys) passkeys")
                }
            case .failure(Chromium.Trouble.noPassphrase):
                report.notes.append("macOS did not hand over \(source.name)'s key")
                if choice.passwords { lines.append("passwords: needs your OK from macOS") }
                if choice.cookies { lines.append("cookies: needs your OK from macOS") }
                if choice.passkeys { lines.append("passkeys: needs your OK from macOS") }
            case .failure:
                report.notes.append("couldn't read \(source.name)'s key")
                if choice.passwords { lines.append("passwords: not readable") }
                if choice.cookies { lines.append("cookies: not readable") }
                if choice.passkeys { lines.append("passkeys: not readable") }
            }
            phase = .moving(lines)
        }

        if choice.localStorage {
            await moveLocalStorage(source, haul: haul, report: &report, lines: &lines)
        }

        if choice.extensions {
            let extensions = haul.extensions
            if #available(macOS 15.4, *) {
                report.extensions = FlowExtensions.install(extensions) { [weak self, weak browser] landed in
                    guard let self, case .done(var report) = self.phase else { return }
                    report.extensions = landed
                    self.phase = .done(report)
                    browser?.announce(landed == 0 ? "No extensions could be installed" : "\(landed) extensions installed")
                }
                if report.extensions > 0 {
                    report.notes.append("extensions are still installing in the background")
                }
            } else {
                report.notes.append("extensions need macOS 15.4 or later")
            }
            lines.append("\(report.extensions) extensions")
            phase = .moving(lines)
        }

        report.notes.append(contentsOf: haul.notes.filter { !$0.contains("bookmarks") && !$0.contains("places") })
        // Refresh saved passwords only when this move actually touched them;
        // Vault.all can ask the keychain for approval even for a tabs-only move.
        if choice.passwords { browser.relist() }
        browser.objectWillChange.send()
        Session.write(now: true, Spaces.shared.shape(visible: browser.tabs, active: browser.activeID))
        if source.isArc {
            let now = Date()
            Store.settings.set(now.timeIntervalSince1970, forKey: Self.arcMovedKey)
            arcMovedAt = now
            moveAgain = false
        }
        phase = .done(report)
    }

    /// What the keychain key unlocked, read in one detached pass.
    private struct Unlocked {
        var logins: Chromium.Found?
        var cookies: [FlowModel.Cookie]?
        var passkeys: [FlowModel.Passkey]?
    }

    /// Reads the browser's localStorage LevelDBs off the main actor, then has
    /// `StorageImport` set it origin by origin in a hidden web view — the one
    /// part WebKit insists happen here, awaited so the window keeps drawing.
    /// Every profile's storage goes into the shared store (where a space with
    /// no profile looks); a profile that one of the moved spaces wears also
    /// gets its own into that profile's store.
    private func moveLocalStorage(_ source: FlowSource, haul: FlowModel.Haul, report: inout Report, lines: inout [String]) async {
        lines.append("reading local storage…")
        phase = .moving(lines)
        let root = source.root
        let found = await Task.detached(priority: .userInitiated) { FlowLocalStorage.read(root: root) }.value
        found.warnings.forEach { NSLog("Copper: Flow local storage: %@", $0) }
        var plan = [StorageImport.Target(label: "shared", store: StorageImport.sharedStore,
                                         data: found.merged, origins: found.merged.keys.sorted())]
        let worn = Set(haul.spaces.compactMap(\.profile))
        for (name, origins) in found.profiles where worn.contains(name) && !origins.isEmpty {
            plan.append(StorageImport.Target(label: "profile:\(name)", store: Spaces.store(forProfile: name),
                                             data: origins, origins: origins.keys.sorted()))
        }
        let line = lines.count - 1
        let sites = found.merged.count
        let summary = await StorageImport.shared.put(plan) { [weak self] done, total in
            guard let self, case .moving(var shown) = self.phase, line < shown.count else { return }
            // Count every few origins rather than redraw the sheet 900 times.
            guard done == total || done.isMultiple(of: 10) else { return }
            shown[line] = "local storage for \(sites) sites… \(done)/\(total)"
            self.phase = .moving(shown)
        }
        guard let summary else {
            lines[line] = "local storage: another import is running"
            report.notes.append("local storage was not moved: an import was already running")
            phase = .moving(lines)
            return
        }
        report.storageSites = sites
        report.storageKeys = found.keyCount
        report.storageKeysSet = summary.keys
        lines[line] = "local storage for \(sites) sites (\(found.keyCount.formatted()) keys)"
        if summary.failedOrigins > 0 {
            report.notes.append("local storage: \(summary.failedOrigins) sites kept only part of theirs (over WebKit's 5 MB, or would not load)")
        }
        if found.partitioned > 0 {
            report.notes.append("left out \(found.partitioned) third-party (partitioned) local storage keys")
        }
        phase = .moving(lines)
    }

    func undo() {
        guard !createdSpaces.isEmpty else { return }
        let ids = createdSpaces
        createdSpaces.removeAll()
        guard let browser = browserForUndo else { return }
        for id in ids { Spaces.shared.remove(id, in: browser) }
        Session.write(now: true, Spaces.shared.shape(visible: browser.tabs, active: browser.activeID))
        phase = .idle
    }

    /// Import just the address history, without opening the larger Flow sheet.
    /// The SQLite copy/read is off the main actor; only the small merge touches
    /// History, which is main-actor isolated.
    func importHistory(preferred name: String = "Arc", in browser: Browser) {
        if case .reading = historyImport { return }
        let source = historySource(named: name, rootOverride: nil)
            ?? (name.caseInsensitiveCompare("Arc") == .orderedSame ? historySource(named: "Chrome", rootOverride: nil) : nil)
        guard let source else {
            browser.announce("No readable \(name) history found")
            return
        }
        historyImport = .reading(source.name, 0)
        let sourceName = source.name
        Task { [weak self, weak browser] in
            let places = await Task.detached(priority: .userInitiated) {
                FlowChromium.places(in: source)
            }.value
            guard let self, let browser else { return }
            self.mergeHistory(places, source: sourceName, into: browser)
        }
    }

    /// Synchronous history import for `bench`, where one request must return
    /// one complete JSON object. It is intentionally available only in a test
    /// world when the caller supplies an isolated root.
    @discardableResult
    func importHistoryNow(named name: String, limit: Int = Int.max, rootOverride: URL?, in browser: Browser) -> [String: Any] {
        guard Store.testing || rootOverride == nil else { return ["error": "history import only works in a test run"] }
        guard let source = historySource(named: name, rootOverride: rootOverride) else {
            return ["error": "no readable \(name) history found"]
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let places = FlowChromium.places(in: source, limit: limit)
        historyImport = .reading(source.name, places.count)
        mergeHistory(places, source: source.name, into: browser)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        return ["source": source.name, "places": places.count, "visits": browser.history.visitCount,
                "seconds": seconds, "historyFile": Store.file("history.json").path]
    }

    private func historySource(named name: String, rootOverride: URL?) -> FlowSource? {
        guard let source = Chromium.known.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        if let rootOverride {
            let profiles = Self.historyProfiles(in: rootOverride)
            guard !profiles.isEmpty else { return nil }
            return FlowSource(source: source, profiles: profiles, isArc: source.name == "Arc", locked: false, rootOverride: rootOverride)
        }
        refreshSources(autoScan: false)
        guard let found = sources.first(where: { $0.id == source.name }), !found.locked else { return nil }
        return found
    }

    private static func historyProfiles(in root: URL) -> [String] {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("History").path) { return [""] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  FileManager.default.fileExists(atPath: entry.appendingPathComponent("History").path)
            else { return nil }
            return entry.lastPathComponent
        }.sorted()
    }

    private func mergeHistory(_ places: [Chromium.Place], source: String, into browser: Browser) {
        historyImport = .reading(source, places.count)
        for (index, place) in places.enumerated() {
            browser.history.take(place.url, title: place.title, count: place.count, last: place.last)
            if index.isMultiple(of: 1000) && index > 0 { historyImport = .reading(source, index) }
        }
        browser.history.settle()
        historyImport = .done(source, places.count, Date())
        browser.announce(places.isEmpty ? "No places from \(source)" : "Brought in \(places.count.formatted()) places from \(source)")
    }

    func close() { open = false }

    /// Lets a person hand over the one protected folder without changing it.
    @MainActor
    func chooseFolder(for source: FlowSource) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = source.root.deletingLastPathComponent()
        panel.message = "Pick the “\(source.name)” folder so Copper may read it. Nothing in it is changed."
        panel.prompt = "Allow"
        panel.begin { [weak self] response in
            guard response == .OK, let picked = panel.url,
                  let root = self?.readableRoot(picked, for: source)
            else { return }
            Self.roots[source.name] = root
            self?.refreshSources(autoScan: false)
            if let updated = self?.source(named: source.name) { self?.scan(updated) }
        }
    }

    private func readableRoot(_ picked: URL, for source: FlowSource) -> URL? {
        let expected = source.source.root.lastPathComponent
        let candidates: [URL]
        if picked.lastPathComponent == expected {
            candidates = [picked]
        } else {
            candidates = [picked.appendingPathComponent(expected, isDirectory: true)]
        }
        for root in candidates {
            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                return root.standardizedFileURL
            } catch {
                continue
            }
        }
        return nil
    }

    func source(named name: String) -> FlowSource? {
        sources.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func benchBookmarks(_ nodes: [Bookmark]) -> [[String: Any]] {
        nodes.map { node in
            if node.isFolder { return ["title": node.title, "children": benchBookmarks(node.children ?? [])] }
            return ["title": node.title, "url": node.url ?? ""]
        }
    }

    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "sources"
        switch op {
        case "import":
            guard Store.testing else { return ["error": "history import only works in a test run"] }
            guard let source = request["source"] as? String else { return ["error": "history import needs arc or chrome"] }
            let limit = (request["limit"] as? Int) ?? Int.max
            let root = (request["root"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL }
            return importHistoryNow(named: source, limit: limit, rootOverride: root, in: browser)
        case "sources":
            refreshSources(autoScan: false)
            return ["sources": sources.map { ["name": $0.name, "profiles": $0.profiles, "profileCount": $0.profileCount, "isArc": $0.isArc, "glyph": $0.glyph, "locked": $0.locked, "root": $0.root.path] }]
        case "root":
            guard Store.testing else { return ["error": "flow root only works in a test run"] }
            guard let name = request["source"] as? String,
                  let source = Chromium.known.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  let path = request["path"] as? String
            else { return ["error": "root needs a known source and path"] }
            let root = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: root.path) else { return ["error": "root does not exist"] }
            Self.roots[source.name] = root
            refreshSources(autoScan: false)
            guard let updated = self.source(named: source.name) else { return ["error": "root is not a readable source"] }
            return ["source": updated.name, "root": updated.root.path, "locked": updated.locked, "profiles": updated.profiles]
        case "bookmarks":
            // In a probe world, inspect the tree that actually landed, not
            // just the source preview (including root order and nesting).
            guard Store.testing else { return ["error": "bookmark tree only works in a test run"] }
            return ["count": browser.bookmarks.count, "roots": Self.benchBookmarks(browser.bookmarks.roots)]
        case "scan":
            guard let source = source(named: request["source"] as? String ?? "") else { return ["error": "no source"] }
            guard !source.locked else { return ["error": "source is locked"] }
            let haul = scanNow(source)
            return ["source": source.name, "tabs": haul.tabCount, "spaces": haul.spaces.count, "groups": haul.groupCount,
                    "bookmarks": haul.bookmarkCount, "places": haul.placeCount,
                    "passkeys": haul.passkeyCount, "extensions": haul.extensions.count,
                    "extensionDetails": haul.extensions.map { item in
                        ["id": item.id, "name": item.name, "enabled": item.enabled] as [String: Any]
                    },
                    "notes": haul.notes]
        case "move":
            // A test run moves freely; the real profile only when the script
            // says so outright (`bench flow move … --real`) — the one way to
            // bring cookies over without clicking through the sheet, and never
            // by accident from a script meant for a test world.
            guard Store.testing || (request["real"] as? Bool) == true else {
                return ["error": "flow move only works in a test run (or with --real)"]
            }
            guard let source = source(named: request["source"] as? String ?? "") else { return ["error": "no source"] }
            if let only = request["only"] as? String {
                choice = FlowModel.Choice()
                choice.tabs = false; choice.bookmarks = false; choice.history = false; choice.passwords = false; choice.cookies = false; choice.localStorage = false; choice.passkeys = false; choice.extensions = false
                for item in only.split(separator: ",").map({ String($0).lowercased() }) {
                    switch item {
                    case "tabs", "spaces": choice.tabs = true
                    case "bookmarks": choice.bookmarks = true
                    case "history", "places": choice.history = true
                    case "passwords": choice.passwords = true
                    case "cookies": choice.cookies = true
                    case "localstorage", "storage": choice.localStorage = true
                    case "passkeys": choice.passkeys = true
                    case "extensions": choice.extensions = true
                    default: break
                    }
                }
            }
            guard !moving else { return ["error": "a move is already running"] }
            _ = scanNow(source)
            // The move runs on (local storage alone is minutes of origins,
            // past the bench's 25 s answer); the script asks `flow status`
            // until it is done, as `storage import` does.
            Task { await move(source, into: browser) }
            return ["started": true, "source": source.name]
        case "status":
            switch phase {
            case .moving(let lines): return ["running": true, "lines": lines]
            case .done(let report):
                return ["running": false, "source": selected?.name ?? "", "report": report.line, "tabs": report.tabs, "spaces": report.spaces, "groups": report.groups,
                        "bookmarks": report.bookmarks, "places": report.places, "passwords": report.passwords, "cookies": report.cookies, "passkeys": report.passkeys, "extensions": report.extensions,
                        "localStorageSites": report.storageSites, "localStorageKeys": report.storageKeys, "localStorageKeysSet": report.storageKeysSet,
                        "arcMovedAt": arcMovedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                        "notes": report.notes]
            default: return ["running": false, "phase": "\(phase)"]
            }
        case "localstorage":
            // The reader alone, written as `arc-localstorage` JSON, so the
            // two readers can be diffed on the same data. Reads only.
            guard let source = source(named: request["source"] as? String ?? "") else { return ["error": "no source"] }
            guard let out = request["path"] as? String else { return ["error": "localstorage needs --path OUT.json"] }
            let root = (request["root"] as? String).map { URL(fileURLWithPath: $0) } ?? source.root
            let started = Date()
            let found = FlowLocalStorage.read(root: root)
            do { try FlowLocalStorage.json(found.merged).write(to: URL(fileURLWithPath: out)) } catch { return ["error": error.localizedDescription] }
            return ["path": out, "origins": found.merged.count, "keys": found.keyCount, "partitioned": found.partitioned,
                    "undecoded": found.undecoded, "warnings": found.warnings, "seconds": Date().timeIntervalSince(started),
                    "profiles": found.profiles.map { "\($0.name): \($0.origins.count)" }]
        case "open":
            // A script's `--only` move leaves its narrowed switches behind;
            // the sheet opens on the defaults a person would see.
            choice = FlowModel.Choice()
            moveAgain = request["again"] as? Bool ?? false
            open = true
            refreshSources()
            return ["open": true, "sources": sources.count, "arcMovedAt": arcMovedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
        case "probe":
            // Why a source was or wasn't found: the folder, whether the app
            // can list it, and which profile folders carry a Preferences file.
            return ["known": Chromium.known.map { source -> [String: Any] in
                var row: [String: Any] = ["name": source.name, "root": source.root.path,
                                          "exists": FileManager.default.fileExists(atPath: source.root.path)]
                let listed: Bool
                do {
                    _ = try FileManager.default.contentsOfDirectory(at: source.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    listed = true
                } catch {
                    listed = false
                }
                row["locked"] = !listed && FileManager.default.fileExists(atPath: source.root.path)
                do {
                    let names = try FileManager.default.contentsOfDirectory(atPath: source.root.path)
                    row["entries"] = names.count
                } catch {
                    row["listError"] = String(describing: error)
                }
                row["profiles"] = FlowChromeTabs.profiles(of: source)
                return row
            }]
        default:
            return ["error": "unknown flow operation \(op)"]
        }
    }
}
