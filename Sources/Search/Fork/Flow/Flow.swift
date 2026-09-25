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
        var notes: [String] = []

        var line: String {
            "\(tabs) tabs in \(spaces) spaces · \(groups) groups · \(bookmarks) bookmarks · \(places) places · \(passwords) passwords · \(cookies) cookies · \(passkeys) passkeys · \(extensions) extensions"
        }
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case preview(FlowModel.Haul)
        case moving([String])
        case done(Report)
    }

    @Published var open = false
    @Published private(set) var sources: [FlowSource] = []
    @Published var choice = FlowModel.Choice()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selected: FlowSource?

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
        haul.bookmarkCount = FlowChromium.bookmarks(in: source).count
        haul.placeCount = FlowChromium.places(in: source).count
        haul.notes.append("\(haul.bookmarkCount) bookmarks")
        haul.notes.append("\(haul.placeCount) places")
        return haul
    }

    /// Performs each choice independently. A failure is a line in the report,
    /// never a reason to abandon the remaining data.
    func move(_ source: FlowSource, into browser: Browser) {
        guard !source.locked else { return }
        browserForUndo = browser
        selected = source
        let haul = lastHaul.spaces.isEmpty && !lastHaul.notes.isEmpty ? Flow.read(source) : lastHaul
        var report = Report()
        var lines: [String] = []
        phase = .moving(lines)

        if choice.tabs {
            let adopted = Spaces.shared.adopt(haul.spaces, in: browser, sourceName: source.name, sourceIsArc: source.isArc)
            createdSpaces = adopted.spaces
            report.tabs = adopted.tabs
            report.spaces = adopted.spaces.count
            report.groups = adopted.groups
            lines.append("\(report.tabs) tabs in \(report.spaces) spaces")
            phase = .moving(lines)
        }

        if choice.bookmarks {
            let count = browser.takeBookmarks(from: source)
            report.bookmarks = count
            lines.append("\(count) bookmarks")
            phase = .moving(lines)
        }

        if choice.history {
            let places = FlowChromium.places(in: source)
            for place in places {
                browser.history.take(place.url, title: place.title, count: place.count, last: place.last)
            }
            browser.history.settle()
            report.places = places.count
            lines.append("\(report.places) places")
            phase = .moving(lines)
        }

        if choice.passwords || choice.cookies || choice.passkeys {
            do {
                let key = try Chromium.key(for: source.readerSource)
                if choice.passwords {
                    let found = try Chromium.read(source.readerSource, key: key)
                    for login in found.logins where Vault.save(host: login.host, user: login.user, password: login.password, used: login.used) {
                        report.passwords += 1
                    }
                    var never = Vault.never
                    found.never.forEach { never.insert($0) }
                    Vault.never = never
                    browser.relist()
                    lines.append("\(report.passwords) passwords")
                }
                if choice.cookies {
                    let cookies = try FlowCookies.read(source.readerSource, key: key, profiles: source.profiles)
                    report.cookies = cookies.count
                    Task { [cookies] in
                        let store = Store.websites.httpCookieStore
                        _ = await FlowCookies.install(cookies, into: store)
                    }
                    lines.append("\(report.cookies) cookies")
                }
                if choice.passkeys {
                    let passkeys = try FlowPasskeys.read(source.readerSource, key: key, profiles: source.profiles)
                    report.passkeys = FlowPasskeys.install(passkeys, from: source.name)
                    lines.append("\(report.passkeys) passkeys")
                }
            } catch Chromium.Trouble.noPassphrase {
                report.notes.append("macOS did not hand over \(source.name)'s key")
                if choice.passwords { lines.append("passwords: needs your OK from macOS") }
                if choice.cookies { lines.append("cookies: needs your OK from macOS") }
                if choice.passkeys { lines.append("passkeys: needs your OK from macOS") }
            } catch {
                report.notes.append("couldn't read \(source.name)'s key")
                if choice.passwords { lines.append("passwords: not readable") }
                if choice.cookies { lines.append("cookies: not readable") }
                if choice.passkeys { lines.append("passkeys: not readable") }
            }
            phase = .moving(lines)
        }

        if choice.extensions {
            let extensions = haul.extensions
            if #available(macOS 15.4, *) {
                report.extensions = FlowExtensions.install(extensions)
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
        phase = .done(report)
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

    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "sources"
        switch op {
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
        case "scan":
            guard let source = source(named: request["source"] as? String ?? "") else { return ["error": "no source"] }
            guard !source.locked else { return ["error": "source is locked"] }
            let haul = scanNow(source)
            return ["source": source.name, "tabs": haul.tabCount, "spaces": haul.spaces.count, "groups": haul.groupCount,
                    "bookmarks": haul.bookmarkCount, "places": haul.placeCount,
                    "passkeys": haul.passkeyCount, "extensions": haul.extensions.count, "notes": haul.notes]
        case "move":
            guard Store.testing else { return ["error": "flow move only works in a test run"] }
            guard let source = source(named: request["source"] as? String ?? "") else { return ["error": "no source"] }
            if let only = request["only"] as? String {
                choice = FlowModel.Choice()
                choice.tabs = false; choice.bookmarks = false; choice.history = false; choice.passwords = false; choice.cookies = false; choice.passkeys = false; choice.extensions = false
                for item in only.split(separator: ",").map({ String($0).lowercased() }) {
                    switch item {
                    case "tabs", "spaces": choice.tabs = true
                    case "bookmarks": choice.bookmarks = true
                    case "history", "places": choice.history = true
                    case "passwords": choice.passwords = true
                    case "cookies": choice.cookies = true
                    case "passkeys": choice.passkeys = true
                    case "extensions": choice.extensions = true
                    default: break
                    }
                }
            }
            _ = scanNow(source)
            move(source, into: browser)
            if case .done(let report) = phase {
                return ["source": source.name, "report": report.line, "tabs": report.tabs, "spaces": report.spaces, "groups": report.groups,
                        "bookmarks": report.bookmarks, "places": report.places, "passwords": report.passwords, "cookies": report.cookies, "passkeys": report.passkeys, "extensions": report.extensions,
                        "notes": report.notes]
            }
            return ["error": "flow did not finish"]
        case "open":
            open = true
            refreshSources()
            return ["open": true, "sources": sources.count]
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
