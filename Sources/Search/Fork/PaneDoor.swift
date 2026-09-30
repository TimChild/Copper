import SwiftUI

// The panes beside the page — the agent's, Jev's timeline, the second half
// of a split — and the small doors in their headers.
//
// The doors used to be the glyph alone: a 10pt SF symbol in a plain button
// with no frame, so the cross that closes a pane had a hit target the size
// of the cross. This is the one control both panes draw instead — a real
// square, a wash under the pointer, the glyph unchanged — and beside it the
// one thing neither pane had: a way to put every pane away at once.

/// One glyph in a pane's header or toolbar. Quiet at rest, washed under the
/// pointer, and a square you can actually hit.
struct PaneDoor: View {
    let icon: String
    var help = ""
    /// Dimmed to nearly nothing when it has nowhere to go — a door that is
    /// not there is quieter than a door that is greyed out.
    var on = true
    /// The glyph's colour at rest; the ink under the pointer.
    var tint: Color = Palette.muted
    /// The square. 26 in a 38pt header; the split's 32pt bar takes 24.
    var size: CGFloat = 26
    let act: () -> Void

    @State private var over = false

    var body: some View {
        Button(action: on ? act : {}) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? (over ? Palette.ink : tint) : Palette.muted.opacity(0.3))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
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

/// What is open beside the page, and how to close it.
@MainActor
enum Panes {
    /// How many panes are open right now: the agent, Jev, the split.
    static var open: Int {
        (Agent.shared.open ? 1 : 0) + (Drive.shared.paneOpen ? 1 : 0) + (Split.shared.on ? 1 : 0)
    }

    /// Whether the "close all" door earns its place: only beside a second pane.
    static var several: Bool { open > 1 }

    /// ⌘⌥E, the menu, ⌘K, and the door in either header: everything beside
    /// the page goes. Jev's run is put away too unless it is still driving.
    static func closeAll(in browser: Browser) {
        Agent.shared.open = false
        let trace = Drive.shared
        if trace.live { trace.paneOpen = false } else { trace.dismiss() }
        Split.shared.close()
    }

    /// Escape, at the end of the app's ladder: the pane nearest the edge
    /// closes — Jev's, then the agent's — but only while the keyboard is in
    /// the browser window and not in a page, where Escape means something to
    /// the page. The split's halves are pages, so Escape never ends a split.
    static func escape(_ event: NSEvent, in browser: Browser) -> Bool {
        guard let window = event.window, window == Links.window else { return false }
        if let view = window.firstResponder as? NSView, LineKeys.page(of: view) != nil { return false }
        let trace = Drive.shared
        if trace.paneOpen {
            if trace.live { trace.paneOpen = false } else { trace.dismiss() }
            return true
        }
        if Agent.shared.open {
            Agent.shared.open = false
            return true
        }
        return false
    }
}
