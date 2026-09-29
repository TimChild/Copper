import Foundation

// Where a new tab belongs. A second after a page lands, the tab is weighed
// against the groups and tabs already open, and a place is proposed — or
// taken, if Settings says so.
//
// Four judges, cheapest first, each only if the one before had nothing:
//   1. Your rules: this host always goes here. Free, and final.
//   2. Jev: one typed question over the open groups — which of these, if
//      any — in ~200 ms with a confidence we trust when it clears the bar.
//   3. The router (Sonnet, or whatever is set): when Jev is unsure, or when
//      nothing fits and a new group needs a name.
//   4. A host match: same site as a group's tab, when no key is set at all.
// Nothing here ever blocks the page; every step is a background wait with a
// budget, and a tab that has moved on is left alone.

@MainActor
final class Grouper: ObservableObject {
    static let shared = Grouper()

    struct Suggestion: Equatable {
        let tab: Tab.ID
        /// An existing group, or nil for one to be made with `name`.
        let group: UUID?
        let name: String
        let reason: String
        /// Which judge said so: rule, jev, router, host.
        let source: String
    }

    /// The one open question, under its tab in the column.
    @Published private(set) var suggestion: Suggestion?
    /// A tab being weighed right now, for the spinner.
    @Published private(set) var thinking: Tab.ID?
    /// The last thing that happened, for Settings and the bench.
    @Published private(set) var lastNote = ""

    private weak var browser: Browser?
    private var waits: [Tab.ID: DispatchWorkItem] = [:]
    /// Tab → host it was last judged on, so a page that navigates within
    /// the same site isn't asked about again and again.
    private var judged: [Tab.ID: String] = [:]
    private var expiry: DispatchWorkItem?

    private init() {}

    // MARK: - when a page lands

    /// From the navigation delegate. A beat later, if the tab is still on
    /// that page, it is weighed.
    func landed(_ tab: Tab, in browser: Browser) {
        self.browser = browser
        guard Intelligence.shared.keys.grouping != .off else { return }
        guard eligible(tab, in: browser), let host = tab.address?.host()?.lowercased() else { return }
        guard judged[tab.id] != host else { return }
        waits[tab.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.waits[tab.id] = nil
            guard tab.address?.host()?.lowercased() == host, !tab.loading else { return }
            self.judged[tab.id] = host
            self.suggest(for: tab, in: browser, forced: false)
        }
        waits[tab.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func eligible(_ tab: Tab, in browser: Browser) -> Bool {
        guard !tab.shy, !tab.bench, tab.pin == nil, !tab.isBlank else { return false }
        guard let url = tab.address, url.scheme?.hasPrefix("http") == true else { return false }
        guard browser.tabs.contains(where: { $0.id == tab.id }) else { return false }
        return Groups.shared.group(of: tab) == nil
    }

    // MARK: - asking

    /// Weigh this tab now. `forced` is the menu item: it asks even when the
    /// mode is off and even for a tab already judged.
    func suggest(for tab: Tab, in browser: Browser, forced: Bool) {
        self.browser = browser
        guard forced || eligible(tab, in: browser) else { return }
        guard let url = tab.address else { return }
        let keys = Intelligence.shared.keys
        thinking = tab.id
        Task { @MainActor [weak self, weak tab] in
            defer { if self?.thinking == tab?.id { self?.thinking = nil } }
            guard let self, let tab else { return }
            let verdict = await self.decide(tab, url: url, in: browser, keys: keys)
            guard let verdict, browser.tabs.contains(where: { $0.id == tab.id }) else {
                if forced { browser.announce("Nothing to group this with yet") }
                return
            }
            // The page moved on while we thought: the answer is about a page
            // that isn't there.
            guard tab.address?.host() == url.host() else { return }
            if keys.grouping == .auto && !forced {
                self.apply(verdict, in: browser)
            } else {
                self.offer(verdict, in: browser)
            }
        }
    }

    /// The judges, in order.
    private func decide(_ tab: Tab, url: URL, in browser: Browser, keys: Intelligence.Keys) async -> Suggestion? {
        let groups = Groups.shared
        let title = tab.title
        let host = url.host()?.lowercased() ?? ""

        // 1. Rules.
        if let rule = groups.rules.first(where: { $0.matches(url) }) {
            let existing = groups.group(named: rule.group)
            lastNote = "rule \(rule.pattern) → \(rule.group)"
            return Suggestion(tab: tab.id, group: existing?.id, name: existing?.name ?? rule.group, reason: "Your rule for \(rule.pattern)", source: "rule")
        }

        // What there is to choose between.
        let present = groups.all.filter { !groups.members(of: $0.id, in: browser).isEmpty }
        var keyed: [(key: String, group: TabGroup, summary: String)] = []
        for (i, group) in present.enumerated() {
            let members = groups.members(of: group.id, in: browser)
            let hosts = Array(Set(members.compactMap { $0.address?.host()?.lowercased() })).sorted().prefix(5).joined(separator: ", ")
            let titles = members.prefix(4).map { String($0.title.prefix(60)) }.joined(separator: " · ")
            keyed.append((key: "g\(i + 1)", group: group, summary: "\(group.name) — \(hosts)\(titles.isEmpty ? "" : " — \(titles)")"))
        }
        let loose = browser.tabs.filter { $0.id != tab.id && $0.pin == nil && !$0.shy && !$0.bench && !$0.isBlank && groups.group(of: $0) == nil }
        func brief(_ t: Tab) -> [String: String] { ["host": t.address?.host() ?? "", "title": String(t.title.prefix(80))] }
        let groupRows: [[String: Any]] = keyed.map { k in
            ["key": k.key, "name": k.group.name, "tabs": groups.members(of: k.group.id, in: browser).prefix(8).map(brief)]
        }
        let state: [String: Any] = [
            "tab": ["url": url.absoluteString, "host": host, "title": title] as [String: String],
            "groups": groupRows,
            "other_open_tabs": loose.prefix(20).map(brief),
        ]

        // 2. Jev, when there is something to pick from.
        var jevSaidNone = false
        if Intelligence.shared.jevReady, !keyed.isEmpty {
            var criteria: [String: String] = [:]
            for k in keyed { criteria[k.key] = k.summary }
            criteria["none"] = "None of these groups fits `tab`"
            let questions: [String: Any] = [
                "group": Jev.choice("Which existing group in `groups` does `tab` belong with, judging by its site and what it is about?", criteria),
                "worth_grouping": Jev.noul("`tab` is a page worth grouping with other open tabs rather than leaving on its own (not a one-off search, redirect, sign-in or blank page)."),
            ]
            do {
                let answer = try await Jev.ask(state: state, questions: questions, keys: keys)
                let worth = answer.nouls["worth_grouping"] ?? 1
                if let pick = answer.choices["group"] {
                    lastNote = String(format: "jev %@ %.2f (%.0f ms)", pick.key, pick.confidence, answer.latencyMs)
                    if pick.key == "none" {
                        jevSaidNone = pick.confidence >= keys.threshold
                    } else if pick.confidence >= keys.threshold, worth >= 0.35,
                              let hit = keyed.first(where: { $0.key == pick.key }) {
                        return Suggestion(tab: tab.id, group: hit.group.id, name: hit.group.name,
                                          reason: String(format: "Jev, %.0f%% sure", pick.confidence * 100), source: "jev")
                    }
                }
            } catch {
                lastNote = "jev failed: \(error.localizedDescription)"
            }
        }

        // 3. The router: unsure, or nothing fits and a name is needed.
        if Intelligence.shared.modelReady {
            let system = """
            You organise browser tabs into groups. Answer with one JSON object and nothing else:
            {"action": "existing" | "new" | "none", "group": "<key of an existing group, or a short new name (1-3 words)>", "reason": "<one short sentence>"}
            Use "existing" only when the tab clearly belongs with that group's tabs. Use "new" when the tab and at least one other open tab would sit well together under a name that is not yet a group, or when the tab starts an obvious project/topic. Use "none" for one-off pages, searches, sign-ins and anything not worth grouping.
            """
            let user = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            do {
                let reply = try await Router.ask(system: system, user: "Groups keyed g1…; the tab to place is `tab`.\n\n\(user)", keys: keys)
                let action = (reply.json["action"] as? String ?? "none").lowercased()
                let named = (reply.json["group"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let reason = (reply.json["reason"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                lastNote = String(format: "router %@ %@ (%.0f ms)", action, named, reply.latencyMs)
                switch action {
                case "existing":
                    if let hit = keyed.first(where: { $0.key.lowercased() == named.lowercased() }) ?? keyed.first(where: { $0.group.name.lowercased() == named.lowercased() }) {
                        return Suggestion(tab: tab.id, group: hit.group.id, name: hit.group.name, reason: reason.isEmpty ? "\(reply.model)" : reason, source: "router")
                    }
                case "new":
                    guard !named.isEmpty else { break }
                    if let existing = groups.group(named: named) {
                        return Suggestion(tab: tab.id, group: existing.id, name: existing.name, reason: reason, source: "router")
                    }
                    return Suggestion(tab: tab.id, group: nil, name: String(named.prefix(32)), reason: reason.isEmpty ? "\(reply.model)" : reason, source: "router")
                default:
                    return nil
                }
            } catch {
                lastNote = "router failed: \(error.localizedDescription)"
            }
        }

        // 4. Same site as a group's tab. The fallback when nothing is set up,
        // and when both lanes failed.
        if !jevSaidNone {
            for k in keyed where groups.members(of: k.group.id, in: browser).contains(where: { $0.address?.host()?.lowercased() == host }) {
                lastNote = "host match → \(k.group.name)"
                return Suggestion(tab: tab.id, group: k.group.id, name: k.group.name, reason: "Same site as tabs in \(k.group.name)", source: "host")
            }
        }
        return nil
    }

    // MARK: - answering

    private func offer(_ verdict: Suggestion, in browser: Browser) {
        suggestion = verdict
        if !browser.prefs.sidebar {
            browser.announce("Group into \(verdict.name)? — ⌃G to accept")
        }
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.suggestion == verdict else { return }
            self.suggestion = nil
        }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func apply(_ verdict: Suggestion, in browser: Browser) {
        guard let tab = (browser.tabs + Spaces.shared.parkedTabs).first(where: { $0.id == verdict.tab }) else { return }
        let group = Groups.shared.group(verdict.group) ?? Groups.shared.create(named: verdict.name)
        Groups.shared.assign(tab, to: group, in: browser)
        browser.announce("Grouped into \(group.name)")
        if suggestion?.tab == verdict.tab { suggestion = nil }
    }

    /// The chip's tick, or ⌃G with a suggestion up.
    func accept() {
        guard let suggestion, let browser else { return }
        apply(suggestion, in: browser)
        self.suggestion = nil
    }

    /// The chip's cross. The tab is not asked about again on this site.
    func dismiss() {
        suggestion = nil
    }

    /// ⌃G: accept what is offered, or ask about the active tab.
    func act(in browser: Browser) {
        if suggestion != nil { accept(); return }
        guard let tab = browser.active else { return }
        suggest(for: tab, in: browser, forced: true)
    }

    /// A tab that left: nothing pending about it.
    func forget(_ id: Tab.ID) {
        waits[id]?.cancel()
        waits[id] = nil
        judged[id] = nil
        if suggestion?.tab == id { suggestion = nil }
    }
}
