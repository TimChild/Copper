import SwiftUI
import AppKit

// ⌘K, as a card.
//
// Upstream's Omnibox is a field for addresses: one pill, a list under it, a
// small dot per row. ⌘K is a different instrument — it is the whole browser
// answering "what did you mean" — and it wants the shape Arc gives it: one
// card floating a third of the way down the window, an input you can read
// from across the room, and rows that each say, on the right, what Return
// will do with them.
//
// Nothing here knows about spaces or commands; it draws the rows the browser
// hands it. What a row *is* is decided in CommandBar.offers.

struct CommandPalette: View {
    @ObservedObject var browser: Browser
    /// A page is behind this, rather than an empty tab. The page gets dimmed;
    /// an empty tab has nothing to dim.
    let over: Bool

    /// Wide enough for a title, a host and a hint without any of the three
    /// eating the others.
    private static let width: CGFloat = 640

    /// How far down the window the top of the card sits. A card pinned to the
    /// middle floats; a card near the top reads as a toolbar. A third of the
    /// way down is where the eye already is.
    private static let drop: CGFloat = 0.3

    @State private var place = WindowRuler.Place()
    /// The site marks, arriving a moment after the rows they belong to.
    @ObservedObject private var marks = Marks.ticker

    var body: some View {
        ZStack(alignment: .top) {
            // The page, still there, just told to be quiet.
            Rectangle()
                .fill(Color.black.opacity(over ? 0.16 : 0.05))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { browser.dismiss() }
                .transition(.opacity)

            card
                .frame(width: CommandPalette.width)
                // The card belongs to the window, not to the page area it
                // happens to be drawn in, so it is shifted back over the
                // column of tabs by half that column's width.
                .offset(x: -inset / 2, y: top)
        }
        .background(WindowRuler { place = $0 })
        .animation(Motion.settle, value: browser.offers)
        // Every row that names a site wants that site's mark, and most of
        // these rows have no page behind them to ask. See Fork/Marks.
        .onAppear { Marks.want(browser.offers.map(\.url)) }
        .onChange(of: browser.offers) { _, offers in Marks.want(offers.map(\.url)) }
    }

    /// Where to put the top of the card, counted from the top of the region
    /// SwiftUI handed this view — which is not the top of the window, and on
    /// a 900pt window starts some 240pt above it.
    private var top: CGFloat {
        guard place.height > 0 else { return 240 }
        return place.height * CommandPalette.drop - place.top
    }

    private var inset: CGFloat {
        browser.prefs.sidebar && !browser.folded ? browser.prefs.sideWidth : 0
    }

    private var card: some View {
        VStack(spacing: 0) {
            field
            if !browser.offers.isEmpty {
                Rectangle()
                    .fill(Palette.hairline.opacity(0.55))
                    .frame(height: 1)
                rows
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Palette.ground)
        )
        // Clip first, cast second. A .shadow draws behind whatever the view
        // is at that point in the chain, so a .clipShape after it trims the
        // shadow to the card's own bounds and leaves a flat rectangle with a
        // hard edge — which is what this was, for two rounds.
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        // No outline. A card this size separates itself by sitting above the
        // page, and the shadow is the only thing that says so — one tight
        // shadow for the edge, one wide one for the lift.
        .shadow(color: .black.opacity(0.09), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.26), radius: 48, y: 20)
        .transition(.scale(scale: 0.985, anchor: .top).combined(with: .opacity))
    }

    private var field: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.muted)
            AddressField(
                browser: browser,
                literal: true,
                size: 17.5,
                placeholder: "Search or enter an address"
            )
            .frame(height: 24)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var rows: some View {
        VStack(spacing: 1) {
            ForEach(Array(browser.offers.enumerated()), id: \.offset) { index, offer in
                Row(offer: offer, picked: browser.picked == index, tint: tint, stamp: marks.landed)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.take(offer) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    /// The space's own colour, so the selected row belongs to where you are.
    private var tint: Color { Spaces.shared.space.tint }

    private struct Row: View {
        let offer: Suggestion
        let picked: Bool
        let tint: Color
        /// Changes when a site mark lands, which is the only thing that can
        /// make a row draw differently without the row itself changing.
        let stamp: Int

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 11) {
                Mark(offer: offer, tint: tint, picked: picked, stamp: stamp)
                    .frame(width: 18, height: 18)

                // One weight, picked or not. Going semibold on the selected
                // row widened it enough to squeeze the muted half out of the
                // row — so the one row you were about to press Return on was
                // the one that stopped telling you which space it lived in.
                // The pill and the tinted hint say "selected" without moving
                // anything.
                Text(offer.key)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                // A host cut down to "mail.go…" has stopped being an answer
                // to anything, so it is shown whole and the title — still
                // readable from its first two thirds — is what gives way
                // when the row runs out of width.
                if !offer.detail.isEmpty {
                    Text(offer.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(2)
                }

                // Last to give way: see Suggestion.badge.
                if !offer.badge.isEmpty {
                    Text(offer.badge)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(3)
                }

                Spacer(minLength: 14)

                // Shown only on the row Return would take — "Switch to Tab"
                // set down the right of six rows is a column of grey noise
                // saying the same thing six times — but laid out on every
                // row, so selecting one changes what the row looks like and
                // never what it is shaped like.
                if !offer.hint.isEmpty {
                    Text(offer.hint)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(picked ? tint : Palette.muted.opacity(0.8))
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(picked || hovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background {
                if picked {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.17))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.hover)
                }
            }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: picked)
        }
    }

    /// The thing on the left. A site wears its own icon; a command and a
    /// search wear a glyph; a site whose icon hasn't arrived wears its first
    /// letter, the way the tabs do.
    private struct Mark: View {
        let offer: Suggestion
        let tint: Color
        let picked: Bool
        let stamp: Int

        var body: some View {
            switch offer.kind {
            case .command:
                glyph(offer.glyph.isEmpty ? "command" : offer.glyph)
            case .search:
                glyph("magnifyingglass")
            default:
                if let host = Marks.key(for: offer.url), let icon = Favicons.shared.cached(host) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .transition(.opacity)
                } else {
                    letter
                }
            }
        }

        /// Bare, the way Arc draws its magnifier: no chip, no plate. A grey
        /// rounded square behind the glyph reads as a different kind of row
        /// from the ones wearing a favicon, and the search is the same kind
        /// of row as all the others.
        private func glyph(_ name: String) -> some View {
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(picked ? tint : Palette.muted)
                .frame(width: 18, height: 18)
        }

        /// No icon yet — a fresh profile has none, and a sleeping tab has
        /// never asked its site for one. A grey square for every row would
        /// make the whole card grey, so each host gets a colour of its own,
        /// steady between launches because it comes from the letters.
        private var letter: some View {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(hue: hue, saturation: 0.42, brightness: 0.78))
                .overlay(
                    Text(initial)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                )
        }

        private var source: String {
            let host = offer.url.host() ?? offer.key
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        private var initial: String { String(source.prefix(1)).uppercased() }

        private var hue: Double {
            let sum = source.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
            return Double(sum % 360) / 360
        }
    }
}

/// Where the card's region sits inside the window, and how tall the window is.
///
/// SwiftUI will happily measure the region it gives you, but the region the
/// field overlay gets is stretched past the window's edges by the views
/// beneath it that ignore the safe area — on a 900pt window it comes out
/// around 1390, starting well above the title bar. Placing a card "a third of
/// the way down" against that number puts it above the top of the window. So
/// the card is placed against the window, measured through an AppKit view
/// that is in both.
struct WindowRuler: NSViewRepresentable {
    struct Place: Equatable {
        /// The window's own height.
        var height: CGFloat = 0
        /// How far below the top of the window this region begins — negative
        /// when it starts above it, which is the usual case here.
        var top: CGFloat = 0
    }

    let report: (Place) -> Void

    func makeNSView(context: Context) -> NSView { Ruler(report: report) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Ruler)?.report = report }

    final class Ruler: NSView {
        var report: (Place) -> Void
        private var last = Place()

        init(report: @escaping (Place) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("no coder") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            measure()
        }

        override func layout() {
            super.layout()
            measure()
        }

        private func measure() {
            guard let root = window?.contentView, root !== self else { return }
            let mine = convert(bounds, to: root)
            // AppKit counts from the bottom left unless a view says otherwise.
            let top = root.isFlipped ? mine.minY : root.bounds.maxY - mine.maxY
            let place = Place(height: root.bounds.height, top: top)
            guard place.height > 0, place != last else { return }
            last = place
            // Not from inside a layout pass: this drives a SwiftUI state
            // change, and changing state while AppKit is laying the same
            // views out is how you get a view that never settles.
            DispatchQueue.main.async { [report] in report(place) }
        }
    }
}
