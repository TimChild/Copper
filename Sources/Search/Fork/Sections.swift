import SwiftUI

// The sidebar's three sections, as Arc has them.
//
//   Favourites   the pin grid at the top — upstream's pins, untouched.
//   Saved        the tabs you keep. Above the hairline and the New Tab row.
//   Today        everything else, newest first, under that row.
//
// Which of the two lower sections a tab is in is a fact about the tab, not a
// guess about when it arrived: `saved` is an explicit set, written into the
// session as one optional flag per entry and read back the same way. An
// upstream-shaped file has no flag, so everything in it restores as saved and
// nothing regresses.
//
// Today is swept: a row nobody has looked at for the archive window (a day,
// by default) is closed through `Browser.close`, the same path the cross on
// the row takes, so it lands in Reopen Closed Tab rather than disappearing.

@MainActor
final class Sections: ObservableObject {
    static let shared = Sections()

    /// How long a Today row may sit unlooked-at before it is archived.
    enum Archive: String, Codable, CaseIterable, Identifiable {
        case h12, h24, h48, never

        var id: String { rawValue }

        var title: String {
            switch self {
            case .h12: return "12h"
            case .h24: return "24h"
            case .h48: return "48h"
            case .never: return "Never"
            }
        }

        var hours: Double? {
            switch self {
            case .h12: return 12
            case .h24: return 24
            case .h48: return 48
            case .never: return nil
            }
        }
    }

    /// The tabs you keep. Pins are not in here — they are their own section.
    @Published private(set) var saved: Set<Tab.ID> = []

    @Published var archive: Archive {
        didSet { Store.settings.set(archive.rawValue, forKey: "sections.archive") }
    }

    /// When each tab was last looked at. Kept here rather than on `Tab`,
    /// which starts every restored row's clock at launch and so would make
    /// the whole of yesterday look like this minute.
    private var seen: [Tab.ID: Date] = [:]

    private var sweeper: Timer?

    /// How many rows the last sweep took, for the bench.
    private(set) var lastSwept = 0

    /// The row that has just been saved. Saved lands at the bottom of a
    /// block that may be scrolled far above it, so the column brings it into
    /// view rather than letting the tab appear to vanish.
    @Published private(set) var reveal: Tab.ID?

    private init() {
        archive = Store.settings.string(forKey: "sections.archive").flatMap(Archive.init(rawValue:)) ?? .h24
    }

    // MARK: - reading

    /// A grouped tab is saved whatever its flag says: folders live in Saved,
    /// so a Today row dragged into one comes up with it.
    func isSaved(_ tab: Tab) -> Bool {
        saved.contains(tab.id) || Groups.shared.membership[tab.id] != nil
    }

    /// A tab the sections have never met — a ⌘T tab, a link opened in the
    /// background, a bench tab. It belongs at the top of Today.
    func knows(_ tab: Tab) -> Bool { seen[tab.id] != nil || saved.contains(tab.id) }

    /// When the row was last in front. A tab that is awake has been looked
    /// at this session whatever the file said, so its own clock wins.
    func lastSeen(_ tab: Tab) -> Date {
        guard let stored = seen[tab.id] else { return Date() }
        return tab.asleep ? stored : max(stored, tab.touched)
    }

    // MARK: - moving between the two

    func note(_ id: Tab.ID?) {
        guard let id else { return }
        seen[id] = Date()
    }

    /// Save a row or let it go. Saving parks it at the end of the Saved run;
    /// unsaving puts it at the top of Today, where the newest rows are.
    func set(_ tab: Tab, saved on: Bool, in browser: Browser) {
        guard tab.pin == nil else { return }
        if on {
            saved.insert(tab.id)
        } else {
            saved.remove(tab.id)
            // Folders live in Saved. A row that leaves Saved leaves its
            // folder with it, or it would be pulled straight back up.
            if Groups.shared.membership[tab.id] != nil { Groups.shared.remove(tab) }
            seen[tab.id] = Date()
        }
        let kept = browser.tabs.filter { $0.pin == nil && isSaved($0) }.count
        browser.move(tab, to: browser.pinnedCount + max(0, on ? kept - 1 : kept))
        reveal = on ? tab.id : nil
    }

    /// A row that has just appeared: it is today's, it has been seen now,
    /// and Arc puts it at the top of the block rather than the bottom.
    /// Called as the column redraws, so nothing else has to remember to.
    func arrived(in browser: Browser) {
        let fresh = browser.tabs.filter { $0.pin == nil && !knows($0) }
        guard !fresh.isEmpty else { return }
        for tab in fresh { seen[tab.id] = Date() }
        let top = browser.pinnedCount + browser.tabs.filter { $0.pin == nil && isSaved($0) }.count
        // Newest first: the last one to arrive ends up above the rest.
        for tab in fresh { browser.move(tab, to: top) }
    }

    // MARK: - the sweep

    /// Everything in Today nobody has looked at inside the window, closed the
    /// ordinary way. The row you are on is never taken out from under you.
    @discardableResult
    func sweep(in browser: Browser, olderThan override: Double? = nil) -> Int {
        guard let hours = override ?? archive.hours else { lastSwept = 0; return 0 }
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        let stale = browser.tabs.filter {
            $0.pin == nil && !isSaved($0) && $0.id != browser.activeID && !$0.isBlank && lastSeen($0) < cutoff
        }
        for tab in stale { browser.close(tab) }
        lastSwept = stale.count
        return stale.count
    }

    /// Once the session is back, and every half hour after. Switching space
    /// sweeps the row that just came on screen (see `Spaces.select`), so the
    /// spaces you are not looking at are not swept behind your back.
    func begin(in browser: Browser) {
        sweeper?.invalidate()
        sweeper = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak browser] _ in
            MainActor.assumeIsolated { if let browser { Sections.shared.sweep(in: browser) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak browser] in
            if let browser { self.sweep(in: browser) }
        }
    }

    // MARK: - the session

    func restore(_ tab: Tab, saved on: Bool, seen when: Double?) {
        if on { saved.insert(tab.id) }
        seen[tab.id] = when.map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    func forget(_ id: Tab.ID) {
        saved.remove(id)
        seen[id] = nil
    }

    func clear() {
        saved.removeAll()
        seen.removeAll()
    }

    // MARK: - the bench

    /// `./bench sections` counts each space's two blocks; `sections save ID`,
    /// `sections unsave ID`, `sections archive` (the sweep, now),
    /// `sections window 12h|24h|48h|never`.
    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let arg = request["arg"] as? String ?? ""
        func find(_ key: String) -> Tab? {
            guard !key.isEmpty else { return nil }
            return browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
        }
        var note: [String: Any] = [:]
        switch request["op"] as? String ?? "" {
        case "save":
            guard let tab = find(arg) else { return ["error": "no tab \(arg)"] }
            set(tab, saved: true, in: browser)
        case "unsave":
            guard let tab = find(arg) else { return ["error": "no tab \(arg)"] }
            set(tab, saved: false, in: browser)
        case "archive":
            // A bare `archive` runs the sweep the clock would have run; an
            // age in hours runs it against that instead, for a test that
            // doesn't want to wait a day for something to go stale.
            note["archived"] = sweep(in: browser, olderThan: Double(arg))
        case "window":
            // 24, 24h, h24 and never all say the same thing.
            let key = arg.lowercased().trimmingCharacters(in: .whitespaces)
            guard let window = Archive(rawValue: key == "never" ? key : "h" + key.filter(\.isNumber)) else {
                return ["error": "window 12h|24h|48h|never"]
            }
            archive = window
        default: break
        }
        func counts(_ tabs: [Tab]) -> [String: Any] {
            let loose = tabs.filter { $0.pin == nil }
            return ["saved": loose.filter { isSaved($0) }.count,
                    "today": loose.filter { !isSaved($0) }.count,
                    "favourites": tabs.count - loose.count]
        }
        let spaces = Spaces.shared
        note["window"] = archive.rawValue
        note["oldest"] = oldestToday(in: browser)
        note["spaces"] = spaces.all.map { space -> [String: Any] in
            var row = counts(space.id == spaces.current ? browser.tabs : (spaces.parkedRow(space.id) ?? []))
            row["name"] = space.name
            row["current"] = space.id == spaces.current
            return row
        }
        note["today"] = browser.tabs.filter { $0.pin == nil && !isSaved($0) }.map { tab -> [String: Any] in
            ["id": String(tab.id.uuidString.prefix(8)).lowercased(), "title": tab.title,
             "seen": Int(Date().timeIntervalSince(lastSeen(tab)) / 3600)]
        }
        return note
    }

    /// How old the oldest Today row is, in hours — so a sweep that took
    /// nothing can say there was nothing to take.
    func oldestToday(in browser: Browser) -> Int {
        let ages = browser.tabs.filter { $0.pin == nil && !isSaved($0) }.map { Date().timeIntervalSince(lastSeen($0)) }
        return Int((ages.max() ?? 0) / 3600)
    }
}

/// Save / Unsave, on a tab's context menu in both layouts.
struct SaveMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var sections = Sections.shared

    var body: some View {
        if tab.pin == nil {
            Divider()
            if sections.isSaved(tab) {
                Button("Unsave") { sections.set(tab, saved: false, in: browser) }
            } else {
                Button("Save") { sections.set(tab, saved: true, in: browser) }
                    .disabled(tab.isBlank)
            }
        }
    }
}

/// The one Settings line the sections add, on the Tabs page next to sleep.
struct ArchiveLine: View {
    @ObservedObject var sections = Sections.shared

    var body: some View {
        Line("Archive Today after", "Untouched rows below the New Tab line close themselves, and wait in Reopen Closed Tab.") {
            Segmented(options: Sections.Archive.allCases.map { ($0, $0.title) }, selection: $sections.archive)
        }
    }
}
