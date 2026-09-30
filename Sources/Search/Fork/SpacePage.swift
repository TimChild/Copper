import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The Space page: everything about one space on one card over the window.
//
// The editor used to be a 296pt popover off the header or a chip: name,
// icon, a row of swatches, a compact theme strip, profile. It had no room
// for what a theme had grown into — a picture to pick again, a scene, blur,
// a tone — and the column behind it was the only preview, which is no
// preview at all for a space you are not in. So a click on the current
// space's icon (at the foot, or in the title row) opens this instead, the
// same kind of card the Settings and History panels are: a live column on
// the left, drawn with the space's real `SpaceTint`, and the controls on
// the right. Every change lands as it is made, as the popover's did.

/// The page over the browser window, while `SpaceEditing` names a space.
/// Mounted once, over everything, from the window's root view.
struct SpacePageLayer: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var editing = SpaceEditing.shared
    @ObservedObject private var spaces = Spaces.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let id = editing.space, spaces.all.contains(where: { $0.id == id }) {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .onTapGesture { editing.close() }
                        .transition(.opacity)
                    SpacePage(browser: browser, id: id,
                              height: min(SpacePage.size.height, geo.size.height - 48))
                        .id(id)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .animation(Motion.settle, value: editing.space)
    }
}

struct SpacePage: View {
    @ObservedObject var browser: Browser
    let id: UUID
    var height: CGFloat = SpacePage.size.height
    /// Laid out whole, without the scroll — for the bench's picture, which
    /// would otherwise only ever show the top of the controls.
    var unrolled = false

    @ObservedObject private var spaces = Spaces.shared
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var emoji = ""
    @State private var profileDraft = ""
    @State private var namingProfile = false
    /// The Look tab picked before the theme can say so itself: Picture,
    /// chosen with no picture yet, is still a colour until one is picked.
    @State private var picked: Kind?
    /// The preview's appearance when it is not the window's — to see the
    /// space in the other mode without switching the whole Mac.
    @State private var previewNight: Bool?
    @FocusState private var focus: Field?

    private enum Field { case name, emoji, profile }

    static let size = CGSize(width: 660, height: 780)
    private static let rail: CGFloat = 236

    /// The symbols on offer: enough for the spaces people make; anything
    /// else is an emoji away.
    static let symbols = [
        "house", "briefcase", "book", "hammer", "gamecontroller", "cart", "heart", "star",
        "flask", "graduationcap", "music.note", "airplane", "paintbrush", "leaf", "terminal", "globe",
        "camera", "film", "bolt", "flame", "moon", "sun.max", "cup.and.saucer", "dumbbell", "chart.bar", "folder",
    ]

    enum Kind: String, CaseIterable, Identifiable {
        case colour, gradient, picture, animated
        var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        init(_ theme: SpaceTheme) {
            self = theme.motion != nil ? .animated : theme.image != nil ? .picture : theme.colors.count > 1 ? .gradient : .colour
        }
    }

    private var space: Space? { spaces.all.first { $0.id == id } }
    private var look: SpaceTheme { space?.look ?? .plain }
    private var night: Bool { scheme == .dark }
    /// For the tiles on the card: the space's colour, but the card's ink —
    /// the column's tone must not turn a white card's marks white.
    private var tint: SpaceTint { SpaceTint(theme: look, dark: night).offColumn }
    private var kind: Kind { picked ?? Kind(look) }

    private func set(_ change: (inout SpaceTheme) -> Void) {
        var theme = look
        change(&theme)
        spaces.theme(id, theme)
    }

    var body: some View {
        if let space {
            HStack(spacing: 0) {
                preview(space)
                Rectangle().fill(Palette.hairline).frame(width: 1)
                VStack(spacing: 0) {
                    header(space)
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    if unrolled {
                        controls(space)
                    } else {
                        ScrollView(.vertical) { controls(space) }
                            .scrollIndicators(.automatic)
                    }
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    footer
                }
            }
            .frame(width: SpacePage.size.width, height: unrolled ? nil : height)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 34, y: 12)
            .onAppear { draft = space.name }
        }
    }

    // MARK: - the preview

    /// The column as it will be: the real backdrop and the real tint, under
    /// a few rows standing in for tabs, with Light / Dark under it.
    private func preview(_ space: Space) -> some View {
        let shown = previewNight ?? night
        return VStack(spacing: 12) {
            SpaceColumnPreview(space: space, all: spaces.all, night: shown)
                .frame(maxHeight: unrolled ? 520 : .infinity)
            Picker("", selection: Binding(get: { shown }, set: { previewNight = $0 == night ? nil : $0 })) {
                Text("Light").tag(false)
                Text("Dark").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 140)
        }
        .padding(16)
        .frame(width: SpacePage.rail)
        .frame(maxHeight: .infinity)
        .background(Palette.wash.opacity(0.5))
    }

    // MARK: - the controls

    private func header(_ space: Space) -> some View {
        HStack(spacing: 12) {
            SpaceGlyph(space: space, size: 22, dark: night, ink: tint.mark, bare: true)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.ground))
            VStack(alignment: .leading, spacing: 1) {
                Text(space.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                let n = spaces.count(of: id, in: browser)
                Text("\(n) tab\(n == 1 ? "" : "s") · \(space.profile ?? "Shared profile") · \(look.kind)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { SpaceEditing.shared.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Palette.wash))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close   esc")
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private func controls(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Name") { name }
            section("Icon", trailing: space.symbol ?? (space.icon == nil ? (space.emoji == nil ? "None" : "From the name") : "Emoji")) { icons(space) }
            section("Look", trailing: kind == Kind(look) ? nil : "pick a picture below") {
                Picker("", selection: Binding(get: { kind }, set: choose(kind:))) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            section(kind == .picture ? "Tint" : "Colours", trailing: colourName(space)) { colours }
            if kind == .picture { section("Picture") { pictures } }
            if kind == .animated { section("Scene", trailing: AnimatedBackdrop.styles.first { $0.id == look.motion?.style }?.name) { scenes } }
            section("Adjust") { adjust }
            section("Profile") { profile(space) }
        }
        .padding(20)
    }

    /// A caption over its content; `trailing` names the current choice.
    private func section<Content: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.8))
                if let trailing {
                    Spacer(minLength: 6)
                    Text(trailing).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var name: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .focused($focus, equals: .name)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.wash))
            .onChange(of: draft) { _, now in
                let trimmed = now.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { spaces.rename(id, to: trimmed) }
            }
            .onSubmit { SpaceEditing.shared.close() }
    }

    // MARK: icon

    /// None (the dot Arc draws for a space without one), the symbols, and
    /// a field for an emoji.
    private func icons(_ space: Space) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 5), count: 9), alignment: .leading, spacing: 5) {
                tile(selected: space.icon == nil) {
                    Circle().fill(tint.mark).frame(width: 7, height: 7)
                } act: { spaces.icon(id, nil); emoji = "" }
                .help("No icon — a dot, or the emoji the name starts with")
                ForEach(SpacePage.symbols, id: \.self) { symbol in
                    tile(selected: space.symbol == symbol) {
                        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint.mark)
                    } act: { spaces.icon(id, "sf:" + symbol); emoji = "" }
                    .help(symbol)
                }
            }
            HStack(spacing: 8) {
                if let shown = space.emoji, space.icon != nil {
                    Text(shown).font(.system(size: 17)).frame(width: 26)
                }
                TextField("Type or paste an emoji", text: $emoji)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focus, equals: .emoji)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash))
                    .onChange(of: emoji) { _, now in
                        // The first emoji typed is the icon; the rest is noise.
                        guard let first = now.first(where: { $0.unicodeScalars.first?.properties.isEmojiPresentation == true
                            || $0.unicodeScalars.contains { $0.properties.isEmojiModifierBase } }) else { return }
                        spaces.icon(id, String(first))
                        if now != String(first) { emoji = String(first) }
                    }
                Button("Emoji…") {
                    focus = .emoji
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                }
                .controlSize(.small)
            }
        }
    }

    private func tile<Content: View>(selected: Bool, @ViewBuilder _ content: () -> Content, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            content()
                .frame(width: 34, height: 30)
                // The chosen tile wears the column's own colour; the others
                // the card's wash.
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? tint.ground : Palette.wash.opacity(0.7)))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tint.dot.opacity(0.8), lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: look

    /// A tab of the Look picker, applied. Colour keeps the first colour and
    /// drops the rest; Gradient makes sure there are two; Picture keeps the
    /// colours as the tint over it; Animated starts the first scene, or the
    /// one it had.
    private func choose(kind new: Kind) {
        picked = nil
        switch new {
        case .colour:
            set { $0.motion = nil; $0.image = nil; $0.colors = Array($0.colors.prefix(1)) }
        case .gradient:
            set {
                $0.motion = nil
                $0.image = nil
                if $0.colors.count < 2 { $0.colors.append(SpaceTheme.next(after: $0.colors.last)) }
            }
        case .picture:
            set { $0.motion = nil }
            if look.image == nil { picked = .picture }
        case .animated:
            set { $0.motion = SpaceTheme.Motion(style: $0.motion?.style ?? AnimatedBackdrop.styles.first?.id ?? "ribbons",
                                                speed: $0.motion?.speed ?? 1) }
        }
    }

    private func colourName(_ space: Space) -> String {
        guard look.colors.count == 1 else { return "\(look.colors.count) colours" }
        let named = SpaceColour.allCases.first { theme(for: $0).colors == look.colors }
        return named?.name ?? "Custom"
    }

    /// A named colour's own theme — what `Spaces.tint` gives a space.
    private func theme(for colour: SpaceColour) -> SpaceTheme {
        colour.hue.map(SpaceTheme.hue) ?? .plain
    }

    /// The wells, a door to add or drop a stop, and the named colours.
    private var colours: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Array(look.colors.enumerated()), id: \.offset) { index, stop in
                    ColorPicker("", selection: Binding(
                        get: { stop.color },
                        set: { new in
                            guard let picked = SpaceTheme.Stop(new) else { return }
                            set { if $0.colors.indices.contains(index) { $0.colors[index] = picked } }
                        }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
                }
                // A plain colour is one stop by definition; more is Gradient.
                if look.colors.count < 3, kind != .colour {
                    round("plus", help: "Add a colour") { set { $0.colors.append(SpaceTheme.next(after: $0.colors.last)) } }
                }
                if look.colors.count > (kind == .gradient ? 2 : 1) {
                    round("minus", help: "One colour fewer") { set { $0.colors.removeLast() } }
                }
                Spacer(minLength: 0)
            }
            // The named colours set the first stop and leave the rest of the
            // look alone. A space that comes back to exactly a named colour's
            // theme goes back to being that hue, as the menu's Colour does.
            HStack(spacing: 7) {
                ForEach(SpaceColour.allCases) { colour in
                    let named = theme(for: colour)
                    let chosen = look.colors.first == named.colors.first
                    Button {
                        var next = look
                        if next.colors.isEmpty { next.colors = named.colors } else { next.colors[0] = named.colors[0] }
                        if next == named { spaces.tint(id, hue: colour.hue) } else { spaces.theme(id, next) }
                    } label: {
                        ZStack {
                            Circle().fill(SpaceTint(hue: colour.hue, dark: night).swatch)
                            if chosen {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(colour.name)
                    .scaleEffect(chosen ? 1.12 : 1)
                    .animation(Motion.quick, value: chosen)
                }
            }
        }
    }

    /// Choose… for a new one; the pictures already in `themes/`, newest
    /// first, to reuse; and a way back to none.
    private var pictures: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(look.image == nil ? "Choose…" : "Change…") { choosePicture() }
                    .controlSize(.small)
                if look.image != nil {
                    Button("Clear") { set { $0.image = nil }; picked = .picture }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            let recent = SpacePictures.recent()
            if !recent.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(54), spacing: 7), count: 6), alignment: .leading, spacing: 7) {
                    ForEach(recent, id: \.self) { name in
                        Button {
                            set { $0.image = name; $0.motion = nil }
                            picked = nil
                        } label: {
                            Group {
                                if let thumb = SpacePictures.thumbnail(name) {
                                    Image(nsImage: thumb).resizable().scaledToFill()
                                } else {
                                    Palette.wash
                                }
                            }
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(look.image == name ? tint.dot : Palette.hairline, lineWidth: look.image == name ? 2 : 1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Pictures you pick are kept here to use again.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    /// The scenes by name, and how fast the chosen one moves.
    private var scenes: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(AnimatedBackdrop.styles, id: \.id) { style in
                    let on = look.motion?.style == style.id
                    Button {
                        set { $0.motion = SpaceTheme.Motion(style: style.id, speed: $0.motion?.speed ?? 1) }
                    } label: {
                        Text(style.name)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? tint.mark : Palette.ink.opacity(0.8))
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(Capsule().fill(on ? tint.ground : Palette.wash.opacity(0.7)))
                            .overlay { if on { Capsule().strokeBorder(tint.dot.opacity(0.8), lineWidth: 1.5) } }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            slider("Speed", value: look.motion?.speed ?? 1, range: 0...2,
                   readout: String(format: "%.1f×", look.motion?.speed ?? 1)) { v in
                set { $0.motion?.speed = v }
            }
        }
    }

    /// Intensity, grain, blur and the tone.
    private var adjust: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Intensity", value: look.intensity, range: 0.2...1) { v in set { $0.intensity = v } }
            slider("Grain", value: look.grain, range: 0...1) { v in set { $0.grain = v } }
            // Blur has nothing to soften on a flat colour or a gradient.
            slider("Blur", value: look.blur, range: 0...1) { v in set { $0.blur = v } }
                .disabled(kind == .colour || kind == .gradient)
                .opacity(kind == .colour || kind == .gradient ? 0.45 : 1)
                .help(kind == .colour || kind == .gradient ? "Blur softens a picture or a scene" : "")
            tone
        }
    }

    /// Dark to bright with Normal in the middle. The middle is sticky — a
    /// drag that ends near it lands on exactly as-is, which is hard to hit
    /// by hand on a bare slider.
    private var tone: some View {
        HStack(alignment: .top, spacing: 10) {
            label("Tone").padding(.top, 3)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { look.tone }, set: { v in set { $0.tone = abs(v) < 0.08 ? 0 : v } }), in: -1...1)
                    .controlSize(.small)
                HStack {
                    Text("Dark")
                    Spacer()
                    Text("Normal").fontWeight(look.tone == 0 ? .semibold : .regular)
                    Spacer()
                    Text("Bright")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
            }
            Text(look.tone == 0 ? "—" : String(format: "%@%d", look.tone < 0 ? "−" : "+", Int((abs(look.tone) * 100).rounded())))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: 38, alignment: .trailing)
                .padding(.top, 3)
        }
    }

    private func label(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 64, alignment: .leading)
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, readout: String? = nil,
                        _ change: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            label(title)
            Slider(value: Binding(get: { value }, set: change), in: range).controlSize(.small)
            Text(readout ?? "\(Int((value * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .frame(width: 38, alignment: .trailing)
        }
    }

    /// A small round door beside the colour wells.
    private func round(_ symbol: String, help: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.wash))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "A picture for the space's column"
        guard panel.runModal() == .OK, let url = panel.url, let name = SpaceTheme.adopt(image: url) else { return }
        set { $0.image = name; $0.motion = nil }
        picked = nil
    }

    // MARK: profile and the foot

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
            .frame(maxWidth: 200, alignment: .leading)
            if namingProfile {
                TextField("Profile name", text: $profileDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focus, equals: .profile)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash))
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
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if spaces.all.count > 1 {
                Button("Delete Space…") { SpaceDelete.ask(id, in: browser) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Done") { SpaceEditing.shared.close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }
}

// MARK: - the preview column

/// A column in miniature: the lights, an address, three favourites, the
/// space's title, a live row and a few resting ones, New Tab and the foot's
/// chips — every one drawn with the tint the real column uses, so what the
/// preview says about legibility is what the column will do.
struct SpaceColumnPreview: View {
    let space: Space
    let all: [Space]
    let night: Bool

    var body: some View {
        let tint = SpaceTint(space: space, dark: night)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 8, height: 8)
                }
                Spacer()
                ForEach(["chevron.left", "chevron.right", "arrow.clockwise"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 9, weight: .semibold)).foregroundStyle(tint.ink.opacity(0.72))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.square)
                .frame(height: 26)
                .overlay(alignment: .leading) {
                    Text("copper.app").font(.system(size: 11)).foregroundStyle(tint.muted).padding(.leading, 9)
                }
                .padding(.horizontal, 8)

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(i == 0 ? tint.pill : tint.square)
                        .frame(height: 30)
                        .overlay { RowMark(icon: nil, letter: ["M", "C", "G"][i], tint: tint, size: 14) }
                }
            }
            .padding(8)

            HStack(spacing: 8) {
                SpaceGlyph(space: space, size: 13, dark: night, ink: tint.muted, bare: true)
                Text(space.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tint.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 28)

            row("Inbox", "I", tint: tint, live: true)
            row("Design review", "D", tint: tint)
            row("Reading list", "R", tint: tint)
            Rectangle().fill(tint.hairline).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 6)
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 10)).frame(width: 14)
                Text("New Tab").font(.system(size: 12))
            }
            .foregroundStyle(tint.muted)
            .padding(.horizontal, 14)
            .frame(height: 28)
            row("Today's page", "T", tint: tint)
            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "books.vertical").font(.system(size: 11)).foregroundStyle(tint.ink.opacity(0.72))
                Spacer(minLength: 2)
                ForEach(all.prefix(5)) { other in
                    SpaceChip(space: other, current: other.id == space.id, dark: night, over: false, ink: tint.ink)
                        .scaleEffect(0.78)
                        .frame(width: 22, height: 22)
                }
                Spacer(minLength: 2)
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(tint.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { tint.backdrop }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    private func row(_ title: String, _ letter: String, tint: SpaceTint, live: Bool = false) -> some View {
        HStack(spacing: 8) {
            RowMark(icon: nil, letter: letter, tint: tint, size: 14)
            Text(title)
                .font(.system(size: 12, weight: live ? .semibold : .regular))
                .foregroundStyle(live ? tint.ink : tint.ink.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            if live {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.pill)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.rim, lineWidth: 1))
                    .shadow(color: tint.lift, radius: 3, y: 1)
            }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - pictures to pick again

/// The pictures already copied into `themes/` — every one some space has
/// worn — newest first, with small thumbnails made once.
@MainActor
enum SpacePictures {
    private static var thumbs: [String: NSImage] = [:]

    static func recent(limit: Int = 12) -> [String] {
        let folder = Store.file("themes")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && !$0.lastPathComponent.hasPrefix(".") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(limit)
            .map(\.lastPathComponent)
    }

    /// 160 pixels on the long side, off ImageIO's thumbnailer rather than
    /// decoding the whole 2800-pixel picture for a 54pt square.
    static func thumbnail(_ name: String) -> NSImage? {
        if let seen = thumbs[name] { return seen }
        guard let source = CGImageSourceCreateWithURL(SpaceTheme.file(name) as CFURL, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: small, size: NSSize(width: small.width / 2, height: small.height / 2))
        thumbs[name] = image
        return image
    }
}
