import SwiftUI

// The space's colour, spread thin over the whole column.
//
// A space already carries a hue (`Space.hue`, 0…1, or nil for grey). Arc
// washes its entire sidebar in that hue at a saturation low enough that you
// read it as "a warm grey" rather than "a coloured panel" — around a tenth
// in a light window, a good deal deeper in a dark one, where a dark grey has
// room to hold colour without shouting. Everything the column draws — the
// ground, the resting favourite, the row under the pointer, the pill on the
// live row, the hairline — is the same hue at a different strength, which is
// what makes it look like one surface instead of a stack of them.
//
// One struct, made fresh each time the column draws: it holds two numbers.

struct SpaceTint {
    /// The space's hue, or nil for the plain grey Copper had before.
    let hue: Double?
    let dark: Bool

    init(hue: Double?, dark: Bool) {
        self.hue = hue
        self.dark = dark
    }

    /// The tint the column is wearing right now.
    @MainActor init(_ scheme: ColorScheme) {
        self.init(hue: Spaces.shared.space.hue, dark: scheme == .dark)
    }

    /// The hue at a given strength, or a neutral of the same brightness for a
    /// space that never picked one.
    private func mix(_ saturation: Double, _ brightness: Double) -> Color {
        Color(hue: hue ?? 0, saturation: hue == nil ? 0 : saturation, brightness: brightness)
    }

    /// The hue at a given strength, made exactly as light as asked rather
    /// than as bright. Brightness is a poor guide to how light a colour
    /// looks — yellow at 0.96 is nearly white, indigo at 0.96 is not — so
    /// the light column's surfaces are set by luminance, and every space's
    /// ground sits the same step below the white of the live row.
    private func lit(_ saturation: Double, _ luminance: Double) -> Color {
        let s = hue == nil ? 0 : saturation
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if SpaceTint.luminance(hue ?? 0, s, middle) < luminance { low = middle } else { high = middle }
        }
        return Color(hue: hue ?? 0, saturation: s, brightness: (low + high) / 2)
    }

    /// Relative luminance of an sRGB hue/saturation/brightness triple.
    static func luminance(_ h: Double, _ s: Double, _ v: Double) -> Double {
        let sector = (h * 6).truncatingRemainder(dividingBy: 6)
        let f = sector - sector.rounded(.down)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// The whole column. A soft grey or pastel in the light — deep enough
    /// that white reads as paper on it, a quarter darker than the pill by
    /// luminance in every hue — and unmistakable in the dark.
    var ground: Color { dark ? mix(0.26, 0.135) : lit(0.105, 0.75) }

    /// A favourite at rest: one step *in* from the ground, so the grid reads
    /// as a block of soft squares without a single border between them.
    var square: Color { dark ? mix(0.28, 0.205) : lit(0.145, 0.67) }

    /// Under the pointer. Nearer the ground than the pill — hover that
    /// announces itself is hover you notice, and it must never be mistaken
    /// for the row you are on.
    var hover: Color { dark ? mix(0.28, 0.225) : lit(0.075, 0.84) }

    /// The live row and the live square. The light window moves *towards*
    /// white here rather than away from it: on a pastel ground the page you
    /// are reading is the one that looks like paper, which is what Arc does
    /// and what a darker pill — the obvious first guess — gets backwards.
    var pill: Color { dark ? mix(0.32, 0.315) : mix(0.02, 1.0) }

    /// The live pill's edge: one point of the space's colour, or of ink for
    /// a grey space, so the paper has an outline even where the ground
    /// comes close to it.
    var rim: Color {
        hue == nil ? Palette.ink.opacity(dark ? 0.14 : 0.10) : dot.opacity(dark ? 0.35 : 0.28)
    }

    /// The soft shadow the live pill lifts off the column with.
    var lift: Color { .black.opacity(dark ? 0.32 : 0.10) }

    /// The short bar at the live row's left edge: the space's colour at
    /// full strength, the one cue that survives a glance from across a room.
    var bar: Color { hue == nil ? Palette.ink.opacity(0.55) : dot }

    /// The only line in the column, and it is half a line at that.
    var hairline: Color { dark ? mix(0.34, 0.48).opacity(0.32) : mix(0.30, 0.66).opacity(0.22) }

    /// The soft square a letter sits on for a site that has no icon yet.
    var chip: Color { dark ? mix(0.22, 0.36).opacity(0.5) : mix(0.30, 0.76).opacity(0.5) }

    /// A space's colour at full strength: the swatch in the picker, the
    /// split's outline, and what the chips at the foot are thinned from.
    var dot: Color { mix(0.62, dark ? 0.86 : 0.70) }

    /// A space's own mark — its letter or symbol — on a chip: the same hue,
    /// dark enough to read on a light square and light enough on a dark one.
    var mark: Color { mix(hue == nil ? 0 : 0.66, dark ? 0.92 : 0.40) }

    /// The square behind a mark, for every space but the current one: the
    /// dot, thinned until it is a colour rather than a button.
    var chipFill: Color { dot.opacity(dark ? 0.30 : 0.22) }
    /// The same square under the pointer.
    var chipLift: Color { dot.opacity(dark ? 0.48 : 0.40) }

    /// Titles. The live one is nearly the app's ink; the rest step back
    /// without going grey, so the column stays one colour all the way down.
    var ink: Color { dark ? mix(0.07, 0.97) : mix(0.42, 0.15) }
    var muted: Color { dark ? mix(0.14, 0.70).opacity(0.86) : mix(0.26, 0.40).opacity(0.74) }
    var faint: Color { dark ? mix(0.14, 0.58).opacity(0.72) : mix(0.24, 0.52).opacity(0.62) }
}
