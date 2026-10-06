import AppKit
import SwiftUI

// Settings search's keys, and its bench verbs.

/// Keys while Settings is open, seen by the app's key monitor before the
/// page or a field (App.swift `take()` asks first):
/// ⌘F puts the keyboard in the search field; Esc clears the query, and only
/// on an empty one closes the panel; ↑ ↓ ↩ walk and pick results; and a
/// letter typed while no field has the keyboard starts a search.
@MainActor
enum SettingsKeys {
    static func take(_ event: NSEvent, in browser: Browser) -> Bool {
        guard browser.tuning, event.type == .keyDown else { return false }
        let finder = SettingsFinder.of(browser)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if command, key == "f", flags.isDisjoint(with: [.shift, .option, .control]) {
            finder.focus()
            return true
        }
        if event.keyCode == 53 {
            return finder.clear()
        }
        guard !command, !flags.contains(.control) else { return false }

        let editing = event.window?.firstResponder is NSText
        let inField = finder.fieldFocused && editing

        // ↑ ↓ ↩ over the results — from the field, or from nowhere in particular.
        if finder.showingResults, inField || !editing {
            switch event.keyCode {
            case 125: finder.move(1); return true
            case 126: finder.move(-1); return true
            case 36, 76: finder.pickSelected(); return true
            default: break
            }
        }
        // Back to the results from a page search landed on.
        if inField, !finder.showingResults, finder.searching, event.keyCode == 125 {
            finder.showingResults = true
            return true
        }
        // Type to search.
        if !editing, !flags.contains(.option), let typed = event.characters, printable(typed),
           finder.searching || typed.trimmingCharacters(in: .whitespaces).isEmpty == false {
            finder.type(typed, in: event.window)
            return true
        }
        return false
    }

    private static func printable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            // Function keys and arrows arrive in the private-use block.
            if (0xF700...0xF8FF).contains(scalar.value) { return false }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            return true
        }
    }
}

/// `bench settings …` — see the bench script's help.
@MainActor
enum SettingsBench {
    static func handle(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? "state"
        let arg = (request["arg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let finder = SettingsFinder.of(browser)

        switch op {
        case "open":
            if !arg.isEmpty {
                guard let page = SettingsPanel.Page(rawValue: arg.lowercased()) else {
                    answer(["error": "no page \(arg) — one of \(SettingsPanel.Page.allCases.map(\.rawValue).joined(separator: ", "))"])
                    return
                }
                browser.settingsPage = page
                Store.settings.set(page.rawValue, forKey: "settings.page")
            }
            let wasOpen = browser.tuning
            browser.tuning = true
            if wasOpen { _ = finder.clear() }
            answer(["open": true, "page": browser.settingsPage.rawValue])

        case "close":
            browser.tuning = false
            answer(["open": false])

        case "search":
            // Ranked results as JSON; with the panel open, the field shows
            // the query too, so `window` can picture the results.
            let started = CFAbsoluteTimeGetCurrent()
            let hits = SettingsMatcher.search(arg)
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            if browser.tuning {
                finder.query = arg
                finder.showingResults = !arg.isEmpty
            }
            let ranked = hits.enumerated().map { index, hit -> [String: Any] in
                [
                    "rank": index + 1,
                    "page": hit.entry.page.rawValue,
                    "section": hit.entry.section,
                    "title": hit.entry.title,
                    "anchor": hit.entry.anchor,
                    "score": (hit.score * 10).rounded() / 10,
                    "marked": marked(hit.entry.title, hit.titleMarks),
                    "kind": hit.entry.isPage ? "page" : "row",
                    "toggle": hit.entry.toggle != nil,
                ]
            }
            answer(["query": arg, "count": hits.count, "ms": (ms * 100).rounded() / 100, "results": ranked,
                    "order": finder.results.map(\.entry.title)])

        case "pick":
            // pick N: the Nth result as drawn (1-based), as Return would.
            guard browser.tuning else { answer(["error": "settings isn't open — settings open, then settings search QUERY"]); return }
            guard let n = Int(arg), n >= 1, n <= finder.results.count else {
                answer(["error": "pick 1…\(finder.results.count)"])
                return
            }
            let hit = finder.results[n - 1]
            finder.selection = n - 1
            finder.pick(hit)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                let flashing: Any = finder.flashing ?? NSNull()
                answer([
                    "picked": hit.entry.title, "page": browser.settingsPage.rawValue,
                    "anchor": hit.entry.anchor, "flashing": flashing,
                    "drawn": (finder.drawn[browser.settingsPage] ?? []).contains(hit.entry.anchor),
                ])
            }

        case "select":
            // select N: move the keyboard's choice, as ↑/↓ would.
            guard let n = Int(arg), n >= 1, n <= finder.results.count else { answer(["error": "select 1…\(finder.results.count)"]); return }
            finder.selection = n - 1
            answer(["selection": n, "title": finder.results[n - 1].entry.title])

        case "toggle":
            // toggle N: flip result N's in-place switch, as clicking it would.
            guard let n = Int(arg), n >= 1, n <= finder.results.count else { answer(["error": "toggle 1…\(finder.results.count)"]); return }
            let hit = finder.results[n - 1]
            guard let toggle = hit.entry.toggle?(browser) else { answer(["error": "\(hit.entry.title) has no switch"]); return }
            let before = toggle.wrappedValue
            toggle.wrappedValue.toggle()
            answer(["title": hit.entry.title, "before": before, "after": toggle.wrappedValue])

        case "index":
            guard arg.isEmpty || arg == "check" else { answer(["error": "settings index check"]); return }
            check(in: browser, answer: answer)

        default:
            answer(state(browser))
        }
    }

    static func state(_ browser: Browser) -> [String: Any] {
        let finder = SettingsFinder.of(browser)
        return [
            "open": browser.tuning,
            "page": browser.settingsPage.rawValue,
            "query": finder.query,
            "results": finder.results.count,
            "selection": finder.selection + 1,
            "chosen": finder.results.indices.contains(finder.selection) ? finder.results[finder.selection].entry.title : NSNull(),
            "showingResults": finder.showingResults,
            "fieldFocused": finder.fieldFocused,
            "flashing": finder.flashing ?? NSNull(),
            "firstResponder": Links.window?.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull(),
            "indexEntries": SettingsIndex.entries.count,
        ]
    }

    /// Opens every page in turn and compares what it drew with the index.
    private static func check(in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let finder = SettingsFinder.of(browser)
        let pages = SettingsPanel.Page.allCases
        let before = browser.settingsPage
        let wasOpen = browser.tuning
        _ = finder.clear()
        browser.tuning = true
        var report: [String: Any] = [:]
        var failures: [String] = []
        var fallbacks: [String] = []

        func visit(_ index: Int) {
            guard index < pages.count else {
                browser.settingsPage = before
                if !wasOpen { browser.tuning = false }
                answer([
                    "ok": failures.isEmpty,
                    "entries": SettingsIndex.entries.count,
                    "pages": report,
                    "failures": failures,
                    "viaFallback": fallbacks,
                ])
                return
            }
            let page = pages[index]
            browser.settingsPage = page
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let drawn = finder.drawn[page] ?? []
                let entries = SettingsIndex.entries.filter { $0.page == page }
                var missing: [String] = []
                var referenced = Set<String>()
                for entry in entries {
                    referenced.insert(entry.anchor)
                    if let fallback = entry.fallback { referenced.insert(fallback) }
                    if drawn.contains(entry.anchor) { continue }
                    if let fallback = entry.fallback, drawn.contains(fallback) {
                        fallbacks.append("\(page.rawValue): \(entry.title) → \(fallback)")
                        continue
                    }
                    missing.append("\(entry.title) (\(entry.anchor))")
                }
                let unindexed = drawn.subtracting(referenced).sorted()
                let rows = entries.filter { !$0.isPage }.count
                if rows == 0 { failures.append("\(page.rawValue): no rows indexed") }
                for m in missing { failures.append("\(page.rawValue): entry not drawn — \(m)") }
                for u in unindexed { failures.append("\(page.rawValue): anchor with no entry — \(u)") }
                report[page.rawValue] = ["entries": entries.count, "anchors": drawn.count, "missing": missing, "unindexed": unindexed]
                visit(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { visit(0) }
    }

    /// The title with its matched letters in [brackets].
    private static func marked(_ text: String, _ marks: Set<Int>) -> String {
        var out = ""
        var open = false
        for (i, c) in text.enumerated() {
            let on = marks.contains(i)
            if on != open { out += on ? "[" : "]"; open = on }
            out.append(c)
        }
        if open { out += "]" }
        return out
    }
}
