import SwiftUI

// How groups look in the column: Arc's folders. A header where a run of
// grouped tabs starts — chevron, folder glyph in the group's colour, the
// name, and the count only while it is shut — its rows stepped in under it,
// and, under a tab that has just landed, one line asking whether it belongs
// somewhere. Which folder sits inside which is read out of the names by
// `FolderTree` (Fork/Folders.swift). The rows themselves are upstream's
// SideRow, untouched; this only decides what goes between them and how far
// in each one starts.

struct GroupedRows: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var groups = Groups.shared
    @ObservedObject var grouper = Grouper.shared
    let pill: Namespace.ID
    let tint: SpaceTint
    /// The sidebar draws the loose list as two blocks (Saved, Today); each
    /// hands in the ids it owns and this draws only those.
    var only: Set<Tab.ID>? = nil
    /// Where this block starts in the whole loose list, so a drag inside it
    /// moves the tab to the right place in the row and not to the row's top.
    var offset = 0
    /// A row let go a clear step past the block's top (-1) or bottom (+1):
    /// the sidebar reads that as crossing the seam between Saved and Today.
    var crossed: ((Tab, Int) -> Void)? = nil

    @State private var dragging: Tab.ID?
    @State private var from = 0
    @State private var travel: CGFloat = 0

    static let row: CGFloat = 28
    static let gap: CGFloat = 2

    private var loose: [Tab] {
        browser.tabs.filter { $0.pin == nil && (only?.contains($0.id) ?? true) }
    }

    /// What the column draws, top to bottom: a header at the start of each
    /// run, then the run's rows — none of them, nor any folder inside it,
    /// while the folder is shut. Worked out by `FolderTree`.
    private var rows: [FolderRow] { FolderTree.plan(loose) }

    /// Rows the column shows beyond one per tab: a header for each folder,
    /// less the rows a folded one hides. For sizing a block before it is
    /// drawn (see SideBar.today).
    static func extraRows(in tabs: [Tab]) -> Int {
        let loose = tabs.filter { $0.pin == nil }
        return FolderTree.plan(loose).count - loose.count
    }

    var body: some View {
        VStack(spacing: GroupedRows.gap) {
            ForEach(rows) { row in
                switch row {
                case .head(let group, let count, _, let depth, let label):
                    GroupHead(browser: browser, group: group, count: count, label: label, tint: tint)
                        .padding(.leading, CGFloat(depth) * Folders.step)
                case .tab(let tab, let index, let group, let depth):
                    let step = GroupedRows.row + GroupedRows.gap
                    let held = dragging == tab.id
                    VStack(spacing: GroupedRows.gap) {
                        SideRow(
                            browser: browser,
                            tab: tab,
                            live: tab.id == browser.activeID,
                            tint: tint,
                            pill: pill,
                            close: { browser.close(tab) }
                        )
                        .padding(.leading, CGFloat(depth) * Folders.step)
                        // A hair of the folder's colour down the middle of
                        // its header's glyph, under the rows it holds. The
                        // step in is what says they are inside it; this
                        // only says which folder, once two are open at once.
                        .overlay(alignment: .leading) {
                            if let group, depth > 0 {
                                RoundedRectangle(cornerRadius: 0.5)
                                    .fill(folderTint(group).opacity(0.2))
                                    .frame(width: 1)
                                    .padding(.vertical, 3)
                                    .offset(x: CGFloat(depth - 1) * Folders.step + 13.5)
                            }
                        }
                        if let asked = grouper.suggestion, asked.tab == tab.id {
                            SuggestionChip(suggestion: asked)
                        } else if grouper.thinking == tab.id {
                            ThinkingChip()
                        }
                    }
                    .offset(y: held ? travel - CGFloat(index - from) * step : 0)
                    .zIndex(held ? 1 : 0)
                    .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
                    .gesture(reorder(tab: tab, index: index, step: step))
                }
            }
        }
        .coordinateSpace(name: "rows")
        .animation(Motion.quick, value: grouper.suggestion)
        .animation(Motion.quick, value: grouper.thinking)
        .onChange(of: browser.tabs.map(\.id)) { _, _ in
            groups.prune(keeping: browser.tabs + Spaces.shared.parkedTabs)
        }
    }

    /// A folder with no colour of its own wears the space's, as Arc's do.
    private func folderTint(_ group: TabGroup) -> Color {
        group.hue.map { Color(hue: $0, saturation: 0.55, brightness: 0.75) } ?? tint.dot
    }

    /// Upstream's reorder, unchanged but for the drop: a row let go inside
    /// another group's run joins it, and one dragged clear of its own leaves.
    private func reorder(tab: Tab, index: Int, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("rows"))
            .onChanged { value in
                if dragging != tab.id {
                    dragging = tab.id
                    from = index
                }
                travel = value.translation.height
                let moved = Int((travel / step).rounded())
                let target = min(max(0, from + moved), loose.count - 1)
                if target != index {
                    withAnimation(Motion.settle) {
                        browser.move(tab, to: offset + target + browser.pinnedCount)
                    }
                }
            }
            .onEnded { _ in
                // A whole row past the block's own end, not just over its
                // last line: the seam is crossed on purpose or not at all.
                let wanted = from + Int((travel / step).rounded())
                withAnimation(Motion.settle) {
                    dragging = nil
                    travel = 0
                }
                if wanted < -1 { crossed?(tab, -1) }
                else if wanted > loose.count { crossed?(tab, 1) }
                else { groups.settle(tab, in: browser) }
            }
    }
}

/// A folder's line: fold it, name it, colour it, make another inside it,
/// or let it go.
///
/// A folder is a row like any other row, and that is the whole of its
/// layout: the glyph sits in the row's own 16pt mark column and the name
/// starts where every title on the column starts, so a folder at the top
/// level is flush with the saved tabs around it and only the tabs *inside*
/// it step in — one mark's width, once per level. The chevron costs no
/// width at all: it takes the glyph's place under the pointer, which is
/// where Arc keeps its own, and rotates as the folder opens.
struct GroupHead: View {
    @ObservedObject var browser: Browser
    @ObservedObject var groups = Groups.shared
    let group: TabGroup
    let count: Int
    /// The part of the name below the folder it is in — `BuildrFi`, not
    /// `Misc › BuildrFi`.
    var label: String? = nil
    let tint: SpaceTint

    @State private var hovering = false
    @State private var renaming = false
    @State private var adding = false
    @State private var draft = ""

    /// A folder with no colour of its own wears the space's, as Arc's do.
    /// Deeper than the column it sits on, either way round: the folder is
    /// the one drawn thing in a row of photographed ones, and a wash of the
    /// ground's own hue would leave it a smudge among real favicons.
    private var colour: Color {
        guard let hue = group.hue ?? tint.hue else { return Palette.muted }
        return Color(hue: hue, saturation: tint.dark ? 0.52 : 0.74, brightness: tint.dark ? 0.82 : 0.54)
    }

    /// What the folder is made of: paper, not paint. Arc's folder is a pale
    /// near-white card with the space's colour around it, which is what
    /// lets it sit in a column of real favicons without shouting over them.
    private var paper: Color {
        tint.dark ? Color(hue: group.hue ?? tint.hue ?? 0, saturation: 0.10, brightness: 0.90)
                  : Color.white.opacity(0.92)
    }

    /// The mark column: the folder, or — under the pointer, in its place —
    /// the chevron that says which way a click will go.
    private var mark: some View {
        ZStack {
            ZStack {
                Image(systemName: "folder.fill").foregroundStyle(paper)
                Image(systemName: "folder").foregroundStyle(colour)
            }
            .font(.system(size: 13))
            .opacity(hovering ? 0 : 1)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint.muted)
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                .opacity(hovering ? 1 : 0)
        }
        .frame(width: 16, height: 16)
    }

    var body: some View {
        HStack(spacing: 0) {
            mark
                .padding(.trailing, 8)
            Text(label ?? group.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(tint.ink)
            Spacer(minLength: 2)
            if group.collapsed, count > 0 {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(tint.faint)
                    .padding(.trailing, 9)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 6)
        .frame(height: GroupedRows.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? tint.hover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { withAnimation(Motion.settle) { groups.toggleCollapsed(group.id) } }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .popover(isPresented: $renaming) {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .padding(8)
                .onSubmit { groups.rename(group.id, to: draft); renaming = false }
        }
        .popover(isPresented: $adding) {
            TextField("Folder name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .padding(8)
                .onSubmit {
                    groups.createInside(group, named: draft)
                    adding = false
                }
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: group.collapsed)
        .transition(.opacity)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename…") { draft = group.name; renaming = true }
        Menu("Colour") {
            Button("Grey") { groups.tint(group.id, hue: nil) }
            ForEach(Array(stride(from: 0.0, to: 1.0, by: 0.125)), id: \.self) { hue in
                Button { groups.tint(group.id, hue: hue) } label: {
                    Label { Text(String(format: "%.0f°", hue * 360)) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 0.75))
                    }
                }
            }
        }
        Button(group.collapsed ? "Expand" : "Collapse") { groups.toggleCollapsed(group.id) }
        Button("New Folder Inside…") { draft = ""; adding = true }
        Divider()
        Button("Ungroup") { groups.dissolve(group.id) }
        Button("Close Tabs in Group", role: .destructive) { groups.closeAll(group.id, in: browser) }
    }
}

/// Under a tab that just landed: where it could go, and yes or no.
struct SuggestionChip: View {
    @ObservedObject var grouper = Grouper.shared
    let suggestion: Grouper.Suggestion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
            Text("Group into \(suggestion.name)?")
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Palette.ink.opacity(0.85))
            Spacer(minLength: 2)
            Button { grouper.accept() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 18, height: 18)
                    .background(Palette.ink.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("\(suggestion.reason)   ⌃G")
            Button { grouper.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18)
                    .background(Palette.ink.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.wash.opacity(0.7))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// While a judge is out.
struct ThinkingChip: View {
    var body: some View {
        HStack(spacing: 6) {
            Ring(size: 9)
            Text("Finding a group…")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .frame(height: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

/// The Group submenu on a tab's context menu, in both layouts.
struct GroupMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var groups = Groups.shared

    var body: some View {
        Divider()
        Menu("Group") {
            Button("Suggest a Group") { Grouper.shared.suggest(for: tab, in: browser, forced: true) }
                .disabled(tab.isBlank)
            Button("New Group from Tab") {
                let group = groups.create(named: Fork.brand(tab.address?.host()))
                groups.assign(tab, to: group, in: browser)
            }
            .disabled(tab.isBlank)
            if !groups.all.isEmpty { Divider() }
            ForEach(groups.all) { group in
                Button { groups.assign(tab, to: group, in: browser) } label: {
                    Label { Text(group.name) } icon: {
                        Image(systemName: groups.membership[tab.id] == group.id ? "checkmark" : "circle.fill")
                            .foregroundStyle(groups.membership[tab.id] == group.id ? Palette.ink : group.tint)
                    }
                }
            }
            if groups.group(of: tab) != nil {
                Divider()
                Button("Remove from Group") { groups.remove(tab) }
            }
        }
    }
}

/// The Groups menu in the menu bar; ⌃G is the one key to learn.
struct GroupCommands: Commands {
    @ObservedObject var browser: Browser
    @ObservedObject var groups = Groups.shared
    @ObservedObject var grouper = Grouper.shared

    var body: some Commands {
        CommandMenu("Groups") {
            Button(grouper.suggestion != nil ? "Accept Suggested Group" : "Suggest a Group for This Tab") {
                grouper.act(in: browser)
            }
            .keyboardShortcut("g", modifiers: [.control])
            .disabled(browser.active?.isBlank ?? true)
            Button("New Group from This Tab") {
                guard let tab = browser.active else { return }
                let group = groups.create(named: Fork.brand(tab.address?.host()))
                groups.assign(tab, to: group, in: browser)
            }
            .keyboardShortcut("g", modifiers: [.control, .shift])
            .disabled(browser.active?.isBlank ?? true)
            Button("Remove from Group") {
                if let tab = browser.active { groups.remove(tab) }
            }
            .disabled(browser.active.map { groups.group(of: $0) == nil } ?? true)
            if !groups.all.isEmpty {
                Divider()
                ForEach(groups.all) { group in
                    Button("Move to \(group.name)") {
                        if let tab = browser.active { groups.assign(tab, to: group, in: browser) }
                    }
                }
            }
        }
    }
}
