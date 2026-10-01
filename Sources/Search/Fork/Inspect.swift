import AppKit
import Foundation
import WebKit

/// The Web Inspector is public to users (and `isInspectable` is public to
/// apps), but WebKit still has no public keyboard API for its element picker.
/// `_inspector` has been the stable bridge used by Safari-style tooling, so
/// keep this private API in one small, defensive helper and fall back plainly
/// when a future WebKit removes it.
@MainActor
enum Inspect {
    struct State {
        let available: Bool
        let visible: Bool
        let elementSelectionActive: Bool
    }

    static func element(in tab: Tab) -> State {
        guard let inspector = inspector(in: tab),
              inspector.responds(to: NSSelectorFromString("show")),
              inspector.responds(to: NSSelectorFromString("toggleElementSelection"))
        else {
            return unavailable
        }

        let wasVisible = flag("isVisible", on: inspector) ?? false
        let wasSelecting = flag("isElementSelectionActive", on: inspector) ?? false
        // A Web Inspector is a separate window; make the browser active before
        // asking WebKit to place it, just as the context menu does.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !wasVisible { inspector.perform(NSSelectorFromString("show")) }
        // Toggling is intentional: an already-visible inspector with an active
        // picker stops it; an inspector without one starts it.
        inspector.perform(NSSelectorFromString("toggleElementSelection"))
        return state(of: inspector, selectingFallback: !wasSelecting)
    }

    /// Read the inspector state without changing the picker. The bench uses
    /// this after `show()` has had a turn to create WebKit's separate window.
    static func status(in tab: Tab) -> State {
        guard let inspector = inspector(in: tab),
              inspector.responds(to: NSSelectorFromString("show")),
              inspector.responds(to: NSSelectorFromString("toggleElementSelection"))
        else {
            return unavailable
        }
        return state(of: inspector, selectingFallback: false)
    }

    private static let unavailable = State(available: false, visible: false, elementSelectionActive: false)

    private static func inspector(in tab: Tab) -> NSObject? {
        let web = tab.web
        let inspectorKey = NSSelectorFromString("_inspector")
        guard web.responds(to: inspectorKey) else { return nil }
        return web.value(forKey: "_inspector") as? NSObject
    }

    private static func state(of inspector: NSObject, selectingFallback: Bool) -> State {
        State(
            available: true,
            visible: flag("isVisible", on: inspector) ?? false,
            elementSelectionActive: flag("isElementSelectionActive", on: inspector) ?? selectingFallback
        )
    }

    private static func flag(_ name: String, on inspector: NSObject) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard inspector.responds(to: selector) else { return nil }
        // `perform` is only safe for object-returning selectors. The inspector's
        // two state getters return BOOL, so read their KVC property after the
        // responds check instead of treating a BOOL as an object pointer.
        let key = name.hasPrefix("is")
            ? name.dropFirst(2).prefix(1).lowercased() + name.dropFirst(3)
            : name
        if let result = inspector.value(forKey: key) as? Bool { return result }
        return (inspector.value(forKey: key) as? NSNumber)?.boolValue
    }
}
