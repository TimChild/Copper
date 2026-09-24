import AppKit
import WebKit

// The tools an agent gets, named and shaped like Playwright MCP's so the
// skills already written for that work here unchanged: browser_snapshot,
// browser_click, browser_type, browser_navigate, browser_take_screenshot
// and the rest. Under them is the tab you have open, not a browser of the
// agent's own.
//
// Elements are addressed by `ref` — an id the snapshot hands out (e1, e2…)
// and remembers on the element itself — or by a CSS selector when the agent
// knows one. Clicks and keys go in as real events at the window (Input.swift)
// so pages see trusted input; when a tab has no window to receive them, the
// DOM gets an event of the same shape instead.

enum Tools {
    struct Failure: Error {
        let text: String
    }

    enum Content {
        case text(String)
        case image(Data, mime: String)

        var json: [String: Any] {
            switch self {
            case .text(let s): return ["type": "text", "text": s]
            case .image(let d, let mime): return ["type": "image", "data": d.base64EncodedString(), "mimeType": mime]
            }
        }
    }

    static func instructions(jev: Bool) -> String {
        let base = "This is Copper, the user's own browser: their tabs, their sign-ins. Call browser_tabs to see what is open, browser_snapshot to read the current page as an accessibility tree with refs (e12), then browser_click / browser_type / browser_press_key with those refs. Prefer working in the tab the user is already on; open a new one only when asked. Take a screenshot when layout matters. Nothing here is sandboxed — act as the user would."
        guard jev else { return base }
        return base + " Jev mode is on: for any multi-step task prefer jev_run with one plain-English goal (every concrete value in it) — Copper drives the page itself with browser-use's jev-ultrafast loop, ~200 ms a decision, and returns the trace. jev_observe is the fast indexed read; jev_extract answers a question about the page as JSON; jev_step supervises one decision at a time. Fall back to the browser_* tools where Jev reports BLOCKED, and verify DONE yourself."
    }

    // MARK: - the catalogue

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
        ]
    }

    private static func string(_ description: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var out: [String: Any] = ["type": "string", "description": description]
        for (k, v) in extra { out[k] = v }
        return out
    }
    private static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
    private static func bool(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }

    static let elementProperties: [String: Any] = [
        "element": string("Human-readable element description, used to obtain permission to interact with the element"),
        "ref": string("Exact target element reference from the page snapshot (e.g. e12)"),
        "selector": string("CSS selector, if you know one and have no ref"),
    ]

    static func catalogue(jev: Bool) -> [[String: Any]] {
        jev ? Ultrafast.catalogue + playwright : playwright
    }

    static var playwright: [[String: Any]] {
        [
            tool("browser_tabs", "List, create, close, or select a browser tab", [
                "action": string("Operation to perform", ["enum": ["list", "new", "close", "select"]]),
                "index": number("Tab index (from list) for close/select; omit to act on the current tab"),
                "url": string("Address to open, for new"),
            ], required: ["action"]),
            tool("browser_navigate", "Navigate to a URL in the current tab", ["url": string("The URL to navigate to")], required: ["url"]),
            tool("browser_navigate_back", "Go back to the previous page"),
            tool("browser_navigate_forward", "Go forward to the next page"),
            tool("browser_snapshot", "Capture accessibility snapshot of the current page. Better than a screenshot for reading and for finding refs to act on.", [
                "selector": string("Only the subtree under this CSS selector"),
                "interactive": bool("Only interactive elements (links, buttons, fields) — smaller"),
                "limit": number("Cap on the number of nodes; default 600"),
            ]),
            tool("browser_click", "Perform click on a web page", elementProperties.merging([
                "doubleClick": bool("Double click instead of single"),
                "button": string("Button to click, defaults to left", ["enum": ["left", "right", "middle"]]),
                "modifiers": ["type": "array", "items": ["type": "string", "enum": ["Alt", "Control", "ControlOrMeta", "Meta", "Shift"]], "description": "Modifier keys to hold"] as [String: Any],
            ]) { a, _ in a }),
            tool("browser_type", "Type text into editable element", elementProperties.merging([
                "text": string("Text to type into the element"),
                "submit": bool("Whether to press Enter after typing"),
                "slowly": bool("Type one character at a time, firing key events; default sets the value at once"),
            ]) { a, _ in a }, required: ["text"]),
            tool("browser_fill_form", "Fill multiple form fields", [
                "fields": ["type": "array", "description": "Fields to fill", "items": ["type": "object", "properties": [
                    "name": string("Human-readable field name"),
                    "type": string("Field type", ["enum": ["textbox", "checkbox", "radio", "combobox", "slider"]]),
                    "ref": string("Exact target field reference from the snapshot"),
                    "value": string("Value to fill; for checkbox 'true'/'false'"),
                ]]] as [String: Any],
            ], required: ["fields"]),
            tool("browser_press_key", "Press a key on the keyboard", [
                "key": string("Name of the key to press or a character to generate, such as ArrowLeft, Enter, Escape, Tab, a"),
                "modifiers": ["type": "array", "items": ["type": "string"], "description": "Alt, Control, Meta, Shift"] as [String: Any],
            ], required: ["key"]),
            tool("browser_hover", "Hover over element on page", elementProperties),
            tool("browser_select_option", "Select an option in a dropdown", elementProperties.merging([
                "values": ["type": "array", "items": ["type": "string"], "description": "Values or labels to select"] as [String: Any],
            ]) { a, _ in a }, required: ["values"]),
            tool("browser_drag", "Perform drag and drop between two elements", [
                "startElement": string("Source element description"), "startRef": string("Source ref"),
                "endElement": string("Target element description"), "endRef": string("Target ref"),
            ], required: ["startRef", "endRef"]),
            tool("browser_take_screenshot", "Take a screenshot of the current page (PNG). Coordinates in the image are CSS pixels of the page.", [
                "type": string("Image format", ["enum": ["png", "jpeg"]]),
                "fullPage": bool("Whole scrollable page rather than the viewport"),
                "ref": string("Screenshot just this element"),
                "filename": string("Also save to this path"),
            ]),
            tool("browser_evaluate", "Evaluate JavaScript expression on page or element", [
                "function": string("() => { /* code */ } or (element) => { /* code */ } when ref is given"),
                "ref": string("Element to pass to the function"),
            ], required: ["function"]),
            tool("browser_wait_for", "Wait for text to appear or disappear, or for a time to pass", [
                "text": string("Text to wait for"), "textGone": string("Text to wait to disappear"), "time": number("Seconds to wait"),
            ]),
            tool("browser_scroll", "Scroll the page or an element", [
                "ref": string("Element to scroll into view, or to scroll within"),
                "deltaY": number("Pixels to scroll down (negative for up); default one screen"),
                "deltaX": number("Pixels to scroll right"),
            ]),
            tool("browser_get_text", "The page's readable text (or an element's), for reading without a snapshot", ["ref": string("Element ref"), "selector": string("CSS selector")]),
            tool("browser_console_messages", "Console messages captured on the current page since it loaded"),
            tool("browser_find", "Find on the page: the refs of elements whose text matches", ["text": string("Text to look for")], required: ["text"]),
            tool("browser_resize", "Resize the browser window", ["width": number("Width"), "height": number("Height")], required: ["width", "height"]),
            tool("browser_close", "Close the current tab"),
            tool("browser_groups", "Copper's tab groups: list them, or move the current tab into one", [
                "action": string("list, assign, remove, suggest", ["enum": ["list", "assign", "remove", "suggest"]]),
                "group": string("Group name for assign (created if new)"),
            ], required: ["action"]),
        ] + Probe.catalogue
    }

    // MARK: - dispatch

    @MainActor
    static func call(_ name: String, _ args: [String: Any], in browser: Browser) async throws -> [Content] {
        switch name {
        case "browser_tabs": return try await tabs(args, in: browser)
        case "browser_close":
            let tab = try current(browser)
            browser.close(tab)
            return [.text("Closed. \(tabList(browser))")]
        case "browser_resize":
            guard let w = args["width"] as? NSNumber, let h = args["height"] as? NSNumber else { throw Failure(text: "width and height") }
            guard let window = Links.window ?? NSApp.windows.first(where: { $0.isVisible }) else { throw Failure(text: "no window") }
            var frame = window.frame
            frame.size = CGSize(width: w.doubleValue, height: h.doubleValue)
            window.setFrame(frame, display: true, animate: false)
            return [.text("Window is \(Int(w.doubleValue))×\(Int(h.doubleValue))")]
        case "browser_groups": return groups(args, in: browser)
        case "jev_run", "jev_step", "jev_observe", "jev_extract": return try await Ultrafast.call(name, args, in: browser)
        default: break
        }

        let tab = try current(browser)
        // A sleeping tab comes back for the agent the way it does for a click.
        if tab.asleep { _ = tab.wake() } else if tab.hollow { tab.revive() }
        let web = tab.web

        switch name {
        case "browser_perf_probe": return try await Probe.run(args, in: browser)
        case "browser_navigate":
            guard let raw = args["url"] as? String else { throw Failure(text: "url required") }
            guard let url = Address.url(from: raw) else { throw Failure(text: "not an address: \(raw)") }
            tab.go(to: url)
            try await settle(tab)
            return [.text(pageLine(tab))]
        case "browser_navigate_back":
            web.goBack()
            try await settle(tab)
            return [.text(pageLine(tab))]
        case "browser_navigate_forward":
            web.goForward()
            try await settle(tab)
            return [.text(pageLine(tab))]
        case "browser_snapshot":
            let interactive = (args["interactive"] as? Bool) ?? false
            let limit = (args["limit"] as? NSNumber)?.intValue ?? 600
            let selector = args["selector"] as? String
            let text = try await Page.snapshot(web, selector: selector, interactive: interactive, limit: limit)
            return [.text("\(pageLine(tab))\n\n\(text)")]
        case "browser_click":
            let target = try locator(args)
            let rect = try await Page.prepare(web, target)
            let button = (args["button"] as? String) ?? "left"
            let double = (args["doubleClick"] as? Bool) ?? false
            let mods = Input.modifiers(from: args["modifiers"] as? [String] ?? [])
            if Input.canPost(to: web) {
                Input.click(web, at: rect.center, button: button, count: double ? 2 : 1, modifiers: mods)
            } else {
                _ = try await Page.js(web, "window.__copper.click(\(Page.quote(target.script)), \(double), \(Page.quote(button)))")
            }
            try await settle(tab, budget: 3)
            return [.text("Clicked \(args["element"] as? String ?? target.script). \(pageLine(tab))")]
        case "browser_hover":
            let target = try locator(args)
            let rect = try await Page.prepare(web, target)
            if Input.canPost(to: web) { Input.move(web, to: rect.center) }
            else { _ = try await Page.js(web, "window.__copper.hover(\(Page.quote(target.script)))") }
            return [.text("Hovering \(args["element"] as? String ?? target.script)")]
        case "browser_type":
            let target = try locator(args)
            guard let text = args["text"] as? String else { throw Failure(text: "text required") }
            let submit = (args["submit"] as? Bool) ?? false
            let slowly = (args["slowly"] as? Bool) ?? false
            let rect = try await Page.prepare(web, target)
            if Input.canPost(to: web) {
                Input.click(web, at: rect.center, button: "left", count: 1, modifiers: [])
                try await Task.sleep(nanoseconds: 60_000_000)
                _ = try await Page.js(web, "window.__copper.focus(\(Page.quote(target.script)))")
                if slowly {
                    Input.type(web, text)
                } else {
                    _ = try await Page.js(web, "window.__copper.setValue(\(Page.quote(target.script)), \(Page.quote(text)))")
                }
                if submit { Input.key(web, "Enter", modifiers: []) }
            } else {
                _ = try await Page.js(web, "window.__copper.setValue(\(Page.quote(target.script)), \(Page.quote(text)))")
                if submit { _ = try await Page.js(web, "window.__copper.submit(\(Page.quote(target.script)))") }
            }
            if submit { try await settle(tab, budget: 3) }
            return [.text("Typed into \(args["element"] as? String ?? target.script)\(submit ? " and submitted" : ""). \(pageLine(tab))")]
        case "browser_fill_form":
            guard let fields = args["fields"] as? [[String: Any]] else { throw Failure(text: "fields required") }
            var lines: [String] = []
            for field in fields {
                guard let ref = field["ref"] as? String else { continue }
                let value = (field["value"] as? String) ?? ""
                let kind = (field["type"] as? String) ?? "textbox"
                let result = try await Page.js(web, "window.__copper.fill(\(Page.quote("ref:" + ref)), \(Page.quote(kind)), \(Page.quote(value)))")
                lines.append("\(field["name"] as? String ?? ref): \(Page.render(result))")
            }
            return [.text(lines.joined(separator: "\n"))]
        case "browser_press_key":
            guard let key = args["key"] as? String else { throw Failure(text: "key required") }
            let mods = Input.modifiers(from: args["modifiers"] as? [String] ?? [])
            if Input.canPost(to: web) {
                Input.key(web, key, modifiers: mods)
            } else {
                _ = try await Page.js(web, "window.__copper.key(\(Page.quote(key)))")
            }
            try await settle(tab, budget: 2)
            return [.text("Pressed \(key). \(pageLine(tab))")]
        case "browser_select_option":
            let target = try locator(args)
            let values = (args["values"] as? [String]) ?? []
            let result = try await Page.js(web, "window.__copper.select(\(Page.quote(target.script)), \(Page.quote(values)))")
            return [.text(Page.render(result))]
        case "browser_drag":
            guard let a = args["startRef"] as? String, let b = args["endRef"] as? String else { throw Failure(text: "startRef and endRef") }
            let from = try await Page.prepare(web, Locator(ref: a))
            let to = try await Page.prepare(web, Locator(ref: b))
            if Input.canPost(to: web) {
                Input.drag(web, from: from.center, to: to.center)
            } else {
                _ = try await Page.js(web, "window.__copper.drag(\(Page.quote("ref:" + a)), \(Page.quote("ref:" + b)))")
            }
            return [.text("Dragged \(a) to \(b)")]
        case "browser_take_screenshot":
            let jpeg = (args["type"] as? String) == "jpeg"
            let full = (args["fullPage"] as? Bool) ?? false
            var rect: CGRect?
            if let ref = args["ref"] as? String { rect = try await Page.prepare(web, Locator(ref: ref)) }
            let data = try await Page.screenshot(web, rect: rect, fullPage: full, jpeg: jpeg)
            if let path = args["filename"] as? String { try? data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
            return [.image(data, mime: jpeg ? "image/jpeg" : "image/png"), .text(pageLine(tab))]
        case "browser_evaluate":
            guard let function = args["function"] as? String else { throw Failure(text: "function required") }
            let script: String
            if let ref = args["ref"] as? String {
                script = "(\(function))(window.__copper.find(\(Page.quote("ref:" + ref))))"
            } else {
                script = "(\(function))()"
            }
            let result = try await Page.js(web, script)
            return [.text(Page.render(result))]
        case "browser_wait_for":
            if let seconds = (args["time"] as? NSNumber)?.doubleValue {
                try await Task.sleep(nanoseconds: UInt64(min(seconds, 30) * 1_000_000_000))
            }
            let deadline = Date().addingTimeInterval(15)
            if let text = args["text"] as? String {
                while Date() < deadline {
                    if let hit = try await Page.js(web, "document.body && document.body.innerText.includes(\(Page.quote(text)))") as? Bool, hit { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            if let text = args["textGone"] as? String {
                while Date() < deadline {
                    if let hit = try await Page.js(web, "document.body && document.body.innerText.includes(\(Page.quote(text)))") as? Bool, !hit { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            return [.text(pageLine(tab))]
        case "browser_scroll":
            let dy = (args["deltaY"] as? NSNumber)?.doubleValue
            let dx = (args["deltaX"] as? NSNumber)?.doubleValue ?? 0
            if let ref = args["ref"] as? String, dy == nil {
                _ = try await Page.prepare(web, Locator(ref: ref))
                return [.text("Scrolled \(ref) into view")]
            }
            let y = dy ?? (web.bounds.height * 0.85)
            let within = (args["ref"] as? String).map { "ref:" + $0 } ?? ""
            _ = try await Page.js(web, "window.__copper.scroll(\(Page.quote(within)), \(dx), \(y))")
            try await Task.sleep(nanoseconds: 120_000_000)
            return [.text("Scrolled by \(Int(dx)),\(Int(y)). \(pageLine(tab))")]
        case "browser_get_text":
            let target = (try? locator(args))
            let result = try await Page.js(web, "window.__copper.text(\(Page.quote(target?.script ?? "")))")
            return [.text(Page.render(result))]
        case "browser_console_messages":
            let result = try await Page.js(web, "JSON.stringify(window.__copper.console())")
            return [.text(Page.render(result))]
        case "browser_find":
            guard let text = args["text"] as? String else { throw Failure(text: "text required") }
            let result = try await Page.js(web, "window.__copper.findText(\(Page.quote(text)))")
            return [.text(Page.render(result))]
        default:
            throw Failure(text: "Unknown tool \(name)")
        }
    }

    // MARK: - tabs

    @MainActor
    static func current(_ browser: Browser) throws -> Tab {
        guard let tab = browser.active else { throw Failure(text: "no active tab") }
        return tab
    }

    @MainActor
    static func tabList(_ browser: Browser) -> String {
        var lines: [String] = []
        for (i, tab) in browser.tabs.enumerated() {
            let marker = tab.id == browser.activeID ? "(current) " : ""
            let group = Groups.shared.group(of: tab).map { " [\($0.name)]" } ?? ""
            let pin = tab.pin != nil ? " (pinned)" : ""
            // Only a tab that is actually burning gets a figure; the rest stay quiet.
            let heat = Heat.shared.reading(for: tab).flatMap { $0.sustained >= 10 ? " {cpu \(Int($0.sustained))%}" : nil } ?? ""
            lines.append("- \(i): \(marker)[\(tab.title)] (\(tab.address?.absoluteString ?? "about:blank"))\(pin)\(group)\(heat)")
        }
        let gpu = Heat.shared.gpu.flatMap { $0 >= 10 ? "\nGPU process (shared by all tabs): \(Int($0))% of a core" : nil } ?? ""
        return "### Open tabs\n" + lines.joined(separator: "\n") + gpu
    }

    @MainActor
    private static func tabs(_ args: [String: Any], in browser: Browser) async throws -> [Content] {
        let action = (args["action"] as? String) ?? "list"
        let index = (args["index"] as? NSNumber)?.intValue
        func pick() throws -> Tab {
            if let index {
                guard browser.tabs.indices.contains(index) else { throw Failure(text: "no tab \(index) — \(tabList(browser))") }
                return browser.tabs[index]
            }
            return try current(browser)
        }
        switch action {
        case "list":
            return [.text(tabList(browser))]
        case "new":
            let tab: Tab
            if let raw = args["url"] as? String, let url = Address.url(from: raw) {
                tab = browser.open(url, foreground: true)
                try await settle(tab)
            } else {
                browser.newTab()
                tab = try current(browser)
            }
            return [.text("Opened. \(tabList(browser))")]
        case "close":
            browser.close(try pick())
            return [.text("Closed. \(tabList(browser))")]
        case "select":
            let tab = try pick()
            browser.select(tab)
            return [.text("Selected. \(tabList(browser))")]
        default:
            throw Failure(text: "action must be list, new, close or select")
        }
    }

    @MainActor
    private static func groups(_ args: [String: Any], in browser: Browser) -> [Content] {
        let action = (args["action"] as? String) ?? "list"
        let groups = Groups.shared
        switch action {
        case "assign":
            guard let tab = browser.active, let name = args["group"] as? String, !name.isEmpty else { return [.text("group name required")] }
            groups.assign(tab, to: groups.create(named: name), in: browser)
            return [.text("Grouped into \(name)")]
        case "remove":
            if let tab = browser.active { groups.remove(tab) }
            return [.text("Removed from its group")]
        case "suggest":
            if let tab = browser.active { Grouper.shared.suggest(for: tab, in: browser, forced: true) }
            return [.text("Asked; the suggestion will appear under the tab")]
        default:
            let lines = groups.all.map { g in "- \(g.name): " + groups.members(of: g.id, in: browser).map { "[\($0.title)]" }.joined(separator: ", ") }
            return [.text(lines.isEmpty ? "No groups" : lines.joined(separator: "\n"))]
        }
    }

    // MARK: - helpers

    struct Locator {
        /// `ref:e12` or `css:…` — what the page script expects.
        let script: String
        init(ref: String) { script = "ref:" + ref }
        init(css: String) { script = "css:" + css }
    }

    private static func locator(_ args: [String: Any]) throws -> Locator {
        if let ref = args["ref"] as? String, !ref.isEmpty { return Locator(ref: ref) }
        if let css = args["selector"] as? String, !css.isEmpty { return Locator(css: css) }
        throw Failure(text: "ref (from browser_snapshot) or selector required")
    }

    @MainActor
    static func pageLine(_ tab: Tab) -> String {
        "### Page\n- URL: \(tab.address?.absoluteString ?? "about:blank")\n- Title: \(tab.title)"
    }

    /// Until the page stops loading, plus a beat, or the budget is spent.
    @MainActor
    static func settle(_ tab: Tab, budget: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(budget)
        // Give a navigation a moment to begin before asking whether it's done.
        try await Task.sleep(nanoseconds: 120_000_000)
        while Date() < deadline {
            if !tab.loading { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
