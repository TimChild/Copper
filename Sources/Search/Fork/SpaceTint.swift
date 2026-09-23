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

    /// The whole column. Barely there in the light, unmistakable in the dark.
    var ground: Color { dark ? mix(0.26, 0.135) : mix(0.105, 0.963) }

    /// A favourite at rest: one step *in* from the ground, so the grid reads
    /// as a block of soft squares without a single border between them.
    var square: Color { dark ? mix(0.28, 0.205) : mix(0.145, 0.922) }

    /// Under the pointer. Most of the way to the pill and no further — hover
    /// that announces itself is hover you notice, and Arc's you don't.
    var hover: Color { dark ? mix(0.28, 0.225) : mix(0.075, 0.988) }

    /// The live row and the live square. The light window moves *towards*
    /// white here rather than away from it: on a pastel ground the page you
    /// are reading is the one that looks like paper, which is what Arc does
    /// and what a darker pill — the obvious first guess — gets backwards.
    var pill: Color { dark ? mix(0.32, 0.315) : mix(0.045, 1.0) }

    /// The only line in the column, and it is half a line at that.
    var hairline: Color { dark ? mix(0.34, 0.48).opacity(0.32) : mix(0.30, 0.66).opacity(0.22) }

    /// The soft square a letter sits on for a site that has no icon yet.
    var chip: Color { dark ? mix(0.22, 0.36).opacity(0.5) : mix(0.30, 0.76).opacity(0.5) }

    /// A space, reduced to a dot at the foot of the column.
    var dot: Color { mix(0.62, dark ? 0.86 : 0.70) }

    /// Titles. The live one is nearly the app's ink; the rest step back
    /// without going grey, so the column stays one colour all the way down.
    var ink: Color { dark ? mix(0.07, 0.97) : mix(0.42, 0.15) }
    var muted: Color { dark ? mix(0.14, 0.70).opacity(0.86) : mix(0.26, 0.40).opacity(0.74) }
    var faint: Color { dark ? mix(0.14, 0.58).opacity(0.72) : mix(0.24, 0.52).opacity(0.62) }
}
