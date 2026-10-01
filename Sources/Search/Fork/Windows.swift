import AppKit
import SwiftUI

// More than one window. ⌘N opens another browser window with its own row
// of tabs, as many as you like; the window Copper launches with stays the
// one that owns Spaces, the session file, the bench and the MCP server's
// home. Every other window is a plain row of tabs — no spaces of its own —
// sharing the one history, bookmarks, settings and hidden-element lists, so
// nothing on disk is ever written by two owners.
//
// Other windows come back at the next launch (windows.json, beside
// session.json). Closing one with the red button lets its tabs go, the way
// closing a window does in any browser; quitting keeps them.
//
// Agents follow the window you are in: the MCP server and the command bar
// act on the frontmost browser window, and fall back to the first one when
// that window closes.

@MainActor
enum Windows {
    /// The browser the app launches with. The app's scene holds it; every
    /// other window borrows its shared parts (Browser.init(window:)).
    static let main = Browser()

    /// The windows opened with ⌘N, by the id their scene carries.
    private static var others: [UUID: Browser] = [:]
    private static var order: [UUID] = []

    /// Every browser that has, or had at launch, a window — the first one first.
    static var all: [Browser] { [main] + order.compactMap { others[$0] } }

    /// Set by the first window's view: opens a scene for an id.
    static var opener: ((UUID) -> Void)?
    /// The app is on its way out: windows closing now are being kept.
    static var quitting = false

    /// ⌘N.
    static func newWindow() {
        guard let opener else { return }
        opener(UUID())
    }

    /// The browser for a window scene's id, made the first time it is asked for.
    static func browser(for id: UUID) -> Browser {
        if let known = others[id] { return known }
        let browser = Browser(window: id)
        others[id] = browser
        order.append(id)
        return browser
    }

    // MARK: - which window is which

    private final class Weak { weak var window: NSWindow?; weak var browser: Browser?
        init(_ w: NSWindow, _ b: Browser) { window = w; browser = b } }
    private static var windows: [Weak] = []
    /// Each window's two observers, let go when it closes.
    private static var tokens: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    /// A browser's window, once it is on screen. Also where agents turn when
    /// the window becomes the one in front.
    static func attach(_ window: NSWindow, to browser: Browser) {
        guard !windows.contains(where: { $0.window === window && $0.browser === browser }) else { return }
        windows.removeAll { $0.window == nil || $0.window === window }
        windows.append(Weak(window, browser))
        let center = NotificationCenter.default
        let key = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak browser] _ in
            MainActor.assumeIsolated {
                guard let browser else { return }
                front = browser
                MCP.shared.follow(browser)
            }
        }
        let slot = ObjectIdentifier(window)
        let close = center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak browser] _ in
            MainActor.assumeIsolated {
                for token in tokens.removeValue(forKey: slot) ?? [] { NotificationCenter.default.removeObserver(token) }
                guard let browser, let id = browser.windowID else { return }
                closed(id)
            }
        }
        tokens[slot] = [key, close]
        // A window opened with ⌘N is key before it is attached: the
        // notification above has already gone by.
        if window.isKeyWindow {
            front = browser
            MCP.shared.follow(browser)
        }
    }

    /// The browser window in front, or the first one.
    private(set) static weak var front: Browser?
    static var current: Browser { front ?? main }

    /// The browser a window belongs to; nil for a panel, a popup, a sheet.
    static func owner(of window: NSWindow?) -> Browser? {
        guard let window else { return nil }
        return windows.first { $0.window === window }?.browser
    }

    /// A browser's own window.
    static func window(of browser: Browser) -> NSWindow? {
        windows.first { $0.browser === browser && $0.window != nil }?.window
    }

    /// True for a window some browser owns.
    static func isBrowserWindow(_ window: NSWindow?) -> Bool { owner(of: window) != nil }

    /// The browser with this tab in its row.
    static func owner(of tab: Tab) -> Browser? {
        all.first { browser in browser.tabs.contains { $0 === tab } }
    }

    /// A ⌘N window closed. Quitting keeps it for next time; the red button
    /// lets its pages go.
    private static func closed(_ id: UUID) {
        guard !quitting, let browser = others.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if front === browser { front = nil }
        if MCP.shared.follows(browser) { MCP.shared.follow(main) }
        // An agent at work in this window stops with it, rather than
        // building pages in a browser nobody can see.
        Agent.shared.stop(ifIn: browser)
        browser.retire()
        saved.removeAll { $0.id == id }
        write(now: true)
    }

    // MARK: - keeping

    struct Saved: Codable {
        var id: UUID
        var tabs: [Session.Entry]
        var active: Int
    }

    private static var file: URL { Store.file("windows.json") }
    private static let writer = DispatchQueue(label: "copper.windows.write", qos: .utility)
    private static var saved: [Saved] = {
        guard let data = try? Data(contentsOf: Windows.file) else { return [] }
        return (try? JSONDecoder().decode([Saved].self, from: data)) ?? []
    }()

    /// The row a reopened window starts with.
    static func savedTabs(for id: UUID) -> Saved? { saved.first { $0.id == id } }

    /// A ⌘N window's row changed.
    static func keep(_ browser: Browser, now: Bool = false) {
        guard record(browser) else { return }
        write(now: now)
    }

    /// The row as it is, in memory. False for a window that is not open.
    @discardableResult
    private static func record(_ browser: Browser) -> Bool {
        guard let id = browser.windowID, others[id] != nil else { return false }
        var entries: [Session.Entry] = []
        var active = 0
        for tab in browser.tabs {
            guard let entry = Session.Entry(tab) else { continue }
            if tab.id == browser.activeID { active = entries.count }
            entries.append(entry)
        }
        let row = Saved(id: id, tabs: entries, active: active)
        if let i = saved.firstIndex(where: { $0.id == id }) { saved[i] = row } else { saved.append(row) }
        return true
    }

    /// Every ⌘N window, to disk on the way out.
    static func flush() {
        quitting = true
        for browser in all where !browser.primary { record(browser) }
        write(now: true)
    }

    private static func write(now: Bool) {
        let rows = saved
        let file = Windows.file
        let put: @Sendable () -> Void = {
            guard let data = try? JSONEncoder().encode(rows) else { return }
            try? data.write(to: file, options: .atomic)
        }
        // One queue, in order: an older snapshot can never land after a newer one.
        if now { writer.sync(execute: put) } else { writer.async(execute: put) }
    }

    /// Launch: the windows that were open when Copper quit, back on screen.
    /// A scene macOS already restored is simply brought forward again.
    static func reopen() {
        guard let opener else { return }
        for row in saved where !row.tabs.isEmpty { opener(row.id) }
        // A window that came back empty is not worth keeping a record of.
        saved.removeAll { $0.tabs.isEmpty }
    }
}

/// A window opened with ⌘N: its own browser, the same view as the first.
struct OtherWindow: View {
    let id: UUID
    @StateObject private var browser: Browser

    init(id: UUID) {
        self.id = id
        _browser = StateObject(wrappedValue: Windows.browser(for: id))
    }

    var body: some View {
        ContentView(browser: browser)
            .frame(minWidth: 640, minHeight: 420)
    }
}

/// The first window's hand on `openWindow`, for ⌘N from anywhere.
struct WindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            guard Windows.opener == nil else { return }
            Windows.opener = { id in openWindow(id: "window", value: id) }
            // The ones open at the last quit, a moment after the first window
            // is up so it keeps its place in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Windows.reopen()
                NSApp.windows.first { Windows.owner(of: $0) === Windows.main }?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - the bench

extension Windows {
    /// `windows` lists every browser window; `windows new`; `windows open N URL`
    /// (a tab in window N); `windows key N`; `windows close N` (the red button);
    /// `windows saved` is windows.json as held; `windows quit` is ⌘Q.
    static func bench(_ request: [String: Any]) -> [String: Any] {
        let op = request["op"] as? String ?? ""
        let arg = request["arg"] as? String ?? ""
        let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let list = all
        func pick() -> Browser? { bits.first.flatMap(Int.init).flatMap { list.indices.contains($0) ? list[$0] : nil } }
        switch op {
        case "new": newWindow()
        case "open":
            guard let browser = pick(), bits.count > 1, let url = URL(string: bits[1]) else { return ["error": "open N URL"] }
            _ = browser.open(url, foreground: true)
        case "key":
            guard let browser = pick() else { return ["error": "key N"] }
            window(of: browser)?.makeKeyAndOrderFront(nil)
        case "close":
            guard let browser = pick() else { return ["error": "close N"] }
            window(of: browser)?.performClose(nil)
        case "quit":
            // A real ⌘Q, so a test can see what comes back at the next launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return ["quitting": true]
        case "saved":
            return ["saved": saved.map { ["id": $0.id.uuidString, "tabs": $0.tabs.map(\.url), "active": $0.active] as [String: Any] }]
        default: break
        }
        return ["windows": list.enumerated().map { i, browser -> [String: Any] in
            let window = window(of: browser)
            return ["index": i, "primary": browser.primary, "id": browser.windowID?.uuidString ?? "",
                    "number": window?.windowNumber ?? 0, "key": window?.isKeyWindow ?? false,
                    "visible": window?.isVisible ?? false, "front": browser === current,
                    "mcp": MCP.shared.follows(browser),
                    "tabs": browser.tabs.map { $0.address?.absoluteString ?? "" },
                    "tabIDs": browser.tabs.map { String($0.id.uuidString.prefix(8)).lowercased() },
                    "active": browser.tabs.firstIndex { $0.id == browser.activeID } ?? -1]
        }, "opener": opener != nil]
    }
}
