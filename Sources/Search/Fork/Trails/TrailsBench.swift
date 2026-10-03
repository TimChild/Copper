import AppKit
import SwiftUI

// `./bench --world W trails …` — the flight in a probe world, as data, and
// the few things a test can't do by hand in a headless window: make an
// afternoon pass (backdate), hold a Glance open for a picture, open a page
// from a page the way ⌘-click does.

extension Trails {
    /// `trails` lists; `trails open URL [FROM]` (a real tab; FROM — a tab id
    /// prefix — makes it a page opened from that one, as ⌘-click does),
    /// `trails type ID URL` (an address typed into a tab), `trails backdate N
    /// HOURS`, `trails glance N|off`, `trails toggle N`, `trails rename N
    /// TEXT`, `trails close N`, `trails ask N`, `trails canvas N`, `trails
    /// move ID N|new`, `trails file` (trails.json as written), `trails menu`
    /// (what ⌘⇧W is bound to). N is a trail's place in the list.
    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        guard Flights.trails else { return ["error": "the Trails flight is off — `flight trails on`", "flights": ["trails": false]] }
        attach(browser)
        let op = (request["op"] as? String ?? "list").lowercased()
        let words = (request["arg"] as? String ?? "").split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let column = self.column(browser.tabs.filter(Trails.member), in: browser)
        let all = column.fresh + column.earlier.flatMap(\.plans)
        func plan(_ key: String?) -> Plan? {
            guard let key else { return nil }
            if let n = Int(key), all.indices.contains(n) { return all[n] }
            return all.first { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
        }
        func tab(_ key: String?) -> Tab? {
            guard let key, !key.isEmpty else { return nil }
            return browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
        }
        var note: [String: Any] = [:]
        switch op {
        case "list", "status":
            break
        case "open":
            guard let text = words.first, let url = Address.url(from: text) else { return ["error": "trails open URL [FROM]"] }
            if let from = tab(words.dropFirst().first) {
                let child = browser.open(url, foreground: false)
                Trails.opened(child, from: from, in: browser)
                note["opened"] = String(child.id.uuidString.prefix(8)).lowercased()
            } else {
                let fresh = browser.open(url, foreground: true)
                note["opened"] = String(fresh.id.uuidString.prefix(8)).lowercased()
            }
        case "type":
            let text = words.dropFirst().joined(separator: " ")
            guard let target = tab(words.first), !text.isEmpty, let url = Google.destination(for: text) else {
                return ["error": "trails type ID URL|WORDS"]
            }
            Trails.typed(into: target, in: browser)
            target.go(to: url)
        case "backdate":
            guard let trail = plan(words.first), let hours = words.dropFirst().first.flatMap(Double.init) else {
                return ["error": "trails backdate N HOURS"]
            }
            backdate(trail.id, hours: hours)
        case "glance":
            if words.first == "off" { Glance.dismiss() } else {
                guard let trail = plan(words.first) else { return ["error": "trails glance N|off"] }
                TrailThumbs.shared.want(trail.pages.map(\.tab))
                glancing = trail.id
            }
        case "toggle":
            guard let trail = plan(words.first) else { return ["error": "trails toggle N"] }
            withAnimation(Trails.motion) { toggle(trail) }
        case "rename":
            guard let trail = plan(words.first) else { return ["error": "trails rename N TEXT"] }
            rename(trail.id, to: words.dropFirst().joined(separator: " "))
        case "close":
            guard let trail = plan(words.first) else { return ["error": "trails close N"] }
            close(trail, in: browser)
        case "ask":
            guard let trail = plan(words.first) else { return ["error": "trails ask N"] }
            ask(trail, in: browser)
            note["draft"] = Agent.shared.draft
            note["paneOpen"] = Agent.shared.open
        case "canvas":
            guard let trail = plan(words.first) else { return ["error": "trails canvas N"] }
            sendToCanvas(trail, in: browser)
            note["sending"] = trail.pages.count
        case "move":
            guard let moving = tab(words.first), let to = words.dropFirst().first else { return ["error": "trails move ID N|new"] }
            if to == "new" {
                reroot(moving, in: browser, keepTitle: true)
            } else {
                guard let trail = plan(to) else { return ["error": "no trail \(to)"] }
                move(moving, to: trail.id, in: browser)
            }
        case "file":
            write(now: true)
            guard let data = try? Data(contentsOf: Store.file("trails.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return ["file": NSNull()] }
            return ["file": json]
        case "menu":
            var bound: [String] = []
            func walk(_ menu: NSMenu, _ path: String) {
                for item in menu.items {
                    if item.keyEquivalent.lowercased() == "w", item.keyEquivalentModifierMask.contains(.command) {
                        let shift = item.keyEquivalentModifierMask.contains(.shift) || item.keyEquivalent == "W"
                        bound.append("\(path) › \(item.title)  ⌘\(shift ? "⇧" : "")W\(item.isEnabled ? "" : " (disabled)")")
                    }
                    if let sub = item.submenu { walk(sub, path.isEmpty ? item.title : "\(path) › \(item.title)") }
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
            return ["w": bound]
        default:
            return ["error": "unknown trails op \(op)"]
        }
        let after = self.column(browser.tabs.filter(Trails.member), in: browser)
        note["trails"] = describe(after, in: browser)
        note["tide"] = Flights.shared.tide.rawValue
        note["glancing"] = glancing.map { id in (after.fresh + after.earlier.flatMap(\.plans)).firstIndex { $0.id == id } ?? -1 } ?? NSNull()
        return note
    }

    private func describe(_ column: Column, in browser: Browser) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        func add(_ plan: Plan, place: String) {
            rows.append([
                "index": rows.count,
                "id": String(plan.id.uuidString.prefix(8)).lowercased(),
                "title": plan.title,
                "searched": plan.searched,
                "place": place,
                "open": plan.single ? true : isOpen(plan),
                "live": plan.live,
                "hours": (Date().timeIntervalSince(plan.used) / 3600 * 10).rounded() / 10,
                "pages": plan.pages.map { page -> [String: Any] in
                    ["id": String(page.tab.id.uuidString.prefix(8)).lowercased(), "depth": page.depth,
                     "title": page.tab.label, "url": (page.tab.pending ?? page.tab.address)?.absoluteString ?? "",
                     "asleep": page.tab.asleep]
                },
            ])
        }
        for plan in column.fresh { add(plan, place: "fresh") }
        for bucket in column.earlier { for plan in bucket.plans { add(plan, place: "earlier · \(bucket.title)") } }
        return rows
    }
}
