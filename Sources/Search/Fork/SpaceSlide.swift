import AppKit
import QuartzCore
import SwiftUI

// A space switch, the way Arc draws one: the column slides.
//
// Switching swaps `browser.tabs` wholesale (Spaces.select), and left to
// itself the column animated that as every old row leaving and every new one
// arriving — up to a few hundred transitions, each a spring, and every
// colour on the column interpolated from one space's ink to the next's,
// frame after frame for half a second. The main thread spent most of that
// half second in SwiftUI.
//
// Instead the switch is one move. The moment it is asked for, the column as
// it stands is pictured — a bitmap of what is on screen, taken before
// anything changes — and the new space's rows go in at once, with no
// animation at all. Then two layers travel together: the picture of the
// old column slides out one way and fades, and the real new column slides in
// from the other side. The lights, the address and the strip at the foot
// stay where they are; the picture's copy of them, and of the old ground,
// fades in place over the new, so the theme crossfades while the rows
// travel. After ~0.22 s the picture is dropped and nothing is left of it.
//
// Which way: towards a space after this one in `Spaces.all`, the old column
// leaves to the left; before it, to the right. Reduce Motion keeps the
// crossfade and drops the travel.

@MainActor
final class SpaceSlide: ObservableObject {
    static let shared = SpaceSlide()

    /// The old column, as it was on screen when the switch was asked for.
    /// Nil between slides — which is also how the views know one is on.
    @Published private(set) var picture: NSImage?
    /// How far along: 0 at the switch, 1 once the new column is home.
    @Published private(set) var phase: CGFloat = 1
    /// +1 when the new space is after the old one (the old column leaves to
    /// the left), -1 before it, 0 under Reduce Motion.
    @Published private(set) var way: CGFloat = 0

    /// Where the column is, and where the band that travels is, in SwiftUI's
    /// global space (the window's content, from its top left). Kept up to
    /// date by the column as it is laid out; not published, since nothing
    /// has to redraw when they change. Zero while no column is on screen.
    var column: CGRect = .zero
    var band: CGRect = .zero

    var moving: Bool { picture != nil }

    /// Arc's is about this: quick off the mark, a soft landing, and over
    /// before the eye has finished following it.
    static let duration = 0.22
    static let curve = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: duration)

    /// Which slide is the current one, so a switch that interrupts another
    /// is not ended by the first one's completion.
    private var serial = 0
    /// `bench spaces slide at X`: the next slide stops at X and stays there,
    /// for a picture of it. Nil in normal use.
    private var hold: CGFloat?

    // MARK: - the switch

    /// Called by `Spaces.select` before anything changes. True when there is
    /// a column on screen to slide — the caller then makes its change with
    /// animations off, since the slide is the only motion there is.
    func begin(forward: Bool, in browser: Browser) -> Bool {
        let started = CACurrentMediaTime()
        timed = browser.prefs.bench
        guard column.width > 1, column.height > 1, band.height > 1,
              let window = Links.window, window.isVisible,
              let shot = photograph(in: window) else { return false }
        serial += 1
        let mine = serial
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) {
            picture = shot
            phase = 0
            way = still ? 0 : (forward ? 1 : -1)
        }
        timing = Timing(asked: started, pictured: CACurrentMediaTime())
        // One turn of the run loop: it commits the frame that has the new
        // column in place under the picture (the switch's own frame, looking
        // exactly as the old one did), and the slide sets off from there.
        // A second turn, to let the column's scroll-to-live-row settle
        // first, was measured costing up to 40 ms of standing still; the
        // scroll runs without an animation during a slide, so it is already
        // where it will be.
        DispatchQueue.main.async {
            self.timing?.committed = CACurrentMediaTime()
            self.go(mine)
        }
        return true
    }

    private func go(_ mine: Int) {
        guard mine == serial, picture != nil else { return }
        timing?.moved = CACurrentMediaTime()
        watch()
        if let hold {
            var calm = Transaction()
            calm.disablesAnimations = true
            withTransaction(calm) { phase = hold }
            return
        }
        withAnimation(SpaceSlide.curve, completionCriteria: .logicallyComplete) {
            phase = 1
        } completion: { [weak self] in
            guard let self, mine == self.serial else { return }
            self.end()
        }
    }

    private func end() {
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) {
            picture = nil
            phase = 1
        }
        timing?.ended = CACurrentMediaTime()
        unwatch()
    }

    // MARK: - the picture

    /// The column's pixels, from the window's own drawing, in points at the
    /// screen's scale — what `SpaceEditing.picture` does for the Space page,
    /// cut to the column's rectangle of the live window.
    private func photograph(in window: NSWindow) -> NSImage? {
        guard let view = window.contentView else { return nil }
        // The compositor's copy first: the window's own pixels, as already
        // on screen, cut to the column — a few milliseconds, where asking
        // the views to draw themselves again (below) took thirty to sixty
        // and made the slide set off late. An app may always read its own
        // window; the drawing is only for when that comes back empty.
        if let fast = composited(view: view, in: window) { return fast }
        // SwiftUI's global space runs down from the content's top left;
        // AppKit's, unless the view is flipped, up from its bottom left.
        let rect = view.isFlipped ? column
            : NSRect(x: column.minX, y: view.bounds.height - column.maxY, width: column.width, height: column.height)
        let inside = rect.intersection(view.bounds).integral
        guard inside.width > 1, inside.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: inside) else { return nil }
        view.cacheDisplay(in: inside, to: rep)
        let image = NSImage(size: inside.size)
        image.addRepresentation(rep)
        return image
    }

    /// The column's rectangle of the window, from the window server.
    private func composited(view: NSView, in window: NSWindow) -> NSImage? {
        guard let screen = window.screen ?? NSScreen.screens.first,
              let primary = NSScreen.screens.first else { return nil }
        let local = view.isFlipped ? column
            : NSRect(x: column.minX, y: view.bounds.height - column.maxY, width: column.width, height: column.height)
        let onScreen = window.convertToScreen(view.convert(local, to: nil))
        // Quartz counts down from the top of the primary display.
        let quartz = CGRect(x: onScreen.minX, y: primary.frame.maxY - onScreen.maxY,
                            width: onScreen.width, height: onScreen.height)
        _ = screen
        guard let image = CGWindowListCreateImage(quartz, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              image.width > 8, image.height > 8 else { return nil }
        return NSImage(cgImage: image, size: column.size)
    }

    // MARK: - the bench

    /// What the last switch cost, in milliseconds from the moment it was
    /// asked for: the picture, the frame with the new column in it, the first
    /// frame that moved; and how the frames came while it moved.
    private struct Timing {
        var asked: CFTimeInterval
        var pictured: CFTimeInterval
        var committed: CFTimeInterval?
        var moved: CFTimeInterval?
        var ended: CFTimeInterval?
        var frames: [CFTimeInterval] = []
        var period: CFTimeInterval = 0
    }

    private var timing: Timing?
    private var link: CADisplayLink?
    /// Frames are only counted while a script may drive the app.
    private var timed = false

    /// A display link over the slide, while the bench is on: every frame's
    /// time, so a frame the main thread was too busy to make shows as a gap.
    private func watch() {
        guard timed, let view = Links.window?.contentView else { return }
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func unwatch() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        timing?.frames.append(link.timestamp)
        timing?.period = link.targetTimestamp - link.timestamp
    }

    /// `spaces slide` — the last switch's timings; `spaces slide at X` —
    /// the next slides stop at X (0…1) and stay, for a picture;
    /// `spaces slide off` — back to sliding, and any held slide ends.
    func bench(_ arg: String) -> [String: Any] {
        let words = arg.split(separator: " ").map(String.init)
        if words.first == "at", words.count > 1, let x = Double(words[1]) {
            hold = min(1, max(0, CGFloat(x)))
        } else if words.first == "off" {
            hold = nil
            if picture != nil { end() }
        }
        var note: [String: Any] = ["moving": moving, "hold": hold.map { Double($0) } ?? -1,
                                   "column": [Int(column.minX), Int(column.minY), Int(column.width), Int(column.height)],
                                   "band": [Int(band.minX), Int(band.minY), Int(band.width), Int(band.height)]]
        guard let t = timing else { return note }
        func ms(_ x: CFTimeInterval?) -> Double { x.map { (($0 - t.asked) * 10000).rounded() / 10 } ?? -1 }
        note["picture"] = ms(t.pictured)
        note["committed"] = ms(t.committed)
        note["moved"] = ms(t.moved)
        note["ended"] = ms(t.ended)
        let gaps = zip(t.frames.dropFirst(), t.frames).map { $0 - $1 }
        note["frames"] = t.frames.count
        note["period"] = (t.period * 10000).rounded() / 10
        note["longest"] = ((gaps.max() ?? 0) * 10000).rounded() / 10
        note["missed"] = t.period > 0 ? gaps.reduce(0) { $0 + max(0, Int(($1 / t.period).rounded()) - 1) } : 0
        return note
    }
}

// MARK: - the two layers

/// The band that travels — the favourites, the space's name and its rows —
/// as the real, live column: in from the side while a slide is on, and held
/// to its own edges while it is, so the part still on its way in never draws
/// over the page. At rest it is not clipped at all, so nothing that hangs
/// over its edge (a favourite in the hand, its shadow) is cut.
struct SpaceSlideBand: ViewModifier {
    @ObservedObject private var slide = SpaceSlide.shared

    func body(content: Content) -> some View {
        content
            .offset(x: slide.moving ? slide.way * slide.column.width * (1 - slide.phase) : 0)
            .clipShape(BandEdge(on: slide.moving))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slide.band = $0 }
    }

    /// The band's own rectangle while it moves; otherwise one so large it
    /// clips nothing. A shape rather than a `.clipped()` put on and taken off,
    /// which would make the column a different view, and rebuild it.
    private struct BandEdge: Shape {
        var on: Bool
        func path(in rect: CGRect) -> Path { Path(on ? rect : rect.insetBy(dx: -10_000, dy: -10_000)) }
    }
}

/// The old column, over the new one while a slide is on: its copy of the
/// band slides out and fades; its copy of everything else — the lights, the
/// address, the strip, and the old ground behind them — fades where it
/// stands, so the theme crossfades while the rows travel. Takes no clicks:
/// the new column under it is the real one from the first frame.
struct SpaceSlideCurtain: View {
    @ObservedObject private var slide = SpaceSlide.shared

    var body: some View {
        if let picture = slide.picture {
            let size = slide.column.size
            let top = max(0, slide.band.minY - slide.column.minY)
            let height = min(slide.band.height, size.height - top)
            ZStack(alignment: .topLeading) {
                // Everything that stays: the picture with the band cut out.
                Image(nsImage: picture)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .mask(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Rectangle().frame(height: top)
                            Color.clear.frame(height: height)
                            Rectangle()
                        }
                    }
                // The band, on its way out. Its last point is the column's
                // hairline, which stays put, so it is left behind.
                Image(nsImage: picture)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .offset(x: -slide.way * size.width * slide.phase)
                    .mask(alignment: .topLeading) {
                        Rectangle()
                            .frame(width: max(0, size.width - 1), height: height)
                            .offset(y: top)
                    }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .opacity(1 - slide.phase)
            .allowsHitTesting(false)
        }
    }
}
