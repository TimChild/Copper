import SwiftUI

// Two pages side by side. The row of tabs is unchanged: one tab is the
// active one, as ever, and a second — `side` — is shown beside it. Everything
// that acts on "the tab" (⌘L, ⌘W, find, reader) still acts on the active one;
// clicking into the other pane makes that one active, so focus follows the
// pointer without a second notion of selection anywhere.

@MainActor
final class Split: ObservableObject {
    static let shared = Split()
    @Published private(set) var side: Tab.ID?
    /// Fraction of the stage the left pane takes.
    @Published var fraction: CGFloat = 0.5

    var on: Bool { side != nil }

    /// ⌘⇧D. Splits with the tab to the right of the active one (or the
    /// left, at the end of the row); a second press closes the split.
    func toggle(in browser: Browser) {
        if side != nil { side = nil; return }
        guard let here = browser.tabs.firstIndex(where: { $0.id == browser.activeID }), browser.tabs.count > 1 else {
            browser.announce("Nothing to split with — open another tab")
            return
        }
        let other = browser.tabs[here + 1 < browser.tabs.count ? here + 1 : here - 1]
        open(with: other, in: browser)
    }

    func open(with tab: Tab, in browser: Browser) {
        guard tab.id != browser.activeID else { return }
        side = tab.id
        if !tab.wake() { tab.revive() }
        tab.touch()
    }

    func close() { side = nil; swapped = false }

    /// The cross on a pane's own toolbar. The tab goes, the split goes with
    /// it, and the other pane's page is what you are left looking at — which
    /// is the only outcome that doesn't need explaining.
    func dismiss(_ tab: Tab, in browser: Browser) {
        let other = tab.id == side ? browser.active : browser.tabs.first { $0.id == side }
        side = nil
        swapped = false
        browser.close(tab)
        if let other, other.id != tab.id, browser.tabs.contains(where: { $0.id == other.id }) {
            browser.select(other)
        }
    }

    /// The name the stage measures the handle's drag against.
    static let space = "split.stage"

    /// The space's colour, for the live pane's outline — the accent when the
    /// space has no colour of its own, because grey would say nothing.
    var tint: Color {
        Spaces.shared.space.hue.map { Color(hue: $0, saturation: 0.62, brightness: 0.72) } ?? Color.accentColor
    }

    /// Which pane a tab is in: left (active), right (side), or nowhere.
    func has(_ id: Tab.ID?) -> Bool { id != nil && id == side }

    /// Called when a tab's page is clicked, and by a pane's own toolbar.
    /// Nothing to do but select it: selecting is what trades the panes over.
    func touched(_ tab: Tab, in browser: Browser) {
        guard tab.id == side else { return }
        browser.select(tab)
    }

    /// `tab` is about to become the live one. If it is the tab already in the
    /// side pane, the panes trade places here — in the same breath as the
    /// selection, before anything redraws.
    ///
    /// Doing it afterwards, off the stage's `onChange`, leaves one frame in
    /// which the active tab and the side tab are the same tab. Both panes ask
    /// for that one page, a web view can only live in one of them, and the
    /// pane that loses the fight is blank from then on. That is the whole
    /// reason this is called from `Browser.select` rather than from the view.
    func arriving(_ tab: Tab, in browser: Browser) {
        guard tab.id == side, let was = browser.activeID, was != tab.id,
              browser.tabs.contains(where: { $0.id == was })
        else { return }
        side = was
        swapped.toggle()
    }

    /// The side pane sits right unless a swap put the old active there.
    @Published private(set) var swapped = false

    /// Selecting a third tab replaces the active pane, as it always did.
    /// Closing either pane's tab ends the split.
    ///
    /// Selecting the tab that is *already* in the side pane doesn't end the
    /// split — it moves the focus into that pane. The two trade places as it
    /// happens, so the outline moves across the window and neither page does.
    /// That is what a click into the other pane does, and `⌘⌥→` and
    /// `bench select` come down the same road, so they behave the same way
    /// without knowing anything about panes.
    func reconcile(_ browser: Browser, was: Tab.ID? = nil) {
        guard let side else { return }
        guard browser.tabs.contains(where: { $0.id == side }) else { self.side = nil; return }
        guard side == browser.activeID else { return }
        if let was, was != side, browser.tabs.contains(where: { $0.id == was }) {
            self.side = was
            swapped.toggle()
        } else {
            self.side = nil
        }
    }
}

extension Tab {
    /// The stage tells the split when a page was clicked.
    static var touched: ((Tab) -> Void)?
}

/// The page area: one page, or two cards with air between them.
///
/// The pair floats — a margin around, a gutter down the middle, the space's
/// colour washed behind so the cards read as cards rather than as a window
/// sawn in half. Only the live one is outlined.
struct SplitStage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var split = Split.shared
    @ObservedObject var spaces = Spaces.shared
    let active: Tab

    /// How far the page area spills past the window's top and bottom edges.
    /// Zero in a sane layout; see `PaneSpill`.
    @State private var spill = PaneSpill.none
    @ObservedObject private var agent = Agent.shared
    @ObservedObject private var trace = JevTrace.shared

    /// The stage, and the panes beside it when they are open — the agent's,
    /// and Jev's timeline while a run is on. Both may be open at once; they
    /// take their width from the page, never from the sidebar.
    var body: some View {
        HStack(spacing: 0) {
            driven
            if agent.open {
                Rectangle().fill(Palette.hairline).frame(width: 1)
                AgentPane(browser: browser)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if trace.paneOpen {
                Rectangle().fill(Palette.hairline).frame(width: 1)
                JevPane(browser: browser)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.glide, value: agent.open)
        .animation(Motion.glide, value: trace.paneOpen)
    }

    /// The page area while something else has the wheel: the pill in the
    /// corner and a warm line just inside the edge, so it is never a surprise
    /// that the page is moving on its own. Both go the moment the run ends.
    private var driven: some View {
        stage
            .overlay {
                RoundedRectangle(cornerRadius: split.on ? SplitMetrics.corner : 0, style: .continuous)
                    .strokeBorder(JevStyle.accent.opacity(trace.live ? 0.35 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if trace.live { JevPill().padding(8).transition(.opacity) }
            }
            .animation(Motion.quick, value: trace.live)
    }

    @ViewBuilder
    private var stage: some View {
        if let id = split.side, let side = browser.tabs.first(where: { $0.id == id }) {
            let left = split.swapped ? side : active
            let right = split.swapped ? active : side
            GeometryReader { geo in
                // What the fraction divides: the width left once the margins
                // and the gutter have taken theirs.
                let span = max(geo.size.width - 2 * SplitMetrics.margin - SplitMetrics.gutter, 1)
                // And the height, once the margins and whatever the stage
                // hangs off the window have taken theirs.
                let tall = max(geo.size.height - spill.top - spill.bottom - 2 * SplitMetrics.margin, 1)
                let least = min(SplitMetrics.least, span / 2)
                let leftWidth = min(span - least, max(least, span * split.fraction))

                ZStack(alignment: .topLeading) {
                    HStack(spacing: SplitMetrics.gutter) {
                        card(left, CGSize(width: leftWidth, height: tall))
                        card(right, CGSize(width: span - leftWidth, height: tall))
                    }
                    .padding(.horizontal, SplitMetrics.margin)
                    .padding(.top, SplitMetrics.margin + spill.top)
                    .padding(.bottom, SplitMetrics.margin + spill.bottom)

                    SplitHandle(span: span, inset: SplitMetrics.margin)
                        .frame(height: tall + 2 * SplitMetrics.margin)
                        .offset(
                            x: SplitMetrics.margin + leftWidth + SplitMetrics.gutter / 2 - SplitMetrics.grip / 2,
                            y: spill.top
                        )
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .background(PaneSpill.probe { spill = $0 })
            }
            .background(backdrop)
            .coordinateSpace(name: Split.space)
            .onChange(of: browser.activeID) { was, _ in split.reconcile(browser, was: was) }
            .onChange(of: browser.tabs.map(\.id)) { _, _ in split.reconcile(browser) }
        } else {
            Page(tab: active)
        }
    }

    /// The ground the cards sit on: the window's own, with the space's colour
    /// over it — enough that a white page reads as a card laid on something
    /// rather than as the window with two lines scratched into it.
    private var backdrop: some View {
        ZStack {
            Palette.ground
            wash
        }
    }

    /// Deliberately stronger than the sidebar's wash. The sidebar's job is to
    /// stay behind the tabs; this one has to be seen in a 7pt margin.
    private var wash: Color { split.tint.opacity(0.22) }

    private func card(_ tab: Tab, _ size: CGSize) -> some View {
        SplitCard(
            browser: browser,
            tab: tab,
            live: tab.id == browser.activeID,
            tint: split.tint,
            wash: wash,
            size: CGSize(width: max(size.width, 1), height: max(size.height, 1))
        )
    }
}
