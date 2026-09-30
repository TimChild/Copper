import AppKit
import Foundation

// ⌘T, the way Arc has it.
//
// Upstream's ⌘T makes a blank tab and puts the cursor in its field, so every
// ⌘T you regret is a tab you have to close again. Arc's asks first: the same
// card as ⌘K, a question, and a handful of answers in groups — search for it,
// what Google thinks you are typing, the tab you already have open, the page
// you were on last week — and no tab exists until you pick one. Escape and
// you are exactly where you were.
//
// The card is CommandPalette's; this decides what goes in it and what picking
// a row does. Browser keeps the flat list of rows (so the arrow keys, Return
// and the pointer work the way they already do) and asks here for it on every
// keystroke. The two slow sources — Google's completions and a ranking of all
// of history — are worked out away from the keystroke and handed back through
// `Browser.relaunch` when they land.

@MainActor
final class Launcher: ObservableObject {
    static let shared = Launcher()

    /// The titled groups: the row a heading sits above, and what it says.
    /// The first row — what Return does — needs no heading.
    @Published private(set) var headings: [Int: String] = [:]

    /// What Return does to a row, and the two other things it can do.
    enum How: String { case open, background, split }

    /// How many rows each group may bring. Enough that the answer you meant
    /// is usually on screen; few enough that the card stays one thing you
    /// glance at rather than a page you scroll.
    private enum Cap {
        static let suggestions = 4
        static let tabs = 4
        static let history = 4
        static let bookmarks = 2
        static let commands = 2
        static let recent = 6
        static let elsewhere = 2
        static let closed = 2
    }

    /// The question now on screen. Anything that lands for another one is
    /// late and is dropped (or kept, for when you backspace to it).
    private var asked = ""
    private weak var browser: Browser?

    /// Google's completions, by query, so backspacing asks nobody anything.
    private var completions: [String: [String]] = [:]
    private var remembered: [String] = []
    /// The last completions that landed, for any query. Until the answer to
    /// this keystroke arrives, the answer to the previous one — whittled to
    /// what still fits — holds the group's place, so the rows under it do not
    /// jump up and back down on every letter.
    private var lastCompletions: [String] = []
    private var fetch: URLSessionDataTask?
    private var waiting: DispatchWorkItem?

    /// History's best rows for the question they answer.
    private var visited: (query: String, rows: [Hit]) = ("", [])
    private let ranking = DispatchQueue(label: "copper.launcher.history", qos: .userInitiated)

    /// A cookie-less, cache-less session: a query completion is a question
    /// about words, and nothing about it needs to be remembered by anyone.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 2.5
        return URLSession(configuration: config)
    }()

    /// Bench counters: completions asked for, and asks cancelled by a later
    /// keystroke before they were sent.
    private(set) var sent = 0
    private(set) var dropped = 0

    // MARK: - asking

    /// A fresh card. The last question's leftovers are not this one's.
    func begin() {
        waiting?.cancel()
        fetch?.cancel()
        asked = ""
        lastCompletions = []
        visited = ("", [])
        headings = [:]
    }

    /// The rows for what is in the field, now — from what is at hand — with
    /// the slower answers sent for.
    func rows(for typed: String, in browser: Browser) -> [Suggestion] {
        self.browser = browser
        let query = typed.trimmingCharacters(in: .whitespaces)
        asked = query
        guard !query.isEmpty else {
            waiting?.cancel()
            fetch?.cancel()
            return resting(in: browser)
        }
        rank(query, in: browser)
        complete(query)
        return assemble(query, in: browser)
    }

    /// Everything that has landed so far, laid out for `query`.
    private func assemble(_ query: String, in browser: Browser) -> [Suggestion] {
        var groups: [(String, [Suggestion])] = []
        var seen = Set<String>()
        func keep(_ row: Suggestion) -> Bool { seen.insert(Launcher.canonical(row.url)).inserted }

        let top = Launcher.top(query, in: browser)
        let needle = query.lowercased()
        // Open tabs are claimed first: "github.com" typed with GitHub open
        // should still offer the switch, not only a second copy.
        let open = tabs(matching: needle, in: browser).filter(keep).prefix(Cap.tabs).map { $0 }
        _ = keep(top)

        // Google's completions — the ones for this query if they are in, the
        // last ones that still carry on from it if not.
        let words = completions[needle] ?? lastCompletions.filter { $0.lowercased().hasPrefix(needle) }
        var searches: [Suggestion] = []
        for phrase in words where phrase.lowercased() != needle {
            guard let url = Google.url(for: phrase) else { continue }
            var row = Suggestion(key: phrase, title: Google.name, url: url, kind: .search)
            row.hint = "Search \(Google.name)"
            guard keep(row) else { continue }
            searches.append(row)
            if searches.count == Cap.suggestions { break }
        }
        groups.append(("\(Google.name) Suggestions", searches))

        // Open tabs: this space's first, then the ones parked in others, each
        // wearing its space so you know a switch is coming.
        groups.append(("Switch to Tab", open))

        // History, ranked away from the keystroke. Until this query's ranking
        // is in, the last one's rows that still match stand in for it.
        let hits = visited.query == needle ? visited.rows
            : visited.rows.filter { Launcher.score(key: $0.key, lowered: $0.title.lowercased(), needle: needle) != nil }
        // A site's untitled front door is the credit its deeper pages give
        // it; beside one of those pages it is the same answer said twice.
        let titledHosts = Set(hits.filter { !$0.title.isEmpty }.compactMap { URL(string: $0.url)?.host() })
        var been: [Suggestion] = []
        for hit in hits {
            guard let url = URL(string: hit.url) else { continue }
            if hit.title.isEmpty, !hit.key.contains("/"), let host = url.host(), titledHosts.contains(host) { continue }
            var row = Suggestion(key: hit.title.isEmpty ? hit.key : hit.title, title: hit.key, url: url, kind: .visited)
            row.detail = Launcher.host(url, besides: row.key)
            row.hint = pageHint(browser)
            guard keep(row) else { continue }
            been.append(row)
            if been.count == Cap.history { break }
        }
        groups.append(("History", been))

        var marks: [Suggestion] = []
        for (title, url) in Launcher.bookmarks(browser.bookmarks.roots) {
            let lowered = title.lowercased()
            guard Launcher.score(key: Launcher.strip(Address.pretty(url)), lowered: lowered, needle: needle) != nil else { continue }
            var row = Suggestion(key: title.isEmpty ? Address.pretty(url) : title, title: Address.pretty(url), url: url, kind: .bookmark)
            row.detail = Launcher.host(url, besides: row.key)
            row.hint = pageHint(browser)
            guard keep(row) else { continue }
            marks.append(row)
            if marks.count == Cap.bookmarks { break }
        }
        groups.append(("Bookmarks", marks))

        // The browser's own commands, last and few: ⌘T is for going
        // somewhere, and ⌘K is where commands live. "/" asks for them first.
        let commandNeedle = needle.hasPrefix("/") ? String(needle.dropFirst()) : needle
        var doing: [Suggestion] = []
        if !commandNeedle.isEmpty {
            for command in CommandBar.commands(browser) where command.name.lowercased().contains(commandNeedle) {
                var row = Suggestion(key: command.name, title: "", url: URL(string: "copper://command/\(command.id)")!, kind: .command)
                row.glyph = command.glyph
                row.hint = "Run"
                doing.append(row)
                if doing.count == Cap.commands { break }
            }
        }
        if needle.hasPrefix("/") { groups.insert(("Commands", doing), at: 0) } else { groups.append(("Commands", doing)) }

        return lay(top: [top], groups)
    }

    /// Rows in order, and where each titled group begins.
    private func lay(top: [Suggestion], _ groups: [(String, [Suggestion])]) -> [Suggestion] {
        var rows = top
        var marks: [Int: String] = [:]
        for (title, members) in groups where !members.isEmpty {
            marks[rows.count] = title
            rows.append(contentsOf: members)
        }
        headings = marks
        return rows
    }

    /// The first row: what Return does with the words as they stand.
    static func top(_ query: String, in browser: Browser) -> Suggestion {
        if let url = Address.url(from: query) {
            var row = Suggestion(key: "Open \(Address.pretty(url))", title: "", url: url, kind: .known)
            row.hint = pageHint(browser)
            return row
        }
        var row = Suggestion(key: "Search \(Google.name) for “\(query)”", title: Google.name,
                             url: Google.url(for: query) ?? URL(string: "https://www.google.com")!, kind: .search)
        row.hint = pageHint(browser)
        return row
    }

    /// Said on the right of a row that opens a page. A blank tab under the
    /// card takes the page itself, so there it is not a new tab.
    static func pageHint(_ browser: Browser) -> String {
        browser.active?.isBlank == true ? "Open" : "Open in New Tab"
    }

    private func pageHint(_ browser: Browser) -> String { Launcher.pageHint(browser) }

    // MARK: - the empty card

    /// Nothing typed: the tabs you were just on, most recent first — the
    /// same order Control-Tab walks — so ⌘T, ↓, Return goes back one and each
    /// further ↓ goes back one more. Then the tabs you closed.
    private func resting(in browser: Browser) -> [Suggestion] {
        let here = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let parked = Dictionary(Spaces.shared.parkedTabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The trail first — where you actually were, across space switches —
        // then the row's own order for tabs not looked at since launch.
        var recent: [Suggestion] = []
        var listed = Set<Tab.ID>()
        for id in Recent.shared.trail + Recent.shared.order where id != browser.activeID && !listed.contains(id) {
            guard let tab = here[id], !tab.isBlank, let row = Launcher.row(for: tab, current: true, browser: browser) else { continue }
            listed.insert(id)
            recent.append(row)
            if recent.count == Cap.recent { break }
        }
        // Then a couple from other spaces: the ones you left most recently
        // by the trail, or by when they were last looked at.
        let away = Recent.shared.trail.compactMap { parked[$0] }
            + Spaces.shared.parkedTabs.sorted { $0.touched > $1.touched }
        var others = 0
        for tab in away where others < Cap.elsewhere && !tab.isBlank && !listed.contains(tab.id) {
            guard let row = Launcher.row(for: tab, current: false, browser: browser) else { continue }
            listed.insert(tab.id)
            recent.append(row)
            others += 1
        }

        let closed = browser.ghosts.reversed().prefix(Cap.closed).map { ghost -> Suggestion in
            var row = Suggestion(key: "Reopen “\(ghost.label)”", title: "",
                                 url: URL(string: "copper://reopen/\(ghost.id.uuidString)")!, kind: .command)
            row.glyph = "arrow.uturn.backward"
            row.detail = Launcher.host(ghost.url, besides: ghost.label)
            row.hint = "Reopen"
            return row
        }
        return lay(top: [], [("Recent Tabs", recent), ("Recently Closed", Array(closed))])
    }

    // MARK: - open tabs

    private func tabs(matching needle: String, in browser: Browser) -> [Suggestion] {
        var scored: [(row: Suggestion, rank: Double, touched: Date)] = []
        func consider(_ tab: Tab, current: Bool) {
            guard tab.id != browser.activeID, !tab.isBlank, let url = tab.address,
                  let match = Launcher.score(key: Launcher.strip(Address.pretty(url)), lowered: tab.label.lowercased(), needle: needle),
                  let row = Launcher.row(for: tab, current: current, browser: browser) else { return }
            // This space's tabs above every other space's: the one you can
            // switch to without the column changing under you comes first.
            scored.append((row, match + (current ? 1_000 : 0), tab.touched))
        }
        browser.tabs.forEach { consider($0, current: true) }
        Spaces.shared.parkedTabs.forEach { consider($0, current: false) }
        return scored
            .sorted { $0.rank == $1.rank ? $0.touched > $1.touched : $0.rank > $1.rank }
            .map(\.row)
    }

    private static func row(for tab: Tab, current: Bool, browser: Browser) -> Suggestion? {
        guard let url = tab.address else { return nil }
        var row = Suggestion(key: tab.label, title: Address.pretty(url), url: url, kind: .open, tab: tab.id)
        row.detail = host(url, besides: tab.label)
        row.hint = "Switch to Tab"
        if !current, let space = Spaces.shared.all.first(where: { Spaces.shared.parkedRow($0.id)?.contains { $0.id == tab.id } == true }) {
            let name = space.title.count <= 22 ? space.title : String(space.title.prefix(21)) + "…"
            row.badge = "· " + (space.emoji.map { "\($0) " } ?? "") + name
        }
        return row
    }

    // MARK: - history, off the main thread

    /// One ranked place from history, carried back from the ranking queue.
    struct Hit: Sendable {
        let key: String
        let title: String
        let url: String
    }

    private func rank(_ query: String, in browser: Browser) {
        let needle = query.lowercased()
        guard visited.query != needle else { return }
        // The whole of history as plain values, handed over by reference: the
        // array is copied only if history changes while it is being read.
        let places = browser.history.places
        let now = Date()
        ranking.async { [weak self] in
            let rows = Launcher.rank(places, needle: needle, now: now, limit: 8)
            DispatchQueue.main.async {
                guard let self else { return }
                // A ranking for an older question is no use to this one.
                guard self.asked.lowercased() == needle else { return }
                self.visited = (needle, rows)
                self.refresh()
            }
        }
    }

    /// Where the words match first, then how often and how lately you went.
    /// A month-old habit counts for about a third of a fresh one, as it does
    /// for the address field's own completion.
    nonisolated static func rank(_ places: [History.Place], needle: String, now: Date, limit: Int) -> [Hit] {
        var scored: [(Hit, Double)] = []
        scored.reserveCapacity(64)
        for place in places {
            // A bare domain with no title is a credit every deeper visit gives
            // its front door; it is still a good answer to its own name.
            guard let match = score(key: place.key, lowered: place.lowered, needle: needle) else { continue }
            let days = max(0, now.timeIntervalSince(place.last) / 86_400)
            let frecency = Double(place.count) * exp(-days / 30)
            let door = place.key.contains("/") ? 0.0 : 4.0
            scored.append((Hit(key: place.key, title: place.title, url: place.url), match + door + 12 * log1p(frecency)))
        }
        return scored
            .sorted { $0.1 == $1.1 ? $0.0.key.count < $1.0.key.count : $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// How well `needle` fits a place: its address from the start, one of
    /// its host's labels, a word of its title, and — past two letters —
    /// anywhere in its host or title. Several words must each be found.
    nonisolated static func score(key: String, lowered title: String, needle: String) -> Double? {
        let needle = strip(needle)
        guard !needle.isEmpty else { return nil }
        if needle.contains(" ") {
            let words = needle.split(separator: " ")
            let haystack = title + " " + key
            guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
            return title.hasPrefix(String(words[0])) ? 70 : 55
        }
        if key.hasPrefix(needle) { return 100 }
        let host = key.split(separator: "/").first.map(String.init) ?? key
        if host.split(separator: ".").contains(where: { $0.hasPrefix(needle) }) { return 85 }
        if title.hasPrefix(needle) || title.contains(" " + needle) { return 75 }
        guard needle.count >= 2 else { return nil }
        if host.contains(needle) { return 60 }
        if title.contains(needle) { return 50 }
        if needle.count >= 3, key.contains(needle) { return 35 }
        return nil
    }

    // MARK: - Google's completions

    /// Asked for a beat after the last keystroke rather than on every one,
    /// and the ask before it called off: a word typed at speed is one
    /// question, not seven.
    private func complete(_ query: String) {
        let needle = query.lowercased()
        waiting?.cancel()
        if fetch != nil { fetch?.cancel(); fetch = nil; dropped += 1 }
        // A command is not a search, and a pasted address with its scheme is
        // not a query anyone completes.
        guard completions[needle] == nil, !needle.hasPrefix("/"), !needle.contains("://") else { return }
        let work = DispatchWorkItem { [weak self] in self?.ask(needle) }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func ask(_ needle: String) {
        guard asked.lowercased() == needle else { return }
        var parts = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        parts.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ie", value: "utf-8"),
            URLQueryItem(name: "oe", value: "utf-8"),
            URLQueryItem(name: "q", value: needle),
        ]
        guard let url = parts.url else { return }
        sent += 1
        // Offline, refused or slow: the group simply never appears. There is
        // nothing to tell anyone — the search row above it still works.
        let task = Launcher.session.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let list = Launcher.parse(data) else { return }
            DispatchQueue.main.async { self?.landed(needle, list) }
        }
        fetch = task
        task.resume()
    }

    /// `["query", ["completion", …], …]`, as Firefox's search box is sent.
    nonisolated static func parse(_ data: Data) -> [String]? {
        let body = (try? JSONSerialization.jsonObject(with: data))
            ?? String(data: data, encoding: .isoLatin1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        guard let array = body as? [Any], array.count > 1, let list = array[1] as? [String] else { return nil }
        return list
    }

    private func landed(_ needle: String, _ list: [String]) {
        fetch = nil
        completions[needle] = list
        remembered.append(needle)
        if remembered.count > 64 { completions[remembered.removeFirst()] = nil }
        guard asked.lowercased() == needle else { return }
        lastCompletions = list
        refresh()
    }

    /// Something landed for the question on screen: lay the card out again.
    private func refresh() {
        guard let browser, browser.launching, !asked.isEmpty else { return }
        browser.relaunch(assemble(asked, in: browser))
    }

    // MARK: - picking

    /// A row, taken. Return opens it in a new tab (or in the blank tab the
    /// card is over); ⇧Return opens it behind the tab you are on; ⌥Return
    /// opens it beside it, in a split. An open tab is switched to — across
    /// spaces — rather than opened a second time.
    func take(_ row: Suggestion, in browser: Browser, how asked: How? = nil) {
        let how = asked ?? Launcher.how(from: NSApp.currentEvent)
        if row.url.scheme == "copper" {
            browser.landed()
            if row.url.host() == "reopen" {
                if let id = UUID(uuidString: row.url.lastPathComponent), let ghost = browser.ghosts.first(where: { $0.id == id }) {
                    browser.reopen(ghost)
                }
            } else {
                _ = CommandBar.run(row.url, in: browser)
            }
            return
        }
        if let id = row.tab {
            if let tab = browser.tabs.first(where: { $0.id == id }) {
                if how == .split, tab.id != browser.activeID { Split.shared.open(with: tab, in: browser) }
                else { browser.select(tab) }
            } else {
                _ = Spaces.shared.reveal(id, in: browser)
            }
            browser.landed()
            return
        }
        switch how {
        case .open:
            if let active = browser.active, active.isBlank, !active.floating {
                active.go(to: row.url)
                browser.editing = false
            } else {
                browser.open(row.url, foreground: true)
            }
        case .background:
            browser.open(row.url, foreground: false)
            browser.announce("Opened in the background")
        case .split:
            let tab = browser.open(row.url, foreground: false)
            Split.shared.open(with: tab, in: browser)
        }
        browser.landed()
    }

    /// Return with nothing picked: the words themselves.
    func take(typed: String, in browser: Browser, how: How? = nil) {
        let query = typed.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        take(Launcher.top(query, in: browser), in: browser, how: how)
    }

    private static func how(from event: NSEvent?) -> How {
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if flags.contains(.option) { return .split }
        if flags.contains(.shift) { return .background }
        return .open
    }

    /// The other ways to take the row you are on, said quietly beside what
    /// Return does. Empty for a row that has only one thing to do.
    static func aside(for row: Suggestion, in browser: Browser) -> String {
        if row.url.scheme == "copper" { return "" }
        if let id = row.tab {
            return browser.tabs.contains(where: { $0.id == id }) ? "⌥↩ Split" : ""
        }
        return "⇧↩ Background   ⌥↩ Split"
    }

    // MARK: - keys

    /// The keys the card answers before the field does. Plain Return and
    /// the arrows are the field's already; these are the ones it has no word
    /// for. True when the key was used.
    static func key(_ event: NSEvent, in browser: Browser) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53:
            // One press, all the way out. ⌘K's first Escape lets go of the
            // row; here nothing has happened yet, so there is nothing to undo
            // step by step.
            browser.dismiss()
            return true
        case 36, 76:
            // Plain Return is the field's, and goes through Browser.submit.
            guard !flags.contains(.command), flags.contains(.shift) || flags.contains(.option) else { return false }
            // An input method still composing gets its Return.
            if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            let how: How = flags.contains(.option) ? .split : .background
            if let picked = browser.picked, browser.offers.indices.contains(picked) {
                shared.take(browser.offers[picked], in: browser, how: how)
            } else {
                shared.take(typed: browser.typed, in: browser, how: how)
            }
            return true
        default:
            // ⌘1–⌘9: the row with that number, without walking to it.
            guard flags == .command, let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) else { return false }
            if browser.offers.indices.contains(digit - 1) { shared.take(browser.offers[digit - 1], in: browser, how: .open) }
            return true
        }
    }

    // MARK: - small pieces

    /// One address however it was written. The query stays: two Google
    /// searches differ only in theirs, and `Address.pretty` drops it.
    static func canonical(_ url: URL) -> String {
        var text = strip(url.absoluteString)
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    nonisolated static func strip(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value
    }

    /// The host, which is the part of an address anyone reads — unless the
    /// row is already called by it.
    static func host(_ url: URL, besides name: String) -> String {
        let full = url.host() ?? ""
        let host = full.hasPrefix("www.") ? String(full.dropFirst(4)) : full
        return host.caseInsensitiveCompare(name) == .orderedSame ? "" : host
    }

    private static func bookmarks(_ nodes: [Bookmark]) -> [(String, URL)] {
        nodes.flatMap { node -> [(String, URL)] in
            if let children = node.children { return bookmarks(children) }
            guard let url = node.url.flatMap(URL.init(string:)) else { return [] }
            return [(node.title, url)]
        }
    }

    // MARK: - bench

    /// `bench newtab TEXT`: the card as ⌘T would draw it for TEXT, by group,
    /// after the slow answers have had `settle` seconds to land. `go` takes
    /// the first row (or the row `pick` names) the way `how` says; `keep`
    /// leaves the card up for a picture.
    func bench(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let started = DispatchTime.now().uptimeNanoseconds
        browser.launch()
        browser.typed = request["text"] as? String ?? ""
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let settle = request["settle"] as? Double ?? 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [self] in
            var groups: [[String: Any]] = []
            var current: [String: Any] = ["heading": "", "rows": [[String: Any]]()]
            for (index, row) in browser.offers.enumerated() {
                if let heading = headings[index] {
                    if !((current["rows"] as? [Any])?.isEmpty ?? true) || !(current["heading"] as? String ?? "").isEmpty { groups.append(current) }
                    current = ["heading": heading, "rows": [[String: Any]]()]
                }
                var rows = current["rows"] as? [[String: Any]] ?? []
                rows.append(["index": index, "key": row.key, "kind": "\(row.kind)", "url": row.url.absoluteString,
                             "detail": row.detail, "badge": row.badge, "hint": row.hint,
                             "aside": Launcher.aside(for: row, in: browser), "tab": row.tab.map { String($0.uuidString.prefix(8)).lowercased() } ?? ""])
                current["rows"] = rows
            }
            if !((current["rows"] as? [Any])?.isEmpty ?? true) { groups.append(current) }
            var out: [String: Any] = ["groups": groups, "picked": browser.picked ?? -1, "milliseconds": milliseconds,
                                      "suggestAsks": sent, "suggestCancelled": dropped, "launching": browser.launching]
            let before = browser.tabs.count
            if request["go"] as? Bool == true {
                let how = How(rawValue: request["how"] as? String ?? "") ?? .open
                let index = request["pick"] as? Int ?? browser.picked ?? 0
                if browser.offers.indices.contains(index) { take(browser.offers[index], in: browser, how: how) }
                out["tookIndex"] = index
            } else if request["keep"] as? Bool != true {
                browser.dismiss()
            }
            out["tabsBefore"] = before
            out["tabsAfter"] = browser.tabs.count
            out["active"] = browser.active.map { ["title": $0.label, "url": $0.address?.absoluteString ?? ""] } ?? [:]
            out["space"] = Spaces.shared.space.name
            answer(out)
        }
    }
}
