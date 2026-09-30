import SwiftUI
import WebKit

// A living backdrop for the column: a three.js scene drawn in the theme's
// colours. The scene itself is Backdrop/scene.js — a noise-displaced plane
// in perspective, Stripe's hero technique — and this file is the frame it
// hangs in: one non-interactive WKWebView per backdrop, kept for as long as
// the view is on screen and fed new colours through evaluateJavaScript
// rather than reloaded, and told to stop drawing whenever nobody can see it.
//
// The still gradient the theme would otherwise draw sits underneath: it is
// what shows while the page loads, and all there is if the scene files are
// missing or WebGL is refused.

struct AnimatedBackdrop: View {
    /// The scenes on offer, by the name `SpaceTheme.Motion.style` stores.
    static let styles: [(id: String, name: String)] = [
        ("ribbons", "Ribbons"), ("silk", "Silk"), ("aurora", "Aurora"), ("waves", "Waves"),
    ]

    let style: String
    /// The column colours (already `SpaceTheme.ground`-ed) the scene paints with.
    let colors: [Color]
    /// 0…2, 1 is the scene's own pace.
    let speed: Double
    /// 0…1, how soft the scene is drawn.
    let blur: Double
    let dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: colors.count > 1 ? colors : colors + colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if BackdropScene.folder != nil {
                BackdropWeb.Host(look: BackdropScene.Look(
                    style: style, colors: colors.map(BackdropScene.hex), speed: speed, blur: blur, dark: dark))
                    .allowsHitTesting(false)
            }
        }
    }
}

enum BackdropScene {
    /// Everything the page needs to draw, as one value so a SwiftUI update
    /// that changes nothing sends nothing.
    struct Look: Equatable {
        var style: String
        var colors: [String]
        var speed: Double
        var blur: Double
        var dark: Bool

        var json: String {
            let object: [String: Any] = ["style": style, "colors": colors, "speed": speed, "blur": blur, "dark": dark]
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }
    }

    /// Where scene.html and three.js live. SwiftPM puts the target's
    /// resources in `Search_Search.bundle` beside the binary, which is what a
    /// bench run of `.build/release/Search` sees as its resource folder;
    /// build.sh copies the same bundle into Copper.app's Resources. Opened
    /// as a bundle rather than by path, because the toolchain decides
    /// whether the files sit at its root or under Contents/Resources. Nil is
    /// a build without it, and the column stays still.
    static let folder: URL? = {
        let name = "Search_Search.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        let folders = roots.flatMap { root -> [URL] in
            var found: [URL] = []
            if let inner = Bundle(url: root.appendingPathComponent(name))?.resourceURL { found.append(inner.appendingPathComponent("Backdrop")) }
            found.append(root.appendingPathComponent("Backdrop"))
            return found
        }
        return folders.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scene.html").path) }
    }()

    /// `#rrggbb` in sRGB, which is how the shaders want their colours.
    static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        let byte = { (v: CGFloat) in Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// Bench runs never reach the screen — WebKit calls their windows
    /// occluded and stops requestAnimationFrame — so under test the scene
    /// keeps drawing on a timer and the pause rules that read the window are
    /// skipped. Reduce Motion and Low Power are honoured either way.
    static let forced = Store.testing
}

/// The web view behind an animated column. It draws nothing itself until the
/// page is up and the first look has been sent, and it holds one process for
/// its whole life: colours, speed, blur and appearance go over as a JSON
/// call, and a change of style swaps the shader without a reload.
final class BackdropWeb: WKWebView, WKNavigationDelegate {
    struct Host: NSViewRepresentable {
        let look: BackdropScene.Look

        func makeNSView(context: Context) -> BackdropWeb {
            let view = BackdropWeb()
            view.apply(look)
            return view
        }

        // The same view, whatever SwiftUI redraws above it: a new WebContent
        // process for every colour tweak would be the one thing this must
        // never cost.
        func updateNSView(_ view: BackdropWeb, context: Context) {
            view.apply(look)
        }
    }

    private var look: BackdropScene.Look?
    private var loaded = false
    private var sent: String?
    private var observers: [NSObjectProtocol] = []
    private var occlusion: NSObjectProtocol?

    /// One throwaway store for every backdrop: the page keeps no state, and
    /// sharing one lets WebKit warm a second column's process from the first.
    private static let store = WKWebsiteDataStore.nonPersistent()

    private static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        // scene.js is an ES module loaded from a file URL, and WebKit treats
        // each file as its own origin unless told the folder is one page.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        if BackdropScene.forced {
            // Under test the window is never visible, so WebKit would nap the
            // process and stretch its timers; the bench needs it at pace.
            config.preferences.inactiveSchedulingPolicy = .none
            if config.preferences.responds(to: NSSelectorFromString("_setHiddenPageDOMTimerThrottlingEnabled:")) {
                config.preferences.setValue(false, forKey: "hiddenPageDOMTimerThrottlingEnabled")
            }
        }
        return config
    }

    init() {
        super.init(frame: .zero, configuration: BackdropWeb.configuration())
        navigationDelegate = self
        // The gradient underneath shows until the first frame, and nothing
        // white flashes in between.
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { isInspectable = Store.testing }
        guard let folder = BackdropScene.folder else { return }
        loadFileURL(folder.appendingPathComponent("scene.html"), allowingReadAccessTo: folder)
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            // Power-state changes arrive on a background queue.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }

    // Nothing here is for the pointer: rows, doors and drags belong to the
    // SwiftUI column drawn over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func apply(_ look: BackdropScene.Look) {
        guard look != self.look else { return }
        self.look = look
        guard loaded else { return }
        call("set", look.json)
        refresh()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let look { call("set", look.json) }
        if BackdropScene.forced {
            call("force", "true")
            // So a bench can find the processes to weigh: the same private
            // selectors Heat reads, and just as optional.
            let pids = ["_webProcessIdentifier", "_gpuProcessIdentifier"].map { name -> String in
                guard responds(to: NSSelectorFromString(name)), let pid = value(forKey: name) as? NSNumber else { return "?" }
                return pid.stringValue
            }
            NSLog("AnimatedBackdrop: web process %@, gpu process %@", pids[0], pids[1])
        }
        sent = nil
        refresh()
    }

    // MARK: Pausing

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    override func viewDidHide() { super.viewDidHide(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }

    /// What the page should be doing right now. `still` draws one frame and
    /// stops — the scene is there, it just doesn't move; `pause` draws
    /// nothing new, for a column nobody can see.
    private var mode: String {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled { return "still" }
        guard let window, !isHiddenOrHasHiddenAncestor else { return "pause" }
        if BackdropScene.forced { return "run" }
        guard window.occlusionState.contains(.visible), NSApp.isActive else { return "pause" }
        return "run"
    }

    private func refresh() {
        guard loaded else { return }
        let mode = mode
        guard mode != sent else { return }
        sent = mode
        call("mode", "'\(mode)'")
    }

    /// `window.backdrop.NAME(ARG)` — or, before the module has run, a note
    /// for it to pick up when it does.
    private func call(_ name: String, _ argument: String) {
        let js = "(function(){var b=window.backdrop;if(b){b.\(name)(\(argument));}else{(window.__backdropPending=window.__backdropPending||[]).push(['\(name)',\(argument)]);}})()"
        evaluateJavaScript(js) { _, error in
            if let error, Store.testing { NSLog("AnimatedBackdrop: %@", "\(error)") }
        }
    }
}
