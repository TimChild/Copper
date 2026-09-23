import SwiftUI

/// How far a view hangs off the top and bottom of the window it is in.
///
/// It should always be nothing, and in a window with a handful of tabs it is.
/// But `Side.swift`'s column is a plain VStack with no scroll view in it, so
/// with a real session — Collin's is around 250 tabs — the sidebar's natural
/// height is well over a thousand points. The row of views it sits in takes
/// the tallest child's height, SwiftUI hands the window's host view that
/// height, and AppKit centres the whole thing: the sidebar loses its first
/// rows off the top, and the page column beside it starts a couple of hundred
/// points above the window's own top edge.
///
/// That is invisible while the page area is one web view bled to every edge,
/// which is what it was. It is not invisible once the page area has a margin
/// and each pane carries a toolbar: both were being drawn off-screen above the
/// title bar, and the split looked exactly like the full-bleed one it
/// replaced.
///
/// The column being over-tall is the sidebar's to fix (a scroll view, which is
/// that piece's business, not this one's). Until it does, the split measures
/// what it actually got and lays its cards out inside the part of it a person
/// can see. When the sidebar is fixed both numbers become zero and this stops
/// doing anything at all.
struct PaneSpill: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static let none = PaneSpill()

    /// A view that measures where it lands in the window and says so. Put it
    /// behind the thing whose spill you want — it takes that thing's frame.
    static func probe(_ report: @escaping (PaneSpill) -> Void) -> some View {
        Probe(report: report)
    }

    private struct Probe: NSViewRepresentable {
        let report: (PaneSpill) -> Void

        func makeNSView(context: Context) -> Ruler { Ruler() }

        func updateNSView(_ view: Ruler, context: Context) {
            view.report = report
            view.measure()
        }
    }

    /// An empty view whose only job is to know where it is.
    final class Ruler: NSView {
        var report: ((PaneSpill) -> Void)?
        /// Only ever say something that isn't what was said last time —
        /// reporting from `layout()` sets state, which causes a layout.
        private var said = PaneSpill.none

        override func layout() {
            super.layout()
            measure()
        }

        func measure() {
            guard let window else { return }
            // The window's own base coordinates, not the content view's: the
            // content view is inset by the title bar, and the edges we are
            // trying not to fall off — the ones a screenshot has — are the
            // window's. AppKit counts up from the bottom, so the window is
            // 0 ..< height and anything outside that is off an edge.
            let mine = convert(bounds, to: nil)
            let spill = PaneSpill(
                top: max(0, mine.maxY - window.frame.height),
                bottom: max(0, -mine.minY)
            )
            guard spill != said else { return }
            said = spill
            // Not during this layout pass: setting SwiftUI state from inside
            // one is how you get a loop the runtime complains about.
            DispatchQueue.main.async { [report] in report?(spill) }
        }
    }
}
