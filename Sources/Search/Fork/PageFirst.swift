import AppKit
import WebKit

// ⌘K belongs to the page when the page wants it.
//
// The app's key monitor (App.swift `take`) runs before the first responder
// ever sees a key, and ⌘K went straight to the tab search — so in Tuesday,
// Linear, Slack, Notion, GitHub, anything with its own ⌘K palette, the
// browser's search opened over the app's and the app's never did. Safari
// gives those pages the key; so does this.
//
// Same rule as `LineKeys` (Arrows.swift): ask who has the keyboard.
//
// - A page (a PageView in front, with an address) gets the key first, once.
//   WebKit's `performKeyEquivalent` hands it to the page's `keydown`; a page
//   that calls `preventDefault()` keeps it and nothing more happens. A key
//   the page did not use comes back up through `NSApp.sendEvent` a second
//   time — the same NSEvent — and that second pass is where the app takes it,
//   so the tab search still opens on every page that has no ⌘K of its own.
//
// - Anyone else — the omnibox, a native field, a button, nobody — is the old
//   behaviour: the app takes the key on the first pass. Held-⌘K walking the
//   summon list lives there too, since the field is first responder by then.
//
// The cost is one round trip to the web process before the tab search opens
// on a page that ignores ⌘K — a few milliseconds, well under a key repeat.
@MainActor
enum PageFirst {
    /// The key last let through to a page, so its return trip is recognised.
    private static var lent: NSEvent?
    /// Keys handed to a page, and keys a page sent back unused — for the bench.
    private(set) static var offered = 0
    private(set) static var returned = 0

    /// True when the key should go through to the page now — the caller
    /// returns `false` from the monitor and waits for the return trip. False
    /// when the app should act on it: no page has the keyboard, or this is
    /// the page handing it back unused.
    static func lend(_ event: NSEvent) -> Bool {
        if let lent, PageView.same(lent, event) {
            PageFirst.lent = nil
            returned += 1
            return false
        }
        // The event's window first: the key window can be a popover or a
        // panel while the press is still meant for the page beneath it.
        let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
        guard let view = responder as? NSView, let web = LineKeys.page(of: view) else { return false }
        // A blank tab has no page to ask; the app keeps the key.
        guard web.url != nil else { return false }
        lent = event
        offered += 1
        return true
    }
}
