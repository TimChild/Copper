import AppKit
import SwiftUI

// Glance: rest the pointer on a folded trail for a moment and its pages come
// out beside the column as a small filmstrip — a picture of each page still
// awake (or left a moment ago), its mark and title otherwise. A card goes to
// its page. Moving away, Escape or a click anywhere else puts it away. It
// never builds or loads a page to show one.

/// The hover timing: 350 ms on a row before a Glance comes out, a short
/// grace on the way out so the pointer can cross from the row to the cards.
@MainActor
enum Glance {
    static let delay = 0.35
    private static var waiting: DispatchWorkItem?
    private static var closing: DispatchWorkItem?
    private static var overRow: UUID?
    private static var overCards = false

    static func hover(_ id: UUID, _ over: Bool) {
        let trails = Trails.shared
        if over {
            overRow = id
            closing?.cancel()
            // Already glancing at a neighbour: move straight across.
            if let showing = trails.glancing, showing != id {
                trails.glancing = id
                return
            }
            waiting?.cancel()
            let work = DispatchWorkItem { if overRow == id { trails.glancing = id } }
            waiting = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else if overRow == id {
            overRow = nil
            waiting?.cancel()
            later()
        }
    }

    static func cards(_ over: Bool) {
        overCards = over
        if over { closing?.cancel() } else { later() }
    }

    static func dismiss() {
        waiting?.cancel()
        closing?.cancel()
        overRow = nil
        overCards = false
        Trails.shared.glancing = nil
    }

    private static func later() {
        closing?.cancel()
        let work = DispatchWorkItem {
            guard overRow == nil, !overCards else { return }
            Trails.shared.glancing = nil
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }
}

/// The filmstrip itself, in the popover hanging off the row.
struct TrailGlance: View {
    @ObservedObject var browser: Browser
    let plan: Trails.Plan
    let tint: SpaceTint

    @ObservedObject private var thumbs = TrailThumbs.shared
    @State private var escape: Any?

    private static let card = CGSize(width: 176, height: 110)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: plan.searched ? "magnifyingglass" : "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Trails.ink(tint))
                Text(plan.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(plan.pages) { page in
                        GlanceCard(tab: page.tab, tint: tint, picture: thumbs.pictures[page.tab.id], live: page.tab.id == browser.activeID, size: TrailGlance.card) {
                            Glance.dismiss()
                            browser.select(page.tab)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(width: stripWidth, height: TrailGlance.card.height + 26)
        }
        .padding(14)
        .onHover { Glance.cards($0) }
        .onExitCommand { Glance.dismiss() }
        .onAppear {
            TrailThumbs.shared.want(plan.pages.map(\.tab))
            // Escape puts it away even while the window under it has the keys.
            escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, Trails.shared.glancing != nil else { return event }
                MainActor.assumeIsolated { Glance.dismiss() }
                return nil
            }
        }
        .onDisappear {
            if let escape { NSEvent.removeMonitor(escape) }
            escape = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Glance at \(plan.title)")
    }

    /// At most three and a half cards across; past that the strip scrolls.
    private var stripWidth: CGFloat {
        let shown = min(CGFloat(plan.pages.count), 3.5)
        return shown * TrailGlance.card.width + max(0, ceil(shown) - 1) * 10
    }

    private var subtitle: String {
        let pages = "\(plan.pages.count) page\(plan.pages.count == 1 ? "" : "s")"
        let gap = Date().timeIntervalSince(plan.used)
        guard gap > 90 else { return pages + " · just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return pages + " · " + formatter.localizedString(for: plan.used, relativeTo: Date())
    }
}

/// One page in the strip: its picture, or a quiet card with its mark, and
/// its title under it.
private struct GlanceCard: View {
    @ObservedObject var tab: Tab
    let tint: SpaceTint
    let picture: NSImage?
    let live: Bool
    let size: CGSize
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let picture {
                        Image(nsImage: picture)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height, alignment: .top)
                            .clipped()
                    } else {
                        Palette.wash
                        VStack(spacing: 7) {
                            RowMark(icon: tab.icon, letter: tab.monogram, tint: tint, size: 26)
                            if let host = (tab.pending ?? tab.address).map(SideAddress.host) {
                                Text(host)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 10)
                            }
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(live ? Palette.ink.opacity(0.55) : Palette.hairline, lineWidth: live ? 1.5 : 1)
                )
                .shadow(color: .black.opacity(hovering ? 0.14 : 0.06), radius: hovering ? 7 : 3, y: hovering ? 3 : 1)
                .scaleEffect(hovering ? 1.02 : 1)
                HStack(spacing: 5) {
                    RowMark(icon: tab.icon, letter: tab.monogram, tint: tint, size: 12)
                    Text(tab.label)
                        .font(.system(size: 11.5, weight: live ? .semibold : .regular))
                        .foregroundStyle(Palette.ink.opacity(0.88))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: size.width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.2, bounce: 0), value: hovering)
        .help(tab.label)
    }
}
