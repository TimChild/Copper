import AppKit
import SwiftUI
import WebKit

// What a trail can be asked to do, from its row's menu, the menu bar or the
// bench: close, ask the agent about it, put it on the canvas. Each one goes
// through what Copper already has — `Browser.close` (so ⌘⇧T brings pages
// back), the ⌘E pane's composer, the canvas tools — and adds no path of its own.

extension Trails {
    /// Every page of the trail, closed the ordinary way: the one in front
    /// last, so the window lands outside the trail rather than on the next
    /// page of it. Each lands in Reopen Closed Tab, and ⌘⇧T puts them back on
    /// this trail (the graveyard, above).
    func close(_ plan: Plan, in browser: Browser) {
        let pages = plan.pages.map(\.tab).filter { tab in browser.tabs.contains { $0.id == tab.id } }
        guard !pages.isEmpty else { return }
        let front = pages.filter { $0.id == browser.activeID }
        // Its name stays with it in the graveyard, for ⌘⇧T.
        caption(plan.id, plan.title)
        // Closing the trail you are on lands on the next one down the
        // column (or the one above, closing the last), not on whichever row
        // happened to sit beside its last page.
        if !front.isEmpty {
            let fresh = column(browser.tabs.filter(Trails.member), in: browser).fresh
            if let here = fresh.firstIndex(where: { $0.id == plan.id }) {
                let next = fresh.indices.contains(here + 1) ? fresh[here + 1] : (here > 0 ? fresh[here - 1] : nil)
                if let next { browser.select(next.recent) }
            }
        }
        withAnimation(Motion.settle) {
            for tab in pages where tab.id != browser.activeID { browser.close(tab) }
            for tab in front where browser.tabs.contains(where: { $0.id == tab.id }) { browser.close(tab) }
        }
        glancing = nil
        let title = plan.single ? (pages.first?.label ?? "Trail") : plan.title
        browser.announce("Closed “\(Trails.short(title))” — ⌘⇧T brings \(pages.count == 1 ? "it" : "its pages") back")
    }

    /// The trail's pages, in order, in the ⌘E pane's composer: the agent the
    /// pane already has, asked about the whole line of reading rather than
    /// one page. Nothing is sent until you send it.
    func ask(_ plan: Plan, in browser: Browser) {
        var lines = ["About my trail “\(plan.title)” — the pages I opened, in order:", ""]
        for page in plan.pages {
            let url = (page.tab.pending ?? page.tab.address)?.absoluteString ?? ""
            lines.append(String(repeating: "  ", count: page.depth) + "- \(page.tab.label)" + (url.isEmpty ? "" : " — \(url)"))
        }
        lines += ["", "What have I found so far, what's still open, and what should I read next?"]
        let agent = Agent.shared
        agent.draft = lines.joined(separator: "\n")
        agent.open = true
        agent.focusTick += 1
    }

    /// The trail as a little map on the personal canvas: a frame named after
    /// it, a link card per page, laid out by depth, with an arrow from each
    /// page to the ones opened from it — placed right of whatever is already
    /// on the board, then shown.
    func sendToCanvas(_ plan: Plan, in browser: Browser) {
        let pages = plan.pages.compactMap { page -> (page: Page, url: String)? in
            guard let url = page.tab.pending ?? page.tab.address, url.scheme?.hasPrefix("http") == true else { return nil }
            return (page, url.absoluteString)
        }
        guard !pages.isEmpty else {
            browser.announce("Nothing on this trail can go on a canvas")
            return
        }
        let board = Canvases.personalID
        let stamp = String(UUID().uuidString.prefix(6)).lowercased()
        let title = plan.title
        browser.announce("Sending “\(Trails.short(title))” to Canvas…")
        Task { @MainActor in
            do {
                // Right of everything there, top-aligned with it.
                var left = 0.0
                var top = 0.0
                if case .text(let text)? = try await CanvasTools.call("canvas_read", ["id": board], in: browser).first,
                   let data = text.data(using: .utf8),
                   let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let shapes = read["shapes"] as? [[String: Any]], !shapes.isEmpty {
                    func number(_ shape: [String: Any], _ key: String) -> Double { (shape[key] as? NSNumber)?.doubleValue ?? 0 }
                    left = (shapes.map { number($0, "x") + number($0, "w") }.max() ?? 0) + 120
                    top = shapes.map { number($0, "y") }.min() ?? 0
                }
                let cardW = 320.0, cardH = 84.0, stepX = 360.0, stepY = 108.0, pad = 40.0
                let deepest = pages.map(\.page.depth).max() ?? 0
                var ops: [[String: Any]] = [[
                    "op": "add",
                    "shape": ["type": "frame", "id": "trail-\(stamp)", "title": title,
                              "x": left, "y": top,
                              "w": pad * 2 + Double(deepest) * stepX + cardW,
                              "h": pad * 2 + 18 + Double(pages.count - 1) * stepY + cardH],
                ]]
                var ids: [Tab.ID: String] = [:]
                for (row, item) in pages.enumerated() {
                    let id = "trail-\(stamp)-\(row)"
                    ids[item.page.tab.id] = id
                    ops.append(["op": "add", "shape": [
                        "type": "link", "id": id, "url": item.url, "title": item.page.tab.label,
                        "x": left + pad + Double(item.page.depth) * stepX,
                        "y": top + pad + 18 + Double(row) * stepY,
                        "w": cardW, "h": cardH,
                    ]])
                }
                for item in pages {
                    guard let node = nodes[item.page.tab.id], let parent = node.parent,
                          let from = ids[parent], let to = ids[item.page.tab.id] else { continue }
                    ops.append(["op": "connect", "from": from, "to": to])
                }
                _ = try await CanvasTools.call("canvas_apply", ["id": board, "ops": ops, "as": "Trails"], in: browser)
                CanvasHost.show(board, in: browser)
                _ = try? await CanvasTools.call("canvas_focus", ["id": board, "shapeIds": ["trail-\(stamp)"]], in: browser)
                browser.announce("“\(Trails.short(title))” is on your canvas")
            } catch {
                browser.announce("Couldn't reach the canvas — \(error.localizedDescription)")
            }
        }
    }

    /// A title short enough for an announcement.
    static func short(_ text: String) -> String {
        text.count > 42 ? String(text.prefix(40)) + "…" : text
    }
}

// MARK: - pictures for Glance

/// Small pictures of trail pages, for Glance. Taken from views that already
/// exist — the page you are leaving, or a page still awake when its trail is
/// glanced at — and never by building or loading one: a page asleep shows its
/// mark and title instead. Memory only, the most recent few dozen.
@MainActor
final class TrailThumbs: ObservableObject {
    static let shared = TrailThumbs()

    @Published private(set) var pictures: [Tab.ID: NSImage] = [:]
    private var order: [Tab.ID] = []
    private var asking: Set<Tab.ID> = []
    private static let keep = 48

    func take(_ tab: Tab) {
        // A page opened behind and never on a stage has never been laid out:
        // its picture would be blank, so it keeps its mark-and-title card.
        guard Flights.trails, let web = tab.built, !tab.asleep, !tab.isBlank, !asking.contains(tab.id),
              web.bounds.width > 1, web.bounds.height > 1 else { return }
        asking.insert(tab.id)
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 320
        let id = tab.id
        web.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.asking.remove(id)
                guard let image else { return }
                self.pictures[id] = image
                self.order.removeAll { $0 == id }
                self.order.append(id)
                if self.order.count > TrailThumbs.keep {
                    let drop = self.order.removeFirst()
                    self.pictures[drop] = nil
                }
            }
        }
    }

    /// The pages of a trail about to be glanced at: any still awake gets a
    /// fresh picture.
    func want(_ tabs: [Tab]) {
        for tab in tabs { take(tab) }
    }
}

// MARK: - the menu bar

/// View › Close Trail (⌘⇧W) and Ask About This Trail, only while the flight
/// is on: off, the menu has nothing more in it than before.
struct TrailsCommands: Commands {
    @ObservedObject var browser: Browser
    /// Handed down by `ForkCommands`, which is what SwiftUI re-reads when
    /// the flight flips.
    let on: Bool

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            if on {
                Divider()
                Button("Close Trail") { Trails.shared.closeCurrent(in: browser) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Ask About This Trail") { Trails.shared.askCurrent(in: browser) }
            }
        }
    }
}

extension Trails {
    /// The trail holding the page in front, worked out as the column draws it.
    func current(in browser: Browser) -> Plan? {
        guard let active = browser.active, Trails.member(active) else { return nil }
        let column = column(browser.tabs.filter(Trails.member), in: browser)
        return (column.fresh + column.earlier.flatMap(\.plans)).first { plan in plan.pages.contains { $0.tab.id == active.id } }
    }

    func closeCurrent(in browser: Browser) {
        guard let plan = current(in: browser) else {
            NSSound.beep()
            return
        }
        close(plan, in: browser)
    }

    func askCurrent(in browser: Browser) {
        guard let plan = current(in: browser) else {
            Agent.shared.askOnPage(in: browser)
            return
        }
        ask(plan, in: browser)
    }
}
