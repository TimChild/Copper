import Foundation

// ⌘K, widened. Upstream's switcher lists the pages you have open; this adds
// the pages open in other spaces, your bookmarks, and the browser's own
// commands — all in the rows it already draws, matched by what you type.
// An empty field still shows only open pages, so ⌘K-Return stays what it was.
//
// A command travels as a URL, copper://command/<id>, because a Suggestion is
// a URL with a name; submit() hands those here instead of to a page.

enum CommandBar {
    /// How many rows the card will draw before it stops. Arc shows five or
    /// six; past eight the card is taller than it is wide and stops reading
    /// as one thing you glance at.
    static let limit = 8

    struct Command {
        let id: String
        let name: String
        /// The mark on the left of the row. A command has no site to borrow
        /// an icon from, so it says what it is with a glyph.
        let glyph: String
        let run: (Browser) -> Void

        init(id: String, name: String, glyph: String = "command", run: @escaping (Browser) -> Void) {
            self.id = id
            self.name = name
            self.glyph = glyph
            self.run = run
        }
    }

    @MainActor static func commands(_ browser: Browser) -> [Command] {
        var list: [Command] = [
            .init(id: "new-tab", name: "New Tab", glyph: "plus") { $0.newTab() },
            .init(id: "new-private", name: "New Private Tab", glyph: "eyeglasses") { $0.newShyTab() },
            .init(id: "reopen", name: "Reopen Closed Tab", glyph: "arrow.uturn.backward") { $0.reopen() },
            .init(id: "close", name: "Close Tab", glyph: "xmark") { b in if let t = b.active { b.close(t) } },
            .init(id: "pin", name: "Pin Tab", glyph: "pin") { b in if let t = b.active { b.pin(t) } },
            .init(id: "bookmark", name: "Bookmark This Page", glyph: "bookmark") { $0.bookmarkCurrent() },
            .init(id: "sidebar", name: "Toggle Sidebar", glyph: "sidebar.left") { $0.toggleSidebar() },
            .init(id: "reader", name: "Reading Mode", glyph: "doc.plaintext") { $0.toggleReader() },
            .init(id: "float", name: "Float the Video", glyph: "pip") { $0.toggleFloat() },
            .init(id: "hide", name: "Hide Something on This Page", glyph: "eye.slash") { $0.toggleHiding() },
            .init(id: "history", name: "History", glyph: "clock.arrow.circlepath") { $0.recalling = true },
            .init(id: "downloads", name: "Downloads", glyph: "arrow.down.circle") { $0.hoarding = true },
            .init(id: "passwords", name: "Passwords", glyph: "key") { $0.managing = true },
            .init(id: "settings", name: "Settings", glyph: "gearshape") { $0.tuning = true },
            .init(id: "update-check", name: "Check for Copper updates", glyph: "arrow.triangle.2.circlepath") { _ in Updates.shared.check(force: true) },
            .init(id: "clear-history", name: "Clear History", glyph: "trash") { $0.clearHistory() },
            .init(id: "split", name: Split.shared.on ? "Close Split View" : "Split View", glyph: "rectangle.split.2x1") { Split.shared.toggle(in: $0) },
            .init(id: "agent", name: Agent.shared.open ? "Close Agent" : "Agent", glyph: "sparkles") { _ in Agent.shared.toggle() },
            .init(id: "ask-page", name: "Ask About This Page", glyph: "text.bubble") { Agent.shared.askOnPage(in: $0) },
            .init(id: "new-space", name: "New Space", glyph: "square.on.square") { Spaces.shared.add(in: $0) },
            .init(id: "next-space", name: "Next Space", glyph: "chevron.right") { Spaces.shared.step(1, in: $0) },
            .init(id: "prev-space", name: "Previous Space", glyph: "chevron.left") { Spaces.shared.step(-1, in: $0) },
        ]
        if Updates.shared.available {
            list.insert(.init(id: "update", name: "Update Copper to \(Updates.shared.latest?.version ?? "")", glyph: "arrow.down.circle") { _ in Updates.shared.upgrade() }, at: 0)
        }
        for space in Spaces.shared.all where space.id != Spaces.shared.current {
            list.append(.init(id: "space-\(space.id)", name: "Switch to \(space.name)", glyph: "circle.grid.2x2") {
                Spaces.shared.select(space.id, in: $0)
            })
        }
        return list
    }

    /// The rows for what was typed. Open pages first — this space's, then the
    /// ones parked in other spaces — then bookmarks and places you have been,
    /// then the browser's own commands, and a search last, so ⌘K-Return is
    /// still "back to the page I was just on".
    ///
    /// An empty field is not empty: it is the pages you have open and a few
    /// things you might do, which is what a command bar is for.
    @MainActor static func offers(for typed: String, open: [Suggestion], in browser: Browser) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return dressed(open + resting(browser)) }
        func hit(_ texts: String...) -> Bool { texts.contains { $0.lowercased().contains(needle) } }

        // Each kind gets a few rows and no more. Without the caps one
        // popular word fills the card with the same kind of answer — eight
        // tabs, say — and the bar stops being able to surprise you with the
        // bookmark or the command you had forgotten about.
        var elsewhere: [Suggestion] = []
        for tab in Spaces.shared.parkedTabs where !tab.isBlank {
            guard let url = tab.address, hit(tab.title, Address.pretty(url)) else { continue }
            var row = Suggestion(key: tab.title.isEmpty ? Address.pretty(url) : tab.title, title: Address.pretty(url), url: url, kind: .open)
            row.tab = tab.id
            // Which space it is in is the one thing about this row you
            // cannot work out from the rest of it, so it goes in the quiet
            // text beside the title, where it is readable on every row — the
            // hint on the right only shows on the row Return would take.
            row.detail = shortDetail(row)
            row.badge = "· " + short(Spaces.shared.name(of: tab))
            elsewhere.append(row)
            if elsewhere.count == 2 { break }
        }

        var marks: [Suggestion] = []
        for (title, url) in bookmarks(browser.bookmarks.roots) where hit(title, url.absoluteString) {
            marks.append(Suggestion(key: title.isEmpty ? Address.pretty(url) : title, title: Address.pretty(url), url: url, kind: .bookmark))
            if marks.count == 2 { break }
        }

        // Where you have actually been. Upstream's ⌘L list, borrowed.
        let been = browser.history.suggestions(for: typed, limit: 3).map { row in
            Suggestion(key: row.title.isEmpty ? row.key : row.title, title: row.key, url: row.url, kind: row.kind)
        }

        var doing: [Suggestion] = []
        for command in commands(browser) where hit(command.name) {
            var row = Suggestion(key: command.name, title: "", url: URL(string: "copper://command/\(command.id)")!, kind: .command)
            row.glyph = command.glyph
            doing.append(row)
            if doing.count == 2 { break }
        }

        var list = Array(open.prefix(3)) + elsewhere + marks + been + doing
        // The way out, always — and last, so it is never the row that gets
        // cut: words that match nothing are still a question someone can
        // answer.
        if let asked = Google.url(for: typed) {
            list = Array(list.prefix(limit - 1))
            list.append(Suggestion(key: typed, title: Google.name, url: asked, kind: .search))
        }
        return dressed(list)
    }

    /// The empty field: what is open, and a few doors.
    @MainActor private static func resting(_ browser: Browser) -> [Suggestion] {
        let wanted = ["new-tab", "split", "new-space", "history"]
        let all = commands(browser)
        return wanted.compactMap { id in
            guard let command = all.first(where: { $0.id == id }) else { return nil }
            var row = Suggestion(key: command.name, title: "", url: URL(string: "copper://command/\(command.id)")!, kind: .command)
            row.glyph = command.glyph
            return row
        }
    }

    /// One row per place, each carrying what Return would do with it.
    ///
    /// The same site reaches this list by several roads — a tab that is open
    /// on it, a bookmark, the front door history credits on every visit — and
    /// three rows for one site is the fastest way to make a short list feel
    /// long. A page that is already open wins; after that one row per host,
    /// except where the path differs and the title says so.
    private static func dressed(_ list: [Suggestion]) -> [Suggestion] {
        var seen: Set<String> = []
        var hosts: Set<String> = []
        var out: [Suggestion] = []
        for row in list {
            if row.kind == .command || row.kind == .search {
                guard seen.insert(row.url.absoluteString).inserted else { continue }
            } else {
                // A trailing slash is not a page of its own, and leaving it
                // on is why "gemini.google.com" and "gemini.google.com/"
                // used to come back as two answers to one question.
                var where_ = Address.pretty(row.url).lowercased()
                if where_.hasSuffix("/") { where_ = String(where_.dropLast()) }
                guard seen.insert(where_).inserted else { continue }
                let host = (row.url.host() ?? where_).lowercased()
                if row.kind == .open {
                    // Two tabs on one site are two pages, and their titles
                    // say which is which. Only pages you have open get that
                    // licence.
                    hosts.insert(host)
                } else {
                    // A bookmark, a visit, and the front-door credit history
                    // gives every visit are three roads to one site — and,
                    // until this, three rows saying the same thing.
                    guard hosts.insert(host).inserted else { continue }
                }
            }
            var row = row
            if row.detail.isEmpty { row.detail = shortDetail(row) }
            row.hint = hint(for: row)
            out.append(row)
            if out.count == limit { break }
        }
        return out
    }

    /// A space can be called anything, and a long name on the right of a row
    /// pushes the title out of its own row.
    private static func short(_ name: String) -> String {
        name.count <= 24 ? name : String(name.prefix(23)) + "…"
    }

    private static func hint(for row: Suggestion) -> String {
        switch row.kind {
        case .open: return "Switch to Tab"
        case .command: return "Run"
        case .search: return "Search \(Google.name)"
        case .bookmark: return "Open Bookmark"
        default: return "Open"
        }
    }

    /// The quiet half of a row: the host, which is the part of an address
    /// anyone actually reads.
    private static func shortDetail(_ row: Suggestion) -> String {
        switch row.kind {
        case .command, .search: return ""
        default:
            let full = row.url.host() ?? row.title
            let host = full.hasPrefix("www.") ? String(full.dropFirst(4)) : full
            // A row with no title of its own is already showing its host as
            // its name. Saying it twice is not saying it louder.
            guard host.caseInsensitiveCompare(row.key) != .orderedSame else { return "" }
            return short(host)
        }
    }

    private static func bookmarks(_ nodes: [Bookmark]) -> [(String, URL)] {
        nodes.flatMap { node -> [(String, URL)] in
            if let children = node.children { return bookmarks(children) }
            guard let url = node.url.flatMap(URL.init(string:)) else { return [] }
            return [(node.title, url)]
        }
    }

    /// True when the URL was a command and has been run.
    @MainActor static func run(_ url: URL, in browser: Browser) -> Bool {
        guard url.scheme == "copper", url.host() == "command" else { return false }
        let id = url.lastPathComponent
        commands(browser).first { $0.id == id }?.run(browser)
        return true
    }
}

extension Spaces {
    func name(of tab: Tab) -> String {
        for space in all where parkedRow(space.id)?.contains { $0.id == tab.id } == true { return space.name }
        return space.name
    }

    /// Bring a tab open in another space to the front, switching to it.
    func reveal(_ id: Tab.ID, in browser: Browser) -> Bool {
        guard let space = all.first(where: { parkedRow($0.id)?.contains { $0.id == id } == true }) else { return false }
        select(space.id, in: browser)
        if let tab = browser.tabs.first(where: { $0.id == id }) { browser.select(tab) }
        return true
    }
}
