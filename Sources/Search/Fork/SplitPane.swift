import SwiftUI

// What a split pane looks like. The model is in Split.swift; this is the card
// it is drawn as — a rounded page with its own hairline toolbar, floating in
// the page area with the space's colour washed behind it.
//
// Arc's split is not two pages meeting at a line. It is two cards with air
// around them, and the one you are typing into is the one wearing the
// outline. Everything here exists to say which of the two is live without
// spending a word on it.
//
// Two things to know before editing.
//
// `Page` is a WKWebView in SwiftUI's clothing. It has no size of its own and
// takes whatever height it is offered, so a card built out of padding grows
// taller than the room it was given and its margins fall off both ends of the
// window — which is exactly what the first cut of this did. Every frame here
// is therefore a number, handed down from the stage's GeometryReader, not a
// padding and a hope.
//
// A web view is also a real AppKit layer: `.clipShape` does not round it, and
// wrapping the subtree that holds it in `.clipShape` or `.shadow` hands it the
// wrong frame again. So the card never clips or shadows the subtree — the
// corners are painted back out afterwards (`CornerCut`), the shadow belongs to
// the background shape alone, and the toolbar is an overlay, which does land
// on top of an AppKit layer where a sibling would not.

enum SplitMetrics {
    /// The air between the two cards.
    static let gutter: CGFloat = 8
    /// The air around the pair, inside the page area.
    static let margin: CGFloat = 7
    /// A card's corner. Between Arc's and the window's own.
    static let corner: CGFloat = 11
    /// The strip of chrome each card carries.
    static let bar: CGFloat = 32
    /// A card never gets narrower than this, however far the handle is pulled.
    static let least: CGFloat = 220
    /// How wide the invisible line between the cards is to the pointer —
    /// the gutter is only 8, which is a hard thing to hit on purpose.
    static let grip: CGFloat = 18
}

/// One pane: its toolbar, its page, its outline.
struct SplitCard: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    /// The pane the keyboard is in.
    let live: Bool
    /// The space's colour, for the live pane's outline.
    let tint: Color
    /// What is behind the cards, so the corners can be painted back out in it.
    let wash: Color
    /// The room the stage measured for this card. Not negotiable: see above.
    let size: CGSize

    var body: some View {
        Page(tab: tab)
            .frame(width: size.width, height: max(size.height - SplitMetrics.bar, 1))
            .padding(.top, SplitMetrics.bar)
            .frame(width: size.width, height: size.height)
            .background(plate)
            .overlay(alignment: .top) { SplitBar(browser: browser, tab: tab, live: live) }
            // The web view is square whatever we ask of it, so the corners are
            // painted back out in the colour behind the card. No layer tree
            // argues with paint.
            .overlay { CornerCut(radius: SplitMetrics.corner).fill(Palette.ground, style: FillStyle(eoFill: true)) }
            .overlay { CornerCut(radius: SplitMetrics.corner).fill(wash, style: FillStyle(eoFill: true)) }
            .overlay { edge }
            .animation(Motion.quick, value: live)
    }

    /// The card's own ground, and the only thing carrying the shadow — put the
    /// shadow on the subtree instead and the page inside it loses its place.
    private var plate: some View {
        RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous)
            .fill(Palette.ground)
            .shadow(color: .black.opacity(live ? 0.16 : 0.09), radius: live ? 10 : 6, y: 2)
    }

    /// The live pane is outlined in the space's colour. The other is not
    /// outlined at all — that is the whole point of the outline.
    private var edge: some View {
        RoundedRectangle(cornerRadius: SplitMetrics.corner, style: .continuous)
            .strokeBorder(live ? tint : Palette.hairline.opacity(0.9), lineWidth: live ? 2 : 1)
            .allowsHitTesting(false)
    }
}

/// Everything outside a rounded rectangle, so it can be filled with whatever
/// is behind the card and leave the corners looking cut.
private struct CornerCut: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addPath(Path(roundedRect: rect, cornerRadius: radius, style: .continuous))
        return path
    }
}

/// A pane's own hairline toolbar: where it has been, what it is, and the
/// cross that ends it.
struct SplitBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool

    var body: some View {
        HStack(spacing: 1) {
            PaneGlyph(icon: "arrow.left", help: "Back", on: tab.canGoBack) { tab.back() }
            PaneGlyph(icon: "arrow.right", help: "Forward", on: tab.canGoForward) { tab.forward() }
            PaneGlyph(
                icon: tab.loading ? "xmark" : "arrow.clockwise",
                help: tab.loading ? "Stop" : "Reload",
                on: true
            ) {
                tab.loading ? tab.stop() : tab.reload()
            }

            Spacer(minLength: 2)

            HStack(spacing: 5) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 13, dim: !live)
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(live ? Palette.ink.opacity(0.7) : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Spacer(minLength: 2)

            PaneGlyph(icon: "xmark", help: "Close this pane", on: true) {
                Split.shared.dismiss(tab, in: browser)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: SplitMetrics.bar)
        .background(alignment: .bottom) {
            // The bar is a band a shade off the page, the way Arc's is, so
            // chrome still reads as chrome over a white page; the hairline
            // where the two meet does the rest.
            ZStack(alignment: .bottom) {
                Palette.ground
                Palette.ink.opacity(0.05)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
        }
        // A click anywhere on the bar is a click into the pane.
        .contentShape(Rectangle())
        .onTapGesture { Split.shared.touched(tab, in: browser) }
    }

    /// Where the pane is, not what it is called: the tab in the column already
    /// says the title, and with no address row anywhere else in the window
    /// this strip is the one place the address can be read.
    private var name: String {
        if let address = tab.address { return Address.pretty(address) }
        if !tab.title.isEmpty { return tab.title }
        return "New Tab"
    }
}

/// One glyph in a pane's toolbar. Small, muted, and dimmed to nothing when it
/// has nowhere to go — a door that is not there is quieter than a door that
/// is greyed out.
private struct PaneGlyph: View {
    let icon: String
    let help: String
    let on: Bool
    let act: () -> Void

    @State private var over = false

    var body: some View {
        Button(action: on ? act : {}) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? Palette.ink.opacity(over ? 0.9 : 0.65) : Palette.muted.opacity(0.3))
                .frame(width: 21, height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(over && on ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { over = $0 && on }
        .animation(Motion.quick, value: over)
    }
}

/// The line between the panes: nothing at all until the pointer finds it,
/// then a short soft bar you can pull. Double-click puts it back in the
/// middle.
struct SplitHandle: View {
    @ObservedObject var split = Split.shared
    /// The width the fraction is measured against, and where it starts.
    let span: CGFloat
    let inset: CGFloat

    @State private var over = false
    @State private var dragging = false

    var body: some View {
        let showing = over || dragging
        ZStack {
            Color.clear
            Capsule(style: .continuous)
                .fill(Palette.ink.opacity(showing ? 0.3 : 0))
                .frame(width: 4, height: 54)
        }
        .frame(width: SplitMetrics.grip)
        .contentShape(Rectangle())
        .onHover { inside in
            over = inside
            inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop()
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Split.space))
                .onChanged { drag in
                    dragging = true
                    let least = SplitMetrics.least / max(span, 1)
                    let want = (drag.location.x - inset) / max(span, 1)
                    split.fraction = min(1 - least, max(least, want))
                }
                .onEnded { _ in dragging = false }
        )
        // Double-click is the way back to even. SwiftUI hands the two-click
        // tap to this gesture before the drag sees it, so the two do not
        // fight over the same pointer.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                withAnimation(Motion.glide) { split.fraction = 0.5 }
            }
        )
        .animation(Motion.quick, value: showing)
    }
}
