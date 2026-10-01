import AppKit
import os
import WebKit

// The canvas page in a tab, and the bridge between it and Copper.
//
// A canvas tab is an ordinary Tab whose address is `copper://canvas/<id>`.
// There is no scheme handler: on its way into WebKit that address is caught
// (`decide`, from the browser's navigation delegate) and the bundled
// `canvas.html` is loaded in its place with `loadFileURL`. The tab keeps the
// copper:// address (Tab ignores the file URL), so the omnibox, the session
// and the agents all see the canvas, not a file.
//
// The page speaks through one script message handler, `canvas`
// (`window.webkit.messageHandlers.canvas.postMessage(json)`), and is spoken
// to through `window.copperCanvas.*` (docs/canvas.md has the whole contract).
// It never touches the network: when the canvas has a room on the cloud,
// Copper holds the WebSocket (`CanvasRoom`) and relays frames both ways.
// Every Yjs update the page reports is kept on disk (CanvasStore) before
// anything else happens to it, so a canvas works — and survives — offline.

// MARK: - the bundled page

enum CanvasPage {
    /// `Resources/canvas.html` inside SwiftPM's `Search_Search.bundle` — beside
    /// the binary on a bench run, under Contents/Resources in Copper.app
    /// (build.sh copies it there). Opened as a bundle, as the backdrop's page
    /// is, because the toolchain decides whether a copied folder sits at the
    /// bundle's root or under its Resources; never through `Bundle.module`,
    /// whose accessor traps when the bundle isn't where SwiftPM left it.
    static let file: URL? = {
        let name = "Search_Search.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        var candidates: [URL] = []
        for root in roots {
            let bundle = root.appendingPathComponent(name)
            if let inner = Bundle(url: bundle)?.resourceURL {
                candidates.append(inner.appendingPathComponent("Resources/canvas.html"))
                candidates.append(inner.appendingPathComponent("canvas.html"))
            }
            candidates.append(bundle.appendingPathComponent("Resources/canvas.html"))
            candidates.append(bundle.appendingPathComponent("Contents/Resources/Resources/canvas.html"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.standardizedFileURL
    }()

    /// What the page may read: its own folder, nothing more.
    static var folder: URL? { file?.deletingLastPathComponent() }

    /// The page for one canvas: `canvas.html?id=<id>`, so a page coming back
    /// from its own history (a slept tab waking) still says which canvas it is.
    static func url(for id: String) -> URL? {
        guard let file, var parts = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "id", value: id)]
        return parts.url
    }

    static func isPage(_ url: URL?) -> Bool {
        guard let url, url.isFileURL, let file else { return false }
        return url.standardizedFileURL.path == file.path
    }

    static func id(fromPage url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }

    /// The row's mark while the tab wears icons.
    static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "Canvas")
        image?.isTemplate = true
        return image
    }()
}

// MARK: - what the sidebar watches

/// Which canvases are open, which are live in a room, and how many other
/// people are in each room — one place for the sidebar to observe.
@MainActor
final class CanvasPresence: ObservableObject {
    static let shared = CanvasPresence()
    @Published fileprivate(set) var open: Set<String> = []
    @Published fileprivate(set) var live: Set<String> = []
    @Published fileprivate(set) var peers: [String: Int] = [:]

    fileprivate func recount() {
        let hosts = CanvasHost.all
        let open = Set(hosts.map(\.canvasId))
        let live = Set(hosts.filter(\.roomOpen).map(\.canvasId))
        var peers: [String: Int] = [:]
        for host in hosts where host.roomOpen { peers[host.canvasId] = max(peers[host.canvasId] ?? 0, host.collaborators) }
        if open != self.open { self.open = open }
        if live != self.live { self.live = live }
        if peers != self.peers { self.peers = peers }
    }
}

/// Who an agent's ops are attributed to, and how it shows on the board.
struct CanvasAgent {
    var id: String
    var name: String
    var color: String

    /// The agent making this call: the MCP client by the name it gave (or
    /// "Agent"), "Copper agent" for the ⌘E pane. `as` (a name or `{name,
    /// color}`) overrides.
    @MainActor static func caller(_ said: Any? = nil) -> CanvasAgent {
        var name = "Agent"
        var key = "agent"
        if let who = DriveCaller.who {
            key = who.key
            name = who.key == "pane" ? "Copper agent" : (who.agent.isEmpty ? "Agent" : who.agent)
        }
        var color: String?
        if let text = said as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            name = String(text.trimmingCharacters(in: .whitespaces).prefix(60))
        } else if let object = said as? [String: Any] {
            if let given = object["name"] as? String, !given.isEmpty { name = String(given.prefix(60)) }
            if let given = object["color"] as? String, !given.isEmpty { color = given }
        }
        let id = "agent:" + (key == "agent" || said != nil ? name.lowercased() : key)
        return CanvasAgent(id: id, name: name, color: color ?? CanvasColors.stable(name))
    }

    var json: [String: Any] { ["id": id, "name": name, "color": color] }
}

// MARK: - the bridge's door

/// The one `canvas` message handler every canvas web view shares. It finds
/// the host by the web view the message came from, and only listens to the
/// main frame of the bundled page — a popup that inherited the handler, or
/// a frame inside the page, is ignored.
final class CanvasRelay: NSObject, WKScriptMessageHandler {
    static let shared = CanvasRelay()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame, let web = message.webView,
                  let host = CanvasHost.host(showing: web),
                  CanvasPage.isPage(message.frameInfo.request.url ?? web.url)
            else { return }
            var body = message.body as? [String: Any]
            if body == nil, let text = message.body as? String, let data = text.data(using: .utf8) {
                body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            guard let body else { return }
            host.received(body, from: web)
        }
    }
}

// MARK: - the host

@MainActor
final class CanvasHost {
    static let handler = "canvas"
    static let log = Logger(subsystem: "com.collinrijock.copper", category: "canvas")

    struct Failure: Error { let text: String }

    private static var hosts: [Tab.ID: CanvasHost] = [:]
    /// Controllers that already carry the handler: registering a name twice
    /// is a crash, and re-registering under a live page can cut it off.
    private static let attached = NSHashTable<WKUserContentController>.weakObjects()

    static var all: [CanvasHost] {
        hosts = hosts.filter { $0.value.tab != nil }
        return Array(hosts.values)
    }

    weak var tab: Tab?
    weak var browser: Browser?
    private(set) var canvasId: String
    private var storeKey: String

    /// Bumped by every `ready` the page sends; `initialized` catches up when
    /// the page has been given its state.
    private var generation = 0
    private var initialized = 0
    private weak var readyWeb: WKWebView?
    private(set) var selection: [String] = []
    private var online = false
    private var room: CanvasRoom?
    /// The page's end of the relayed socket (its BridgeSocket), as far as
    /// the host knows: none, asked for (`wsOpen`), or told it is open.
    private enum PageSocket { case none, waiting, open }
    private var pageSocket = PageSocket.none
    private var pageEverAsked = false
    /// The room is newly (re)connected and its frames haven't been handed to
    /// any page socket yet — the server's SyncStep1 is among them.
    private var roomFresh = false
    private var heldFrames: [Data] = []
    private var openFallback: DispatchWorkItem?
    /// Frames came from the room since the last snapshot: the copy on disk
    /// is behind what collaborators wrote.
    private var remoteDirty = false
    private var lastSnapshot = Date()
    private var appearance: NSKeyValueObservation?
    private var compactingSince: Date?
    private var compactionUnsupported = false
    /// Clients in the room: awareness client id → whose it is (the state's
    /// `user.id`, else the client id) and when it was last heard from.
    private var peers: [UInt: (user: String, seen: Date)] = [:]
    /// Short-lived hashes of updates just passed between this Mac's tabs.
    private var recent: [Int] = []

    var entry: Canvases.Entry? { Canvases.shared.entry(canvasId) }
    var store: CanvasStore { CanvasStore.store(for: storeKey) }
    var isReady: Bool { initialized > 0 && initialized == generation && readyWeb != nil && readyWeb === tab?.built }
    var roomOpen: Bool { room?.isOpen ?? false }
    /// Other people in the room right now — by person, not by tab: you in a
    /// second tab or on another Mac are not a collaborator. Awareness states
    /// are renewed every 15 s, so one not heard for 45 s has gone.
    var collaborators: Int {
        let now = Date()
        let me = Canvases.shared.identity.id
        return Set(peers.values.filter { $0.user != me && now.timeIntervalSince($0.seen) < 45 }.map(\.user)).count
    }

    private init(tab: Tab, id: String, browser: Browser?) {
        self.tab = tab
        self.browser = browser
        canvasId = id
        storeKey = Canvases.shared.entry(id).map { Canvases.shared.storeKey($0) } ?? id
    }

    // MARK: finding hosts and tabs

    static func host(for tab: Tab) -> CanvasHost? {
        guard let host = hosts[tab.id], host.tab != nil else { return nil }
        return host
    }

    static func host(showing web: WKWebView) -> CanvasHost? {
        all.first { $0.tab?.built === web }
    }

    static func hosts(of id: String) -> [CanvasHost] { all.filter { $0.canvasId == id } }

    /// The tab showing this canvas — in this window's row, or parked in
    /// another space — whether or not its page is up yet.
    static func tab(showing id: String, in browser: Browser) -> Tab? {
        let here = browser.tabs + (browser.primary ? Spaces.shared.parkedTabs : [])
        return here.first { tab in (tab.pending ?? tab.address).flatMap(CanvasLinks.id(from:)) == id }
    }

    /// The canvas in front: the active tab, when it is one.
    static func active(in browser: Browser) -> String? {
        browser.active.flatMap { ($0.pending ?? $0.address).flatMap(CanvasLinks.id(from:)) }
    }

    /// Bring a canvas up: its tab if one is open (switched to when in front
    /// is asked for), else a new tab — the blank one in front, if that is
    /// what is showing.
    @discardableResult
    static func show(_ id: String, in browser: Browser, foreground: Bool = true) -> Tab {
        if let tab = tab(showing: id, in: browser) {
            if foreground {
                if browser.tabs.contains(where: { $0.id == tab.id }) { browser.select(tab) } else { _ = Spaces.shared.reveal(tab.id, in: browser) }
            }
            return tab
        }
        let url = CanvasLinks.url(id)
        if foreground, let blank = browser.active, blank.isBlank, !blank.floating {
            browser.replaceBlank(blank, with: url)
            browser.landed()
            return browser.active ?? blank
        }
        let tab = browser.open(url, foreground: foreground)
        if foreground { browser.landed() }
        return tab
    }

    // MARK: the web view

    /// A canvas tab's own configuration: the `canvas` handler is on it before
    /// the view exists, and no extension sees the page (Browser.open and the
    /// session restore ask for it; a tab told to go to a canvas some other
    /// way gets the handler when the page is loaded into it).
    static func configuration(for url: URL) -> WKWebViewConfiguration? {
        guard CanvasLinks.isCanvas(url) else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Store.testing && !Store.ownContainer
            ? WKWebsiteDataStore(forIdentifier: Store.probeStore(1)) : .default()
        config.applicationNameForUserAgent = Web.userAgentName
        if Store.testing, !Store.measuring { config.preferences.inactiveSchedulingPolicy = .none }
        config.userContentController.add(CanvasRelay.shared, name: handler)
        attached.add(config.userContentController)
        return config
    }

    private static func attach(_ web: WKWebView) {
        let controller = web.configuration.userContentController
        guard !attached.contains(controller) else { return }
        controller.removeScriptMessageHandler(forName: handler)
        controller.add(CanvasRelay.shared, name: handler)
        attached.add(controller)
    }

    private static func detach(_ web: WKWebView?) {
        guard let controller = web?.configuration.userContentController, attached.contains(controller) else { return }
        controller.removeScriptMessageHandler(forName: handler)
        attached.remove(controller)
    }

    /// The browser's navigation delegate asks this first. True: handled, cancel
    /// the navigation. False: carry on as usual.
    ///
    /// - `copper://canvas/<id>` in a tab's main frame: the canvas page loads there.
    /// - the bundled page itself (a reload, a slept tab waking up): allowed,
    ///   and the tab is a canvas tab again if it had stopped being one.
    /// - anywhere else, from a canvas page: a link or script on the page is
    ///   sent to a tab of its own; the address field, Back and Forward take the
    ///   tab with them and it stops being a canvas.
    static func decide(_ action: WKNavigationAction, url: URL, in web: WKWebView, browser: Browser) -> Bool {
        let main = action.targetFrame?.isMainFrame ?? false
        let popup = action.targetFrame == nil
        let tab = host(showing: web)?.tab ?? browser.tab(for: web) ?? (browser.primary ? Spaces.shared.parkedTabs.first { $0.built === web } : nil)

        if let id = CanvasLinks.id(from: url) {
            guard let tab, main, !popup else {
                // A link to a canvas from a page, or from a frame: the canvas,
                // in a tab of its own.
                show(id, in: browser, foreground: true)
                return true
            }
            mount(tab, id, in: browser)
            return true
        }

        guard let tab else { return false }
        if CanvasPage.isPage(url) {
            guard main else { return false }
            let id = CanvasPage.id(fromPage: url) ?? Canvases.personalID
            let host = hosts[tab.id] ?? register(tab, id, in: browser)
            host.browser = browser
            attach(web)
            if (tab.pending ?? tab.address).flatMap(CanvasLinks.id(from:)) != id {
                tab.setAddressOptimistically(CanvasLinks.url(id))
            }
            // Back/Forward may bring the page out of WebKit's page cache
            // whole — alive, and with nothing new to say.
            if action.navigationType == .backForward { host.adoptIfLive(after: 0.8) }
            return false
        }
        guard let host = hosts[tab.id] else { return false }
        // Frames inside the page go where they go.
        if !main && !popup { return false }
        // Told to go elsewhere by the field, a bookmark or the history list
        // (Tab.go sets the address first), or by Back/Forward: the tab does.
        if action.navigationType == .backForward || !CanvasLinks.isCanvas(tab.address) {
            host.unmount()
            return false
        }
        // The page itself asked: never in place. Web addresses get a tab.
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            browser.open(url, foreground: true)
        }
        return true
    }

    private static func register(_ tab: Tab, _ id: String, in browser: Browser) -> CanvasHost {
        let host = CanvasHost(tab: tab, id: id, browser: browser)
        hosts[tab.id] = host
        CanvasPresence.shared.recount()
        watch()
        return host
    }

    private static var sweeper: Timer?

    /// Every 20 s: a host whose tab is gone, or whose page was let go (a
    /// pinned tab put down, a tab asleep), stops holding its room open; and
    /// the collaborator count forgets people who went quiet.
    private static func watch() {
        guard sweeper == nil else { return }
        sweeper = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated {
                for host in all where host.room != nil && (host.tab?.built == nil || !host.isReady) {
                    host.room?.stop()
                    host.room = nil
                }
                for host in all where host.remoteDirty && Date().timeIntervalSince(host.lastSnapshot) > 120 {
                    host.compactIfNeeded(force: true)
                }
                CanvasPresence.shared.recount()
            }
        }
    }

    /// Load the canvas page into this tab.
    static func mount(_ tab: Tab, _ id: String, in browser: Browser) {
        let host: CanvasHost
        if let known = hosts[tab.id] {
            host = known
            if known.canvasId != id { known.switchTo(id) }
        } else {
            host = register(tab, id, in: browser)
        }
        host.browser = browser
        host.load()
    }

    private func switchTo(_ id: String) {
        room?.stop()
        room = nil
        pageSocket = .none
        pageEverAsked = false
        remoteDirty = false
        canvasId = id
        storeKey = entry.map { Canvases.shared.storeKey($0) } ?? id
        generation = 0
        initialized = 0
        selection = []
        peers = [:]
        CanvasPresence.shared.recount()
    }

    private func load() {
        guard let tab else { return }
        guard let page = CanvasPage.url(for: canvasId), let folder = CanvasPage.folder else {
            tab.failure = "This build of Copper has no canvas page."
            return
        }
        let web = tab.web
        CanvasHost.attach(web)
        // A canvas opened behind the tab you are on has never been laid out:
        // give it the window's size so "near the middle of the view" means something.
        if web.frame.size.width < 10 || web.frame.size.height < 10 {
            let size = Windows.window(of: browser ?? Windows.main)?.contentView?.bounds.size ?? NSSize(width: 1280, height: 820)
            web.frame = CGRect(origin: .zero, size: CGSize(width: max(800, size.width - 260), height: max(600, size.height)))
        }
        tab.failure = nil
        tab.icon = CanvasPage.icon
        web.loadFileURL(page, allowingReadAccessTo: folder)
    }

    /// The tab went somewhere that isn't a canvas.
    private func unmount() {
        room?.stop()
        room = nil
        appearance = nil
        if let tab { CanvasHost.hosts[tab.id] = nil }
        // The handler stays on the view: the page may come Back, and the
        // relay answers nobody but a host's own page in the meantime.
        CanvasPresence.shared.recount()
    }

    /// The tab is closing: its room closes and its view lets go of the handler.
    static func forget(_ tab: Tab) {
        guard let host = hosts.removeValue(forKey: tab.id) else { return }
        host.room?.stop()
        host.room = nil
        detach(tab.built)
        CanvasPresence.shared.recount()
    }

    // MARK: page → host

    func received(_ body: [String: Any], from web: WKWebView) {
        switch body["type"] as? String ?? "" {
        case "ready":
            // A new page: a new provider, which will want a connection of its own.
            readyWeb = web
            room?.stop()
            room = nil
            pageSocket = .none
            pageEverAsked = false
            roomFresh = false
            heldFrames = []
            Task { await ready() }
        case "update":
            guard let b64 = body["b64"] as? String, let update = Data(base64Encoded: b64) else { return }
            keep(update)
        case "selection":
            selection = (body["ids"] as? [Any])?.compactMap { $0 as? String } ?? []
        case "ws":
            guard let b64 = body["b64"] as? String, let frame = Data(base64Encoded: b64) else { return }
            room?.send(frame)
        case "wsOpen":
            // A new BridgeSocket. It needs the server's SyncStep1 of its own,
            // so a room already used by an older socket is reconnected.
            pageSocket = .waiting
            pageEverAsked = true
            openFallback?.cancel()
            guard online else { return }
            if let room, room.isOpen {
                if roomFresh { tellOpen() } else { room.restart() }
            } else {
                startRoom()
            }
        case "wsClose":
            // The provider let go (destroyed, or its own timeout): so does the room.
            pageSocket = .none
            room?.stop()
            room = nil
            CanvasPresence.shared.recount()
        case "openUrl":
            guard let text = body["url"] as? String, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") || CanvasLinks.isCanvas(url),
                  let browser = browser ?? Windows.all.first
            else { return }
            if let id = CanvasLinks.id(from: url) { CanvasHost.show(id, in: browser) } else { browser.open(url, foreground: true) }
        case "log":
            let level = body["level"] as? String ?? "debug"
            let text = String(describing: body["msg"] ?? "")
            CanvasHost.log.debug("page [\(level, privacy: .public)] \(text, privacy: .public)")
            if level == "error" { lastError = text }
        default:
            break
        }
    }

    /// The last error the page logged, for the bench.
    private(set) var lastError: String?

    /// One update from this page (or handed across from another tab on the
    /// same canvas): on disk first, then to every other tab showing it.
    ///
    /// Nothing the page reports is ever dropped — not even while its history
    /// is being handed back: the page writes real changes during `init` (a
    /// new board records its name), and one missing update leaves a gap in
    /// that client's clock that strands every later one. The page doesn't
    /// echo what the host gives it (those carry the host's origin).
    private func keep(_ update: Data) {
        let hash = update.hashValue
        // An update this page only echoed back after being handed it.
        if let at = recent.firstIndex(of: hash) { recent.remove(at: at); return }
        store.append(update)
        Canvases.shared.touched(canvasId)
        for other in CanvasHost.hosts(of: canvasId) where other !== self && other.isReady && other.storeKey == storeKey {
            other.recent.append(hash)
            if other.recent.count > 64 { other.recent.removeFirst(other.recent.count - 64) }
            Task { try? await other.call("window.copperCanvas.applyUpdate(u)", ["u": update.base64EncodedString()]) }
        }
        compactIfNeeded()
    }

    // MARK: ready → init

    private func ready() async {
        generation += 1
        let ticket = generation
        guard let tab, let web = tab.built else { return }
        tab.icon = CanvasPage.icon
        watchAppearance(web)
        // Signed in but the server's list not read yet this run: give it a
        // moment, so the first init already knows whether there is a room —
        // but only a moment. The board never waits on the network: rooms
        // known from before are in canvases.json, and a list that arrives
        // later reloads the page into its room (cloudChanged).
        if Canvases.shared.cloudReady, Canvases.shared.refreshed == nil {
            Canvases.shared.refreshSoon()
            let until = Date().addingTimeInterval(1.5)
            while Canvases.shared.refreshed == nil, Date() < until {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        guard ticket == generation, let entry = entry else {
            if entry == nil { tab.failure = "That canvas isn't here any more." }
            return
        }
        storeKey = Canvases.shared.storeKey(entry)
        let (snapshot, updates) = store.load()
        let remote = Canvases.shared.room(for: entry)
        online = remote != nil
        let me = Canvases.shared.identity
        let options: [String: Any] = [
            "docId": entry.remoteId ?? entry.id,
            "name": entry.name,
            "kind": entry.kind.rawValue,
            "me": ["id": me.id, "name": me.name, "color": me.color],
            "state": snapshot.map { $0.base64EncodedString() as Any } ?? NSNull(),
            "online": online,
            "readOnly": false,
        ]
        do {
            _ = try await call("""
                const c = window.copperCanvas;
                if (!c || typeof c.init !== 'function') throw new Error('copperCanvas.init is missing');
                await c.init(options);
                for (const u of updates) c.applyUpdate(u);
                if (typeof c.theme === 'function') c.theme(theme);
                document.title = title;
                window.__copperCanvasHost = ticket;
                return true;
                """, ["options": options, "updates": updates.map { $0.base64EncodedString() }, "theme": theme(of: web),
                      "title": CanvasLinks.title(entry.name), "ticket": ticket])
        } catch {
            CanvasHost.log.error("init failed: \(String(describing: error), privacy: .public)")
            lastError = "\(error)"
            return
        }
        guard ticket == generation else { return }
        initialized = ticket
        lastSnapshot = Date()
        if online {
            if entry.isPersonal { Canvases.shared.bindPersonal() }
            // The page's provider asks for the socket itself (`wsOpen`), often
            // while init is still running; a page that never asks gets it anyway.
            if pageEverAsked || pageSocket == .waiting {
                if room == nil { startRoom() }
                tellOpen()
            } else {
                startRoom()
            }
        } else {
            room?.stop()
            room = nil
        }
        CanvasPresence.shared.recount()
        // A board opened from a log is folded into one snapshot straight
        // away: the next open hands the page the whole document in `init`
        // (so it sees its own name and history at once) and replays nothing.
        compactIfNeeded(force: !updates.isEmpty)
    }

    private func theme(of web: WKWebView) -> String {
        web.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    private func watchAppearance(_ web: WKWebView) {
        appearance = web.observe(\.effectiveAppearance, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self, self.isReady else { return }
                let theme = self.theme(of: web)
                Task { try? await self.call("if (typeof window.copperCanvas.theme === 'function') window.copperCanvas.theme(t)", ["t": theme]) }
            }
        }
    }

    // MARK: host → page

    /// Runs `body` as an async function in the page's world, with `arguments`
    /// as its locals — no JavaScript is ever built by pasting strings.
    @discardableResult
    func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        guard let web = tab?.built else { throw Failure(text: "the canvas page isn't loaded") }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value is NSNull ? nil : value)
                case .failure(let error):
                    let ns = error as NSError
                    let detail = (ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ns.localizedDescription
                    continuation.resume(throwing: Failure(text: "canvas page: \(detail)"))
                }
            }
        }
    }

    /// A page that is up and running but never said `ready` to this host
    /// (restored from the page cache, or loaded before the host existed) is
    /// given its state now, as if it had.
    func adoptIfLive(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isReady, let web = self.tab?.built, CanvasPage.isPage(web.url) else { return }
            web.evaluateJavaScript("!!(window.copperCanvas && typeof window.copperCanvas.init === 'function')") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, value as? Bool == true, !self.isReady, self.tab?.built === web else { return }
                    self.received(["type": "ready"], from: web)
                }
            }
        }
    }

    /// Until the page has sent `ready` and been given its state. A tab that is
    /// asleep, or was never built, is woken for it.
    func waitReady(timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let started = Date()
        var nudged = false
        var adopted = false
        while Date() < deadline {
            if isReady { return }
            if let tab, !nudged {
                nudged = true
                if tab.asleep { _ = tab.wake() } else if tab.hollow { tab.revive() }
            }
            if !adopted, Date().timeIntervalSince(started) > 2 {
                adopted = true
                adoptIfLive(after: 0)
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        throw Failure(text: "the canvas page didn't come up within \(Int(timeout)) s\(lastError.map { " (\($0))" } ?? "")")
    }

    /// Decoded from a JSON string, or taken as it is when the page answered with an object.
    private static func object(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        if let text = value as? String, let data = text.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return nil
    }

    func apply(_ ops: [Any], as agent: CanvasAgent) async throws -> [String: Any] {
        try await waitReady()
        // `{ops, as}` as one JSON string: the page attributes every shape the
        // batch touches to `as` and shows the agent (writing, then idle) where
        // it last wrote.
        let data = try JSONSerialization.data(withJSONObject: ["ops": ops, "as": agent.json] as [String: Any])
        let raw = try await call("""
            const out = await window.copperCanvas.apply(input);
            return typeof out === 'string' ? out : JSON.stringify(out);
            """, ["input": String(decoding: data, as: UTF8.self)])
        guard var result = CanvasHost.object(raw) else { throw Failure(text: "the canvas page gave back no result") }
        if result["applied"] == nil { result["applied"] = 0 }
        if result["ids"] == nil { result["ids"] = [String]() }
        if result["errors"] == nil { result["errors"] = [Any]() }
        return result
    }

    func read(full: Bool) async throws -> [String: Any] {
        try await waitReady()
        let raw = try await call("""
            const out = await window.copperCanvas.read(opts);
            return typeof out === 'string' ? out : JSON.stringify(out);
            """, ["opts": "{\"full\":\(full ? "true" : "false")}"])
        guard var result = CanvasHost.object(raw) else { throw Failure(text: "the canvas page gave back nothing to read") }
        if let entry, var canvas = result["canvas"] as? [String: Any] {
            // The host's names win: the registry is what the tools list.
            canvas["id"] = entry.id
            canvas["name"] = entry.name
            canvas["kind"] = entry.kind.rawValue
            result["canvas"] = canvas
        } else if let entry {
            result["canvas"] = ["id": entry.id, "name": entry.name, "kind": entry.kind.rawValue]
        }
        if (result["selection"] as? [Any])?.isEmpty ?? true, !selection.isEmpty { result["selection"] = selection }
        return result
    }

    func select(_ ids: [String]) async throws {
        try await waitReady()
        try await call("window.copperCanvas.select(ids)", ["ids": ids])
        selection = ids
    }

    func zoom(to ids: [String]) async throws {
        try await waitReady()
        try await call("window.copperCanvas.zoomTo(ids)", ["ids": ids])
    }

    /// The board as it looks, for an agent that wants to see it.
    func picture() async throws -> Data {
        try await waitReady()
        guard let web = tab?.built else { throw Failure(text: "the canvas page isn't loaded") }
        return try await Tools.Page.screenshot(web, rect: nil, fullPage: false, jpeg: false)
    }

    // MARK: keeping the log short

    /// Past 2 MB / 500 entries — or, `force`, a snapshot now because the
    /// room brought in what others wrote (the page only reports its own
    /// changes, so the copy on disk would otherwise lag behind the room).
    private func compactIfNeeded(force: Bool = false) {
        guard isReady, force || store.wantsCompaction, !compactionUnsupported else { return }
        if let since = compactingSince, Date().timeIntervalSince(since) < 30 { return }
        compactingSince = Date()
        let covered = store.entries
        let store = store
        Task {
            defer { compactingSince = nil }
            do {
                let raw = try await call("""
                    const c = window.copperCanvas;
                    if (typeof c.exportState !== 'function') return null;
                    return await c.exportState();
                    """)
                guard let b64 = raw as? String, let state = Data(base64Encoded: b64), !state.isEmpty else {
                    compactionUnsupported = true
                    return
                }
                store.compact(state: state, dropping: covered)
                remoteDirty = false
                lastSnapshot = Date()
            } catch {
                CanvasHost.log.error("compaction failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: the room

    private func startRoom() {
        guard let entry, let remote = Canvases.shared.room(for: entry) else { return }
        if let room, room.remoteId == remote {
            room.start()
            return
        }
        room?.stop()
        let room = CanvasRoom(remoteId: remote)
        room.onState = { [weak self] open in self?.roomChanged(open) }
        room.onData = { [weak self] frame in self?.deliver(frame) }
        self.room = room
        room.start()
    }

    private func roomChanged(_ open: Bool) {
        openFallback?.cancel()
        heldFrames = []
        if open {
            roomFresh = true
            if pageSocket == .waiting {
                tellOpen()
            } else if !pageEverAsked {
                // A page that never asks for the socket still gets it.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.pageEverAsked else { return }
                    self.pageSocket = .waiting
                    self.tellOpen()
                }
                openFallback = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            }
        } else {
            roomFresh = false
            peers = [:]
            if pageSocket != .none {
                pageSocket = .none
                Task { try? await call("window.copperCanvas.wsState('closed')") }
            }
        }
        CanvasPresence.shared.recount()
    }

    /// The room is up and the page's socket is waiting: open it, then hand
    /// over what the room said in the meantime.
    private func tellOpen() {
        guard let room, room.isOpen, isReady, pageSocket == .waiting else { return }
        pageSocket = .open
        roomFresh = false
        let held = heldFrames
        heldFrames = []
        Task {
            try? await call("""
                window.copperCanvas.wsState('open');
                for (const f of frames) window.copperCanvas.wsMessage(f);
                """, ["frames": held.map { $0.base64EncodedString() }])
        }
    }

    private func deliver(_ frame: Data) {
        guard tab?.built != nil else {
            room?.stop()
            room = nil
            return
        }
        noteIncoming(frame)
        remoteDirty = true
        switch pageSocket {
        case .open:
            Task { try? await call("window.copperCanvas.wsMessage(f)", ["f": frame.base64EncodedString()]) }
        case .waiting, .none:
            // Kept until the page's socket opens — but only for a fresh
            // connection; anything older is for a socket that is gone.
            guard roomFresh else { return }
            heldFrames.append(frame)
            if heldFrames.count > 2000 { heldFrames.removeFirst() }
        }
    }

    /// Signed in, signed out, the list read: canvases whose room came or went
    /// are reloaded so the page starts (or stops) its provider.
    static func cloudChanged() {
        for host in all {
            guard let entry = host.entry, host.isReady else { continue }
            let wants = Canvases.shared.room(for: entry) != nil
            let key = Canvases.shared.storeKey(entry)
            if wants != host.online || key != host.storeKey {
                host.room?.stop()
                host.room = nil
                host.tab?.built?.reload()
            }
        }
        CanvasPresence.shared.recount()
    }

    static func renamed(_ id: String) {
        guard let entry = Canvases.shared.entry(id) else { return }
        for host in hosts(of: id) where host.isReady {
            Task { try? await host.call("document.title = t", ["t": CanvasLinks.title(entry.name)]) }
        }
    }

    /// Deleted or left: its tabs close.
    static func removed(_ id: String) {
        for host in hosts(of: id) {
            if let tab = host.tab { forget(tab) }
        }
        // Every row's tab on it, loaded or not. (One parked in another space
        // stays until it is opened, and then says the canvas has gone.)
        for browser in Windows.all {
            for tab in browser.tabs where (tab.pending ?? tab.address).flatMap(CanvasLinks.id(from:)) == id {
                if tab.pin != nil { tab.pin = nil }
                browser.close(tab)
            }
        }
    }

    // MARK: who else is in the room (y-protocols awareness, read off the wire)

    private func noteIncoming(_ frame: Data) {
        guard let states = CanvasWire.awareness(frame) else { return }
        let now = Date()
        for (client, state) in states {
            guard let state else { peers[client] = nil; continue }
            let user = ((state["user"] as? [String: Any])?["id"] as? String) ?? (state["id"] as? String) ?? "client:\(client)"
            peers[client] = (user, now)
        }
        CanvasPresence.shared.recount()
    }

    // MARK: the bench

    var describe: [String: Any] {
        var out: [String: Any] = [
            "canvas": canvasId, "ready": isReady, "generation": generation, "online": online,
            "room": roomOpen, "collaborators": collaborators, "selection": selection, "store": store.describe,
            "clients": peers.count,
        ]
        if let tab { out["tab"] = String(tab.id.uuidString.prefix(8)).lowercased(); out["address"] = tab.address?.absoluteString ?? "" }
        if let lastError { out["lastError"] = lastError }
        return out
    }
}

// MARK: - the relayed socket

/// One canvas room on the linked cloud: a CloudSocket to
/// `/v1/canvases/<id>/ws`, reconnected after every drop with a backoff from
/// 1 s to 30 s (± 30 % jitter) until stopped.
@MainActor
final class CanvasRoom {
    let remoteId: String
    var onState: ((Bool) -> Void)?
    var onData: ((Data) -> Void)?

    private var socket: CloudSocket?
    private var stopped = true
    private var delay: Double = 1
    /// Connections in a row that never opened. The server closes a room on
    /// a member it revoked or a canvas it deleted (4403 / 4404) and refuses
    /// the next upgrade; CloudSocket doesn't say which, so after a couple of
    /// failures the list is read again — a canvas gone from it closes.
    private var failures = 0
    private var retry: DispatchWorkItem?
    private(set) var isOpen = false

    init(remoteId: String) { self.remoteId = remoteId }

    func start() {
        guard stopped else { return }
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        retry?.cancel()
        retry = nil
        let socket = socket
        self.socket = nil
        socket?.onClose = nil
        socket?.onData = nil
        socket?.onOpen = nil
        socket?.close()
        if isOpen {
            isOpen = false
            onState?(false)
        }
    }

    func send(_ frame: Data) {
        guard isOpen else { return }
        socket?.send(frame)
    }

    /// A new connection at once, without saying the old one closed — for a
    /// new page socket that needs the server's greeting of its own.
    func restart() {
        guard !stopped else { start(); return }
        retry?.cancel()
        let old = socket
        socket = nil
        old?.onClose = nil
        old?.onData = nil
        old?.onOpen = nil
        old?.close()
        isOpen = false
        delay = 1
        connect()
    }

    private func connect() {
        guard !stopped, socket == nil, Canvases.shared.cloudReady else {
            if !stopped { schedule() }
            return
        }
        let socket = Cloud.shared.socket(path: "/v1/canvases/\(remoteId)/ws")
        socket.onOpen = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.delay = 1
                self.failures = 0
                self.isOpen = true
                self.onState?(true)
            }
        }
        socket.onData = { [weak self] data in
            MainActor.assumeIsolated { self?.onData?(data) }
        }
        socket.onClose = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.socket = nil
                if self.isOpen {
                    self.isOpen = false
                    self.onState?(false)
                } else {
                    self.failures += 1
                    if self.failures == 2 || self.failures % 10 == 0 { Canvases.shared.refreshSoon() }
                }
                if let error { CanvasHost.log.debug("room \(self.remoteId, privacy: .public) closed: \(String(describing: error), privacy: .public)") }
                self.schedule()
            }
        }
        self.socket = socket
        socket.connect()
    }

    private func schedule() {
        guard !stopped else { return }
        retry?.cancel()
        let wait = delay * Double.random(in: 0.7...1.3)
        delay = min(30, delay * 2)
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }
}

// MARK: - reading the wire

/// Just enough of lib0's encoding to see who is in a room. A y-websocket
/// frame holds one or more messages, each a varuint type and its payload:
/// 0 sync (a varuint subtype and a varuint8array), 1 awareness (a
/// varuint8array holding a count and, per client, its id, clock and state as
/// JSON — `null` when the client has gone), 2 auth, 3 awareness query.
enum CanvasWire {
    static func awareness(_ frame: Data) -> [(UInt, [String: Any]?)]? {
        var reader = Reader(bytes: [UInt8](frame))
        var out: [(UInt, [String: Any]?)] = []
        var saw = false
        while reader.left > 0 {
            guard let type = reader.varUInt() else { break }
            switch type {
            case 0:
                guard reader.varUInt() != nil, reader.skipBytes() else { return saw ? out : nil }
            case 1:
                guard let length = reader.varUInt(), length <= reader.left else { return saw ? out : nil }
                var inner = Reader(bytes: Array(reader.bytes[reader.at ..< reader.at + Int(length)]))
                reader.at += Int(length)
                saw = true
                guard let count = inner.varUInt(), count < 10_000 else { continue }
                for _ in 0 ..< count {
                    guard let client = inner.varUInt(), inner.varUInt() != nil, let state = inner.string() else { break }
                    let parsed = state == "null" ? nil : (try? JSONSerialization.jsonObject(with: Data(state.utf8))) as? [String: Any]
                    out.append((client, state == "null" ? nil : (parsed ?? [:])))
                }
            case 3:
                continue
            default:
                return saw ? out : nil
            }
        }
        return saw ? out : nil
    }

    struct Reader {
        let bytes: [UInt8]
        var at = 0
        var left: UInt { UInt(bytes.count - at) }

        mutating func varUInt() -> UInt? {
            var value: UInt = 0
            var shift: UInt = 0
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                value |= UInt(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }

        mutating func skipBytes() -> Bool {
            guard let length = varUInt(), length <= left else { return false }
            at += Int(length)
            return true
        }

        mutating func string() -> String? {
            guard let length = varUInt(), length <= left else { return nil }
            let end = at + Int(length)
            defer { at = end }
            return String(decoding: bytes[at ..< end], as: UTF8.self)
        }
    }
}
