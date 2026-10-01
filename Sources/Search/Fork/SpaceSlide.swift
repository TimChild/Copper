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
//
// An animated space's scene is not pictured into the ground the swipe
// draws: the column's one live scene (AnimatedBackdrop) stays under the
// curtain, mixing towards the arriving space as the fingers go, and only
// the band's picture travels over it. That picture still holds the frame
// of the scene it was taken on, so on a commit it does not vanish when the
// live column takes its place but fades out over it as the band settles —
// the frozen frame gives way to the moving one instead of jumping to it.

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

    /// The two spaces a slide or swipe is between: the ground (SpaceGround)
    /// blends `from`'s look towards `to`'s by `phase`. Nil at rest; during a
    /// swipe `to` is nil at the ends, where there is nowhere to go.
    @Published private(set) var from: Space?
    @Published private(set) var to: Space?

    /// The ground's own view, so a picture of the column can be taken with
    /// it hidden (see `photograph`). Set by the host as it is made.
    weak var ground: SpaceGroundHost.Matte?

    var moving: Bool { picture != nil || dragging }

    // The swipe's own state, all nil/false/zero outside one.
    /// True from the first sideways movement until the fingers let go.
    @Published private(set) var dragging = false
    /// The space the swipe is heading for, and its column as last pictured.
    @Published private(set) var arriving: Space?
    @Published private(set) var incoming: NSImage?
    /// At the first or last space there is nowhere to go: the live column is
    /// pulled this far, with resistance, and springs back.
    @Published private(set) var stretch: CGFloat = 0
    /// After a swipe commits, while the band settles: the incoming picture
    /// stays over the live band and fades out, from the phase the fingers
    /// let go at (`landed`) to home.
    @Published private(set) var landing = false
    private(set) var landed: CGFloat = 0
    /// The column as it was when the fingers started; the curtain while the
    /// swipe is on, and the old picture of the slide if it commits.
    private var outgoing: NSImage?
    /// The last picture of every space's column, by space.
    private var cache: [UUID: NSImage] = [:]

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
    func begin(forward: Bool, to space: Space, in browser: Browser) -> Bool {
        let started = CACurrentMediaTime()
        timed = browser.prefs.bench
        guard column.width > 1, column.height > 1, band.height > 1,
              let window = Links.window, window.isVisible,
              let shot = photograph(in: window) else { return false }
        serial += 1
        let mine = serial
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cache[Spaces.shared.current] = shot
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) {
            from = Spaces.shared.space
            to = space
            dragging = false
            arriving = nil
            incoming = nil
            landing = false
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
            landing = false
            stretch = 0
            from = nil
            to = nil
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
            guard let self, mine == self.serial, !self.moving,
                  let window = Links.window, window.isVisible,
                  self.column.width > 1, let shot = self.photograph(in: window) else { return }
            self.cache[Spaces.shared.current] = shot
        }
    }

    // MARK: - the swipe

    /// The column `travel` points sideways from where it started (negative is
    /// to the left) — the fingers' travel, turned round if the swipe
    /// direction setting says so. The first call takes the picture of the column; every
    /// call after only moves things, with no animation — the fingers are the
    /// animation. False when there is no column to drive.
    @discardableResult
    func drag(_ travel: CGFloat, in browser: Browser) -> Bool {
        let spaces = Spaces.shared
        guard browser.primary, let here = spaces.all.firstIndex(where: { $0.id == spaces.current }) else { return false }
        if !dragging {
            // A settle still running from the last swipe or a click is left
            // to finish; these fingers do nothing.
            guard picture == nil else { return false }
            let started = CACurrentMediaTime()
            timed = browser.prefs.bench
            guard column.width > 1, column.height > 1, band.height > 1,
                  let window = Links.window, window.isVisible,
                  let shot = photograph(in: window) else { return false }
            serial += 1
            outgoing = shot
            cache[spaces.current] = shot
            timing = Timing(asked: started, pictured: CACurrentMediaTime())
            var calm = Transaction()
            calm.disablesAnimations = true
            withTransaction(calm) {
                dragging = true
                from = spaces.space
            }
            watch()
        }
        let width = max(column.width, 1)
        // Travel to the left pushes the column left, so the space after this
        // one comes in from the right. `travel` is already the column's way,
        // not the fingers' — Swipes.swift turns it round for Inverted.
        let forward = travel < 0
        let there = here + (forward ? 1 : -1)
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) {
            if travel != 0, spaces.all.indices.contains(there) {
                let space = spaces.all[there]
                if arriving?.id != space.id {
                    arriving = space
                    incoming = cache[space.id]
                }
                to = space
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
                to = nil
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
        guard dragging else { return }
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
                landed = phase
                landing = incoming != nil
                if !landing { incoming = nil }
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

    /// The column's pixels with the ground left out: the rows, the
    /// favourites, the lights, the address and the strip, on clear, so a
    /// picture that travels brings its rows and nothing behind them. The
    /// window's own composited pixels would be a few milliseconds cheaper,
    /// but they have the ground in them, and a ground that travels with the
    /// rows is exactly the seam this is here to remove.
    ///
    /// The views are asked to draw themselves twice into bitmaps, with the
    /// ground's view (SpaceGroundHost) showing a flat black and then a flat
    /// white in place of the ground — all inside one call, so no frame
    /// reaches the screen without the real ground. Over black a pixel is
    /// its own premultiplied colour; the lift it gets over white is what
    /// shows through, one minus its coverage. Cost is reported by `spaces
    /// slide` as `picture`.
    private func photograph(in window: NSWindow) -> NSImage? {
        guard let view = window.contentView, let ground else { return nil }
        // SwiftUI's global space runs down from the content's top left;
        // AppKit's, unless the view is flipped, up from its bottom left.
        let rect = view.isFlipped ? column
            : NSRect(x: column.minX, y: view.bounds.height - column.maxY, width: column.width, height: column.height)
        let inside = rect.intersection(view.bounds).integral
        let scale = window.backingScaleFactor
        let wide = Int(inside.width * scale), high = Int(inside.height * scale)
        func bitmap() -> NSBitmapImageRep? {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = inside.size
            return rep
        }
        guard wide > 1, high > 1, let dark = bitmap(), let light = bitmap() else { return nil }
        let wasHidden = ground.inner.isHidden
        BackdropScene.capturing = true
        ground.inner.isHidden = true
        ground.fill = .black
        view.cacheDisplay(in: inside, to: dark)
        ground.fill = .white
        view.cacheDisplay(in: inside, to: light)
        ground.fill = nil
        ground.inner.isHidden = wasHidden
        BackdropScene.capturing = false
        SpaceSlide.matte(dark, against: light)
        let image = NSImage(size: inside.size)
        image.addRepresentation(dark)
        return image
    }

    /// `dark` was drawn over black and `light` over white; afterwards `dark`
    /// is the same drawing on clear. Over black a pixel's bytes are its
    /// colour times its coverage already (premultiplied, which is the
    /// bitmap's format); over white it is lifted by the rest, so the lift
    /// is one minus the coverage. The largest lift of the three channels
    /// is taken, and the colour held at or under the coverage so the pixel
    /// stays a valid premultiplied one.
    nonisolated private static func matte(_ dark: NSBitmapImageRep, against light: NSBitmapImageRep) {
        guard let a = dark.bitmapData, let b = light.bitmapData,
              dark.bytesPerRow == light.bytesPerRow, dark.pixelsHigh == light.pixelsHigh,
              dark.samplesPerPixel == 4, light.samplesPerPixel == 4 else { return }
        let row = dark.bytesPerRow
        for y in 0..<dark.pixelsHigh {
            var p = a + y * row
            var q = b + y * row
            for _ in 0..<dark.pixelsWide {
                let lift = max(Int(q[0]) - Int(p[0]), Int(q[1]) - Int(p[1]), Int(q[2]) - Int(p[2]))
                let alpha = UInt8(clamping: 255 - max(0, lift))
                p[0] = min(p[0], alpha)
                p[1] = min(p[1], alpha)
                p[2] = min(p[2], alpha)
                p[3] = alpha
                p += 4
                q += 4
            }
        }
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
            // The pictures the swipe has, as PNGs, to see what it slides.
            let dir = words[1]
            for (id, image) in cache {
                let name = Spaces.shared.all.first { $0.id == id }?.name ?? id.uuidString
                if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/cache-\(name).png"))
                }
            }
        } else if words.first == "off" {
            hold = nil
            if picture != nil { end() }
        }
        var note: [String: Any] = ["moving": moving, "hold": hold.map { Double($0) } ?? -1,
                                   "dragging": dragging, "phase": (Double(phase) * 1000).rounded() / 1000,
                                   "way": Double(way), "stretch": (Double(stretch) * 10).rounded() / 10,
                                   "arriving": arriving?.name ?? "", "incoming": incoming != nil, "landing": landing,
                                   "cached": cache.keys.compactMap { id in Spaces.shared.all.first { $0.id == id }?.name },
                                   "space": Spaces.shared.space.name,
                                   "window": Links.window.map { w in [Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height),
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

// MARK: - the layers

// Three layers, on one ground. The ground (SpaceGround, drawn behind the
// column) is live and never pictured: it blends the outgoing theme towards
// the incoming one by `phase`. Over it travel the bands — pictures of the
// rows with nothing behind them, so they carry their own space's ink and
// nothing else — and over everything the lights, the address and the strip
// stay put while their old content fades out and their new fades in. No
// picture holds a ground, so there is no edge where one ground meets
// another and nothing to ghost.

/// The band that travels — the favourites, the space's name and its rows —
/// as the real, live column: in from the side while a slide is on, and held
/// to its own edges while it is, so the part still on its way in never draws
/// over the page. At rest it is not clipped at all, so nothing that hangs
/// over its edge (a favourite in the hand, its shadow) is cut.
struct SpaceSlideBand: ViewModifier {
    @ObservedObject private var slide = SpaceSlide.shared

    func body(content: Content) -> some View {
        content
            .offset(x: slide.dragging ? slide.stretch
                : slide.picture != nil ? slide.way * slide.column.width * (1 - slide.phase) : 0)
            .opacity(opacity)
            .clipShape(BandEdge(on: slide.moving))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slide.band = $0 }
    }

    /// While a swipe is pictured the curtain draws both bands and this one,
    /// still the old space's, keeps out of sight. After a commit the live
    /// band — now the new space's — comes up under the incoming picture as
    /// that fades, so the hand-over from a slightly stale picture to the
    /// real rows is a crossfade rather than a cut.
    private var opacity: Double {
        if slide.dragging, slide.picture != nil { return 0 }
        if slide.landing, slide.picture != nil { return 1 - slide.fade }
        return 1
    }

    /// The band's own rectangle while it moves; otherwise one so large it
    /// clips nothing. A shape rather than a `.clipped()` put on and taken off,
    /// which would make the column a different view, and rebuild it.
    private struct BandEdge: Shape {
        var on: Bool
        func path(in rect: CGRect) -> Path { Path(on ? rect : rect.insetBy(dx: -10_000, dy: -10_000)) }
    }
}

/// The parts of the column that stay put — the lights, the address, the
/// strip. Their live content fades in by the slide's progress while the
/// curtain fades the old content out over it, on the one shared ground.
/// During a swipe the curtain draws both old and new from pictures and the
/// live content, still the old space's, stays out of the way.
struct SpaceSlideStatic: ViewModifier {
    @ObservedObject private var slide = SpaceSlide.shared

    func body(content: Content) -> some View {
        content.opacity(slide.picture == nil ? 1 : slide.dragging ? 0 : Double(slide.phase))
    }
}

extension SpaceSlide {
    /// After a commit, how much of the incoming picture is still over the
    /// live band: 1 where the fingers let go, 0 at home.
    var fade: Double { landing ? Double((1 - phase) / max(0.001, 1 - landed)) : 0 }
}

/// The pictures over the column while a slide is on — rows and static parts
/// only, on clear; the ground under them is the column's own. Takes no
/// clicks: the column under it is the real one from the first frame.
struct SpaceSlideCurtain: View {
    @ObservedObject private var slide = SpaceSlide.shared

    var body: some View {
        if let picture = slide.picture {
            let size = slide.column.size
            let top = max(0, slide.band.minY - slide.column.minY)
            let height = min(slide.band.height, size.height - top)
            ZStack(alignment: .topLeading) {
                if slide.dragging {
                    // The arriving space, pictured as it was last seen: its
                    // lights and strip fading in, its band coming in from
                    // the side. With no picture of it yet, the old lights
                    // and strip stand until the switch and the band is bare.
                    if let incoming = slide.incoming {
                        statics(incoming, size: size, top: top, height: height)
                            .opacity(Double(slide.phase))
                        band(incoming, size: size, top: top, height: height, way: slide.way, at: 1 - slide.phase)
                    }
                    statics(picture, size: size, top: top, height: height)
                        .opacity(slide.incoming == nil ? 1 : Double(1 - slide.phase))
                } else {
                    // A timed slide, or the settle after a swipe's commit:
                    // the live column is the new space's, so only the old
                    // content fades out over it.
                    if slide.landing, let incoming = slide.incoming {
                        band(incoming, size: size, top: top, height: height, way: slide.way, at: 1 - slide.phase)
                            .opacity(slide.fade)
                    }
                    statics(picture, size: size, top: top, height: height)
                        .opacity(Double(1 - slide.phase))
                }
                // The old band, on its way out and fading as it goes.
                band(picture, size: size, top: top, height: height, way: -slide.way, at: slide.phase)
                    .opacity(Double(1 - slide.phase))
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// A picture's lights, address and strip: everything but the band.
    private func statics(_ image: NSImage, size: CGSize, top: CGFloat, height: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .mask(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Rectangle().frame(height: top)
                    Color.clear.frame(height: height)
                    Rectangle()
                }
            }
    }

    /// A picture's band, `at` of a column's width along `way`. Its last
    /// point is the column's hairline, which stays put, so it is left out.
    private func band(_ image: NSImage, size: CGSize, top: CGFloat, height: CGFloat, way: CGFloat, at: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .offset(x: way * size.width * at)
            .mask(alignment: .topLeading) {
                Rectangle()
                    .frame(width: max(0, size.width - 1), height: height)
                    .offset(y: top)
            }
    }
}
