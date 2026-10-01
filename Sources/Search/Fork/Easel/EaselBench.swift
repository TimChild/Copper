import AppKit
import SwiftUI
import WebKit

// `./bench easels …` for measuring a board and driving its row, beside the
// verbs in EaselTabs.swift. These can answer later, from the page or from a
// menu, so they come in here (Bench.swift sends every `easels` request).
//
//   easels scroll DX DY [STEPS] [--zoom] [--app]
//       a two-finger gesture on the board in front, as a trackpad sends it:
//       phase began, STEPS × changed (30 by default) carrying DX, DY points
//       between them, ended — continuous pixel deltas, ~8 ms apart. --zoom
//       holds ⌘ (the board zooms on ⌘/ctrl-wheel); --app sends each event
//       through NSApp.sendEvent, the way the window gets a real one, so the
//       app's own monitors (the space swipe) see it too. Answers at once.
//   easels scroll stats
//       the last gesture: how long the view took to take each event (µs),
//       how evenly they went out, and whether the space swipe touched it.
//   easels perf start | stop
//       a rAF frame-time collector in the page, and its numbers: frames,
//       p50/p95/max ms, over16 (> 17.5 ms), over33 (> 34 ms), plus wheel
//       events seen and their lag (event timestamp → handler, ms). With the
//       page's own `__easelDebug.perf`, its numbers lead and these follow.
//   easels lean
//       what the board in front was spared (EaselLean.swift), from the page.
//   easels rename ID TITLE · ask-rename ID · ask-delete ID · answer delete|cancel · sheet
//   easels rowmenu ID PATH
//       a right-click on the board's sidebar row, and a picture of the
//       window with the menu over it (a windowed run; headless has none).

extension Easels {
    static func bench(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? "list"
        let raw = (request["arg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let words = raw.split(separator: " ").map(String.init)
        func easel(_ prefix: String?) -> Easel? {
            guard let prefix = prefix?.lowercased(), !prefix.isEmpty else { return nil }
            return EaselStore.shared.all.first { $0.id.hasPrefix(prefix) }
        }
        switch op {
        case "scroll":
            answer(words.first == "stats" ? lastScroll : scroll(words, in: browser))
        case "perf":
            perf(words.first ?? "", in: browser, answer: answer)
        case "lean":
            lean(in: browser, answer: answer)
        case "rename":
            guard let board = easel(words.first), words.count > 1 else { return answer(["error": "easels rename ID TITLE"]) }
            rename(board.id, to: words.dropFirst().joined(separator: " "))
            let now = EaselStore.shared.easel(board.id)
            answer(["id": board.id, "title": now?.title ?? "", "renamedFrom": now?.renamedFrom ?? NSNull(),
                    "tabs": tabs(showing: board.id).map { ["title": $0.title, "asleep": $0.asleep] }])
        case "ask-rename":
            guard let board = easel(words.first), let tab = tabs(showing: board.id).first(where: { t in browser.tabs.contains { $0 === t } })
            else { return answer(["error": "easels ask-rename ID — a board with a tab in this row"]) }
            EaselRenaming.shared.ask(tab, in: browser)
            answer(["asked": board.id, "field": EaselRenaming.shared.rows[tab.id] != nil ? "row" : "sheet"])
        case "ask-delete":
            guard let board = easel(words.first) else { return answer(["error": "easels ask-delete ID"]) }
            EaselDelete.ask(board.id, in: browser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(EaselDelete.describe) }
        case "answer":
            let pressed = EaselDelete.answer(words.first ?? "cancel")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                answer(["pressed": pressed, "last": EaselDelete.describe["last"] ?? "", "easels": EaselStore.shared.all.count])
            }
        case "sheet":
            answer(EaselDelete.describe)
        case "rowmenu":
            rowMenu(words, in: browser, answer: answer)
        case "picture":
            // The window with whatever hangs from it — the rename field's
            // popover, the delete sheet — each drawn by its own views.
            guard let path = words.first, let window = Windows.window(of: browser) ?? Links.window else {
                return answer(["error": "easels picture PATH"])
            }
            let extras = NSApp.windows.filter { $0 !== window && $0.isVisible && ($0.sheetParent === window || $0.className.contains("Popover")) }
            guard let image = composite(window, with: extras) else { return answer(["error": "no image"]) }
            answer(["path": write(image, to: path) ? path : "", "size": [image.width, image.height], "extras": extras.map(\.className)])
        default:
            answer(bench(request, in: browser))
        }
    }

    /// The board in front, with a view that can take events.
    private static func front(_ browser: Browser) -> (Tab, PageView)? {
        guard let tab = browser.tabs.first(where: { $0.id == browser.activeID }), showing(tab) != nil,
              let web = tab.built, Input.canPost(to: web)
        else { return nil }
        return (tab, web)
    }

    // MARK: - two fingers

    fileprivate static var lastScroll: [String: Any] = ["error": "no scroll yet"]

    private static func scroll(_ words: [String], in browser: Browser) -> [String: Any] {
        let numbers = words.compactMap(Double.init)
        guard numbers.count >= 2 else { return ["error": "easels scroll DX DY [STEPS] [--zoom] [--app]"] }
        guard let (_, web) = front(browser) else { return ["error": "the tab in front is not an easel"] }
        let steps = max(1, min(2000, numbers.count > 2 ? Int(numbers[2]) : 30))
        let zoom = words.contains("--zoom"), app = words.contains("--app")
        lastScroll = ["running": true]
        WheelRun(web: web, dx: numbers[0], dy: numbers[1], steps: steps, zoom: zoom, app: app)?.start()
        return ["events": steps + 2, "ms": (steps + 2) * 8, "zoom": zoom, "app": app, "lean": web.board]
    }

    // MARK: - frames

    private static func perf(_ what: String, in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard let (_, web) = front(browser) else { return answer(["error": "the tab in front is not an easel"]) }
        guard what == "start" || what == "stop" else { return answer(["error": "easels perf start|stop"]) }
        if what == "start", !Headless.on, let window = web.window {
            // A window behind another one is not drawing — its display link
            // is stopped and rAF with it — so it comes forward, as for the
            // bench's pictures and its scripted space swipes.
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        web.evaluateJavaScript(what == "start" ? perfStart : perfStop) { value, error in
            MainActor.assumeIsolated {
                if let error { return answer(["error": error.localizedDescription]) }
                guard let text = value as? String, let data = text.data(using: .utf8),
                      var out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { return answer(["value": value.map { String(describing: $0) } ?? NSNull()]) }
                out["lean"] = web.board
                answer(out)
            }
        }
    }

    /// Every frame's distance from the last, and every wheel event's lag:
    /// the event's own timestamp (carried through WebKit) to the moment the
    /// page's first listener hears it.
    private static let perfStart = """
    (function () {
      var P = window.__copperPerf;
      if (P) { cancelAnimationFrame(P.raf); window.removeEventListener('wheel', P.onWheel, true); }
      P = window.__copperPerf = { deltas: [], last: null, raf: 0, began: performance.now(), lag: [] };
      function loop(t) { if (P.last !== null) P.deltas.push(t - P.last); P.last = t; P.raf = requestAnimationFrame(loop); }
      P.raf = requestAnimationFrame(loop);
      P.onWheel = function (e) { P.lag.push(performance.now() - e.timeStamp); };
      window.addEventListener('wheel', P.onWheel, { passive: true, capture: true });
      var d = window.__easelDebug, page = !!(d && d.perf && typeof d.perf.start === 'function');
      if (page) d.perf.start();
      return JSON.stringify({ started: true, page: page });
    })()
    """

    private static let perfStop = """
    (function () {
      var P = window.__copperPerf;
      if (!P) return JSON.stringify({ error: 'easels perf start first' });
      cancelAnimationFrame(P.raf);
      window.removeEventListener('wheel', P.onWheel, true);
      window.__copperPerf = null;
      function pick(s, p) { return s.length ? s[Math.min(s.length - 1, Math.floor(p / 100 * s.length))] : 0; }
      function r(n) { return Math.round(n * 10) / 10; }
      var s = P.deltas.slice().sort(function (a, b) { return a - b; });
      var l = P.lag.slice().sort(function (a, b) { return a - b; });
      var native = {
        frames: s.length, p50: r(pick(s, 50)), p95: r(pick(s, 95)), max: r(s[s.length - 1] || 0),
        over16: P.deltas.filter(function (d) { return d > 17.5; }).length,
        over33: P.deltas.filter(function (d) { return d > 34; }).length,
        ms: Math.round(performance.now() - P.began),
        // The event's clock and the page's differ by a constant, so lag is
        // read above the gesture's quickest event: how much later than its
        // best the board took each one (WebKit holds a wheel event back
        // while the page is still busy with the last).
        wheel: l.length, lagP50: r(pick(l, 50) - (l[0] || 0)), lagP95: r(pick(l, 95) - (l[0] || 0)),
        lagMax: r((l[l.length - 1] || 0) - (l[0] || 0))
      };
      var d = window.__easelDebug;
      if (d && d.perf && typeof d.perf.stop === 'function') {
        var page = d.perf.stop();
        page.source = 'page'; page.native = native;
        page.wheel = native.wheel; page.lagP50 = native.lagP50; page.lagP95 = native.lagP95; page.lagMax = native.lagMax;
        return JSON.stringify(page);
      }
      native.source = 'native';
      return JSON.stringify(native);
    })()
    """

    /// What the board in front carries of every page's machinery.
    private static func lean(in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard let (_, web) = front(browser) else { return answer(["error": "the tab in front is not an easel"]) }
        let scripts = web.configuration.userContentController.userScripts.count
        let js = """
        JSON.stringify({ swipe: !!window.__officeSwipe, forms: !!window.__officeForms, veil: !!window.__officeVeil,
          images: !!window.__officeImages, keys: !!window.__copperBoardKeys,
          calm: !!document.getElementById('office-calm') })
        """
        web.evaluateJavaScript(js) { value, _ in
            MainActor.assumeIsolated {
                let page = (value as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                answer(["lean": lean, "board": web.board, "magnifies": web.allowsMagnification, "userScripts": scripts,
                        "page": page ?? NSNull()])
            }
        }
    }

    // MARK: - pictures

    /// The browser window as the compositor has it, with `extras` (a popover,
    /// a sheet, a menu) each drawn by its own views where it sits on screen.
    /// WindowServer will not hand over those windows' pixels from a locked
    /// screen (nor, without the screen-recording grant, a popover's), but a
    /// window may always draw its own views.
    static func composite(_ window: NSWindow, with extras: [NSWindow]) -> CGImage? {
        guard let base = Fork.layered([CGWindowID(window.windowNumber)]) else { return nil }
        let scale = CGFloat(base.width) / max(1, window.frame.width)
        let union = extras.reduce(window.frame) { $0.union($1.frame) }
        guard let context = CGContext(data: nil, width: Int(union.width * scale), height: Int(union.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Screen points and the context both count up from the bottom left.
        func place(_ frame: NSRect) -> CGRect {
            CGRect(x: (frame.minX - union.minX) * scale, y: (frame.minY - union.minY) * scale,
                   width: frame.width * scale, height: frame.height * scale)
        }
        context.draw(base, in: place(window.frame))
        for extra in extras {
            guard let view = extra.contentView?.superview ?? extra.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let drawn = rep.cgImage { context.draw(drawn, in: place(extra.frame)) }
        }
        return context.makeImage()
    }

    @discardableResult
    static func write(_ image: CGImage, to path: String) -> Bool {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - the row's menu, pictured

    /// A right-click on the board's row, through the window as a real one
    /// comes; once the menu is up, the window and the menu are pictured
    /// together and the menu is put away.
    private static func rowMenu(_ words: [String], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        guard words.count >= 2, let board = EaselStore.shared.all.first(where: { $0.id.hasPrefix(words[0].lowercased()) }),
              let tab = browser.tabs.first(where: { showing($0) == board.id }),
              let frame = EaselRenaming.shared.rows[tab.id],
              let window = Windows.window(of: browser) ?? Links.window, let content = window.contentView
        else { return answer(["error": "easels rowmenu ID PATH — a board with a row on screen"]) }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        let shot = MenuShot(window: window, path: words[1])
        shot.out["row"] = [frame.minX, frame.minY, frame.width, frame.height]
        shot.point = CGPoint(x: frame.minX + 60, y: frame.maxY + 2) // drawn just under the row, so the row still shows
        let watch = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            let menu = note.object as? NSMenu
            MainActor.assumeIsolated { shot.began(menu) }
        }
        let point = CGPoint(x: frame.minX + 60, y: content.bounds.height - frame.midY)
        let stamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: stamp,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .rightMouseUp, location: point, modifierFlags: [], timestamp: stamp + 0.05,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        else { NotificationCenter.default.removeObserver(watch); return answer(["error": "no event"]) }
        // Returns once the menu has closed — MenuShot closes it.
        window.sendEvent(down)
        window.sendEvent(up)
        NotificationCenter.default.removeObserver(watch)
        if shot.out["items"] == nil { shot.out["error"] = "no menu came up" }
        answer(shot.out)
    }
}

/// One `easels rowmenu`: the menu, once it is tracking, pictured over its
/// window after a beat to draw, then cancelled.
@MainActor
private final class MenuShot {
    let window: NSWindow
    let path: String
    var out: [String: Any] = [:]
    private var menu: NSMenu?

    init(window: NSWindow, path: String) {
        self.window = window
        self.path = path
    }

    func began(_ menu: NSMenu?) {
        guard self.menu == nil, let menu else { return }
        self.menu = menu
        let timer = Timer(timeInterval: 0.4, repeats: false) { [self] _ in MainActor.assumeIsolated { self.picture() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func picture() {
        guard let menu else { return }
        out["items"] = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menus = info.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                && ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow))
        }.compactMap { ($0[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) } }
        out["menuWindows"] = menus.count
        var image = Fork.layered([CGWindowID(window.windowNumber)] + menus)
        if menus.isEmpty {
            // The compositor lists no menu — a locked screen shows none — so
            // the menu's window draws itself over the picture, and failing
            // that its items are drawn where it opened; the answer says which.
            let menuWindows = NSApp.windows.filter { $0.isVisible && $0.className.contains("Menu") }
            if !menuWindows.isEmpty, let drawn = Easels.composite(window, with: menuWindows) {
                image = drawn
                out["menuFrom"] = "its own window's views"
            } else if let base = image {
                image = MenuShot.drawn(menu, over: base, at: point, in: window)
                out["menuFrom"] = "its items, drawn"
            }
        }
        if let image, Easels.write(image, to: path) {
            out["path"] = path
            out["size"] = [image.width, image.height]
        }
        menu.cancelTracking()
    }

    /// Where the right-click went, in window points from the top left.
    var point = CGPoint.zero

    /// The menu's items as a macOS menu draws them, laid over the window's
    /// picture with its top-left corner at the click.
    private static func drawn(_ menu: NSMenu, over base: CGImage, at point: CGPoint, in window: NSWindow) -> CGImage? {
        let rows = menu.items.map { item in (title: item.isSeparatorItem ? "" : item.title, separator: item.isSeparatorItem) }
        let card = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if row.separator {
                    Rectangle().fill(Color.black.opacity(0.1)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
                } else {
                    HStack(spacing: 0) {
                        Text(row.title).font(.system(size: 13))
                            .foregroundStyle(row.title.hasPrefix("Delete") ? Color.red : Color.black.opacity(0.85))
                        Spacer(minLength: 24)
                        if row.title == "Group" { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: 210, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(20)
        let scale = CGFloat(base.width) / max(1, window.frame.width)
        let renderer = ImageRenderer(content: card.environment(\.colorScheme, .light))
        renderer.scale = scale
        guard let picture = renderer.cgImage,
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let whole = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: whole)
        // The card's 20 pt margin holds its shadow; its corner lands on the click.
        let x = (point.x - 20) * scale, top = (point.y - 20) * scale
        context.draw(picture, in: CGRect(x: x, y: CGFloat(base.height) - top - CGFloat(picture.height),
                                         width: CGFloat(picture.width), height: CGFloat(picture.height)))
        return context.makeImage()
    }
}

/// One `easels scroll`: the gesture, event by event, on a timer 8 ms apart.
/// CGEvent is the one public way to make a continuous, phased wheel event;
/// AppKit reads it back as a trackpad's.
///
/// NSEvent(cgEvent:) takes the event's window from field 51, the window
/// server's own (not in the public CGEventField list), and its location in
/// that window from the window-relative point a real event carries beside
/// the global one (CGEventSetWindowLocation, looked up at run time). With
/// both, the event belongs to the board's window at the board's middle, as
/// a trackpad's would — on a parked headless window too. Straight to the
/// view by default; with --app through NSApp.sendEvent, so the app's
/// monitors (the space swipe) see it first and the window routes it. Should
/// a later macOS take either away, the event is made windowless at the
/// window point instead, which the view reads the same way (`windowed` in
/// the stats says which; --app then reaches no monitor that cares).
@MainActor
private final class WheelRun {
    private let web: PageView
    private let window: NSWindow
    private let zoom: Bool
    private let app: Bool
    private var plan: [(phase: Int64, dx: Int32, dy: Int32)] = []
    private let windowPoint: CGPoint
    private let screenPoint: CGPoint
    private var took: [Double] = []
    private var sent: [Double] = []
    private var slid = false
    private var windowed = 0
    /// The last windowed event that came out somewhere else, for the stats.
    private var missed: [String: Any]?
    private let space = Spaces.shared.current
    private let left = SpaceSwipe.leftToPage
    private var timer: Timer?
    private var keep: WheelRun?

    init?(web: PageView, dx: Double, dy: Double, steps: Int, zoom: Bool, app: Bool) {
        guard let window = web.window else { return nil }
        self.web = web
        self.window = window
        self.zoom = zoom
        self.app = app
        windowPoint = web.convert(CGPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: windowPoint)
        // CGEvent's space: the main display's top left is the origin.
        let top = NSScreen.screens.first?.frame.height ?? 0
        screenPoint = CGPoint(x: onScreen.x, y: top - onScreen.y)
        // Whole points per event, the remainder carried, so the gesture
        // travels exactly DX, DY.
        plan = [(1, 0, 0)]
        var sentX = 0.0, sentY = 0.0
        for i in 1...steps {
            let x = (dx * Double(i) / Double(steps)).rounded(), y = (dy * Double(i) / Double(steps)).rounded()
            plan.append((2, Int32(x - sentX), Int32(y - sentY)))
            sentX = x
            sentY = y
        }
        plan.append((4, 0, 0))
    }

    func start() {
        keep = self
        Input.move(web, to: CGPoint(x: web.bounds.midX, y: web.bounds.midY))
        let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func event(_ step: (phase: Int64, dx: Int32, dy: Int32), at point: CGPoint) -> CGEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: step.dy, wheel2: step.dx, wheel3: 0)
        else { return nil }
        cg.location = point
        // Made now: a made event's clock starts at nought otherwise, and the
        // page's lag reading would be the time since boot.
        cg.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        cg.flags = zoom ? .maskCommand : []
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        return cg
    }

    /// The window server's window-number field (kCGSEventWindowIDField).
    private static let windowField = CGEventField(rawValue: 51)

    /// CoreGraphics' own setter for the window-relative location a real
    /// event carries beside its global one (top-left origin), which AppKit
    /// reads once the event has a window. Not public; looked up, not linked,
    /// and only ever used here.
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()

    /// The event, belonging to the board's window if AppKit will have it so.
    private func made(_ step: (phase: Int64, dx: Int32, dy: Int32)) -> NSEvent? {
        if let field = WheelRun.windowField, let cg = event(step, at: screenPoint) {
            cg.setIntegerValueField(field, value: Int64(window.windowNumber))
            WheelRun.setWindowLocation?(cg, CGPoint(x: windowPoint.x, y: window.frame.height - windowPoint.y))
            // A parked (headless) window is off every display, and an event's
            // location is kept on one: there the windowless event stands in.
            if let ev = NSEvent(cgEvent: cg) {
                if ev.window === window, abs(ev.locationInWindow.x - windowPoint.x) < 1, abs(ev.locationInWindow.y - windowPoint.y) < 1 {
                    return ev
                }
                missed = ["window": ev.window === window, "at": [ev.locationInWindow.x, ev.locationInWindow.y],
                          "wanted": [windowPoint.x, windowPoint.y]]
            }
        }
        let top = NSScreen.screens.first?.frame.height ?? 0
        return event(step, at: CGPoint(x: windowPoint.x, y: top - windowPoint.y)).flatMap { NSEvent(cgEvent: $0) }
    }

    private func tick() {
        guard !plan.isEmpty else { return finish() }
        let step = plan.removeFirst()
        let start = CACurrentMediaTime()
        sent.append(start)
        guard let ev = made(step) else { return }
        if ev.window === window { windowed += 1 }
        if app, ev.window === window { NSApp.sendEvent(ev) } else { web.scrollWheel(with: ev) }
        took.append((CACurrentMediaTime() - start) * 1_000_000)
        slid = slid || SpaceSlide.shared.moving
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.async { [self] in
            let gaps = zip(sent.dropFirst(), sent).map { ($0 - $1) * 1000 }
            Easels.lastScroll = [
                "events": sent.count, "windowed": windowed, "missed": missed ?? NSNull(), "app": app, "zoom": zoom, "lean": web.board,
                "viewMicros": WheelRun.stats(took), "gapMs": WheelRun.stats(gaps), "over12": gaps.filter { $0 > 12 }.count,
                "spaceChanged": Spaces.shared.current != space, "slid": slid || SpaceSlide.shared.moving,
                "leftToPage": SpaceSwipe.leftToPage - left,
            ]
            keep = nil
        }
    }

    static func stats(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [:] }
        func round(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        let pick = { (p: Double) in round(sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]) }
        return ["p50": pick(0.5), "p95": pick(0.95), "max": round(sorted.last ?? 0), "mean": round(sorted.reduce(0, +) / Double(sorted.count))]
    }
}
