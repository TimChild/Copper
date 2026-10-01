import AppKit
import SwiftUI

// Two fingers sideways over the column of tabs: the next space, or the last.
//
// The page has a sideways swipe of its own (Swipe.swift, back and forward),
// so this one lives only over the sidebar. A local monitor sees every wheel
// event before the list does; once a gesture has committed to sideways it is
// ours until the fingers lift — the list never jiggles — and up-and-down is
// left alone entirely. Three-finger swipes (when System Settings hands them
// to apps) count too.
@MainActor enum SpaceSwipe {
    /// Points of sideways travel before the space changes. Arc is about this.
    nonisolated static let threshold: CGFloat = 70

    /// One gesture, from fingers down to fingers up: which axis it committed
    /// to, how far sideways it has come, whether it has already turned the
    /// page. Pure, so the bench can drive it without a trackpad.
    struct Track {
        enum Axis { case undecided, sideways, upright }
        var axis = Axis.undecided
        var travel: CGFloat = 0
        var fired = false

        /// Feed one wheel event; back comes the space to step to (if any) and
        /// whether the event is ours to swallow.
        mutating func feed(phase: NSEvent.Phase, dx: CGFloat, dy: CGFloat) -> (step: Int, swallow: Bool) {
            switch phase {
            case .began, .mayBegin:
                self = Track()
            case .changed:
                if axis == .undecided, abs(dx) + abs(dy) > 2 {
                    axis = abs(dx) > abs(dy) ? .sideways : .upright
                }
                if axis == .sideways {
                    travel += dx
                    if !fired, abs(travel) > SpaceSwipe.threshold {
                        fired = true
                        // Natural direction: fingers moving left bring in the space to the right.
                        return (travel < 0 ? 1 : -1, true)
                    }
                }
            case .ended, .cancelled:
                let ours = axis == .sideways
                self = Track()
                return (0, ours)
            default: break
            }
            // Momentum after a sideways flick is ours too, or the list would take it.
            return (0, axis == .sideways)
        }
    }

    private static var track = Track()
    private static var monitor: Any?

    static func watch(_ browser: Browser) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { event in
            MainActor.assumeIsolated { handle(event, in: browser) }
        }
    }

    private static func handle(_ event: NSEvent, in browser: Browser) -> NSEvent? {
        guard event.window != nil, event.window == Links.window,
              overSidebar(event.locationInWindow, in: browser) else { return event }
        if event.type == .swipe {
            guard event.deltaX != 0 else { return event }
            go(event.deltaX < 0 ? 1 : -1, in: browser)
            return nil
        }
        // A wheel with no phase is a mouse wheel; those scroll.
        guard event.phase != [] || event.momentumPhase != [] else { return event }
        let (step, swallow) = track.feed(phase: event.phase, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        if step != 0 { go(step, in: browser) }
        return swallow ? nil : event
    }

    /// `bench swipe left|right|down`: a whole gesture fed through a Track, the
    /// step it produced carried out. `down` must scroll, not switch.
    static func bench(_ direction: String, in browser: Browser) -> [String: Any] {
        var track = Track()
        var stepped = 0, swallowed = 0
        let dx: CGFloat = direction == "left" ? -12 : direction == "right" ? 12 : 0
        let dy: CGFloat = direction == "down" ? 12 : 0
        _ = track.feed(phase: .began, dx: 0, dy: 0)
        for _ in 0..<8 {
            let (step, swallow) = track.feed(phase: .changed, dx: dx, dy: dy)
            if step != 0 { stepped = step; go(step, in: browser) }
            if swallow { swallowed += 1 }
        }
        _ = track.feed(phase: .ended, dx: 0, dy: 0)
        return ["step": stepped, "swallowed": swallowed, "space": Spaces.shared.space.name]
    }

    /// Switch a space with the same glide used by a two-finger swipe.
    /// Mouse buttons use this helper too, so the two ways of changing spaces
    /// cannot drift into different animations.
    static func go(_ by: Int, in browser: Browser) {
        withAnimation(Motion.glide) { Spaces.shared.step(by, in: browser) }
    }

    /// Whether a point is over the column of tabs — down the left, shown, or
    /// briefly peeking out while folded (the same test Fold.swift uses to lay
    /// it out).
    static func overSidebar(_ location: CGPoint, in browser: Browser) -> Bool {
        guard browser.prefs.sidebar, browser.active?.immersed != true,
              !browser.folded || browser.peeking else { return false }
        return location.x <= browser.prefs.sideWidth
    }
}
