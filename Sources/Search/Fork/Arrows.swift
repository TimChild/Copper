import AppKit
import WebKit

// ⌘← and ⌘→: the start and end of the line while the caret is in text, and
// back and forward the rest of the time. Safari's rule.
//
// The app's key monitor (App.swift `take`) runs before the first responder
// ever sees a key, and it used to send these two straight to back/forward
// regardless — so ⌘← in a Google search box, in the omnibox, or in the
// agent's composer left the page instead of moving the caret.
//
// The fix asks who has the keyboard rather than guessing what they want:
//
// - A native field — the omnibox, a rename popover, the agent's composer, the
//   find bar — puts an NSTextView (the field editor) in front. The key goes
//   through untouched and the field moves its own caret.
//
// - A page puts its PageView in front. WebKit already knows this rule: with
//   an editable focused it runs `moveToLeftEndOfLine:`, and with nothing
//   editable it runs the back-forward list itself, iframes and all
//   (WebPage::performNonEditingBehaviorForSelector, the same code Safari
//   uses). So the key goes through the first time. A key the page could do
//   nothing with — no editable, and nowhere to go back to — comes back up
//   through `NSApp.sendEvent` a second time (see PageView.keyDown), and that
//   second pass is where the app takes it: a quiet no-op instead of the beep.
//
// - Anyone else — the column, a button, nobody — gets the old behaviour: the
//   app navigates the active tab.
@MainActor
enum LineKeys {
    /// The key last let through to a page, so its return trip is recognised.
    private static var lent: NSEvent?
    /// How many came back from a page with nothing done and were kept quiet.
    private(set) static var quieted = 0

    static let left: UInt16 = 123
    static let right: UInt16 = 124

    /// Whether this is ⌘← or ⌘→ (with or without ⇧, and nothing else).
    static func isLineKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == left || event.keyCode == right else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) && !flags.contains(.option) && !flags.contains(.control)
    }

    /// True when the app took the key; false to let it reach the responder.
    static func take(_ event: NSEvent, in browser: Browser) -> Bool {
        let back = event.keyCode == left
        let shifted = event.modifierFlags.contains(.shift)

        // WebKit handing back a key the page had no use for. Swallow it —
        // there is nothing left to do, and the alternative is the beep.
        if let lent, PageView.same(lent, event) {
            LineKeys.lent = nil
            quieted += 1
            return true
        }

        let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
        // A native field editor. The caret is theirs.
        if responder is NSTextView { return false }
        // A page. WebKit's line-or-history rule, then the return trip above.
        if let view = responder as? NSView, page(of: view) != nil {
            lent = event
            return false
        }
        // No text anywhere near the keyboard: the app navigates. ⇧ variants
        // are selection keys and have nothing to select here; let them by.
        guard !shifted else { return false }
        back ? browser.back() : browser.forward()
        return true
    }

    /// The page view a responder belongs to, if it is in one.
    static func page(of view: NSView) -> WKWebView? {
        var walk: NSView? = view
        while let here = walk {
            if let web = here as? WKWebView { return web }
            walk = here.superview
        }
        return nil
    }
}
