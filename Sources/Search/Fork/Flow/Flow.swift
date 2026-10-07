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
    /// All the pure rules in FlowState need of it.
    var candidate: FlowCandidate { FlowCandidate(id: id, readable: !locked) }

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
    /// A test run may list only some sources (`bench flow limit`), so a
    /// script sees its fixtures and not whatever this Mac has installed.
    @MainActor static var only: Set<String>?

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
        /// The local guide opened after a Chrome move, if its tab came up.
        var canvasId: String?
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

        /// For the event log and the bench: which phase, not its contents.
        var name: String {
            switch self {
            case .idle: return "idle"
            case .scanning: return "scanning"
            case .preview: return "preview"
            case .moving: return "moving"
            case .done: return "done"
            }
        }
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
    /// This is also what the quiet nudge under an empty address field checks
    /// — and it says "Arc", so without a name only Arc's folder is looked
    /// at. Chrome's is one macOS protects: walking it on every empty field
    /// would put a refusal on record each time, with nobody having asked.
    static func hasHistorySource(_ name: String? = nil) -> Bool {
        let wanted = (name ?? "Arc").lowercased()
        return Chromium.known.contains { source in
            guard wanted == source.name.lowercased() else { return false }
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

    /// Whether the sheet is up. Only `present(from:via:)` turns it on and
    /// only `close()` turns it off; `FlowPresenter` follows it, and is the
    /// one thing that puts a sheet on screen.
    @Published private(set) var open = false
    @Published private(set) var sources: [FlowSource] = []
    /// The sources have been looked for since the sheet opened. Until then
    /// the picker draws nothing rather than "No other browser found".
    @Published private(set) var sourcesKnown = false
    @Published var choice = FlowModel.Choice()
    @Published private(set) var phase: Phase = .idle {
        didSet { if phase.name != oldValue.name { log("phase", phase.name) } }
    }
    @Published private(set) var selected: FlowSource?
    @Published private(set) var historyImport: HistoryImportState = .idle
    /// When each source was last moved in, by name. A move is a one-time
    /// thing, so once a source has one the sheet says so and wants "Move in
    /// again" before it will run.
    @Published private(set) var movedAt: [String: Date] = Flow.movedAtSetting
    @Published var moveAgain = false

    /// When Arc was last moved in (older scripts read this name).
    var arcMovedAt: Date? { movedAt["Arc"] }

    private static let movedKey = "flow.movedAt"
    private static var movedAtSetting: [String: Date] {
        var out: [String: Date] = [:]
        for (name, value) in Store.settings.dictionary(forKey: movedKey) ?? [:] {
            if let stamp = value as? Double, stamp > 0 { out[name] = Date(timeIntervalSince1970: stamp) }
        }
        // Before every source had a date, only Arc's was kept.
        let arc = Store.settings.double(forKey: "flow.arcMovedAt")
        if out["Arc"] == nil, arc > 0 { out["Arc"] = Date(timeIntervalSince1970: arc) }
        return out
    }

    private func noteMoved(_ name: String, at date: Date) {
        movedAt[name] = date
        Store.settings.set(movedAt.mapValues { $0.timeIntervalSince1970 }, forKey: Self.movedKey)
        moveAgain = false
    }

    private var lastHaul = FlowModel.Haul()
    private var createdSpaces: [UUID] = []
    private weak var browserForUndo: Browser?

    /// The window that asked for the sheet; the presenter hangs it there.
    private(set) weak var requester: Browser?
    /// What the sheet did, for `bench flow events`.
    private(set) var events = FlowEvents()
    /// Only the newest scan, for the selected source, may land.
    private var ticket = FlowScanTicket()
    /// The source whose counts are on screen or being read.
    private var previewed: String?
    /// Only the newest look for sources may land.
    private var detection = 0
    private var activation: NSObjectProtocol?

    private init() {
        // Nothing is read here. Listing another browser's folder is a request
        // macOS records (and for Chrome's, refuses), so it waits until a
        // person opens Move in — never at launch, never behind their back.
        FlowPresenter.shared.start(self)
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
    }

    func log(_ kind: String, _ detail: String = "") {
        events.record(kind, detail, at: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - the sheet

    /// Every way in: ⌘K, the Settings row, the menu, the bench.
    enum Door: String { case command, settings, menu, bench }

    /// The one way to bring the sheet up. Each time it opens it starts
    /// fresh — a finished move is behind it, the switches are back to all on
    /// — unless a move is still running, which it shows.
    func present(from browser: Browser?, via door: Door) {
        log("open", door.rawValue)
        requester = browser ?? Windows.current
        guard !open else { return }
        if !moving {
            phase = .idle
            selected = nil
            previewed = nil
            lastHaul = FlowModel.Haul()
            ticket.cancel()
            choice = FlowModel.Choice()
            moveAgain = false
        }
        open = true
        refresh("open")
    }

    /// Settings closes first, with nothing animating, and the sheet comes up
    /// on the next turn: opening it inside Settings' closing animation
    /// animated the sheet's first layout too, and its text morphed.
    static func presentFromSettings(_ browser: Browser) {
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) { browser.tuning = false }
        DispatchQueue.main.async { Flow.shared.present(from: browser, via: .settings) }
    }

    func close() {
        guard open else { return }
        log("close")
        open = false
        guard !moving else { return }
        // A read still running belongs to a sheet nobody is looking at.
        ticket.cancel()
        if case .scanning = phase {
            phase = .idle
            previewed = nil
        }
    }

    /// Back from System Settings (or any other app): the one thing worth
    /// looking at again is a source that was locked. Nothing else is re-read.
    private func becameActive() {
        let candidates = sources.map(\.candidate)
        guard FlowMachine.recheckOnActivation(sources: candidates, open: open) else { return }
        refresh("activation")
    }

    // MARK: - sources

    /// Looks for sources off the main actor and lands the newest answer.
    func refresh(_ reason: String) {
        detection += 1
        let generation = detection
        let roots = Self.roots
        let only = Self.only
        log("refresh", reason)
        Task.detached(priority: .userInitiated) {
            let found = Flow.detect(roots: roots, only: only)
            await MainActor.run { [weak self] in
                guard let self, generation == self.detection else { return }
                self.apply(found, autoScan: true)
            }
        }
    }

    /// Synchronous form for the bench and the history row, which answer at
    /// once and are not the sheet.
    func refreshSources(autoScan: Bool = false) {
        detection += 1
        apply(Self.detect(roots: Self.roots, only: Self.only), autoScan: autoScan)
    }

    /// Makes one real directory-list attempt before declaring a source locked.
    nonisolated static func detect(roots: [String: URL], only: Set<String>? = nil) -> [FlowSource] {
        let fm = FileManager.default
        return Chromium.known.compactMap { source in
            if let only, !only.contains(source.name) { return nil }
            let override = roots[source.name].flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
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
    }

    /// Publishes a new source list only when it differs, and selects and
    /// reads by `FlowMachine.reconcile`: a selection is kept, the only
    /// readable source is picked for you, nothing changes during a move.
    private func apply(_ found: [FlowSource], autoScan: Bool) {
        if sources != found { sources = found }
        if !sourcesKnown { sourcesKnown = true }
        let decision = FlowMachine.reconcile(
            sources: found.map(\.candidate), selected: selected?.id, previewed: previewed, busy: moving
        )
        guard !moving else { return }
        if decision.resetPreview {
            ticket.cancel()
            previewed = nil
            lastHaul = FlowModel.Haul()
            phase = .idle
        }
        let next = decision.selected.flatMap { id in found.first { $0.id == id } }
        if next != selected { selected = next }
        guard autoScan, let id = decision.scan, let source = found.first(where: { $0.id == id }) else { return }
        scan(source, reason: "auto")
    }

    /// Reads the cheap, non-secret parts off the main actor. Picking the
    /// source already on screen reads nothing again.
    func scan(_ source: FlowSource, reason: String = "pick") {
        guard !source.locked, !moving else { return }
        if selected?.id == source.id, previewed == source.id {
            switch phase {
            case .scanning, .preview: return
            default: break
            }
        }
        selected = source
        previewed = source.id
        let number = ticket.issue(for: source.id)
        phase = .scanning
        log("scan", "\(source.id) \(reason)")
        Task.detached(priority: .userInitiated) { [source] in
            let haul = Flow.read(source)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.ticket.accepts(number, for: source.id, selected: self.selected?.id) else {
                    self.log("scan-dropped", source.id)
                    return
                }
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
        previewed = source.id
        _ = ticket.issue(for: source.id)
        log("scan", "\(source.id) bench")
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
        haul.bookmarkCount = FlowBookmarks.count(FlowChromium.bookmarks(in: source).nodes)
        haul.placeCount = FlowChromium.places(in: source).count
        haul.notes.append("\(haul.bookmarkCount) bookmarks")
        haul.notes.append("\(haul.placeCount) places")
        return haul
    }

    var moving: Bool { if case .moving = phase { return true } else { return false } }

    /// The big button can run: a readable source chosen, its counts in.
    var canMove: Bool {
        guard let selected, !selected.locked, !moving else { return false }
        if case .scanning = phase { return false }
        return true
    }

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
        noteMoved(source.name, at: Date())
        // The guide is Chrome-specific (shortcuts and sidebar copy), not a
        // generic Chromium guide. Do this last, after every imported row has
        // landed, so the canvas is the final foreground tab. The move is done
        // first: background extension installs report into a .done phase, and
        // may land while the canvas loads.
        phase = .done(report)
        guard source.name == "Chrome", let id = await landChromeCanvas(in: browser) else { return }
        if case .done(var latest) = phase {
            latest.canvasId = id
            phase = .done(latest)
        }
        open = false
    }

    private static let chromeCanvasKey = "flow.chromeCanvasID"
    private static let chromeCanvasName = "Switching from Chrome"

    /// A renamed guide still belongs to this move; a deleted one may be made
    /// again. Never apply the template to an existing board — it may have been
    /// edited by its owner, and a failed first apply must not duplicate ops.
    private func landChromeCanvas(in browser: Browser) async -> String? {
        let canvases = Canvases.shared
        let remembered = Store.settings.string(forKey: Self.chromeCanvasKey)
            .flatMap { canvases.entry($0) }
            .flatMap { $0.kind == .local ? $0 : nil }
        let existing = remembered ?? canvases.visible.first {
            $0.kind == .local && $0.name.compare(Self.chromeCanvasName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        do {
            // CanvasPage.folder uses the same Search_Search.bundle resolution as
            // canvas.html, both beside the bare binary and inside Copper.app.
            let ops: [Any]?
            if existing == nil {
                guard let folder = CanvasPage.folder else { throw CanvasHost.Failure(text: "canvas resource bundle is missing") }
                let data = try Data(contentsOf: folder.appendingPathComponent("switching-from-chrome.json"))
                ops = try JSONSerialization.jsonObject(with: data) as? [Any]
                guard ops != nil else { throw CanvasHost.Failure(text: "guide ops are not an array") }
            } else {
                ops = nil
            }
            let entry = existing ?? canvases.createLocal(named: Self.chromeCanvasName)
            Store.settings.set(entry.id, forKey: Self.chromeCanvasKey)
            let host = try await CanvasTools.open(entry, in: browser, foreground: true)
            try await host.waitReady()
            if let ops {
                let result = try await host.apply(ops, as: CanvasAgent(id: "agent:copper", name: "Copper", color: CanvasColors.stable("Copper")))
                let applied = result["applied"] as? Int ?? 0
                let errors = result["errors"] as? [Any] ?? []
                guard applied == ops.count, errors.isEmpty else {
                    throw CanvasHost.Failure(text: "guide applied \(applied)/\(ops.count) ops (\(errors.count) errors)")
                }
                try await host.zoom(to: ["sfc_header", "sfc_f_map"])
            }
            CanvasHost.show(entry.id, in: browser, foreground: true)
            return entry.id
        } catch {
            NSLog("Copper: Flow Chrome canvas: %@", String(describing: error))
            return nil
        }
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
            if node.isFolder { return ["id": node.id.uuidString, "title": node.title, "children": benchBookmarks(node.children ?? [])] }
            return ["id": node.id.uuidString, "title": node.title, "url": node.url ?? ""]
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
        case "bookmark-move":
            guard Store.testing, let id = (request["id"] as? String).flatMap(UUID.init(uuidString:)),
                  browser.bookmarks.roots.contains(where: { $0.id == id })
            else { return ["error": "bookmark-move requires a probe-world top-level id"] }
            browser.bookmarks.move(id, into: nil)
            return ["roots": Self.benchBookmarks(browser.bookmarks.roots)]
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
                choice = FlowBench.choice(only: only)
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
                        "canvasId": report.canvasId ?? "", "notes": report.notes]
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
            // Through the same door a person would use (`--via settings`
            // presses the Settings row, Settings first opened behind it);
            // the sheet opens on the defaults a person would see. Opening
            // is asynchronous, as it is for a person: ask `flow state`.
            let windows = Windows.all
            let at = (request["window"] as? Int).flatMap { windows.indices.contains($0) ? windows[$0] : nil } ?? browser
            switch request["via"] as? String ?? "bench" {
            case "settings":
                at.tuning = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Flow.presentFromSettings(at) }
            case "command": present(from: at, via: .command)
            case "menu": present(from: at, via: .menu)
            default: present(from: at, via: .bench)
            }
            if request["again"] as? Bool == true { moveAgain = true }
            return ["opening": true, "window": windows.firstIndex { $0 === at } ?? 0,
                    "arcMovedAt": arcMovedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
        case "close":
            close()
            return ["open": open]
        case "state":
            // What the sheet shows and where it is: one sheet, one size.
            var out = FlowPresenter.shared.describe()
            out["open"] = open
            out["phase"] = phase.name
            out["selected"] = selected?.name ?? ""
            out["sourcesKnown"] = sourcesKnown
            out["sources"] = sources.map { ["name": $0.name, "locked": $0.locked] as [String: Any] }
            out["moveAgain"] = moveAgain
            out["movedAt"] = movedAt.mapValues { ISO8601DateFormatter().string(from: $0) }
            out["choice"] = FlowBench.choice(choice)
            if case .moving(let lines) = phase { out["lines"] = lines }
            return out
        case "events":
            // Counts of what the sheet did since the last `--clear`.
            let log = events
            if request["clear"] as? Bool == true { events.clear() }
            var counts: [String: Int] = [:]
            for entry in log.entries { counts[entry.kind, default: 0] += 1 }
            return ["counts": counts, "overlapping": log.overlapping, "scansPerOpen": log.scansPerOpen,
                    "entries": log.entries.suffix(request["all"] as? Bool == true ? FlowEvents.limit : 60).map {
                        ["at": ($0.at * 1000).rounded() / 1000, "kind": $0.kind, "detail": $0.detail] as [String: Any]
                    }]
        case "key":
            return FlowPresenter.shared.press(request["key"] as? String ?? "")
        case "shot":
            guard let path = request["path"] as? String else { return ["error": "shot needs --path OUT.png"] }
            return FlowPresenter.shared.shot(to: path)
        case "choose":
            // The switches, set as a person would before pressing the big
            // button: `--only tabs,history`, everything else off.
            guard Store.testing else { return ["error": "flow choose only works in a test run"] }
            choice = FlowBench.choice(only: request["only"] as? String ?? "")
            return ["choice": FlowBench.choice(choice)]
        case "limit":
            guard Store.testing else { return ["error": "flow limit only works in a test run"] }
            let names = (request["only"] as? String ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Nothing is read here: a script may limit the list before it
            // points a source at a copy, so the real folder is never listed.
            Self.only = names.isEmpty ? nil : Set(names)
            return ["only": names]
        case "activate":
            // What coming back from System Settings does, without anything
            // being brought to the front.
            guard Store.testing else { return ["error": "flow activate only works in a test run"] }
            becameActive()
            return ["open": open, "rechecking": FlowMachine.recheckOnActivation(sources: sources.map(\.candidate), open: open)]
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
