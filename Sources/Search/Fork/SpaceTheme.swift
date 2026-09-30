import AppKit
import ImageIO
import SwiftUI

// What a space looks like: a colour, a gradient, or a picture, laid over the
// whole column the way Arc lays its themes.
//
// Arc stores a theme as one colour or a few, an intensity, and a grain; it
// draws the column as those colours pulled most of the way from white and
// dimmed a touch, which is why its sidebars read as salmon or sage rather
// than as a pastel wash. The same numbers come in from an Arc import, so a
// moved space looks the way it did. A picture goes under the colour, which
// stays on it thinly so the rows keep one ink.
//
// Everything the column draws on top — favourites, hover, the live pill, the
// hairline — is a translucent white or black over this (see `SpaceTint`), so
// it reads the same over a flat colour, a gradient or a photograph.

struct SpaceTheme: Codable, Hashable {
    struct Stop: Codable, Hashable {
        var r: Double
        var g: Double
        var b: Double

        init(r: Double, g: Double, b: Double) {
            self.r = min(1, max(0, r))
            self.g = min(1, max(0, g))
            self.b = min(1, max(0, b))
        }

        init(hue: Double, saturation: Double, brightness: Double) {
            let c = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
                .usingColorSpace(.sRGB) ?? .gray
            self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }

        init?(_ color: Color) {
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
            self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

        var hsb: (h: Double, s: Double, v: Double) {
            let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            return (c.hueComponent, c.saturationComponent, c.brightnessComponent)
        }

        func mixed(_ other: Stop, _ t: Double) -> Stop {
            Stop(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }

        func scaled(_ k: Double) -> Stop { Stop(r: r * k, g: g * k, b: b * k) }

        /// `#e8a07a`, `e8a07a` or `#fa7`; nil for anything else.
        init?(hex: String) {
            var digits = hex.trimmingCharacters(in: .whitespaces)
            if digits.hasPrefix("#") { digits.removeFirst() }
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let n = UInt32(digits, radix: 16) else { return nil }
            self.init(r: Double(n >> 16 & 0xFF) / 255, g: Double(n >> 8 & 0xFF) / 255, b: Double(n & 0xFF) / 255)
        }

        var hex: String {
            String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }

        static let white = Stop(r: 1, g: 1, b: 1)
        static let black = Stop(r: 0, g: 0, b: 0)
    }

    /// One colour is a flat column; two or three run top-leading to
    /// bottom-trailing.
    var colors: [Stop]
    /// How far the column goes from white towards the colours — Arc's
    /// `intensityFactor`, 0…1.
    var intensity: Double = 0.8
    /// Film grain over the column, 0…1 — Arc's `noiseFactor`.
    var grain: Double = 0
    /// A picture under the colour: a file name in `themes/`.
    var image: String? = nil

    init(colors: [Stop], intensity: Double = 0.8, grain: Double = 0, image: String? = nil) {
        self.colors = colors
        self.intensity = intensity
        self.grain = grain
        self.image = image
    }

    private enum CodingKeys: String, CodingKey { case colors, intensity, grain, image }

    // Read by hand, not synthesized: a synthesized decoder wants every
    // non-optional key there, defaults or no, so a theme written before a
    // field existed — or by hand, or by an importer that only knew the
    // colours — would throw and take the whole session with it. A missing
    // number is its default; a theme with no colours at all is graphite's.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let colors = (try? c.decodeIfPresent([Stop].self, forKey: .colors)) ?? []
        self.colors = Array((colors.isEmpty ? SpaceTheme.plain.colors : colors).prefix(3))
        intensity = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .intensity)) ?? 0.8))
        grain = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .grain)) ?? 0))
        image = try? c.decodeIfPresent(String.self, forKey: .image)
    }

    /// A space that only ever had a hue: that hue, at the strength that
    /// hue can carry.
    static func hue(_ hue: Double) -> SpaceTheme {
        let (s, v) = strength(hue)
        return SpaceTheme(colors: [Stop(hue: hue, saturation: s, brightness: v)], intensity: 0.8)
    }

    /// How full and how bright a bare hue is taken, around the wheel. One
    /// number for all of them made the warm ones right and the rest neon:
    /// green and cyan are so much lighter to the eye than red at the same
    /// saturation that they came out highlighter-bright, and blue to pink
    /// shouted. So the warm side keeps its strength — salmon, apricot,
    /// butter — green and teal are thinned and dimmed to sage and sea glass,
    /// and blue round to pink sit between. Straight lines between these
    /// points, so an imported hue between two names lands between them.
    private static let strengths: [(h: Double, s: Double, v: Double)] = [
        (0.00, 0.74, 1.00), (0.07, 0.74, 1.00), (0.10, 0.72, 1.00), (0.14, 0.66, 1.00),
        (0.22, 0.56, 0.94), (0.36, 0.50, 0.86), (0.48, 0.52, 0.84), (0.60, 0.62, 0.98),
        (0.70, 0.58, 0.98), (0.80, 0.54, 0.98), (0.90, 0.62, 1.00), (1.00, 0.74, 1.00),
    ]

    static func strength(_ hue: Double) -> (s: Double, v: Double) {
        let h = hue - hue.rounded(.down)
        for (a, b) in zip(strengths, strengths.dropFirst()) where h <= b.h {
            let t = b.h > a.h ? (h - a.h) / (b.h - a.h) : 0
            return (a.s + (b.s - a.s) * t, a.v + (b.v - a.v) * t)
        }
        return (0.74, 1)
    }

    /// The colour a new stop starts as: the last one moved a step round the
    /// wheel, so a second stop makes a gradient you can see at once rather
    /// than a paler copy of the first. A grey gets a lighter grey.
    static func next(after last: Stop?) -> Stop {
        guard let last else { return plain.colors[0] }
        let (h, s, v) = last.hsb
        guard s > 0.12 else { return last.mixed(.white, 0.35) }
        return Stop(hue: (h + 0.09).truncatingRemainder(dividingBy: 1), saturation: s, brightness: v)
    }

    /// What the editor calls it, beside the Theme caption.
    var kind: String { image != nil ? "Picture" : colors.count > 1 ? "Gradient" : "Colour" }

    /// Graphite: no colour at all.
    static let plain = SpaceTheme(colors: [Stop(r: 0.62, g: 0.62, b: 0.64)], intensity: 0.34)

    /// The hue the rest of the app knows the space by — the dot, the picker,
    /// the split's outline. Nil when the theme has no colour worth naming.
    var hue: Double? {
        guard let first = colors.max(by: { $0.hsb.s < $1.hsb.s }), first.hsb.s > 0.12 else { return nil }
        return first.hsb.h
    }

    /// The column's own colour for one stop. In the light: pulled from white
    /// by the intensity, then dimmed — the sum Arc's vibrant sidebar comes
    /// to over a white desktop. In the dark: the same hue, deep and quiet.
    func ground(_ stop: Stop, dark: Bool) -> Stop {
        if dark {
            let (h, s, _) = stop.hsb
            return Stop(hue: h, saturation: min(1, s * 0.8), brightness: 0.17 + 0.09 * intensity)
        }
        return Stop.white.mixed(stop, 0.8 * intensity).scaled(0.96)
    }

    /// One colour standing for the whole column: what a flat surface beside
    /// it (the split's gutter, a popover's arrow) should be.
    func flat(dark: Bool) -> Color {
        guard let first = colors.first else { return Palette.ground }
        let sum = colors.dropFirst().reduce(first) { $0.mixed($1, 0.5) }
        return ground(sum, dark: dark).color
    }

    /// The colours the backdrop runs through.
    func grounds(dark: Bool) -> [Color] { colors.map { ground($0, dark: dark).color } }

    /// Arc's theme for a space — `customInfo.windowTheme` in its sidebar
    /// file: a single colour or a gradient's colours, the intensity and the
    /// grain. Nil for a space Arc left on its default.
    static func arc(_ windowTheme: [String: Any]?) -> SpaceTheme? {
        func dig(_ value: Any?, _ keys: [String]) -> Any? {
            keys.reduce(value) { ($0 as? [String: Any])?[$1] }
        }
        guard let colour = dig(windowTheme, ["background", "single", "_0", "style", "color", "_0"]) as? [String: Any] else { return nil }
        func stop(_ raw: Any?) -> Stop? {
            guard let raw = raw as? [String: Any], (raw["alpha"] as? Double ?? 1) > 0.05,
                  let r = raw["red"] as? Double, let g = raw["green"] as? Double, let b = raw["blue"] as? Double else { return nil }
            return Stop(r: r, g: g, b: b)
        }
        var body: [String: Any]?
        var stops: [Stop] = []
        if let single = dig(colour, ["blendedSingleColor", "_0"]) as? [String: Any] {
            body = single
            stops = [stop(single["color"])].compactMap { $0 }
        } else if let gradient = dig(colour, ["blendedGradient", "_0"]) as? [String: Any] {
            body = gradient
            // The base colours run the gradient; an overlay colour that is
            // actually there is Arc's third stop.
            stops = ((gradient["baseColors"] as? [Any] ?? []) + (gradient["overlayColors"] as? [Any] ?? [])).compactMap(stop)
        }
        guard !stops.isEmpty else { return nil }
        let modifiers = body?["modifiers"] as? [String: Any]
        return SpaceTheme(colors: Array(stops.prefix(3)),
                          intensity: modifiers?["intensityFactor"] as? Double ?? 0.8,
                          grain: modifiers?["noiseFactor"] as? Double ?? 0)
    }

    /// Arc's icon for a space: its emoji, when it has one.
    static func arcIcon(_ iconType: [String: Any]?) -> String? {
        guard let emoji = iconType?["emoji_v2"] as? String, !emoji.isEmpty else { return nil }
        return emoji
    }

    /// Where a theme's picture is kept.
    static func file(_ name: String) -> URL { Store.file("themes").appendingPathComponent(name) }

    /// A picture chosen in the editor, copied in so the theme owns it —
    /// taken down to at most `largest` pixels on its long side and kept as
    /// a JPEG. The column is 300pt wide; a 6K desktop picture is 20 MB of
    /// HEIC that would be decoded whole on the main thread at first draw
    /// and held in memory for good. A file ImageIO cannot read is copied
    /// as it is and left to NSImage.
    static func adopt(image source: URL, largest: Int = 2800) -> String? {
        let folder = Store.file("themes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
           let small = CGImageSourceCreateThumbnailAtIndex(reader, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: largest,
           ] as CFDictionary) {
            let name = UUID().uuidString + ".jpg"
            if let writer = CGImageDestinationCreateWithURL(file(name) as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(writer, small, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
                if CGImageDestinationFinalize(writer) { return name }
            }
        }
        let name = UUID().uuidString + "." + (source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased())
        do {
            try FileManager.default.copyItem(at: source, to: file(name))
            return name
        } catch {
            return nil
        }
    }
}

/// The column's ground: the theme's colour, gradient or picture, and its grain.
struct ThemeBackdrop: View {
    let theme: SpaceTheme
    let dark: Bool

    var body: some View {
        ZStack {
            colour
            if let name = theme.image, let picture = ThemeBackdrop.picture(name) {
                GeometryReader { geo in
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                // A neutral veil first — white in the light, black in the
                // dark — so the picture's own darks (or lights) are pulled
                // towards the ground the ink was chosen for: over a photo's
                // shadowed band the brown titles were going under. It greys
                // the picture less than more colour would.
                (dark ? Color.black.opacity(0.3) : Color.white.opacity(0.22))
                // The colour stays on the picture, thinly, so the ink that is
                // right for the colour stays right over it — thin enough that
                // a vivid picture keeps its colour; deeper in the dark, where
                // light ink needs the picture held down.
                colour.opacity(dark ? 0.35 : 0.15)
            }
            if theme.grain > 0.01 {
                Image(nsImage: ThemeBackdrop.noise)
                    .resizable(resizingMode: .tile)
                    // Overlay, round a middle grey: the grain lightens and
                    // darkens by the same amount, so it is grain on a dark
                    // column too rather than a lift (plus-lighter) or a
                    // shadow (multiply). At full strength it is still the
                    // column you see, not the noise.
                    .opacity(min(1, theme.grain) * 0.45)
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var colour: some View {
        let stops = theme.grounds(dark: dark)
        if stops.count > 1 {
            LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            theme.flat(dark: dark)
        }
    }

    private static var pictures: [String: NSImage] = [:]

    static func picture(_ name: String) -> NSImage? {
        if let seen = pictures[name] { return seen }
        guard let image = NSImage(contentsOf: SpaceTheme.file(name)) else { return nil }
        pictures[name] = image
        return image
    }

    /// A small tile of grey noise round the middle, made once.
    static let noise: NSImage = {
        let side = 96
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<(side * side) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            // 96…159: the top six bits of the step. (150 plus seven bits ran
            // past 255 and wrapped to black specks.)
            let v = UInt8(96 + Int(seed >> 58))
            bytes[i * 4] = v
            bytes[i * 4 + 1] = v
            bytes[i * 4 + 2] = v
            bytes[i * 4 + 3] = 255
        }
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        if let provider = CGDataProvider(data: Data(bytes) as CFData),
           let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        }
        return image
    }()
}
