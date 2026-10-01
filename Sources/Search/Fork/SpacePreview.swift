import AppKit
import SwiftUI

// A space's column, drawn live but not for touching.
//
// A swipe between spaces shows the space you are heading for coming in
// beside the one you are leaving. That space's rows are not on screen — its
// tabs are parked (Spaces.parkedRow) — and putting them on screen just to
// show them would select a tab and wake a page. Earlier versions took a
// picture of each column as it was left and slid the picture in: a space
// not visited since launch had no picture and came in blank, the picture
// was stale, and taking one cost tens of milliseconds at the moment the
// fingers started to move.
//
// So instead the arriving column is drawn from the parked tabs themselves:
// the favourites, the space's name and its rows, with the same measures and
// the same parts as the real column (RowMark, SpaceGlyph, the pill, the
// folder glyphs — see Side.swift and GroupsUI.swift), in the arriving
// space's own ink, on a clear ground so the one live ground (SpaceGround)
// shows through. Only the rows that would be in view are made — the list is
// planned once with every row's height, and the view holds the few that
// fall inside the column — scrolled to where the real column will land, so
// the hand-over to the real column on a commit is a crossfade between two
// renderings of the same rows in the same places.
//
// A preview takes no clicks and no hover, has no menus and no drags; it
// does read each tab it shows, so a title or an icon that arrives while it
// is up is drawn.

/// What a preview draws: a space, the tabs its column has, which is live,
/// how far it is scrolled, and the rows planned out with their heights.
@MainActor
struct SpacePreviewModel {
    let space: Space
    let tabs: [Tab]
    let active: Tab.ID?
    /// How far the rows are scrolled: the live column's offset for the
    /// space on screen, or where the real column would land for a parked
    /// one (see `landing`).
    let scroll: CGFloat
    /// Every row the column would draw, top to bottom, with where it sits.
    let items: [Placed]
    /// The rows' whole height, paddings included — the scroll's document.
    let content: CGFloat
    /// Enough to tell two models apart without comparing every row: the
    /// preview is redrawn only when this changes.
    let signature: Int

    enum Item {
        case header
        case head(TabGroup, depth: Int, label: String)
        case tab(Tab, group: TabGroup?, depth: Int)
        case divider
        case newTab
    }

    struct Placed: Identifiable {
        let id: String
        let item: Item
        let y: CGFloat
        let height: CGFloat
    }

    /// The column's measures, as `SideBar` has them.
    static let row = SideBar.row
    static let gap = SideBar.gap
    static let inset = SideBar.inset
    static let rowInset = SideBar.rowInset
    static let pinGap: CGFloat = 8
    /// The rows' padding inside the scroll: 2 above, 12 below.
    static let above: CGFloat = 2
    static let below: CGFloat = 12
    /// The hairline between Saved and Today: one point and six each side.
    static let divider: CGFloat = 13

    var pinned: [Tab] { tabs.filter { $0.pin != nil } }

    /// The favourites' grid for a column `width` wide — `SideBar`'s sums:
    /// three to a row, four on a wide column; cells split the width; a
    /// cell is wide and short.
    static func pins(width: CGFloat) -> (columns: Int, width: CGFloat, height: CGFloat) {
        let columns = width >= 400 ? 4 : 3
        let available = width - 2 * inset - CGFloat(columns - 1) * pinGap
        let cell = max(20, available / CGFloat(columns))
        return (columns, cell, min(48, max(34, cell * 0.52)))
    }

    /// How tall the favourites block is, with its gap under it; nothing
    /// when there are none.
    static func pinsHeight(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let grid = pins(width: width)
        let rows = (count + grid.columns - 1) / grid.columns
        return CGFloat(rows) * grid.height + CGFloat(rows - 1) * pinGap + 8
    }

    /// The space on screen, as its column stands: `browser.tabs`, the live
    /// row, the scroll where it is. What slides out after a switch.
    @MainActor
    static func live(_ space: Space, in browser: Browser, width: CGFloat, height: CGFloat) -> SpacePreviewModel {
        let scroll = SideScrollElasticity.column?.contentView.bounds.minY ?? 0
        return make(space: space, tabs: browser.tabs, active: browser.activeID, scroll: scroll, width: width, height: height)
    }

    /// A parked space, as its column would be if it came on screen now:
    /// its parked tabs, its own live row, scrolled where the real column
    /// will scroll to. Nil for the space on screen (its rows are not parked).
    @MainActor
    static func parked(_ space: Space, width: CGFloat, height: CGFloat) -> SpacePreviewModel? {
        let spaces = Spaces.shared
        guard space.id != spaces.current, let tabs = spaces.parkedRow(space.id) else { return nil }
        return make(space: space, tabs: tabs, active: spaces.parkedActive(space.id), scroll: nil, width: width, height: height)
    }

    /// Plan the rows and, for a parked space, where the column lands.
    @MainActor
    static func make(space: Space, tabs: [Tab], active: Tab.ID?, scroll given: CGFloat?, width: CGFloat, height: CGFloat) -> SpacePreviewModel {
        let groups = Groups.shared
        let sections = Sections.shared
        let loose = tabs.filter { $0.pin == nil }
        let kept = loose.filter { sections.isSaved($0) }
        let today = loose.filter { !sections.isSaved($0) }

        var items: [Placed] = []
        var y = above
        func put(_ id: String, _ item: Item, _ height: CGFloat) {
            if !items.isEmpty { y += gap }
            items.append(Placed(id: id, item: item, y: y, height: height))
            y += height
        }
        func put(rows: [FolderRow]) {
            for row in rows {
                switch row {
                case .head(let group, _, _, let depth, let label):
                    put(row.id, .head(group, depth: depth, label: label), SpacePreviewModel.row)
                case .tab(let tab, _, let group, let depth):
                    put(row.id, .tab(tab, group: group, depth: depth), SpacePreviewModel.row)
                }
            }
        }
        // The header is the first window's; spaces, and so swipes, are too.
        put("header", .header, row)
        put(rows: FolderTree.plan(kept, homeless: groups.homeless(in: space.id)))
        if !today.isEmpty { put("divider", .divider, divider) }
        put("newtab", .newTab, row)
        put(rows: FolderTree.plan(today))
        let content = y + below

        // Where the real column lands. Its scroll view is the same one
        // before and after the switch (only the rows change), so it keeps
        // its offset as far as the new rows allow, then brings the live row
        // into view by the least it takes (SideBar.show, with no anchor):
        // to the top edge if it is above, the bottom if it is below.
        let viewport = max(1, height - pinsHeight(count: tabs.filter { $0.pin != nil }.count, width: width))
        let scroll: CGFloat
        if let given {
            scroll = given
        } else {
            let old = SideScrollElasticity.column?.contentView.bounds.minY ?? 0
            var off = min(max(0, old), max(0, content - viewport))
            if let live = items.first(where: { if case .tab(let tab, _, _) = $0.item { return tab.id == active } else { return false } }) {
                if live.y < off { off = live.y } else if live.y + live.height > off + viewport { off = live.y + live.height - viewport }
            }
            scroll = max(0, off.rounded())
        }

        var hasher = Hasher()
        hasher.combine(space.id)
        hasher.combine(space.look)
        hasher.combine(space.icon)
        hasher.combine(space.name)
        hasher.combine(active)
        hasher.combine(scroll)
        for tab in tabs {
            hasher.combine(tab.id)
            hasher.combine(tab.pin)
            hasher.combine(sections.isSaved(tab))
            hasher.combine(groups.membership[tab.id])
        }
        for group in groups.all where group.space == space.id {
            hasher.combine(group.id)
            hasher.combine(group.name)
            hasher.combine(group.collapsed)
            hasher.combine(group.hue)
        }
        return SpacePreviewModel(space: space, tabs: tabs, active: active, scroll: scroll, items: items, content: content,
                                 signature: hasher.finalize())
    }

    /// The rows that fall inside a column `height` tall at this scroll.
    func visible(width: CGFloat, height: CGFloat) -> [Placed] {
        let viewport = height - SpacePreviewModel.pinsHeight(count: pinned.count, width: width)
        return items.filter { $0.y + $0.height > scroll && $0.y < scroll + viewport }
    }
}

/// The column, drawn from a model. Equatable on the model's signature, so
/// the slide can place it anew every frame without SwiftUI looking inside.
struct SpacePreview: View, Equatable {
    let model: SpacePreviewModel
    let width: CGFloat
    let height: CGFloat
    let dark: Bool

    /// Whether the two neighbours of the space on screen are kept drawn
    /// (hidden) while nothing moves, so the first frame of a swipe has
    /// nothing to build. Measured: see `bench`; CHANGELOG has the numbers.
    @MainActor static var premount = true

    static func == (a: SpacePreview, b: SpacePreview) -> Bool {
        a.model.signature == b.model.signature && a.width == b.width && a.height == b.height && a.dark == b.dark
    }

    var body: some View {
        let tint = SpaceTint(space: model.space, dark: dark)
        let pinned = model.pinned
        VStack(alignment: .leading, spacing: 0) {
            if !pinned.isEmpty {
                Pins(tabs: pinned, active: model.active, tint: tint, width: width)
                    .padding(.horizontal, SpacePreviewModel.inset)
                    .padding(.bottom, 8)
            }
            Rows(model: model, tint: tint, dark: dark, width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .mask(SideBar.fade)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
    }

    // MARK: - the favourites

    /// `SideBar.pinned`, as a grid of fixed cells left-aligned: so many to a
    /// row, a half-empty last row holding its ground.
    private struct Pins: View {
        let tabs: [Tab]
        let active: Tab.ID?
        let tint: SpaceTint
        let width: CGFloat

        var body: some View {
            let grid = SpacePreviewModel.pins(width: width)
            let rows = stride(from: 0, to: tabs.count, by: grid.columns).map { Array(tabs[$0..<min($0 + grid.columns, tabs.count)]) }
            VStack(alignment: .leading, spacing: SpacePreviewModel.pinGap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: SpacePreviewModel.pinGap) {
                        ForEach(row) { tab in
                            Pin(tab: tab, live: tab.id == active, tint: tint, width: grid.width, height: grid.height)
                        }
                    }
                }
            }
        }
    }

    /// `PinSquare`, less its field, its clicks and its hover.
    private struct Pin: View {
        @ObservedObject var tab: Tab
        let live: Bool
        let tint: SpaceTint
        let width: CGFloat
        let height: CGFloat

        var body: some View {
            let radius = min(12, min(width, height) * 0.28)
            let mark = max(14, min(20, height * 0.46))
            RowMark(icon: tab.icon, letter: tab.pin ?? tab.monogram, tint: tint, size: mark)
                .frame(width: width, height: height)
                .background {
                    if live {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(tint.pill)
                            .overlay {
                                RoundedRectangle(cornerRadius: radius, style: .continuous)
                                    .strokeBorder(tint.rim, lineWidth: 1)
                            }
                            .shadow(color: tint.lift, radius: 5, y: 1.5)
                    } else {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(tint.square)
                    }
                }
        }
    }

    // MARK: - the rows

    /// Only the rows in view, each put where the plan says, inside the
    /// scroll's own paddings. A stack with offsets rather than a scroll
    /// view: nothing here scrolls, and a row off the top costs nothing.
    private struct Rows: View {
        let model: SpacePreviewModel
        let tint: SpaceTint
        let dark: Bool
        let width: CGFloat
        let height: CGFloat

        var body: some View {
            ZStack(alignment: .topLeading) {
                ForEach(model.visible(width: width, height: height)) { placed in
                    line(placed.item)
                        .frame(height: placed.height)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(y: placed.y - model.scroll)
                }
            }
            .padding(.horizontal, SpacePreviewModel.inset)
        }

        @ViewBuilder
        private func line(_ item: SpacePreviewModel.Item) -> some View {
            switch item {
            case .header:
                Header(space: model.space, tint: tint, dark: dark)
            case .head(let group, let depth, let label):
                Head(group: group, label: label, tint: tint)
                    .padding(.leading, CGFloat(depth) * Folders.step)
            case .tab(let tab, let group, let depth):
                Row(tab: tab, live: tab.id == model.active, tint: tint)
                    .padding(.leading, CGFloat(depth) * Folders.step)
                    .overlay(alignment: .leading) {
                        // The hair of the folder's colour under its rows (GroupedRows).
                        if let group, depth > 0 {
                            RoundedRectangle(cornerRadius: 0.5)
                                .fill((group.hue.map { Color(hue: $0, saturation: 0.55, brightness: 0.75) } ?? tint.dot).opacity(0.2))
                                .frame(width: 1)
                                .padding(.vertical, 3)
                                .offset(x: CGFloat(depth - 1) * Folders.step + SpacePreviewModel.rowInset + 7.5)
                        }
                    }
            case .divider:
                Rectangle()
                    .fill(tint.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, SpacePreviewModel.rowInset)
                    .padding(.vertical, 6)
            case .newTab:
                // `Quiet`, at rest.
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 16)
                    Text("New Tab")
                        .font(.system(size: 15))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tint.muted.opacity(0.82))
                .padding(.leading, SpacePreviewModel.rowInset)
                .frame(height: SpacePreviewModel.row)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// `SpaceHeader`, at rest: the glyph where a mark goes, the name in the
    /// theme's colour, and the room its hidden menu dots take.
    private struct Header: View {
        let space: Space
        let tint: SpaceTint
        let dark: Bool

        var body: some View {
            HStack(spacing: 0) {
                SpaceGlyph(space: space, size: 16, dark: dark, ink: tint.muted, bare: true)
                    .frame(width: 24, height: 24)
                    .padding(.leading, -4)
                    .padding(.trailing, 6)
                HStack(spacing: 10) {
                    Text(space.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Color.clear.frame(width: 16)
                }
                .frame(height: SpacePreviewModel.row)
                .frame(maxWidth: .infinity)
            }
            .padding(.leading, SpacePreviewModel.rowInset)
            .padding(.trailing, 8)
            .frame(height: SpacePreviewModel.row)
            .frame(maxWidth: .infinity)
        }
    }

    /// `GroupHead`, at rest: the folder glyph and the name.
    private struct Head: View {
        let group: TabGroup
        let label: String
        let tint: SpaceTint

        private var colour: Color {
            guard let hue = group.hue ?? tint.hue else { return Palette.muted }
            return Color(hue: hue, saturation: tint.dark ? 0.52 : 0.82, brightness: tint.dark ? 0.82 : 0.66)
        }

        private var paper: Color {
            tint.dark ? Color(hue: group.hue ?? tint.hue ?? 0, saturation: 0.10, brightness: 0.90)
                      : Color.white.opacity(0.92)
        }

        var body: some View {
            HStack(spacing: 0) {
                ZStack {
                    if group.collapsed {
                        Image(systemName: "folder.fill").foregroundStyle(colour)
                    } else {
                        Image(systemName: "folder.fill").foregroundStyle(paper)
                        Image(systemName: "folder").foregroundStyle(colour)
                        Image(systemName: "ellipsis")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(colour)
                            .offset(y: 1.5)
                    }
                }
                .font(.system(size: 15))
                .frame(width: 16, height: 16)
                .padding(.trailing, 10)
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(tint.ink)
                Spacer(minLength: 2)
            }
            .padding(.leading, SpacePreviewModel.rowInset)
            .frame(height: SpacePreviewModel.row)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `SideRow`, at rest: mark, title, the sound badge, and the live
    /// row's pill. No hover cross, no agents' hands, no drag.
    private struct Row: View {
        @ObservedObject var tab: Tab
        let live: Bool
        let tint: SpaceTint

        var body: some View {
            HStack(spacing: 10) {
                if !tab.isBlank {
                    RowMark(icon: tab.icon, letter: tab.monogram, tint: tint, size: 16)
                        .opacity(live ? 1 : 0.9)
                }
                if tab.bench {
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(tint.ink.opacity(0.7))
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(tint.ink.opacity(0.7))
                }
                Text(tab.label)
                    .font(.system(size: 15, weight: live ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(tint.ink)
                Spacer(minLength: 2)
                ZStack {
                    if tab.noisy {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(tint.muted)
                    }
                }
                .frame(width: 15, height: 15)
            }
            .padding(.leading, SpacePreviewModel.rowInset)
            .padding(.trailing, 8)
            .frame(height: SpacePreviewModel.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if live {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(tint.pill)
                        GeometryReader { geo in
                            Rectangle()
                                .fill(tint.ink.opacity(0.055))
                                .frame(width: geo.size.width * tab.reading)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(tint.rim, lineWidth: 1)
                    }
                    .shadow(color: tint.lift, radius: 4, y: 1)
                }
            }
        }
    }

    // MARK: - the bench

    /// `spaces preview N|NAME` — what a preview of that space costs to make
    /// off screen at the column's size: the rows planned, the ones in view,
    /// where it scrolls to, and milliseconds for SwiftUI to build and lay
    /// the view out and then to draw it once. `spaces preview premount
    /// on|off` chooses whether the neighbours are kept drawn at rest.
    @MainActor
    static func bench(_ words: [String], find: (String) -> UUID?, in browser: Browser) -> [String: Any] {
        if words.first == "premount" {
            if words.count > 1 { premount = words[1] == "on" }
            SpaceSlide.shared.anchor.generation += 1
            return ["premount": premount]
        }
        let slide = SpaceSlide.shared
        let spaces = Spaces.shared
        guard let key = words.first, let id = find(key), let space = spaces.all.first(where: { $0.id == id }) else {
            return ["error": "spaces preview N|NAME | premount on|off"]
        }
        let width = max(1, slide.column.width), height = max(1, slide.band.height)
        guard width > 1, height > 1, let window = Links.window, let root = window.contentView else { return ["error": "no column on screen"] }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let planned = CACurrentMediaTime()
        guard let model = id == spaces.current
            ? SpacePreviewModel.live(space, in: browser, width: width, height: height)
            : SpacePreviewModel.parked(space, width: width, height: height) else { return ["error": "no rows for \(space.name)"] }
        let made = CACurrentMediaTime()
        // Into the window, off its edge, so SwiftUI has the environment it
        // draws the real one with; taken out again before anything shows.
        let host = NSHostingView(rootView: SpacePreview(model: model, width: width, height: height, dark: dark))
        host.sizingOptions = []
        host.frame = NSRect(x: -width - 10_000, y: 0, width: width, height: height)
        root.addSubview(host)
        let mounted = CACurrentMediaTime()
        host.layoutSubtreeIfNeeded()
        let laid = CACurrentMediaTime()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
        let drawn = CACurrentMediaTime()
        host.removeFromSuperview()
        func ms(_ a: CFTimeInterval, _ b: CFTimeInterval) -> Double { ((b - a) * 10000).rounded() / 10 }
        return ["space": space.name, "rows": model.items.count, "visible": model.visible(width: width, height: height).count,
                "pinned": model.pinned.count, "scroll": Double(model.scroll), "content": Double(model.content),
                "plan": ms(planned, made), "build": ms(made, mounted), "layout": ms(mounted, laid), "draw": ms(laid, drawn),
                "total": ms(planned, drawn), "premount": premount, "width": Double(width), "height": Double(height)]
    }
}

/// Which previews are kept, and which one is on its way in: changed only
/// when that changes, so the stack that holds them is not asked to think
/// about them on every frame of a slide.
@MainActor
final class PreviewAnchor: ObservableObject {
    /// The space whose neighbours are kept drawn — the one the current
    /// slide set off from, so the arriving preview stays through the
    /// settle; nil for the space on screen.
    @Published var home: UUID?
    /// The space a swipe is heading for, drawn whether or not it is kept.
    @Published var arriving: UUID?
    /// Bumped to have the stack look again (the column scrolled, the
    /// premount setting changed).
    @Published var generation = 0
    /// The column's scroll the previews were planned against.
    var scrollSeen: CGFloat = 0
}

/// The previews over the column: the two neighbours of the space on screen,
/// kept drawn and hidden while nothing moves (`SpacePreview.premount`), or
/// the one a swipe is heading for; each placed by the slide, frame by frame,
/// without this view being asked again.
struct SpacePreviewStack: View, Equatable {
    let width: CGFloat
    let height: CGFloat
    let dark: Bool
    @ObservedObject private var spaces = Spaces.shared
    @ObservedObject private var groups = Groups.shared
    @ObservedObject private var sections = Sections.shared
    @ObservedObject private var anchor = SpaceSlide.shared.anchor

    init(width: CGFloat, height: CGFloat, dark: Bool) {
        self.width = width
        self.height = height
        self.dark = dark
    }

    static func == (a: SpacePreviewStack, b: SpacePreviewStack) -> Bool {
        a.width == b.width && a.height == b.height && a.dark == b.dark
    }

    var body: some View {
        anchor.scrollSeen = SideScrollElasticity.column?.contentView.bounds.minY ?? 0
        return ForEach(wanted, id: \.id) { space in
            if let model = SpacePreviewModel.parked(space, width: width, height: height) {
                PreviewPlaced(space: space.id) {
                    SpacePreview(model: model, width: width, height: height, dark: dark).equatable()
                }
            }
        }
    }

    /// The neighbours of `home`, and whatever is arriving. Never the space
    /// on screen while nothing moves — its rows are the live column's.
    private var wanted: [Space] {
        _ = anchor.generation
        let all = spaces.all
        let home = anchor.home ?? spaces.current
        var out: [Space] = []
        if SpacePreview.premount, let i = all.firstIndex(where: { $0.id == home }) {
            if i > 0 { out.append(all[i - 1]) }
            if i + 1 < all.count { out.append(all[i + 1]) }
        }
        if let arriving = anchor.arriving, !out.contains(where: { $0.id == arriving }),
           let space = all.first(where: { $0.id == arriving }) {
            out.append(space)
        }
        return out.filter { $0.id != home }
    }
}

/// One preview, where the slide wants it this frame: coming in beside the
/// live column while the fingers are down, fading out over the live column
/// (now the same space's) after a commit, and otherwise out of sight.
private struct PreviewPlaced<Content: View>: View {
    let space: UUID
    @ViewBuilder let content: () -> Content
    @ObservedObject private var slide = SpaceSlide.shared

    init(space: UUID, @ViewBuilder content: @escaping () -> Content) {
        self.space = space
        self.content = content
    }

    var body: some View {
        let arriving = slide.sliding && slide.to?.id == space
        let x = arriving ? slide.way * slide.column.width * (1 - slide.phase) : 0
        let shown: Double = !arriving ? 0 : slide.dragging ? 1 : slide.landing ? slide.fade : 0
        content()
            .offset(x: x)
            .opacity(shown)
    }
}
