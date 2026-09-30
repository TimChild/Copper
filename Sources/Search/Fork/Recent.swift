import SwiftUI

/// The tabs in the order they were last looked at. A walk keeps the list still
/// until Control is released, so repeated Tab presses are predictable.
@MainActor
final class Recent: ObservableObject {
    static let shared = Recent()

    @Published private(set) var order: [Tab.ID] = []
    @Published private(set) var walking = false
    @Published private(set) var landing: Tab.ID?
    @Published private(set) var showing = false

    private var snapshot: [Tab.ID] = []
    private var reveal: DispatchWorkItem?

    /// Every tab looked at, newest first, in every space. `order` is the row
    /// on screen and is rebuilt from that row whenever the space changes;
    /// this is not, so ⌘T's empty card (Fork/Launcher) still knows which tab
    /// you were on before you went to another space and came back.
    private(set) var trail: [Tab.ID] = []

    private func mark(_ id: Tab.ID) {
        trail.removeAll { $0 == id }
        trail.insert(id, at: 0)
        if trail.count > 64 { trail.removeLast() }
    }

    /// A normal selection puts the tab at the front. During a Control-Tab
    /// walk, the snapshot is deliberately frozen until `end(in:)` commits it.
    func touched(_ id: Tab.ID?) {
        guard !walking, let id else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        mark(id)
    }

    /// Remove tabs that left the row, without disturbing the order of the
    /// tabs that remain. Closing a tab during a walk also removes it from the
    /// frozen snapshot, so the next press skips it.
    func prune(_ tabs: [Tab]) {
        let eligible = tabs.filter { !$0.isBlank }
        let ids = Set(eligible.map(\.id))
        order.removeAll { !ids.contains($0) }
        snapshot.removeAll { !ids.contains($0) }
        if let landing, !ids.contains(landing) { self.landing = nil }
        if !walking {
            order.append(contentsOf: eligible.map(\.id).filter { !order.contains($0) })
        }
    }

    /// Start a walk from the tab currently showing. The row supplies any IDs
    /// not yet seen, which also makes a fresh session immediately useful.
    func begin(in browser: Browser) {
        guard !walking, browser.tabs.count > 1, let active = browser.activeID,
              browser.tabs.first(where: { $0.id == active })?.isBlank == false else { return }
        let ids = browser.tabs.filter { !$0.isBlank }.map(\.id)
        var base = order.filter { ids.contains($0) }
        base.append(contentsOf: ids.filter { !base.contains($0) })
        if !base.contains(active) { base.insert(active, at: 0) }
        snapshot = [active] + base.filter { $0 != active }
        landing = active
        walking = true
        showing = false
        reveal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.walking else { return }
            self.showing = true
        }
        reveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// Move through the frozen MRU list. Positive is the ordinary Control-Tab
    /// direction; negative is Control-Shift-Tab back toward newer tabs.
    func step(_ direction: Int, in browser: Browser) {
        if !walking { begin(in: browser) }
        guard walking else { return }
        prune(browser.tabs)
        guard snapshot.count > 1 else { return }
        let current = landing ?? browser.activeID
        guard let current, let here = snapshot.firstIndex(of: current) else { return }
        let next = (here + direction + snapshot.count) % snapshot.count
        guard let tab = browser.tabs.first(where: { $0.id == snapshot[next] }) else { return }
        landing = tab.id
        browser.select(tab)
    }

    /// Commit the tab where the walk landed, making it the new front of the
    /// list and preserving the frozen order behind it.
    func end(in browser: Browser) {
        guard walking else { return }
        reveal?.cancel()
        let ids = Set(browser.tabs.filter { !$0.isBlank }.map(\.id))
        let valid = snapshot.filter { ids.contains($0) }
        if let active = browser.activeID, ids.contains(active) {
            mark(active)
            order = [active] + valid.filter { $0 != active }
                + browser.tabs.filter { !$0.isBlank }.map(\.id).filter { !valid.contains($0) && $0 != active }
        } else {
            order = valid
        }
        snapshot = []
        landing = nil
        walking = false
        showing = false
    }

    /// A space switch replaces the row wholesale. Its MRU is therefore rebuilt
    /// from the active tab followed by that space's row order.
    func rebuild(from tabs: [Tab]) {
        reveal?.cancel()
        let ids = tabs.filter { !$0.isBlank }.map(\.id)
        let front = landing.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        if let front {
            order = [front] + ids.filter { $0 != front }
        } else {
            order = ids
        }
        snapshot = []
        landing = nil
        walking = false
        showing = false
    }
}
