import SwiftUI

// The space's look, and every surface the column draws over it.
//
// The ground is the space's theme — a colour, a gradient or a picture (see
// `SpaceTheme`), at Arc's strength rather than a pastel wash. Everything on
// top of it is a translucent white or black: the resting favourite a shade
// in, the row under the pointer a shade more, the live pill half-way to
// white. That is how Arc keeps one surface whatever the theme, and it is
// the only way a gradient or a photograph can sit under the rows at all.
// Ink is the theme's own hue taken nearly to black (to white in the dark),
// so a salmon column has warm brown titles, not grey ones.

struct SpaceTint {
    /// The hue the rest of the app knows the space by, or nil for grey.
    let hue: Double?
    let dark: Bool
    /// What the column is washed in.
    let theme: SpaceTheme

    init(hue: Double?, dark: Bool) {
        self.init(theme: hue.map(SpaceTheme.hue) ?? .plain, dark: dark)
    }

    init(theme: SpaceTheme, dark: Bool) {
        self.theme = theme
        self.hue = theme.hue
        self.dark = dark
    }

    init(space: Space, dark: Bool) {
        self.init(theme: space.look, dark: dark)
    }

    /// The tint the column is wearing right now.
    @MainActor init(_ scheme: ColorScheme) {
        self.init(space: Spaces.shared.space, dark: scheme == .dark)
    }

    /// The hue at a given strength, or a neutral of the same brightness for a
    /// space that never picked one.
    private func mix(_ saturation: Double, _ brightness: Double) -> Color {
        Color(hue: hue ?? 0, saturation: hue == nil ? 0 : saturation, brightness: brightness)
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

    /// The column's ground, drawn: colour, gradient or picture, and grain.
    var backdrop: ThemeBackdrop { ThemeBackdrop(theme: theme, dark: dark) }

    /// One flat colour for the whole column, where a surface beside it has
    /// to match it: the split's gutter, a drop target.
    var ground: Color { theme.flat(dark: dark) }

    /// A favourite at rest, the address field: one shade in from the ground.
    var square: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045) }

    /// Under the pointer. A shade more than a favourite at rest, never close
    /// to the live pill.
    var hover: Color { dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06) }

    /// The live row and the live favourite: half-way to white, the page you
    /// are reading looking like paper laid on the column.
    var pill: Color { dark ? Color.white.opacity(0.16) : Color.white.opacity(0.48) }

    /// The live pill's edge, lighter still, so it holds on a pale theme.
    var rim: Color { dark ? Color.white.opacity(0.14) : Color.white.opacity(0.6) }

    /// The soft shadow the live pill lifts off the column with.
    var lift: Color { .black.opacity(dark ? 0.32 : 0.07) }

    /// The space's colour at full strength, for a short mark of it.
    var bar: Color { hue == nil ? Palette.ink.opacity(0.55) : dot }

    /// The only line in the column, and it is half a line at that.
    var hairline: Color { dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08) }

    /// The soft square a letter sits on for a site that has no icon yet.
    var chip: Color { dark ? Color.white.opacity(0.1) : Color.black.opacity(0.07) }

    /// A space's colour at full strength: the swatch in the picker, the
    /// split's outline, and what the chips at the foot are thinned from.
    var dot: Color { mix(0.62, dark ? 0.86 : 0.70) }

    /// The space's colour as a swatch shows it — in the editor and the
    /// Colour menu: the theme's own colour, a touch fuller and deeper so it
    /// holds on a white popover. `dot` is darker and duller on purpose (it
    /// is thinned for the chips); on a swatch it made yellow olive.
    var swatch: Color {
        guard let hue else { return Color(white: dark ? 0.55 : 0.64) }
        let (s, v) = SpaceTheme.strength(hue)
        return Color(hue: hue, saturation: min(1, s + 0.14), brightness: v * (dark ? 0.92 : 0.9))
    }

    /// A space's own mark — its letter or symbol — on a chip: the same hue,
    /// dark enough to read on a light square and light enough on a dark one.
    var mark: Color { mix(hue == nil ? 0 : 0.66, dark ? 0.92 : 0.40) }

    /// The square behind a mark, for every space but the current one: the
    /// dot, thinned until it is a colour rather than a button.
    var chipFill: Color { dot.opacity(dark ? 0.30 : 0.22) }
    /// The same square under the pointer.
    var chipLift: Color { dot.opacity(dark ? 0.48 : 0.40) }

    /// Titles: the theme's hue taken nearly to black, or nearly to white in
    /// the dark — warm brown on salmon, the way Arc sets its own.
    var ink: Color { dark ? mix(0.06, 0.96) : mix(0.9, 0.19) }
    var muted: Color { ink.opacity(0.62) }
    var faint: Color { ink.opacity(0.45) }
}
