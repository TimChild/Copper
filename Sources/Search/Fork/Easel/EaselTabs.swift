import AppKit
import SwiftUI
import WebKit

// Easels as tabs. An easel tab is an ordinary Tab whose configuration was
// made here, for one board: it carries that board's scheme handler and bridge
// (EaselScheme, EaselBridge), set when the configuration is made, because
// WebKit reads both once, when the view is built. Everything else a tab does
// — the sidebar row, sleep and wake, session restore, split view, ⌘K's tab
// search — it does as any tab, because it is one.
//
// What keeps easels Copper's own, rather than something any page can reach:
//
// - Only an easel tab can load copper-easel:// at all. Every other view has
//   no handler for the scheme, so a link, a redirect, an <iframe>, an <img>
//   or a fetch() from a website has nothing to load, and `police` cancels the
//   navigation before upstream would hand the unknown scheme to the system.
// - An easel tab shows its own board and nothing else. A navigation in it
//   that goes anywhere else — a link on the board, a redirect, a frame doing
//   `top.location = …` — is cancelled, and an http(s) one opens in an ordinary
//   tab instead. So the only document that ever runs in an easel tab's main
//   frame is that board's own page, and its bridge has no one else to hear.
// - Frames on a board never load an easel, and no page opens one in a window
//   (`refusesWindow`).
// - Copper itself opens easels: ⌘K, File › New Easel, an address typed into
//   the field, session restore. Each of those ends in `Tab.go(to:)` or a tab
//   restored with `configuration(for:)`; `reroute` sends an easel address
//   handed to an ordinary tab to an easel tab of its own, so the policy
//   above never has to tell Copper's own loads from a page's.

@MainActor
enum Easels {
    nonisolated static let scheme = EaselScheme.name

    /// copper-easel://easel/<id>
    nonisolated static func address(_ id: String) -> URL {
        URL(string: "\(EaselScheme.name)://\(EaselScheme.host)/\(id)")!
    }

    /// A lowercase UUID, the only shape a board's id takes.
    nonisolated static func isID(_ text: String) -> Bool {
        text.count == 36 && text == text.lowercased() && UUID(uuidString: text) != nil
    }

    /// The board an address names — copper-easel://easel/<id>, with or
    /// without a trailing slash, a query or a fragment — or nil.
    nonisolated static func id(of url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == EaselScheme.name, url.host()?.lowercased() == EaselScheme.host,
              let parts = EaselScheme.parts(of: url), parts.count == 1, isID(parts[0])
        else { return nil }
        return parts[0]
    }

    /// The board a view was built for, or nil for every other view.
    static func board(of web: WKWebView?) -> String? {
        (web?.configuration.urlSchemeHandler(forURLScheme: scheme) as? EaselScheme)?.easel
    }

    // MARK: - the configuration

    /// An easel tab's configuration, or nil for any other address. The one
    /// every tab gets — its space's website store, the user agent, the
    /// preferences — less extensions, plus this board's handler and bridge.
    /// Reached through Browser.extensionConfiguration(for:), which every way
    /// of opening a page by address goes through, and from session restore.
    static func configuration(for url: URL) -> WKWebViewConfiguration? {
        guard let id = id(of: url) else { return nil }
        Easels.wearMark()
        let config = Web.configuration()
        // No Chrome extensions on a board, as in a private tab: a content
        // script can put a <script> into the page's own world, and from
        // there the bridge would take it for the board.
        if #available(macOS 15.4, *) { config.webExtensionController = nil }
        config.setURLSchemeHandler(EaselScheme(easel: id), forURLScheme: scheme)
        config.userContentController.add(EaselBridge(easel: id), name: EaselBridge.name)
        return config
    }

    // MARK: - Copper's own ways in

    /// `Tab.go(to:)`, before it loads anything. True when the address was
    /// taken somewhere else and the tab should do nothing more.
    static func reroute(_ tab: Tab, to url: URL) -> Bool {
        let here = board(of: tab.web)
        guard url.scheme?.lowercased() == scheme else {
            // An easel tab only ever shows its board; a page typed into its
            // field gets a tab of its own beside it.
            guard here != nil else { return false }
            browser(of: tab).open(url, foreground: true)
            return true
        }
        guard let wanted = id(of: url) else {
            browser(of: tab).announce("That isn't an easel")
            return true
        }
        guard !EaselStore.shared.isDeleted(wanted) else {
            // Reopen Closed Tab on a board deleted this session: nothing
            // opens, and the blank tab made to hold it goes too.
            let owner = browser(of: tab)
            owner.announce("That easel was deleted")
            if tab.isBlank { DispatchQueue.main.async { if owner.tabs.count > 1 { owner.close(tab) } } }
            return true
        }
        // Its own board: loaded if the view is not showing it yet, left alone
        // if it is — a ⌘K row for the board you are on is not a reload. A
        // board's tab loading for the first time joins Saved (EaselSidebar).
        if here == wanted {
            guard id(of: tab.built?.url) != wanted else { return true }
            keep(tab)
            return false
        }
        show(wanted, in: browser(of: tab), replacing: tab.isBlank ? tab : nil)
        return true
    }

    /// ⌘K's New Easel and File › New Easel: a board, in a new tab in front,
    /// at the bottom of the space's Saved block (`keep`, from `reroute`).
    /// A blank tab in front takes the board, the way ⌘T reuses one.
    static func newEasel(in browser: Browser) {
        let easel = EaselStore.shared.create()
        let blank = browser.active.flatMap { $0.isBlank && !$0.floating ? $0 : nil }
        show(easel.id, in: browser, replacing: blank)
        browser.landed()
    }

    /// A board, wherever it already is — this row, another space, another
    /// window — or a tab of its own. Never a second tab: two pages saving
    /// the whole of one document would each write over the other.
    static func show(_ id: String, in browser: Browser, replacing blank: Tab? = nil) {
        if let tab = browser.tabs.first(where: { showing($0) == id }) {
            browser.select(tab)
            return
        }
        if browser.primary, let tab = Spaces.shared.parkedTabs.first(where: { showing($0) == id }) {
            _ = Spaces.shared.reveal(tab.id, in: browser)
            return
        }
        for other in Windows.all where other !== browser {
            guard let tab = other.tabs.first(where: { showing($0) == id }) else { continue }
            other.select(tab)
            Windows.window(of: other)?.makeKeyAndOrderFront(nil)
            return
        }
        if let blank, browser.tabs.contains(where: { $0 === blank }) {
            browser.replaceBlank(blank, with: address(id))
        } else {
            browser.open(address(id), foreground: true)
        }
    }

    /// `Browser.open`, before it makes a tab: a board that already has one
    /// — in this row, another space, another window — is that tab, brought
    /// forward when the open was meant to be in front. Every way of opening
    /// an address by hand ends there (⌘T, a dropped link, ⌘D, an agent's new
    /// tab), so this is where a second tab for a board is refused.
    static func already(_ url: URL, in browser: Browser, foreground: Bool) -> Tab? {
        guard let id = id(of: url), let tab = tab(showing: id) else { return nil }
        if foreground { show(id, in: browser) }
        return tab
    }

    /// The tab a board is in, wherever it is.
    static func tab(showing id: String) -> Tab? {
        (Windows.all.flatMap(\.tabs) + Spaces.shared.parkedTabs).first { showing($0) == id }
    }

    /// The board a tab holds, awake or asleep; bench tabs don't count.
    static func showing(_ tab: Tab) -> String? {
        guard !tab.bench else { return nil }
        return id(of: tab.pending ?? tab.address)
    }

    static func browser(of tab: Tab) -> Browser { Windows.owner(of: tab) ?? Windows.current }

    static func browser(showing web: WKWebView) -> Browser {
        Windows.all.first { $0.tabs.contains { $0.built === web } } ?? Windows.current
    }

    // MARK: - what pages may do

    /// Browser's navigation policy, before upstream's. Nil is "not ours":
    /// upstream decides as it always has.
    static func police(_ action: WKNavigationAction, in web: WKWebView, browser: Browser) -> WKNavigationActionPolicy? {
        guard let url = action.request.url else { return nil }
        let target = url.scheme?.lowercased() == scheme
        let mainFrame = action.targetFrame?.isMainFrame ?? false
        guard let here = board(of: web) else {
            // An ordinary page reaching for an easel: refused here, rather
            // than handed to the system as somebody's app scheme.
            guard target else { return nil }
            NSLog("easel: a page tried to load %@; refused", url.absoluteString)
            return .cancel
        }
        if target {
            // Its own board, in its own main frame — a load Copper asked for,
            // a reload, a #fragment. Nothing else, and never in a frame.
            if mainFrame, id(of: url) == here { return .allow }
            NSLog("easel: refused %@ in %@ (%@)", url.absoluteString, here, mainFrame ? "main frame" : "a frame")
            return .cancel
        }
        // Frames on a board are upstream's business (P2's embeds).
        guard mainFrame else { return nil }
        let other = url.scheme?.lowercased() ?? ""
        if other == "about" { return .allow }
        if ["http", "https"].contains(other) {
            // The board stays; the page gets a tab of its own, the way a
            // ⌘-click or a middle click leaves you where you are.
            let flags = action.modifierFlags
            let behind = (flags.contains(.command) || MouseButtons.isMiddle(action)) && !flags.contains(.shift)
            browser.open(url, foreground: !behind)
        } else {
            NSLog("easel: refused to leave %@ for %@", here, url.absoluteString)
        }
        return .cancel
    }

    /// Browser's `createWebViewWith`, before upstream's. True when no view
    /// may be made: a board never shares its configuration with a window it
    /// opens (that would hand the window the board's bridge), and no page
    /// opens an easel in one.
    static func refusesWindow(for action: WKNavigationAction, from web: WKWebView, in browser: Browser) -> Bool {
        let url = action.request.url
        if board(of: web) != nil {
            if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                let flags = action.modifierFlags
                let behind = (flags.contains(.command) || MouseButtons.isMiddle(action)) && !flags.contains(.shift)
                browser.open(url, foreground: !behind)
            }
            return true
        }
        if url?.scheme?.lowercased() == scheme {
            NSLog("easel: a page tried to open %@ in a window; refused", url?.absoluteString ?? "")
            return true
        }
        return false
    }

    // MARK: - flushing

    /// Views asked for a last `save`, until it comes or their time is up.
    private static var waiting: [ObjectIdentifier: PageView] = [:]

    /// `Browser.close`, before the tab lets its view go. The page saves on
    /// its own half a second after every change and the moment it is
    /// hidden; this is for the change made in the last half second. The
    /// view is kept a moment past the tab, long enough to answer — nothing
    /// waits on it, so the row still goes at once.
    static func closing(_ tab: Tab) {
        guard let web = tab.built, board(of: web) != nil else { return }
        let key = ObjectIdentifier(web)
        waiting[key] = web
        EaselBridge.tell(web, ["type": "flush"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waiting[key] = nil }
    }

    /// A `save` arrived from this view.
    static func saved(_ web: WKWebView) {
        guard waiting.removeValue(forKey: ObjectIdentifier(web)) != nil else { return }
        NSLog("easel: %@ saved on its way out", board(of: web) ?? "?")
    }

    /// Quitting (`Windows.flush`, from applicationWillTerminate). Every board
    /// that is awake is asked to save, and the quit waits for them — 300 ms
    /// at most — and then for the disk.
    static func flushAll() {
        let tabs = Windows.all.flatMap(\.tabs) + Spaces.shared.parkedTabs
        for tab in tabs {
            guard let web = tab.built, board(of: web) != nil else { continue }
            waiting[ObjectIdentifier(web)] = web
            EaselBridge.tell(web, ["type": "flush"])
        }
        let deadline = Date().addingTimeInterval(0.3)
        while !waiting.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if !waiting.isEmpty { NSLog("easel: %d board(s) did not answer the last flush", waiting.count) }
        waiting = [:]
        EaselStore.drain()
    }

    // MARK: - the mark

    /// The name the board's mark is filed under among the site icons.
    nonisolated static let markKey = EaselScheme.host
    private static var marked = false

    /// A board has no favicon; it wears this, everywhere a site wears its
    /// own — the sidebar row, the strip, ⌘K. Filed in upstream's icon cache
    /// under the host every easel address shares, the way Fork/Marks files
    /// the marks it fetches, so no row needs to know what an easel is. Written
    /// before the first easel tab is made, which is before its row asks.
    static func wearMark() {
        guard !marked else { return }
        marked = true
        let folder = Store.folder.appendingPathComponent("icons", isDirectory: true)
        guard let png = mark() else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: folder.appendingPathComponent(markKey + ".png"), options: .atomic)
    }

    /// Copper's red-orange square with a white scribble: a chip that reads
    /// at 13 points on a pale column, a dark one, or a toned one alike.
    private static func mark() -> Data? {
        let side: CGFloat = 64
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let top = NSColor(srgbRed: 1, green: 0.48, blue: 0.30, alpha: 1)
            let bottom = NSColor(srgbRed: 0.93, green: 0.30, blue: 0.17, alpha: 1)
            NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: 38, weight: .bold)
                .applying(.init(paletteColors: [.white]))
            guard let glyph = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "Easel")?
                .withSymbolConfiguration(config)
            else { return true }
            let size = glyph.size
            glyph.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Said in the sidebar's address pill instead of a host.
    static func pill(for url: URL) -> String? {
        guard let id = id(of: url) else { return nil }
        return "Easel · " + (EaselStore.shared.easel(id)?.title ?? EaselStore.untitled)
    }

    // MARK: - ⌘K

    /// Up to three boards whose titles match what was typed, as rows that
    /// open them (or switch to the tab already showing one). "easel" alone
    /// lists them all, newest first.
    static func offers(for typed: String) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        // Open-page and history rows for boards wear the mark too.
        wearMark()
        let everything = "easel".hasPrefix(needle) || needle.hasPrefix("easel")
        let rest = needle.hasPrefix("easel") ? String(needle.dropFirst(5)).trimmingCharacters(in: .whitespaces) : needle
        var rows: [Suggestion] = []
        for easel in EaselStore.shared.all {
            let title = easel.title.lowercased()
            guard (everything && (rest.isEmpty || title.contains(rest))) || title.contains(needle) else { continue }
            var row = Suggestion(key: easel.title, title: "Easel", url: address(easel.id), kind: .command)
            row.glyph = "scribble.variable"
            row.detail = "Easel"
            rows.append(row)
            if rows.count == 3 { break }
        }
        return rows
    }
}

// MARK: - the bench

extension Easels {
    /// `./bench easels` lists the boards; `easels new` makes one and opens it
    /// the way ⌘K does; `easels open ID`; `easels check ID` reads back what
    /// is on disk (the document's size and first bytes, the index entry, the
    /// pictures); `easels flush ID` asks its page to save now; `easels delete
    /// ID` closes its tab and removes it; `easels path` is the folder;
    /// `easels menu [press]` is File › New Easel as the menu bar has it.
    static func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "list"
        let arg = (request["arg"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let store = EaselStore.shared
        func find() -> Easel? { arg.isEmpty ? nil : store.all.first { $0.id.hasPrefix(arg) } }
        func open(_ id: String) -> [[String: Any]] {
            tabs(showing: id).map { tab in
                // Where the row is: its space, its block, its place in the row.
                let owner = Windows.owner(of: tab)
                let space = owner === Windows.main ? Spaces.shared.space
                    : Spaces.shared.all.first { Spaces.shared.parkedRow($0.id)?.contains { $0 === tab } == true }
                let row = (owner?.tabs ?? space.flatMap { Spaces.shared.parkedRow($0.id) } ?? []).filter { $0.pin == nil }
                return ["tab": Bench.short(tab), "title": tab.title, "asleep": tab.asleep, "active": tab.id == browser.activeID,
                        "space": space?.name ?? "", "pinned": tab.pin != nil,
                        "section": tab.pin != nil ? "favourites" : Sections.shared.isSaved(tab) ? "saved" : "today",
                        "row": row.firstIndex { $0 === tab } ?? -1,
                        "savedCount": row.filter { Sections.shared.isSaved($0) }.count,
                        "lean": tab.built?.board ?? false]
            }
        }
        func describe(_ easel: Easel) -> [String: Any] {
            var out: [String: Any] = ["id": easel.id, "title": easel.title, "createdAt": easel.createdAt, "updatedAt": easel.updatedAt,
                                      "url": address(easel.id).absoluteString, "tabs": open(easel.id)]
            if let stale = easel.renamedFrom { out["renamedFrom"] = stale }
            return out
        }
        switch op {
        case "list":
            return ["easels": store.all.map(describe), "folder": EaselStore.folder.path,
                    "bundle": EaselScheme.bundle?.path ?? ""]
        case "path":
            return ["folder": EaselStore.folder.path]
        case "menu":
            // File › New Easel as AppKit holds it; `menu press` chooses it,
            // the way a click on the menu does.
            guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.title == "New Easel" } == true })?.submenu,
                  let index = file.items.firstIndex(where: { $0.title == "New Easel" })
            else {
                let bar = (NSApp.mainMenu?.items ?? []).map { item in
                    item.title + ": " + (item.submenu?.items.map(\.title).joined(separator: ", ") ?? "")
                }
                return ["error": "no New Easel in the menu bar", "menus": bar]
            }
            let item = file.items[index]
            let flags = item.keyEquivalentModifierMask
            let keys = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            let shortcut = keys.filter { flags.contains($0.0) }.map(\.1).joined() + item.keyEquivalent.uppercased()
            if arg == "press" { file.performActionForItem(at: index) }
            return ["menu": file.title, "item": item.title, "shortcut": shortcut, "enabled": item.isEnabled,
                    "pressed": arg == "press", "easels": store.all.count]
        case "new":
            newEasel(in: browser)
            guard let easel = store.all.first else { return ["error": "no easel"] }
            return describe(easel)
        case "open":
            guard let easel = find() else { return ["error": "no easel “\(arg)” — see easels list"] }
            show(easel.id, in: browser)
            return describe(easel)
        case "check":
            guard let easel = find() else { return ["error": "no easel “\(arg)” — see easels list"] }
            EaselStore.drain()
            let doc = try? Data(contentsOf: EaselStore.document(of: easel.id))
            let pictures = (try? FileManager.default.contentsOfDirectory(atPath: EaselStore.files(of: easel.id).path)) ?? []
            var out = describe(easel)
            out["document"] = doc.map { ["bytes": $0.count, "base64": $0.prefix(48).base64EncodedString()] as [String: Any] } ?? NSNull()
            out["documentPath"] = EaselStore.document(of: easel.id).path
            out["files"] = pictures.sorted()
            return out
        case "flush":
            guard let easel = find() else { return ["error": "no easel “\(arg)” — see easels list"] }
            let views = (Windows.all.flatMap(\.tabs) + Spaces.shared.parkedTabs)
                .filter { showing($0) == easel.id }.compactMap(\.built)
            views.forEach { EaselBridge.tell($0, ["type": "flush"]) }
            return ["flushed": views.count]
        case "click", "draw":
            // Real mouse input on the board in front, in the page's CSS px:
            // `click X Y [COUNT]`, or `draw X,Y X,Y …` — one press, a drag
            // through every point a frame apart, and a release. The laser and
            // the board's gestures only believe trusted events, so a script's
            // PointerEvent would prove nothing.
            guard let tab = browser.tabs.first(where: { $0.id == browser.activeID }), showing(tab) != nil,
                  let web = tab.built, Input.canPost(to: web)
            else { return ["error": "the tab in front is not an easel"] }
            let words = arg.split(separator: " ").map(String.init)
            if op == "click" {
                guard words.count >= 2, let x = Double(words[0]), let y = Double(words[1]) else { return ["error": "easels click X Y [COUNT]"] }
                Input.click(web, at: CGPoint(x: x, y: y), button: "left", count: words.count > 2 ? Int(words[2]) ?? 1 : 1, modifiers: [])
                return ["clicked": [x, y]]
            }
            let points = words.compactMap { word -> CGPoint? in
                let xy = word.split(separator: ",").compactMap { Double($0) }
                return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
            }
            guard points.count >= 2 else { return ["error": "easels draw X,Y X,Y …"] }
            Task { @MainActor in await stroke(web, through: points) }
            return ["drawing": points.count, "ms": points.count * 16]
        case "delete":
            // Straight away, no sheet: the sidebar's Delete Easel… asks
            // first (`easels ask-delete ID`, then `easels answer`).
            guard let easel = find() else { return ["error": "no easel “\(arg)” — see easels list"] }
            delete(easel.id)
            return ["deleted": easel.id]
        default:
            return ["error": "easels list|new|open ID|check ID|flush ID|delete ID|path|menu [press]|click X Y [N]|draw X,Y …"
                + "|scroll DX DY [STEPS] [--zoom] [--app]|scroll stats|perf start|stop|rename ID TITLE|ask-rename ID"
                + "|ask-delete ID|answer delete|cancel|sheet|rowmenu ID PATH|lean"]
        }
    }

    /// A press, a drag through `points` at about 60 Hz, and a release, as the
    /// window would deliver them. Points are the page's CSS px, top-left.
    private static func stroke(_ web: WKWebView, through points: [CGPoint]) async {
        guard let window = web.window, let first = points.first, let last = points.last else { return }
        if window.firstResponder !== web { window.makeFirstResponder(web) }
        func at(_ p: CGPoint) -> CGPoint { web.convert(web.isFlipped ? p : CGPoint(x: p.x, y: web.bounds.height - p.y), to: nil) }
        func post(_ type: NSEvent.EventType, _ p: CGPoint, pressure: Swift.Float) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)
        }
        Input.move(web, to: first)
        if let e = post(.leftMouseDown, first, pressure: 1) { web.mouseDown(with: e) }
        for p in points.dropFirst() {
            try? await Task.sleep(nanoseconds: 16_000_000)
            if let e = post(.leftMouseDragged, p, pressure: 1) { web.mouseDragged(with: e) }
        }
        if let e = post(.leftMouseUp, last, pressure: 0) { web.mouseUp(with: e) }
    }
}
