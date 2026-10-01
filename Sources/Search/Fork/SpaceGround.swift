import AppKit
import SwiftUI

// The column's ground, as one surface.
//
// Arc's sidebar background never slides. Swipe between two spaces and the
// favourites, the title and the rows travel, but the colour under them
// changes in place — salmon becomes sage across the whole column at once,
// with no edge between the two. So the ground here is one view that is
// always drawn live, never pictured: at rest it is the current space's
// theme; while a slide or a swipe is on it is the outgoing theme blended
// towards the incoming one by the slide's progress. Two plain themes
// (colours and gradients) are morphed stop by stop, so a flat salmon turns
// into a three-stop gradient as one surface; anything with a picture is
// crossfaded; an animated space keeps the column's one scene, which mixes
// its own colours (see AnimatedBackdrop) and fades in or out against a
// still neighbour.
//
// The ground lives in its own AppKit view (`SpaceGroundHost`) for one
// reason: so the slide can hide it for the instant it pictures the column
// (SpaceSlide.photograph). The pictures that travel — the outgoing and
// incoming bands — must hold the rows and nothing behind them, and the only
// way to get that from the real views is to draw them once with the ground
// switched off. A SwiftUI state change would not take until the next turn
// of the run loop; an NSView's `isHidden` takes at once, and is put back
// before anything reaches the screen.

/// Two themes and how far between them: 0 is all `from`, 1 all `to`. At
/// rest both are the current space's.
struct SpaceGround: View, Animatable {
    var from: SpaceTheme
    var to: SpaceTheme
    /// Which spaces these are the looks of — the scene keeps a clock per key.
    var fromKey: String
    var toKey: String
    var t: CGFloat
    let dark: Bool

    /// Animatable, so a timed slide's `withAnimation { phase = 1 }` runs
    /// this body with every value in between rather than jumping the
    /// colours from one end to the other.
    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    var body: some View {
        let x = Double(min(1, max(0, t)))
        ZStack {
            if from.simple, to.simple {
                // One surface changing colour: the stops move, nothing fades.
                ThemeBackdrop.Colour(theme: from.mixed(to, x), dark: dark)
            } else {
                // A picture (or a scene's own still colour) cannot be morphed
                // into something else, so the incoming ground fades in over
                // the outgoing one — both drawn live, both whole-column, so
                // there is still no edge, only a change.
                ThemeBackdrop.Still(theme: from, dark: dark)
                if x > 0.001 { ThemeBackdrop.Still(theme: to, dark: dark).opacity(x) }
            }
            Scene(from: from, to: to, fromKey: fromKey, toKey: toKey, x: x, dark: dark)
            ThemeBackdrop.Veil(tone: from.tone + (to.tone - from.tone) * x,
                               grain: from.grain + (to.grain - from.grain) * x)
        }
        .clipped()
    }

    /// The column's scene: one web view for the column's whole life (see
    /// AnimatedBackdrop), told which look to draw and how far to mix towards
    /// the other, and faded against a still neighbour.
    private struct Scene: View {
        let from: SpaceTheme
        let to: SpaceTheme
        let fromKey: String
        let toKey: String
        let x: Double
        let dark: Bool
        @ObservedObject private var spaces = Spaces.shared

        var body: some View {
            if BackdropScene.folder != nil, spaces.all.contains(where: { $0.look.motion != nil }) {
                let a = BackdropScene.Look(theme: from, dark: dark, key: fromKey)
                let b = BackdropScene.Look(theme: to, dark: dark, key: toKey)
                BackdropWeb.Host(drive: drive(a, b))
                    .opacity(a != nil && b != nil ? 1 : a != nil ? 1 - x : x)
                    .allowsHitTesting(false)
            }
        }

        private func drive(_ a: BackdropScene.Look?, _ b: BackdropScene.Look?) -> BackdropScene.Drive {
            var drive = BackdropScene.Drive(look: a ?? b, fade: SpaceSlide.duration + 0.08)
            if let a, let b, a != b {
                // Both animated: the shader mixes the two by the progress.
                drive.look = a
                drive.toward = b
                drive.x = x
            } else if a == nil, let b {
                // Still to animated: the scene is the incoming look from the
                // first frame, and fades in over the still ground.
                drive.look = b
            }
            return drive
        }
    }
}

/// The live column's ground: the current space at rest, the slide's two
/// spaces while one is on. Reads the slide, picks the themes, and hands
/// them to the animatable blend inside the hideable host.
struct SpaceGroundView: View {
    let space: Space
    let dark: Bool
    @ObservedObject private var slide = SpaceSlide.shared

    var body: some View {
        if let from = slide.from, let to = slide.to, slide.picture != nil {
            Blend(from: from.look, to: to.look, fromKey: from.id.uuidString, toKey: to.id.uuidString, t: slide.phase, dark: dark)
        } else {
            Blend(from: space.look, to: space.look, fromKey: space.id.uuidString, toKey: space.id.uuidString, t: 1, dark: dark)
        }
    }

    /// Animatable on the SwiftUI side of the host, so the progress reaches
    /// the AppKit view a frame at a time; the host itself cannot animate.
    private struct Blend: View, Animatable {
        var from: SpaceTheme
        var to: SpaceTheme
        var fromKey: String
        var toKey: String
        var t: CGFloat
        let dark: Bool

        var animatableData: CGFloat {
            get { t }
            set { t = newValue }
        }

        var body: some View {
            SpaceGroundHost(ground: SpaceGround(from: from, to: to, fromKey: fromKey, toKey: toKey, t: t, dark: dark))
        }
    }
}

/// The AppKit view the ground is drawn in, so the slide can take it out of
/// a picture. Takes no clicks: everything the pointer wants is the SwiftUI
/// column drawn over it.
///
/// For a picture (SpaceSlide.photograph) the ground inside is hidden and
/// `fill` is set, so the column is drawn over a flat colour. SwiftUI's own
/// window view paints the window's background under everything it draws,
/// whatever the window or the bitmap is told, so there is no drawing the
/// column on clear; but drawn once over black and once over white, every
/// pixel's colour and coverage fall out of the difference, and that is a
/// picture on clear.
struct SpaceGroundHost: NSViewRepresentable {
    let ground: SpaceGround

    final class Matte: NSView {
        let inner: NSHostingView<SpaceGround>
        /// A flat colour drawn instead of the ground, for a picture.
        var fill: NSColor?

        init(ground: SpaceGround) {
            inner = NSHostingView(rootView: ground)
            super.init(frame: .zero)
            inner.sizingOptions = []
            inner.autoresizingMask = [.width, .height]
            addSubview(inner)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            inner.frame = bounds
        }

        override func draw(_ rect: NSRect) {
            guard let fill else { return }
            fill.setFill()
            rect.fill()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }

    func makeNSView(context: Context) -> Matte {
        let view = Matte(ground: ground)
        SpaceSlide.shared.ground = view
        return view
    }

    func updateNSView(_ view: Matte, context: Context) {
        view.inner.rootView = ground
        SpaceSlide.shared.ground = view
    }
}
