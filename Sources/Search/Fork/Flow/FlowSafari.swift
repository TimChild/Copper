import Foundation

/// Moving in from Safari: one more source in the Move-in sheet, beside
/// Chrome and Arc, on the same sheet, state machine, registry and summary.
///
/// macOS keeps Safari's files behind Full Disk Access, so there are two ways
/// in, and either or both may be there:
///
/// - **Safari's own files**, when Copper may read them (Full Disk Access, or
///   a test world's copy): open windows, tab groups and pinned tabs as
///   spaces, bookmarks and the Reading List, and history, straight from
///   disk. Finding out lists `~/Library/Safari` once and opens its two
///   stores — Full Disk Access answers that and never shows a prompt — and
///   the container's `SafariTabs.db` is opened only after those opened.
/// - **The export.** In Safari, File › Export Browsing Data to File… saves a
///   zip (bookmarks and the Reading List, history, passwords, payment cards,
///   extensions). Dropped on the sheet or picked, it is read in this process
///   (the pick is the consent macOS accepts) and kept for this session only.
///   A bookmarks `.html` or a passwords `.csv` on its own is taken the same
///   way. Passwords come only from here: Safari's own are in the keychain.
///
/// Payment cards and Safari extensions are counted and said out loud, never
/// moved. The readers themselves are pure (FlowSafariFormats.swift); this
/// file decides what a look finds and what stays behind.
enum FlowSafari {
    static let name = "Safari"

    /// Can Copper open Safari's own files?
    enum Access: Equatable {
        /// They open: Full Disk Access, or a test world's copy.
        case readable
        /// macOS refused (the errno; EPERM is Full Disk Access).
        case denied(Int32)
        /// No Safari folder at all — an account that never opened Safari.
        case missing

        var state: FlowAccess.State {
            switch self {
            case .readable: return .readable
            case .denied: return .locked
            case .missing: return .missing
            }
        }
    }

    /// Where Safari keeps things. A test world points both at a copy.
    struct Roots: Equatable, Hashable {
        var library: URL
        var container: URL

        static var system: Roots {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Roots(library: home.appendingPathComponent("Library/Safari", isDirectory: true),
                         container: home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari", isDirectory: true))
        }

        /// A copy laid out as `Safari/` + `Container/`, as a home's
        /// `Library/`, or flat.
        static func copy(at root: URL) -> Roots {
            let fm = FileManager.default
            func has(_ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }
            let library = has("Safari") ? root.appendingPathComponent("Safari", isDirectory: true) : root
            let container: URL
            if has("Container") {
                container = root.appendingPathComponent("Container", isDirectory: true)
            } else if has("Containers/com.apple.Safari/Data/Library/Safari") {
                container = root.appendingPathComponent("Containers/com.apple.Safari/Data/Library/Safari", isDirectory: true)
            } else {
                container = library
            }
            return Roots(library: library, container: container)
        }
    }

    /// What a look through Safari found. Counts only — never a password.
    struct Look: Equatable, Hashable {
        /// Safari's own files were read.
        var direct = false
        /// An export was read.
        var fromExport = false
        var tabs = 0
        var spaces = 0
        var pins = 0
        var tabGroups = 0
        var windows = 0
        var bookmarks = 0
        var readingList = 0
        /// A bookmark file was there to read (the library's or the export's).
        var hasBookmarks = false
        var places = 0
        /// The export had a passwords file.
        var hasPasswords = false
        var passwords = 0
        var passwordsSkipped = 0
        var passwordCodes = 0
        var passwordNotes = 0
        var cards = 0
        var extensions: [String] = []
        var exportedAt: Date?
        var notes: [String] = []
    }

    // MARK: - access, without asking

    /// One listing of `~/Library/Safari` and one open of each store in it —
    /// both answered by Full Disk Access, which never prompts. Nothing in
    /// Safari's container is touched here.
    static func probeAccess(_ roots: Roots) -> Access {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: roots.library.path, isDirectory: &isFolder), isFolder.boolValue else { return .missing }
        do {
            _ = try fm.contentsOfDirectory(atPath: roots.library.path)
        } catch {
            return .denied(posixCode(error))
        }
        for name in ["Bookmarks.plist", "History.db"] {
            let path = roots.library.appendingPathComponent(name).path
            let handle = open(path, O_RDONLY)
            if handle < 0 {
                let code = errno
                if code == ENOENT { continue }
                return .denied(code)
            }
            close(handle)
        }
        return .readable
    }

    static func posixCode(_ error: Error) -> Int32 {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return ns.code == NSFileReadNoPermissionError ? EPERM : EIO
    }

    // MARK: - reading

    /// Everything a move needs, read off the main actor. The passwords stay
    /// text here only for the length of one move.
    struct Collected {
        var tabs = SafariTabsHaul()
        var bookmarks = FlowBookmarksHTML.Sections()
        /// What `FlowBookmarks.take` gets; nil when no bookmark file was
        /// read — then `take` must not run, or it would remove what the last
        /// Safari move brought.
        var bookmarkRead: FlowBookmarks.Read?
        var places: [Chromium.Place] = []
        var passwordsCSV: String?
        var cards = 0
        var extensions: [String] = []
        var exportedAt: Date?
        var direct = false
        var fromExport = false
        var notes: [String] = []

        var spaces: [FlowModel.Space] { tabs.spaces.map(\.space) }
    }

    static func collect(direct: Roots?, export: URL?) -> Collected {
        var out = Collected()
        var exportHTML: String?
        let fm = FileManager.default
        if let roots = direct {
            out.direct = true
            // The container only once the library opened (`probeAccess`).
            let tabs = roots.container.appendingPathComponent("SafariTabs.db")
            if fm.fileExists(atPath: tabs.path) {
                do {
                    out.tabs = try SafariTabsDB.read(at: tabs)
                } catch {
                    out.notes.append("couldn't read Safari's open tabs")
                }
            }
            var lists: [[Chromium.Place]] = []
            for file in historyFiles(roots) {
                do { lists.append(try SafariHistoryDB.places(at: file)) } catch { out.notes.append("couldn't read Safari's history") }
            }
            out.places = SafariHistoryDB.merged(lists)
        }
        if let export {
            do {
                let read = try SafariExport.read(export)
                out.fromExport = true
                out.exportedAt = read.exportedAt
                exportHTML = read.bookmarksHTML
                out.places = SafariHistoryDB.merged([out.places] + read.histories.map(\.places))
                out.passwordsCSV = read.passwordsCSV
                out.cards = read.cardCount
                out.extensions = read.extensions
            } catch {
                out.notes.append((error as? SafariExport.Trouble)?.errorDescription ?? "couldn't read the export")
            }
        }
        // The library's Bookmarks.plist wins over the export's; no file, no take.
        if let found = SafariBookmarks.pick(library: direct?.library.appendingPathComponent("Bookmarks.plist"), exportHTML: exportHTML) {
            out.bookmarks = found.sections
            out.bookmarkRead = found.read
            if !found.read.complete { out.notes.append("couldn't read Safari's bookmarks") }
        }
        return out
    }

    /// History.db, and a profile's own when Safari keeps one per profile.
    static func historyFiles(_ roots: Roots) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        let main = roots.library.appendingPathComponent("History.db")
        if fm.fileExists(atPath: main.path) { out.append(main) }
        for base in [roots.library, roots.container] {
            let profiles = base.appendingPathComponent("Profiles", isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: profiles.path) else { continue }
            for name in names.sorted() {
                let file = profiles.appendingPathComponent(name).appendingPathComponent("History.db")
                if fm.fileExists(atPath: file.path), !out.contains(file) { out.append(file) }
            }
        }
        return out
    }

    static func look(_ got: Collected) -> Look {
        var found = Look()
        found.direct = got.direct
        found.fromExport = got.fromExport
        found.tabs = got.tabs.tabCount
        found.spaces = got.tabs.spaces.count
        found.pins = got.tabs.pinned
        found.tabGroups = got.tabs.tabGroups
        found.windows = got.tabs.windows
        found.bookmarks = got.bookmarks.bookmarkCount
        found.readingList = got.bookmarks.readingListCount
        found.hasBookmarks = got.bookmarkRead != nil
        found.places = got.places.count
        if let csv = got.passwordsCSV {
            let summary = PasswordCSV.summary(csv)
            found.hasPasswords = true
            found.passwords = summary.logins
            found.passwordsSkipped = summary.skipped
            found.passwordCodes = summary.withCodes
            found.passwordNotes = summary.withNotes
        }
        found.cards = got.cards
        found.extensions = got.extensions
        found.exportedAt = got.exportedAt
        found.notes = got.notes
        return found
    }

    static func look(direct: Roots?, export: URL?) -> Look {
        look(collect(direct: direct, export: export))
    }

    /// What the sheet's counts come from: the spaces (for the tab row), the
    /// counts, and Safari's own look.
    static func haul(_ got: Collected) -> FlowModel.Haul {
        var haul = FlowModel.Haul()
        let look = look(got)
        haul.spaces = got.spaces
        haul.bookmarkCount = look.bookmarks + look.readingList
        haul.placeCount = look.places
        haul.loginCount = look.passwords
        haul.safari = look
        haul.notes = got.notes
        return haul
    }

    /// What stayed in Safari, one plain sentence each.
    static func stayed(_ look: Look) -> [String] {
        var out: [String] = []
        if !look.direct {
            out.append("Open tabs and tab groups aren't in Safari's export. To bring them too, allow Copper Full Disk Access and move in again.")
        }
        if !look.hasPasswords {
            out.append(look.fromExport
                ? "This export has no passwords. To bring them, export again from Safari with Passwords ticked."
                : "Passwords are only in Safari's export (File › Export Browsing Data to File…).")
        } else if look.passwordCodes > 0 || look.passwordNotes > 0 {
            out.append("Password notes and one-time codes stayed in Safari.")
        }
        if look.cards > 0 {
            out.append("\(FlowSummary.plural(look.cards, "payment card")) stayed in Safari — Copper doesn't keep card numbers.")
        }
        if !look.extensions.isEmpty {
            let names = look.extensions.prefix(3).joined(separator: ", ") + (look.extensions.count > 3 ? " and \(look.extensions.count - 3) more" : "")
            out.append("Safari extensions (\(names)) only run in Safari.")
        }
        return out
    }

    /// The one line under the checklist naming what can't come.
    static func staysLine(_ look: Look) -> String? {
        var parts: [String] = []
        if look.cards > 0 { parts.append(FlowSummary.plural(look.cards, "payment card")) }
        if !look.extensions.isEmpty { parts.append(FlowSummary.plural(look.extensions.count, "Safari extension")) }
        guard !parts.isEmpty else { return nil }
        return "Stays in Safari: " + parts.joined(separator: " and ") + "."
    }

    // MARK: - bench

    static func describe(_ access: Access) -> String {
        switch access {
        case .readable: return "readable"
        case .missing: return "missing"
        case .denied(let code): return "denied (errno \(code): \(String(cString: strerror(code))))"
        }
    }

    /// Why Safari is or isn't readable, measured the way the card measures
    /// it (`bench flow access --source Safari`). The container is opened
    /// only when the library opened: without Full Disk Access it is never
    /// touched, so nothing can prompt.
    static func report(_ roots: Roots) -> [String: Any] {
        let fm = FileManager.default
        var library: [String: Any] = ["path": roots.library.path, "exists": fm.fileExists(atPath: roots.library.path)]
        do {
            library["entries"] = try fm.contentsOfDirectory(atPath: roots.library.path).count
        } catch {
            let code = posixCode(error)
            library["listErrno"] = Int(code)
            library["listError"] = String(cString: strerror(code))
        }
        for name in ["Bookmarks.plist", "History.db"] {
            let handle = open(roots.library.appendingPathComponent(name).path, O_RDONLY)
            if handle < 0 {
                let code = errno
                library[name] = "errno \(code): \(String(cString: strerror(code)))"
            } else {
                close(handle)
                library[name] = "opened"
            }
        }
        let access = probeAccess(roots)
        var container: [String: Any] = ["path": roots.container.path]
        if access == .readable {
            let handle = open(roots.container.appendingPathComponent("SafariTabs.db").path, O_RDONLY)
            if handle < 0 {
                let code = errno
                container["SafariTabs.db"] = "errno \(code): \(String(cString: strerror(code)))"
            } else {
                close(handle)
                container["SafariTabs.db"] = "opened"
            }
        } else {
            container["SafariTabs.db"] = "not tried — the library did not open, so the container is left alone"
        }
        return ["source": name, "state": "\(access.state)", "access": describe(access), "library": library, "container": container]
    }
}

extension FlowSafari {
    /// What a Safari move can bring of what was chosen: tabs only from its
    /// own files, passwords only from an export that has them, and nothing
    /// Safari doesn't have (sign-ins, site data, passkeys, extensions).
    static func usable(_ choice: FlowModel.Choice, direct: Bool, look: Look?) -> FlowModel.Choice {
        var out = FlowModel.Choice()
        out.tabs = choice.tabs && direct
        out.bookmarks = choice.bookmarks
        out.history = choice.history
        out.passwords = choice.passwords && (look?.hasPasswords ?? false)
        out.cookies = false
        out.localStorage = false
        out.passkeys = false
        out.extensions = false
        return out
    }

    static func anything(_ choice: FlowModel.Choice) -> Bool {
        choice.tabs || choice.bookmarks || choice.history || choice.passwords
    }
}
