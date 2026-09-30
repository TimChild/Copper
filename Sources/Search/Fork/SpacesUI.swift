import AppKit
import UniformTypeIdentifiers
import SwiftUI

// The space, as the column shows it — and the ways to manage it.
//
// The foot used to read as one truncated name and seven identical dots: the
// current space's name cut to a letter, every other space an 8pt circle in
// a colour you could not name, and rename / colour / profile / delete hidden
// behind a right-click on a dot. Arc labels the space at the top of its
// column and draws icons, not dots, at the foot; this does the same, and puts
// the management two clicks away at most:
//
// - `SpaceHeader`: a title row under the traffic lights — the space's mark,
//   its name in full, a chevron. Click it for the space menu; hover shows
//   how many tabs it holds.
// - `SpaceStrip`: every space a 22pt chip at the foot — emoji, symbol or
//   first letter in the space's own colour; the current one on the column's
//   paper-white pill, the way the live row is. Hover names it at once; drag
//   reorders; a plus makes a space and opens its editor straight away.
// - `SpaceEditor`: one popover for name, icon, colour and profile, with
//   Delete at the bottom — and Delete asks first, and can keep the tabs.

// MARK: - the mark

/// What stands for a space: its emoji, its symbol, or its first letter, in
/// the space's own colour.
struct SpaceGlyph: View {
    let space: Space
    let size: CGFloat
    let dark: Bool
    /// The letter or symbol's colour; the space's own mark colour by default.
    var ink: Color?
    /// Arc's way: the icon on its own, filling its square, and a small dot
    /// for a space that has no icon — never a letter.
    var bare = false

    var body: some View {
        let tint = SpaceTint(space: space, dark: dark)
        Group {
            if let emoji = space.emoji {
                Text(emoji).font(.system(size: size * (bare ? 0.9 : 0.6)))
            } else if let symbol = space.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * (bare ? 0.78 : 0.48), weight: .semibold))
                    .foregroundStyle(ink ?? tint.mark)
            } else if bare {
                Circle()
                    .fill(ink ?? tint.mark)
                    .frame(width: size * 0.42, height: size * 0.42)
            } else {
                Text(space.letter)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(ink ?? tint.mark)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Which space has its editor open, and from where — the header, or its
/// chip at the foot, so the popover comes from the thing that was clicked.
@MainActor
final class SpaceEditing: ObservableObject {
    static let shared = SpaceEditing()
    @Published var space: UUID?
    @Published var atStrip = false

    func open(_ id: UUID, atStrip: Bool) {
        self.atStrip = atStrip
        space = id
    }

    func close() { space = nil }

    /// The editor for a space, drawn off screen on a popover's ground — for
    /// the bench, which can't keep a popover open in a browser that isn't
    /// in front (the same trick as the extensions menu's picture).
    static func picture(of id: UUID, in browser: Browser) -> NSBitmapImageRep? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let host = NSHostingView(rootView: SpaceEditor(browser: browser, id: id)
            .background(Color(nsColor: dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.98, alpha: 1)))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSApp.effectiveAppearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: picture)
        return picture
    }
}

// MARK: - the header

/// The title row: which space this column is. Under the lights, above the
/// favourites — the one label the column was missing.
struct SpaceHeader: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var spaces = Spaces.shared
    @ObservedObject private var editing = SpaceEditing.shared
    @Environment(\.colorScheme) private var scheme
    @State private var over = false

    var body: some View {
        let space = spaces.space
        let tint = SpaceTint(space: space, dark: scheme == .dark)
        Menu {
            SpaceMenu(browser: browser, space: space, fromStrip: false)
        } label: {
            // Arc's: the space's icon where a row's mark goes and its name in
            // the theme's own colour, first thing under the favourites.
            HStack(spacing: 10) {
                SpaceGlyph(space: space, size: 16, dark: scheme == .dark, ink: tint.muted, bare: true)
                Text(space.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if over {
                    let n = spaces.count(of: space.id, in: browser)
                    Text("\(n) tab\(n == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(tint.faint)
                        .transition(.opacity)
                }
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint.muted)
                    .frame(width: 16)
                    .opacity(over ? 1 : 0)
            }
            .padding(.leading, SideBar.rowInset)
            .padding(.trailing, 8)
            .frame(height: SideBar.row)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(over ? tint.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { over = $0 }
        .help("\(space.title) — click for the space menu")
        .popover(isPresented: editorShowing(space.id), arrowEdge: .bottom) {
            SpaceEditor(browser: browser, id: space.id)
        }
        .animation(Motion.quick, value: over)
        .animation(Motion.glide, value: spaces.current)
    }

    private func editorShowing(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { editing.space == id && !editing.atStrip },
            set: { if !$0, editing.space == id { editing.close() } }
        )
    }
}

// MARK: - the strip at the foot of the column

struct SpaceStrip<Tools: View>: View {
    @ObservedObject var browser: Browser
    /// The column's own small doors — bookmarks, extensions. They share the
    /// strip's row, the way Arc's do.
    @ViewBuilder var tools: () -> Tools
    @ObservedObject private var spaces = Spaces.shared
    @ObservedObject private var editing = SpaceEditing.shared
    @Environment(\.colorScheme) private var scheme
    @State private var hovering: UUID?
    /// How wide the row of chips actually is, against how wide it wants to
    /// be — when the second is larger the row scrolls, and says so with a
    /// soft edge instead of a chip cut in half.
    @State private var roomForChips: CGFloat = 0

    /// A chip picked up to be moved — the same shape as the favourites' drag.
    @State private var dragging: UUID?
    @State private var from = 0
    @State private var travel: CGFloat = 0

    private var step: CGFloat { SpaceChip.size + SpaceChip.gap }

    private var tint: SpaceTint { SpaceTint(space: spaces.space, dark: scheme == .dark) }

    /// Every space as a chip, the current one lifted; a plus; the doors.
    /// When the chips outgrow the room, the row of them scrolls sideways
    /// with the current one kept in view — no chip ever shrinks to a dot
    /// and no name is ever cut to a letter.
    /// Arc's foot: the library door at the left, every space's icon in the
    /// middle — the current one in colour, the rest quiet — and a plus at
    /// the right.
    var body: some View {
        HStack(spacing: 0) {
            tools()
            Spacer(minLength: 4)
            chips
            Spacer(minLength: 4)
            plus
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .overlayPreferenceValue(ChipFrames.self) { frames in label(frames) }
        .animation(Motion.glide, value: spaces.current)
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpaceChip.gap) {
                    ForEach(Array(spaces.all.enumerated()), id: \.element.id) { index, space in
                        chip(space, index: index)
                    }
                }
                .padding(.vertical, 1)
                .coordinateSpace(name: "chips")
                .animation(Motion.settle, value: spaces.all.map(\.id))
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: CGFloat(spaces.all.count) * step)
            .background(GeometryReader { geo in
                Color.clear.preference(key: StripRoom.self, value: geo.size.width)
            })
            .onPreferenceChange(StripRoom.self) { roomForChips = $0 }
            .mask(overflowing ? AnyView(SpaceStrip.fade) : AnyView(Rectangle()))
            .onChange(of: spaces.current) { _, id in
                withAnimation(Motion.glide) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(spaces.current, anchor: .center) }
        }
    }

    private var overflowing: Bool { roomForChips + 1 < CGFloat(spaces.all.count) * step }

    /// The row runs out under a soft edge at both ends, the way the column's
    /// two blocks of rows do.
    private static var fade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func chip(_ space: Space, index: Int) -> some View {
        let held = dragging == space.id
        return SpaceChip(space: space, current: space.id == spaces.current, dark: scheme == .dark,
                         over: hovering == space.id, ink: tint.ink)
            .id(space.id)
            .anchorPreference(key: ChipFrames.self, value: .bounds) { [space.id: $0] }
            .offset(x: held ? travel - CGFloat(index - from) * step : 0)
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 8, y: 2)
            .contentShape(Rectangle())
            .onTapGesture { spaces.select(space.id, in: browser) }
            .gesture(reorder(space, index: index))
            .onHover { over in hovering = over ? space.id : (hovering == space.id ? nil : hovering) }
            .help(space.title)
            .contextMenu { SpaceMenu(browser: browser, space: space, fromStrip: true) }
            .popover(isPresented: editorShowing(space.id), arrowEdge: .top) {
                SpaceEditor(browser: browser, id: space.id)
            }
    }

    private func editorShowing(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { editing.space == id && editing.atStrip },
            set: { if !$0, editing.space == id { editing.close() } }
        )
    }

    /// Pick a chip up and the others make way, one step per chip's width —
    /// `pinReorder` in Side.swift, along one axis.
    private func reorder(_ space: Space, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("chips"))
            .onChanged { value in
                if dragging != space.id {
                    dragging = space.id
                    from = index
                }
                travel = value.translation.width
                let moved = Int((travel / step).rounded())
                let target = min(max(0, from + moved), spaces.all.count - 1)
                if target != index {
                    withAnimation(Motion.settle) { spaces.move(space.id, to: target) }
                }
            }
            .onEnded { _ in
                withAnimation(Motion.settle) {
                    dragging = nil
                    travel = 0
                }
            }
    }

    /// The hovered space's name, at once, above its chip — not a tooltip a
    /// second later. Kept inside the column's edges.
    @ViewBuilder
    private func label(_ frames: [UUID: Anchor<CGRect>]) -> some View {
        GeometryReader { geo in
            if let id = hovering, dragging == nil, let anchor = frames[id],
               let space = spaces.all.first(where: { $0.id == id }) {
                let rect = geo[anchor]
                let text = Text(space.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tint.pill))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 6, y: 2)
                    .fixedSize()
                // Roughly half the label's width, so it stays in the column.
                let half = CGFloat(min(space.title.count, 28)) * 3.4 + 10
                text
                    .position(x: min(max(half, rect.midX), geo.size.width - half), y: rect.minY - 16)
                    .transition(.opacity.combined(with: .offset(y: 3)))
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.quick, value: hovering)
    }

    /// A space, and its editor open at once, so it gets a name, an icon and
    /// a colour instead of being "Space 9".
    private var plus: some View {
        Button {
            let id = spaces.add(in: browser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { editing.open(id, atStrip: true) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(tint.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Space")
    }
}

/// How much room the row of chips was given.
private struct StripRoom: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Where each chip is, for the hover label.
private struct ChipFrames: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One space at the foot: its mark on a soft square of its own colour. The
/// current one sits on the column's paper-white pill instead — the same
/// thing the live row wears, so the column has one word for "this one".
struct SpaceChip: View {
    let space: Space
    let current: Bool
    let dark: Bool
    let over: Bool
    /// The column's ink, for the dot a space without an icon wears.
    var ink: Color? = nil

    static let size: CGFloat = 28
    static let gap: CGFloat = 5

    /// Arc's: the current space's icon in full colour, every other one
    /// greyed and thinned until the pointer lands on it.
    var body: some View {
        SpaceGlyph(space: space, size: 17, dark: dark, ink: ink, bare: true)
            .saturation(current || over ? 1 : 0)
            .opacity(current ? 1 : (over ? 0.8 : 0.42))
            .frame(width: SpaceChip.size, height: SpaceChip.size)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(over && !current ? Color.black.opacity(dark ? 0 : 0.05) : .clear)
            )
            .animation(Motion.quick, value: over)
            .animation(Motion.quick, value: current)
    }
}

// MARK: - the menu

/// The space menu — from the header, the chip's right-click, and ⌘K.
struct SpaceMenu: View {
    @ObservedObject var browser: Browser
    let space: Space
    let fromStrip: Bool
    @ObservedObject private var spaces = Spaces.shared

    private var index: Int { spaces.all.firstIndex { $0.id == space.id } ?? 0 }

    var body: some View {
        Button("Edit Space…") { SpaceEditing.shared.open(space.id, atStrip: fromStrip) }
        Button("New Tab in Space") {
            if space.id != spaces.current { spaces.select(space.id, in: browser) }
            browser.newTab()
        }
        if let tab = browser.active, space.id != spaces.current {
            Button("Move Current Tab Here") { spaces.move(tab, to: space.id, in: browser) }
        }
        Divider()
        Button("Move Left") { withAnimation(Motion.settle) { spaces.nudge(space.id, by: -1) } }
            .disabled(index == 0)
        Button("Move Right") { withAnimation(Motion.settle) { spaces.nudge(space.id, by: 1) } }
            .disabled(index == spaces.all.count - 1)
        Divider()
        Menu("Colour") {
            ForEach(SpaceColour.allCases) { colour in
                Button { spaces.tint(space.id, hue: colour.hue) } label: {
                    Label {
                        Text(colour.name)
                    } icon: {
                        Image(systemName: SpaceColour.nearest(space.hue) == colour ? "checkmark.circle.fill" : "circle.fill")
                            .foregroundStyle(SpaceTint(hue: colour.hue, dark: false).swatch)
                    }
                }
            }
        }
        Menu("Profile") {
            Button { spaces.profile(space.id, named: nil) } label: {
                Label("Shared", systemImage: space.profile == nil ? "checkmark" : "")
            }
            ForEach(spaces.profiles, id: \.self) { name in
                Button { spaces.profile(space.id, named: name) } label: {
                    Label(name, systemImage: space.profile == name ? "checkmark" : "")
                }
            }
            Divider()
            Button("New Profile…") { SpaceEditing.shared.open(space.id, atStrip: fromStrip) }
        }
        if spaces.all.count > 1 {
            Divider()
            Button("Delete Space…", role: .destructive) { SpaceDelete.ask(space.id, in: browser) }
        }
    }
}

// MARK: - the editor

/// Name, icon, colour, profile — and Delete — in one popover. Every change
/// lands as it is made: the header re-titles and the column re-tints while
/// the popover is still up, so the choice can be seen before it is kept.
struct SpaceEditor: View {
    @ObservedObject var browser: Browser
    let id: UUID
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var emoji = ""
    @State private var profileDraft = ""
    @State private var namingProfile = false
    @FocusState private var focus: Field?

    private enum Field { case name, emoji, profile }

    /// The symbols on offer. Enough to cover the spaces people actually
    /// make; anything else is an emoji away.
    static let symbols = [
        "house", "briefcase", "book", "hammer", "gamecontroller", "cart", "heart",
        "star", "flask", "graduationcap", "music.note", "airplane", "paintbrush", "leaf", "terminal",
    ]

    private var space: Space? { spaces.all.first { $0.id == id } }
    private var tint: SpaceTint { space.map { SpaceTint(space: $0, dark: scheme == .dark) } ?? SpaceTint(hue: nil, dark: scheme == .dark) }

    var body: some View {
        if let space {
            VStack(alignment: .leading, spacing: 12) {
                // Named, so the popover says what it is before the field
                // does — and the field reads as the name, not a search box.
                section("Edit Space") { name }
                section("Icon") { icons(space) }
                section("Colour", trailing: space.theme == nil ? SpaceColour.nearest(space.hue).name : "Custom") { colours(space) }
                section("Theme", trailing: space.theme?.kind) { ThemeEditor(id: id) }
                section("Profile") { profile(space) }
                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.top, 2)
                footer
            }
            .padding(14)
            .frame(width: 296)
            .onAppear {
                draft = space.name
                focus = .name
            }
        }
    }

    private var name: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .focused($focus, equals: .name)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash))
            .onChange(of: draft) { _, now in
                let trimmed = now.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { spaces.rename(id, to: trimmed) }
            }
            .onSubmit { SpaceEditing.shared.close() }
    }

    /// A caption over its content; `trailing` names the current choice at
    /// the far end — the colour's name, so a swatch is never just a colour.
    private func section<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                if let trailing {
                    Spacer(minLength: 6)
                    Text(trailing).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .transition(.opacity)
                        .animation(Motion.quick, value: trailing)
                }
            }
            content()
        }
    }

    /// The letter, the symbols, and a field for an emoji.
    private func icons(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), alignment: .leading, spacing: 4) {
                tile(selected: space.icon == nil) {
                    Text(space.letter).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint.mark)
                } act: { spaces.icon(id, nil); emoji = "" }
                ForEach(SpaceEditor.symbols, id: \.self) { symbol in
                    tile(selected: space.symbol == symbol) {
                        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint.mark)
                    } act: { spaces.icon(id, "sf:" + symbol); emoji = "" }
                }
            }
            HStack(spacing: 6) {
                if let shown = space.emoji, space.icon != nil {
                    Text(shown).font(.system(size: 14)).frame(width: 22)
                }
                TextField("or type an emoji", text: $emoji)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focus, equals: .emoji)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.wash))
                    .onChange(of: emoji) { _, now in
                        // The first emoji typed is the icon; the rest is noise.
                        guard let first = now.first(where: { $0.unicodeScalars.first?.properties.isEmojiPresentation == true
                            || $0.unicodeScalars.contains { $0.properties.isEmojiModifierBase } }) else { return }
                        spaces.icon(id, String(first))
                        if now != String(first) { emoji = String(first) }
                    }
            }
        }
    }

    private func tile<Content: View>(selected: Bool, @ViewBuilder _ content: () -> Content, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            content()
                .frame(width: 30, height: 28)
                // The chosen tile wears the column's own colour. The column's
                // live pill is a translucent white meant to sit over that
                // colour; a popover is not over the column, so on its white
                // the pill would vanish and leave only the ring.
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? tint.ground : Palette.wash.opacity(0.6)))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tint.dot.opacity(0.8), lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The named swatches. The chosen one carries a check; Graphite is a
    /// real choice here, not the absence of one.
    private func colours(_ space: Space) -> some View {
        // Ten 22pt swatches in the popover's 268pt: 4pt between them.
        HStack(spacing: 4) {
            ForEach(SpaceColour.allCases) { colour in
                let chosen = space.theme == nil && SpaceColour.nearest(space.hue) == colour
                Button { spaces.tint(id, hue: colour.hue) } label: {
                    ZStack {
                        Circle().fill(SpaceTint(hue: colour.hue, dark: scheme == .dark).swatch)
                        if chosen {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(colour.name)
                .scaleEffect(chosen ? 1.12 : 1)
                .animation(Motion.quick, value: chosen)
            }
        }
    }

    /// Shared, one of the names in use, or a new one.
    private func profile(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Profile", selection: Binding(
                get: { namingProfile ? "\u{0}new" : (space.profile ?? "") },
                set: { value in
                    if value == "\u{0}new" { namingProfile = true; profileDraft = ""; focus = .profile }
                    else { namingProfile = false; spaces.profile(id, named: value.isEmpty ? nil : value) }
                }
            )) {
                Text("Shared").tag("")
                ForEach(spaces.profiles, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New Profile…").tag("\u{0}new")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 180, alignment: .leading)
            if namingProfile {
                TextField("Profile name", text: $profileDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focus, equals: .profile)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.wash))
                    .onSubmit {
                        let name = profileDraft.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        spaces.profile(id, named: name)
                        namingProfile = false
                    }
            }
            // What a profile is, in one line: the cookie jar. A page that is
            // already up keeps the jar it was built with.
            Text("Its own sign-ins and cookies, shared with spaces of the same profile. Pages opened from now on use it.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if spaces.all.count > 1 {
                Button("Delete Space…") { SpaceDelete.ask(id, in: browser) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Done") { SpaceEditing.shared.close() }
                .keyboardShortcut(.defaultAction)
                .font(.system(size: 12))
        }
    }
}

// MARK: - delete

/// Deleting asks first — and offers to keep the tabs.
@MainActor
enum SpaceDelete {
    /// What the sheet last did, for the bench.
    private(set) static var last = ""
    /// The sheet while it is up, so `bench spaces answer` can press a button.
    private(set) static var asking: NSAlert?

    /// The sheet's words, for the bench — a picture of a sheet needs the
    /// screen-recording grant the window picture does not.
    static var describe: [String: Any] {
        guard let alert = asking else { return [:] }
        return ["message": alert.messageText, "detail": alert.informativeText, "buttons": alert.buttons.map(\.title)]
    }

    /// `bench spaces answer close|move|cancel`: the sheet's button of that
    /// meaning, pressed. False when no sheet is up or it has no such button.
    static func answer(_ choice: String) -> Bool {
        guard let alert = asking else { return false }
        let titles = alert.buttons.map(\.title)
        let index: Int?
        switch choice {
        case "close", "delete": index = titles.firstIndex { $0.hasPrefix("Close Tabs") || $0 == "Delete" }
        case "move", "keep": index = titles.firstIndex { $0.hasPrefix("Move Tabs") }
        default: index = titles.firstIndex { $0 == "Cancel" }
        }
        guard let index else { return false }
        alert.buttons[index].performClick(nil)
        return true
    }

    static func ask(_ id: UUID, in browser: Browser) {
        let spaces = Spaces.shared
        guard spaces.all.count > 1, let space = spaces.all.first(where: { $0.id == id }) else { return }
        let count = spaces.count(of: id, in: browser)
        let neighbour = spaces.neighbour(of: id)
        // The editor's popover goes first, or the sheet lands on top of it.
        SpaceEditing.shared.close()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(space.title)”?"
        switch count {
        case 0: alert.informativeText = "It has no tabs."
        case 1: alert.informativeText = "Its one tab will close."
        default: alert.informativeText = "Its \(count) tabs will close."
        }
        if count > 0 {
            alert.addButton(withTitle: "Close Tabs & Delete").hasDestructiveAction = true
            if let neighbour {
                alert.addButton(withTitle: "Move Tabs to “\(neighbour.title)” & Delete")
            }
        } else {
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        }
        alert.addButton(withTitle: "Cancel")

        let decide: (NSApplication.ModalResponse) -> Void = { response in
            asking = nil
            switch response {
            case .alertFirstButtonReturn:
                spaces.remove(id, in: browser)
                last = "deleted"
            case .alertSecondButtonReturn where count > 0 && neighbour != nil:
                spaces.remove(id, in: browser, movingTabsTo: neighbour?.id)
                last = "moved"
            default:
                last = "cancelled"
            }
        }
        asking = alert
        DispatchQueue.main.async {
            if let window = Links.window, window.isVisible {
                alert.beginSheetModal(for: window, completionHandler: decide)
            } else {
                decide(alert.runModal())
            }
        }
    }
}

/// A space's own theme, past the named colours: one colour or a gradient of
/// up to three, how strongly the column wears it, a grain, and a picture
/// under it all. Every change lands at once, so the column behind the
/// popover is the preview.
struct ThemeEditor: View {
    let id: UUID
    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme

    private var space: Space? { spaces.all.first { $0.id == id } }
    private var look: SpaceTheme { space?.look ?? .plain }

    private func set(_ change: (inout SpaceTheme) -> Void) {
        var theme = look
        change(&theme)
        spaces.theme(id, theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The theme itself, drawn: what the column will be.
            ThemeBackdrop(theme: look, dark: scheme == .dark)
                .frame(height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))

            HStack(spacing: 6) {
                ForEach(Array(look.colors.enumerated()), id: \.offset) { index, stop in
                    ColorPicker("", selection: Binding(
                        get: { stop.color },
                        set: { new in
                            guard let picked = SpaceTheme.Stop(new) else { return }
                            set { if $0.colors.indices.contains(index) { $0.colors[index] = picked } }
                        }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    // Its own well, at its own size: a narrower frame only
                    // pushed the well out past the popover's edge.
                    .fixedSize()
                }
                if look.colors.count < 3 {
                    round("plus", help: "Add a colour — a gradient") { set { $0.colors.append(SpaceTheme.next(after: $0.colors.last)) } }
                }
                if look.colors.count > 1 {
                    round("minus", help: "One colour fewer") { set { $0.colors.removeLast() } }
                }
                Spacer(minLength: 4)
                Button(look.image == nil ? "Image…" : "Change Image…") { choose() }
                    .controlSize(.small)
                if look.image != nil {
                    Button { set { $0.image = nil } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.muted)
                        .help("No image")
                }
            }

            slider("Intensity", value: look.intensity, range: 0.2...1) { v in set { $0.intensity = v } }
            slider("Grain", value: look.grain, range: 0...1) { v in set { $0.grain = v } }
        }
    }

    /// A small round door beside the colour wells.
    private func round(_ symbol: String, help: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.muted)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Palette.wash))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, _ change: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 58, alignment: .leading)
            Slider(value: Binding(get: { value }, set: change), in: range).controlSize(.small)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "A picture for the space's column"
        guard panel.runModal() == .OK, let url = panel.url, let name = SpaceTheme.adopt(image: url) else { return }
        set { $0.image = name }
    }
}
