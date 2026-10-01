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
// Instead the switch is one move, on one ground, with nothing pictured:
//
//   The ground (SpaceGround) is the column's background, drawn live for
//   the whole column — under the lights, the address, the rows and the
//   strip — and blended from the old space's theme to the new one's by how
//   far the slide has gone. It never moves.
//
//   The band — the favourites, the space's name and the rows — travels.
//   The real, live band is one of the two columns in motion; the other is
//   a preview (SpacePreview): the same rows drawn from the space's tabs,
//   with the same parts and measures, in that space's ink, on a clear
//   ground, taking no clicks. On a click or a key the new rows go in with
//   animations off and the live band slides in from the side, while a
//   preview of the rows that were there slides out and fades. After
//   ~0.22 s the preview is dropped and nothing is left of it.
//
//   The lights, the address and the strip stay where they are; their ink
//   is mixed from the old space's to the new one's as the slide goes
//   (SlideInk), so a dark column's white glyphs become a light one's brown
//   with the ground, not after it.
//
// A two-finger swipe (Swipes.swift) drives the same layers by hand. The
// space it is heading for is not on screen, and putting it there would
// select its tab and wake the page, so its preview comes in beside a
// preview of the rows on screen — built from its parked tabs, so a space
// never visited this launch looks exactly as it will. The live band itself
// stays put and out of sight while the fingers are down: moving it is
// moving every row's layers a frame at a time (measured at several
// milliseconds a frame for a long column), where a preview holds only the
// rows in view and nothing but their mark and title. The previews of both
// neighbours are kept drawn and hidden while nothing moves
// (SpacePreview.premount), so the first frame of a swipe has nothing to
// build but the current space's own. When the fingers let go far enough,
// the real switch happens under the arriving preview and the live band —
// now the new space's, laid out as the preview was — takes its place as
// the preview fades; the rows that left carry on out as the preview they
// already were. When not, the previews spring back and the live band
// shows again where it never moved from.
//
// Which way: towards a space after this one in `Spaces.all`, the old column
// leaves to the left; before it, to the right. Reduce Motion keeps the
// crossfade and drops the travel.
//
// Earlier versions pictured the column (the window's pixels, or the views
// drawn twice over black and white for a matte) and slid the pictures. The
// picture cost up to 55 ms at the moment the fingers moved, a space with no
// picture yet came in blank, and the ground baked into a picture met the
// other ground at a seam. None of that is here.

@MainActor
final class SpaceSlide: ObservableObject {
    static let shared = SpaceSlide()

    /// A slide is on: a click's, or a swipe's with a space to head for.
    /// Nil between slides — which is also how the views know one is on.
    @Published private(set) var sliding = false
    /// How far along: 0 at the switch, 1 once the new column is home.
    @Published private(set) var phase: CGFloat = 1
    /// +1 when the new space is after the old one (the old column leaves to
    /// the left), -1 before it, 0 under Reduce Motion.
    @Published private(set) var way: CGFloat = 0
    /// The two spaces the slide is between: the ground blends `from`'s look
    /// towards `to`'s by `phase`, the static parts mix their ink the same
    /// way. Nil at rest; during a swipe `to` is nil at the ends, where there
    /// is nowhere to go.
    @Published private(set) var from: Space?
    @Published private(set) var to: Space?
    /// The rows on their way out, as a preview: the space on screen, taken
    /// from the live column as the fingers start or the instant before a
    /// click's switch (so its scroll and its live row are exact).
    @Published private(set) var leaving: SpacePreviewModel?

    /// Where the column is, and where the band that travels is, in SwiftUI's
    /// global space (the window's content, from its top left). Kept up to
    /// date by the column as it is laid out; not published, since nothing
    /// has to redraw when they change. Zero while no column is on screen.
    var column: CGRect = .zero
    var band: CGRect = .zero

    var moving: Bool { sliding || dragging }

    /// Which previews the column keeps drawn (see SpacePreviewStack).
    let anchor = PreviewAnchor()

    // The swipe's own state, all nil/false/zero outside one.
    /// True from the first sideways movement until the fingers let go.
    @Published private(set) var dragging = false
    /// At the first or last space there is nowhere to go: the live column is
    /// pulled this far, with resistance, and springs back.
    @Published private(set) var stretch: CGFloat = 0
    /// After a swipe commits, while the band settles: the arriving preview
    /// stays over the live band (now the same rows) and fades out, from the
    /// phase the fingers let go at (`landed`) to home.
    @Published private(set) var landing = false
    private(set) var landed: CGFloat = 0

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
              let window = Links.window, window.isVisible else { return false }
        serial += 1
        let mine = serial
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let old = Spaces.shared.space
        // The rows as they stand, planned for the preview that slides out.
        // Planning is the cheap part; the view is built with the frame.
        let model = SpacePreviewModel.live(old, in: browser, width: column.width, height: band.height)
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) {
            dragging = false
            landing = false
            stretch = 0
            from = old
            to = space
            leaving = model
            sliding = true
            phase = 0
            way = still ? 0 : (forward ? 1 : -1)
            // The neighbours kept drawn stay the old space's through the
            // slide, so nothing is built or dropped while it moves.
            anchor.home = old.id
        }
        timing = Timing(asked: started, planned: CACurrentMediaTime())
        // One turn of the run loop: it commits the frame that has the new
        // column in place under the preview (the switch's own frame, looking
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
        guard mine == serial, sliding else { return }
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
        let mine = serial
        var calm = Transaction()
        calm.disablesAnimations = true
        withTransaction(calm) {
            sliding = false
            phase = 1
            dragging = false
            landing = false
            stretch = 0
            from = nil
            to = nil
            leaving = nil
            anchor.arriving = nil
        }
        timing?.ended = CACurrentMediaTime()
        unwatch()
        // The neighbours kept drawn become the new space's — a moment
        // later, so building them is not in the slide's last frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, mine == self.serial, !self.moving else { return }
            self.anchor.home = nil
        }
    }

    // MARK: - the swipe

    /// The column `travel` points sideways from where it started (negative is
    /// to the left) — the fingers' travel, turned round if the swipe
    /// direction setting says so. The first call starts the swipe; every
    /// call after only moves things, with no animation — the fingers are the
    /// animation. False when there is no column to drive.
    @discardableResult
    func drag(_ travel: CGFloat, in browser: Browser) -> Bool {
        let spaces = Spaces.shared
        guard browser.primary, let here = spaces.all.firstIndex(where: { $0.id == spaces.current }) else { return false }
        if !dragging {
            // A settle still running from the last swipe or a click is left
            // to finish; these fingers do nothing.
            guard !sliding else { return false }
            let started = CACurrentMediaTime()
            timed = browser.prefs.bench
            guard column.width > 1, column.height > 1, band.height > 1,
                  let window = Links.window, window.isVisible else { return false }
            serial += 1
            // The rows on screen, planned for the preview that travels in
            // the live band's place — the one view a swipe has to build as
            // it starts (the neighbours are kept ready).
            let model = SpacePreviewModel.live(spaces.space, in: browser, width: column.width, height: band.height)
            timing = Timing(asked: started, planned: CACurrentMediaTime())
            var calm = Transaction()
            calm.disablesAnimations = true
            withTransaction(calm) {
                dragging = true
                from = spaces.space
                leaving = model
                anchor.home = spaces.current
                // The previews were planned against the column's scroll as
                // it was; if it has scrolled since, they land elsewhere now.
                let scroll = SideScrollElasticity.column?.contentView.bounds.minY ?? 0
                if abs(scroll - anchor.scrollSeen) > 0.5 { anchor.generation += 1 }
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
                if to?.id != space.id {
                    to = space
                    anchor.arriving = space.id
                }
                sliding = true
                way = forward ? 1 : -1
                phase = min(1, abs(travel) / width)
                stretch = 0
            } else {
                // Nowhere to go this way: no preview, only the live column
                // pulled against a spring that gets stiffer the further it goes.
                sliding = false
                to = nil
                anchor.arriving = nil
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
    /// under the arriving preview — the live column, now the new space's,
    /// takes the preview's place in the same frame, and the preview of the
    /// rows that were there carries on out.
    func release(velocity: CGFloat, cancelled: Bool, in browser: Browser) {
        guard dragging else { return }
        let mine = serial
        let width = max(column.width, 1)
        guard sliding, let to else {
            // The stretch at an end, home again.
            withAnimation(SpaceSlide.spring(from: stretch, to: 0, speed: velocity), completionCriteria: .logicallyComplete) {
                stretch = 0
            } completion: { [weak self] in
                guard let self, mine == self.serial else { return }
                self.end()
            }
            return
        }
        // In phase per second: positive is on towards `to`.
        let speed = -velocity * way / width
        let fast = SpaceSlide.flick / width
        let commit = !cancelled && (speed > fast || (speed > -fast && phase > SpaceSlide.commitAt))
        timing?.committed = CACurrentMediaTime()
        if commit {
            // The outgoing preview is already up (made as the fingers
            // started), so the switch builds nothing but the new column.
            var calm = Transaction()
            calm.disablesAnimations = true
            withTransaction(calm) {
                dragging = false
                landed = phase
                landing = true
                Spaces.shared.select(to.id, in: browser, sliding: true)
            }
            // As for a click: one turn of the run loop commits the frame with
            // the live column where the preview of it is, and the settle
            // sets off from there. In the same turn SwiftUI would see the
            // band go from outgoing straight to home and not move it.
            DispatchQueue.main.async { self.settle(to: 1, speed: speed, mine) }
        } else {
            settle(to: 0, speed: speed, mine)
        }
    }

    private func settle(to goal: CGFloat, speed: CGFloat, _ mine: Int) {
        guard mine == serial, sliding else { return }
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

    /// After a commit, how much of the arriving preview is still over the
    /// live band: 1 where the fingers let go, 0 at home.
    var fade: Double { landing ? Double((1 - phase) / max(0.001, 1 - landed)) : 0 }

    // MARK: - the bench

    /// What the last switch cost, in milliseconds from the moment it was
    /// asked for: the plan of the outgoing preview, the frame with the new
    /// column in it, the first frame that moved; and how the frames came
    /// while it moved.
    private struct Timing {
        var asked: CFTimeInterval
        var planned: CFTimeInterval
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
        } else if words.first == "off" {
            hold = nil
            if sliding { end() }
        }
        var note: [String: Any] = ["moving": moving, "hold": hold.map { Double($0) } ?? -1,
                                   "dragging": dragging, "phase": (Double(phase) * 1000).rounded() / 1000,
                                   "way": Double(way), "stretch": (Double(stretch) * 10).rounded() / 10,
                                   "from": from?.name ?? "", "to": to?.name ?? "", "leaving": leaving?.space.name ?? "",
                                   "landing": landing, "premount": SpacePreview.premount,
                                   "space": Spaces.shared.space.name,
                                   "window": Links.window.map { w in [Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height),
                                                                      w.occlusionState.contains(.visible) ? 1 : 0] } ?? [],
                                   "screens": NSScreen.screens.map { [Int($0.frame.minX), Int($0.frame.minY), Int($0.frame.width), Int($0.frame.height)] },
                                   "column": [Int(column.minX), Int(column.minY), Int(column.width), Int(column.height)],
                                   "band": [Int(band.minX), Int(band.minY), Int(band.width), Int(band.height)]]
        guard let t = timing else { return note }
        func ms(_ x: CFTimeInterval?) -> Double { x.map { (($0 - t.asked) * 10000).rounded() / 10 } ?? -1 }
        note["planned"] = ms(t.planned)
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

// Three layers, on one ground. The ground (SpaceGround, the column's
// background) is live and never pictured: it blends the outgoing theme
// towards the incoming one by `phase`. Over it travel the bands — the live
// one and a preview — carrying their own space's ink and nothing else; and
// over everything the lights, the address and the strip stay put with
// their ink mixed between the two spaces'. Nothing holds a ground, so
// there is no edge where one ground meets another and nothing to ghost.

/// The band that travels — the favourites, the space's name and its rows —
/// as the real, live column: in from the side after a switch, and held to
/// its own edges while it moves, so the part still on its way never draws
/// over the page. While a swipe has somewhere to go it stays put and out of
/// sight — the previews travel in its place (see the note at the top) —
/// and at an end with nowhere to go it is the thing pulled against the
/// rubber band. At rest it is not clipped at all, so nothing that hangs
/// over its edge (a favourite in the hand, its shadow) is cut.
struct SpaceSlideBand: ViewModifier {
    @ObservedObject private var slide = SpaceSlide.shared

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .opacity(slide.dragging && slide.sliding ? 0 : 1)
            .clipShape(BandEdge(on: slide.moving))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slide.band = $0 }
    }

    private var offset: CGFloat {
        if slide.dragging { return slide.sliding ? 0 : slide.stretch }
        return slide.sliding ? slide.way * slide.column.width * (1 - slide.phase) : 0
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
/// strip — drawn in an ink mixed from the old space's to the new one's by
/// the slide's progress, so they change with the ground under them. At
/// rest, the current space's. The content is built once from whatever tint
/// this hands it; only the tint changes.
struct SlideInk<Content: View>: View {
    @ViewBuilder let content: (SpaceTint) -> Content
    @ObservedObject private var slide = SpaceSlide.shared
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme

    init(@ViewBuilder content: @escaping (SpaceTint) -> Content) {
        self.content = content
    }

    var body: some View {
        let dark = scheme == .dark
        let tint: SpaceTint = {
            if slide.sliding, let from = slide.from, let to = slide.to, from.id != to.id {
                return SpaceTint(theme: from.look.mixed(to.look, Double(min(1, max(0, slide.phase)))), dark: dark)
            }
            return SpaceTint(space: spaces.space, dark: dark)
        }()
        content(tint)
    }
}

/// The previews over the column while a slide is on — the arriving space's
/// rows coming in beside the live band, the old space's rows going out
/// after a switch — and, hidden, the neighbours kept ready for the next
/// swipe. On clear: the ground under them is the column's own. Takes no
/// clicks: the column under it is the real one from the first frame.
struct SpaceSlideCurtain: View {
    @ObservedObject private var slide = SpaceSlide.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let size = slide.column.size
        let top = max(0, slide.band.minY - slide.column.minY)
        let height = max(1, min(slide.band.height, size.height - top))
        let width = max(1, size.width)
        ZStack(alignment: .topLeading) {
            SpacePreviewStack(width: width, height: height, dark: scheme == .dark)
                .equatable()
            if slide.sliding, let leaving = slide.leaving {
                // The old rows, on their way out and fading as they go.
                SpacePreview(model: leaving, width: width, height: height, dark: scheme == .dark)
                    .equatable()
                    .offset(x: -slide.way * width * slide.phase)
                    .opacity(Double(1 - slide.phase))
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .offset(y: top)
        .allowsHitTesting(false)
    }
}
