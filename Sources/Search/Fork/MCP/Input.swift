import AppKit
import WebKit

// Real input. A click made here is an NSEvent delivered to the web view
// the way the window would deliver one, so the page sees a trusted event
// with the same hit-testing, focus and default actions a finger would get —
// which is what separates "the agent clicked" from "a script called
// element.click()", and what makes menus, editors and canvas apps work.
//
// Points arrive in the web view's coordinate space, CSS pixels from the
// top-left of the viewport (the snapshot and screenshots are both taken at
// 1× so they agree). AppKit wants window points with y up; the maths is here
// and nowhere else.

enum Input {
    /// A view can only take events while it has a window.
    @MainActor static func canPost(to web: WKWebView) -> Bool {
        web.window != nil && !web.isHiddenOrHasHiddenAncestor && web.bounds.width > 0
    }

    /// The web view takes first responder in its own window, and that is
    /// all: an agent never brings a window forward, never takes key from
    /// the window you are typing in, never activates the app. Events sent to
    /// a view in a window that is not key still land — that is how agents
    /// drove Copper from a terminal in front of it all along. A backstage
    /// window (Backstage.swift) says it is key, so its page counts as focused.
    /// Only when Copper is in front with no key window at all does the
    /// window take key, the way a click would give it.
    @MainActor private static func focus(_ web: WKWebView, in window: NSWindow) {
        if !(window is Backstage.Window), NSApp.isActive, NSApp.keyWindow == nil, window.isVisible, window.canBecomeKey {
            window.makeKey()
        }
        if window.firstResponder !== web { window.makeFirstResponder(web) }
    }

    @MainActor private static func windowPoint(_ web: WKWebView, _ point: CGPoint) -> CGPoint {
        // Points come in with the page's origin, top-left. WKWebView is a
        // flipped view, so that is its own space too; should a build say
        // otherwise, the y is turned here and nowhere else. convert(_:to: nil)
        // then puts it in the window.
        let local = web.isFlipped ? point : CGPoint(x: point.x, y: web.bounds.height - point.y)
        return web.convert(local, to: nil)
    }

    static func modifiers(from names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "alt", "option": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            case "meta", "cmd", "command", "controlormeta": flags.insert(.command)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        return flags
    }

    // MARK: - mouse

    @MainActor
    static func move(_ web: WKWebView, to point: CGPoint) {
        guard let window = web.window else { return }
        let at = windowPoint(web, point)
        if let e = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            web.mouseMoved(with: e)
        }
    }

    @MainActor
    static func click(_ web: WKWebView, at point: CGPoint, button: String, count: Int, modifiers: NSEvent.ModifierFlags) {
        guard let window = web.window else { return }
        // Focus follows the click, as it would for a person: the window
        // takes key, the web view takes first responder, and only then does
        // the page hear about the mouse.
        focus(web, in: window)
        let at = windowPoint(web, point)
        let (down, up, num): (NSEvent.EventType, NSEvent.EventType, Int) = {
            switch button {
            case "right": return (.rightMouseDown, .rightMouseUp, 1)
            case "middle": return (.otherMouseDown, .otherMouseUp, 2)
            default: return (.leftMouseDown, .leftMouseUp, 0)
            }
        }()
        move(web, to: point)
        for i in 1...max(1, count) {
            let stamp = ProcessInfo.processInfo.systemUptime
            guard let press = NSEvent.mouseEvent(with: down, location: at, modifierFlags: modifiers, timestamp: stamp, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: i, pressure: 1),
                  let release = NSEvent.mouseEvent(with: up, location: at, modifierFlags: modifiers, timestamp: stamp + 0.02, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: i, pressure: 0)
            else { return }
            switch num {
            case 1: web.rightMouseDown(with: press); web.rightMouseUp(with: release)
            case 2: web.otherMouseDown(with: press); web.otherMouseUp(with: release)
            default: web.mouseDown(with: press); web.mouseUp(with: release)
            }
        }
    }

    @MainActor
    static func drag(_ web: WKWebView, from: CGPoint, to: CGPoint) {
        guard let window = web.window else { return }
        if window.firstResponder !== web { window.makeFirstResponder(web) }
        let start = windowPoint(web, from)
        let end = windowPoint(web, to)
        let stamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: stamp, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        web.mouseDown(with: down)
        // A few steps along the way, so drag thresholds and hover targets fire.
        for step in 1...8 {
            let t = CGFloat(step) / 8
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let e = NSEvent.mouseEvent(with: .leftMouseDragged, location: p, modifierFlags: [], timestamp: stamp + Double(step) * 0.01,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                web.mouseDragged(with: e)
            }
        }
        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [], timestamp: stamp + 0.1, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            web.mouseUp(with: up)
        }
    }

    // MARK: - keys

    /// Playwright's key names, to the Mac's virtual key codes. Letters and
    /// digits ride on Bench's US map; the rest are here.
    static let special: [String: (code: UInt16, text: String)] = [
        "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "backspace": (51, "\u{8}"), "delete": (117, "\u{7F}"),
        "escape": (53, "\u{1B}"), "esc": (53, "\u{1B}"),
        "arrowleft": (123, "\u{F702}"), "arrowright": (124, "\u{F703}"), "arrowdown": (125, "\u{F701}"), "arrowup": (126, "\u{F700}"),
        "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"),
        "f1": (122, "\u{F704}"), "f2": (120, "\u{F705}"), "f3": (99, "\u{F706}"), "f4": (118, "\u{F707}"), "f5": (96, "\u{F708}"),
        "f6": (97, "\u{F709}"), "f7": (98, "\u{F70A}"), "f8": (100, "\u{F70B}"), "f9": (101, "\u{F70C}"), "f10": (109, "\u{F70D}"),
        "f11": (103, "\u{F70E}"), "f12": (111, "\u{F70F}"),
    ]

    /// One key, named the way Playwright names them — `Enter`, `ArrowDown`,
    /// `a`, `Shift+Tab`, `Meta+a`.
    @MainActor
    static func key(_ web: WKWebView, _ named: String, modifiers: NSEvent.ModifierFlags) {
        var flags = modifiers
        var name = named
        // "Control+Shift+K" style: the last part is the key.
        if name.contains("+"), name.count > 1 {
            var parts = name.split(separator: "+").map(String.init)
            name = parts.removeLast()
            flags.formUnion(Input.modifiers(from: parts))
        }
        let lower = name.lowercased()
        if let s = special[lower] {
            press(web, code: s.code, text: s.text, flags: flags)
            return
        }
        guard let scalar = name.unicodeScalars.first, name.count == 1 else {
            // Not a key we know by name: type it as text.
            type(web, name)
            return
        }
        let ch = Character(scalar)
        var text = String(ch)
        if ch.isUppercase { flags.insert(.shift) }
        if flags.contains(.shift) { text = text.uppercased() }
        let code = Bench.keyCode(for: ch)
        press(web, code: code, text: text, flags: flags)
    }

    /// Text, a character at a time, each a real key press: what a field
    /// with its own keystroke handling needs.
    @MainActor
    static func type(_ web: WKWebView, _ text: String) {
        for ch in text {
            if ch == "\n" || ch == "\r" { press(web, code: 36, text: "\r", flags: []); continue }
            let code = Bench.keyCode(for: ch)
            press(web, code: code, text: String(ch), flags: ch.isUppercase ? [.shift] : [])
        }
    }

    @MainActor
    private static func press(_ web: WKWebView, code: UInt16, text: String, flags: NSEvent.ModifierFlags) {
        guard let window = web.window else { return }
        focus(web, in: window)
        // Command shortcuts are the window's (⌘L, ⌘W…) before they are the
        // page's; those go through performKeyEquivalent as they would from
        // the keyboard, everything else straight to the view.
        let plain = flags.contains(.command) ? unmodified(text) : text
        let stamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: stamp, windowNumber: window.windowNumber,
                                          context: nil, characters: text, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code),
              let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: stamp + 0.02, windowNumber: window.windowNumber,
                                        context: nil, characters: text, charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code)
        else { return }
        if flags.contains(.command), window.performKeyEquivalent(with: down) { return }
        web.keyDown(with: down)
        web.keyUp(with: up)
    }

    private static func unmodified(_ text: String) -> String { text.lowercased() }
}
