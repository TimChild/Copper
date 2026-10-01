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
//
// A two-finger swipe (Swipes.swift) drives the same two layers by hand. The
// space it is heading for is not on screen, and putting it there just to
// take its picture would select its tab and wake the page, so every space's
// column is pictured as it is left (and again just after it arrives), and
// the swipe slides that picture in. It is a few seconds stale at most and
// only in flight: when the fingers let go far enough, the real switch happens
// under the curtain and the live column takes the picture's place; when not,
// the pictures spring back and are dropped. A space not yet visited this
// launch has no picture, and comes in as its bare ground until it is real.

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
    /// global space (the window's content, from its top left) — per window,
    /// since every browser window has a column (Fork: windows). Kept up to
    /// date by each column as it is laid out; not published, since nothing
    /// has to redraw when they change. Absent while no column is on screen.
    private var columns: [ObjectIdentifier: CGRect] = [:]
    private var bands: [ObjectIdentifier: CGRect] = [:]
    /// The window whose switch is sliding (or last slid). The curtain and
    /// the band move only in its column; another window's stays still.
    private(set) weak var owner: Browser?

    func place(column rect: CGRect?, in browser: Browser) { columns[ObjectIdentifier(browser)] = rect }
    func place(band rect: CGRect, in browser: Browser) { bands[ObjectIdentifier(browser)] = rect }

    /// The sliding window's column and band — the first window's between slides.
    var column: CGRect { columns[ObjectIdentifier(owner ?? Windows.main)] ?? .zero }
    var band: CGRect { bands[ObjectIdentifier(owner ?? Windows.main)] ?? .zero }

    var moving: Bool { picture != nil || dragging }
    /// Whether it is this window's column that is sliding, or under the
    /// fingers; another window's column stays still.
    func moving(in browser: Browser) -> Bool { moving && owner === browser }

    // The swipe's own state, all nil/false/zero outside one. One swipe at a
    // time, in `owner`'s window.
    /// True from the first sideways movement until the fingers let go.
    @Published private(set) var dragging = false
    /// The space the swipe is heading for, and its column as last pictured.
    @Published private(set) var arriving: Space?
    @Published private(set) var incoming: NSImage?
    /// At the first or last space there is nowhere to go: the live column is
    /// pulled this far, with resistance, and springs back.
    @Published private(set) var stretch: CGFloat = 0
    /// The column as it was when the fingers started; the curtain while the
    /// swipe is on, and the old picture of the slide if it commits.
    private var outgoing: NSImage?
    /// The last picture of every space's column, by space — per window
    /// (Fork: windows), since two windows' columns differ in height, and a
    /// picture from one stretched to the other would show. A space never
    /// shown in this window comes in as its bare ground.
    private var caches: [ObjectIdentifier: [UUID: NSImage]] = [:]

    private func cached(_ space: UUID, in browser: Browser) -> NSImage? { caches[ObjectIdentifier(browser)]?[space] }
    private func cache(_ shot: NSImage, for space: UUID, in browser: Browser) { caches[ObjectIdentifier(browser), default: [:]][space] = shot }

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
        // A slide already on in another window ends there, cleanly.
        if picture != nil, owner !== browser { end() }
        owner = browser
        guard column.width > 1, column.height > 1, band.height > 1,
              let window = Windows.window(of: browser), window.isVisible,
              let shot = photograph(in: window) else { return false }
        serial += 1
        let mine = serial
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cache(shot, for: Spaces.shared.current(in: browser), in: browser)
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) {
            dragging = false
            arriving = nil
            incoming = nil
            stretch = 0
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
            dragging = false
            arriving = nil
            incoming = nil
            stretch = 0
        }
        outgoing = nil
        timing?.ended = CACurrentMediaTime()
        unwatch()
        remember()
    }

    /// A fresh picture of the space now on screen, for the next swipe that
    /// heads for it — a moment after it arrives, once its rows have drawn.
    private func remember() {
        let mine = serial
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, mine == self.serial, !self.moving, let browser = self.owner,
                  let window = Windows.window(of: browser), window.isVisible,
                  self.column.width > 1, let shot = self.photograph(in: window) else { return }
            self.cache(shot, for: Spaces.shared.current(in: browser), in: browser)
        }
    }

    // MARK: - the swipe

    /// Fingers `travel` points sideways from where they started (negative is
    /// to the left). The first call takes the picture of the column; every
    /// call after only moves things, with no animation — the fingers are the
    /// animation. False when there is no column to drive.
    @discardableResult
    func drag(_ travel: CGFloat, in browser: Browser) -> Bool {
        let spaces = Spaces.shared
        let current = spaces.current(in: browser)
        guard let here = spaces.all.firstIndex(where: { $0.id == current }) else { return false }
        if !dragging {
            // A slide or swipe still on in another window ends there, cleanly;
            // these fingers are on this one. (Fork: windows)
            if moving, owner !== browser { end() }
            // A settle still running from the last swipe or a click is left
            // to finish; these fingers do nothing.
            guard picture == nil else { return false }
            owner = browser
            let started = CACurrentMediaTime()
            timed = browser.prefs.bench
            guard column.width > 1, column.height > 1, band.height > 1,
                  let window = Windows.window(of: browser), window.isVisible,
                  let shot = photograph(in: window) else { return false }
            serial += 1
            outgoing = shot
            cache(shot, for: current, in: browser)
            timing = Timing(asked: started, pictured: CACurrentMediaTime())
            var calm = Transaction()
            calm.disablesAnimations = true
            withTransaction(calm) { dragging = true }
            watch()
        } else if owner !== browser {
            // Fingers down on one window's column, moving over another's:
            // not this window's swipe.
            return false
        }
        let width = max(column.width, 1)
        // Fingers to the left push the column left, so the space after this
        // one comes in from the right — content follows the fingers.
        let forward = travel < 0
        let there = here + (forward ? 1 : -1)
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) {
            if travel != 0, spaces.all.indices.contains(there) {
                let space = spaces.all[there]
                if arriving?.id != space.id {
                    arriving = space
                    incoming = cached(space.id, in: browser)
                }
                picture = outgoing
                way = forward ? 1 : -1
                phase = min(1, abs(travel) / width)
                stretch = 0
            } else {
                // Nowhere to go this way: no pictures, only the live column
                // pulled against a spring that gets stiffer the further it goes.
                picture = nil
                arriving = nil
                incoming = nil
                phase = 1
                stretch = SpaceSlide.rubber(travel, over: width)
            }
        }
        return true
    }

    /// Resistance at the ends, as a scroll view has it: about a third of
    /// the fingers' travel at first, never more than a quarter column.
    nonisolated static func rubber(_ x: CGFloat, over width: CGFloat) -> CGFloat {
        let limit = width * 0.25
        let pulled = limit * (1 - 1 / (abs(x) * 0.33 / limit + 1))
        return x < 0 ? -pulled : pulled
    }

    /// How far, and how fast, the fingers must have gone for a release to
    /// carry on to the next space rather than spring back.
    static let commitAt: CGFloat = 0.38
    static let flick: CGFloat = 350 // points a second

    /// Fingers up (or the gesture cancelled): carry on, or go back. `velocity`
    /// is the fingers' in points a second, signed like `travel`. The rest of
    /// the way is a spring that sets off at the fingers' speed, so there is
    /// no jolt at the hand-over. On a commit the real switch happens first,
    /// under the curtain — the picture of the old column is still up and the
    /// live column, now the new space's, takes the incoming picture's place
    /// in the same frame.
    func release(velocity: CGFloat, cancelled: Bool, in browser: Browser) {
        guard dragging, owner === browser else { return }
        let mine = serial
        let width = max(column.width, 1)
        guard picture != nil, let arriving else {
            // The stretch at an end, home again.
            withAnimation(SpaceSlide.spring(from: stretch, to: 0, speed: velocity), completionCriteria: .logicallyComplete) {
                stretch = 0
            } completion: { [weak self] in
                guard let self, mine == self.serial else { return }
                self.end()
            }
            return
        }
        // In phase per second: positive is on towards `arriving`.
        let speed = -velocity * way / width
        let fast = SpaceSlide.flick / width
        let commit = !cancelled && (speed > fast || (speed > -fast && phase > SpaceSlide.commitAt))
        timing?.committed = CACurrentMediaTime()
        if commit {
            var calm = Transaction()
            calm.disablesAnimations = true
            withTransaction(calm) {
                dragging = false
                self.arriving = nil
                incoming = nil
                Spaces.shared.select(arriving.id, in: browser, pictured: true)
            }
            // As for a click: one turn of the run loop commits the frame with
            // the live column where the picture of it was, and the settle
            // sets off from there. In the same turn SwiftUI would see the
            // band go from hidden-at-rest straight to home and not move it.
            DispatchQueue.main.async { self.settle(to: 1, speed: speed, mine) }
        } else {
            settle(to: 0, speed: speed, mine)
        }
    }

    private func settle(to goal: CGFloat, speed: CGFloat, _ mine: Int) {
        guard mine == serial, picture != nil else { return }
        timing?.moved = CACurrentMediaTime()
        withAnimation(SpaceSlide.spring(from: phase, to: goal, speed: speed), completionCriteria: .logicallyComplete) {
            phase = goal
        } completion: { [weak self] in
            guard let self, mine == self.serial else { return }
            self.end()
        }
    }

    /// A spring with no bounce whose first instant moves at `speed` (units
    /// of the value a second). SwiftUI wants that as a fraction of the
    /// distance still to go.
    static func spring(from: CGFloat, to: CGFloat, speed: CGFloat) -> Animation {
        let distance = to - from
        let relative = abs(distance) > 0.001 ? speed / distance : 0
        return .interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: Double(min(12, max(0, relative))))
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

    /// The column's rectangle of the window, from the window server: the
    /// whole window's own pixels, cut to the column. Asking the server for a
    /// rectangle of the screen instead came back shifted by the window's
    /// framing (about 12 × 8 points) whenever the window was not frontmost.
    private func composited(view: NSView, in window: NSWindow) -> NSImage? {
        let local = view.isFlipped ? column
            : NSRect(x: column.minX, y: view.bounds.height - column.maxY, width: column.width, height: column.height)
        let inWindow = view.convert(local, to: nil)
        guard let whole = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              whole.width > 8, window.frame.width > 1 else { return nil }
        let scale = CGFloat(whole.width) / window.frame.width
        // The window's picture runs down from its top left.
        let cut = CGRect(x: inWindow.minX * scale, y: (window.frame.height - inWindow.maxY) * scale,
                         width: inWindow.width * scale, height: inWindow.height * scale).integral
        guard let image = whole.cropping(to: cut), image.width > 8, image.height > 8 else { return nil }
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
        guard timed, let view = (owner.flatMap(Windows.window(of:)) ?? Links.window)?.contentView else { return }
        link?.invalidate()
        // The view's link stops while its window is covered; then the swipe
        // bench's event pacing (`spaces swipe stats`) is the measure instead.
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
        } else if words.first == "dump", words.count > 1 {
            // The pictures the swipe has for the sliding (or first) window,
            // as PNGs, to see what it slides.
            let dir = words[1]
            for (id, image) in caches[ObjectIdentifier(owner ?? Windows.main)] ?? [:] {
                let name = Spaces.shared.all.first { $0.id == id }?.name ?? id.uuidString
                if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/cache-\(name).png"))
                }
            }
        } else if words.first == "off" {
            hold = nil
            if picture != nil { end() }
        }
        let browser = owner ?? Windows.main
        var note: [String: Any] = ["moving": moving, "hold": hold.map { Double($0) } ?? -1,
                                   "dragging": dragging, "phase": (Double(phase) * 1000).rounded() / 1000,
                                   "way": Double(way), "stretch": (Double(stretch) * 10).rounded() / 10,
                                   "arriving": arriving?.name ?? "", "incoming": incoming != nil,
                                   "cached": (caches[ObjectIdentifier(browser)] ?? [:]).keys.compactMap { id in Spaces.shared.all.first { $0.id == id }?.name },
                                   "space": Spaces.shared.space(in: browser).name,
                                   "owner": Windows.all.firstIndex { $0 === browser } ?? -1,
                                   "window": Windows.window(of: browser).map { w in [Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height),
                                                                                   w.occlusionState.contains(.visible) ? 1 : 0] } ?? [],
                                   "screens": NSScreen.screens.map { [Int($0.frame.minX), Int($0.frame.minY), Int($0.frame.width), Int($0.frame.height)] },
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
    let browser: Browser
    @ObservedObject private var slide = SpaceSlide.shared

    init(browser: Browser) { self.browser = browser }

    func body(content: Content) -> some View {
        // Only the sliding window's column moves; another window's stays put.
        let mine = slide.owner === browser
        let moving = slide.moving(in: browser)
        content
            .offset(x: !mine ? 0 : slide.dragging ? slide.stretch
                : slide.picture != nil ? slide.way * slide.column.width * (1 - slide.phase) : 0)
            // While a swipe is pictured, the curtain draws both columns and
            // this one, still the old space's, only has to keep out of sight.
            .opacity(mine && slide.dragging && slide.picture != nil ? 0 : 1)
            .clipShape(BandEdge(on: moving))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slide.place(band: $0, in: browser) }
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
    let browser: Browser
    @ObservedObject private var slide = SpaceSlide.shared
    @Environment(\.colorScheme) private var scheme

    init(browser: Browser) { self.browser = browser }

    var body: some View {
        if let picture = slide.picture, slide.owner === browser {
            let size = slide.column.size
            let top = max(0, slide.band.minY - slide.column.minY)
            let height = min(slide.band.height, size.height - top)
            ZStack(alignment: .topLeading) {
                if slide.dragging { arriving(size: size, top: top, height: height, fallback: picture) }
                outgoing(picture, size: size, top: top, height: height)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// While a swipe is on, what a slide has as its live new column: the
    /// arriving space's ground, its picture's lights and strip in place, its
    /// band coming in from the side. With no picture of it yet, the old
    /// column's lights and strip stand in and the band is bare ground.
    @ViewBuilder
    private func arriving(size: CGSize, top: CGFloat, height: CGFloat, fallback: NSImage) -> some View {
        if let space = slide.arriving {
            SpaceTint(space: space, dark: scheme == .dark).backdrop
                .frame(width: size.width, height: size.height)
        }
        Image(nsImage: slide.incoming ?? fallback)
            .resizable()
            .frame(width: size.width, height: size.height)
            .mask(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Rectangle().frame(height: top)
                    Color.clear.frame(height: height)
                    Rectangle()
                }
            }
        if let incoming = slide.incoming {
            Image(nsImage: incoming)
                .resizable()
                .frame(width: size.width, height: size.height)
                .offset(x: slide.way * size.width * (1 - slide.phase))
                .mask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: max(0, size.width - 1), height: height)
                        .offset(y: top)
                }
        }
    }

    private func outgoing(_ picture: NSImage, size: CGSize, top: CGFloat, height: CGFloat) -> some View {
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
    }
}
