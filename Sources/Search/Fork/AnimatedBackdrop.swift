import SwiftUI

// A living backdrop for the column: a three.js scene drawn in the theme's
// colours. CONTRACT STUB — the renderer lands in a later commit; until then
// this draws the still gradient so everything that uses it compiles.

struct AnimatedBackdrop: View {
    /// The scenes on offer, by the name `SpaceTheme.Motion.style` stores.
    static let styles: [(id: String, name: String)] = [
        ("ribbons", "Ribbons"), ("silk", "Silk"), ("aurora", "Aurora"), ("waves", "Waves"),
    ]

    let style: String
    /// The column colours (already `SpaceTheme.ground`-ed) the scene paints with.
    let colors: [Color]
    /// 0…2, 1 is the scene's own pace.
    let speed: Double
    /// 0…1, how soft the scene is drawn.
    let blur: Double
    let dark: Bool

    var body: some View {
        LinearGradient(colors: colors.count > 1 ? colors : colors + colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
