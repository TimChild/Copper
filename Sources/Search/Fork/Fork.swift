import AppKit
import Foundation

// Everything Copper adds to Search lives under Fork/. Upstream files get
// one-line hooks into here and nothing else, so a rebase onto the next
// upstream release touches as few of their lines as possible. See PATCHES.md.
enum Fork {
    static let name = "Copper"
    static let bundle = "com.collinrijock.copper"
    /// Upstream's updater verifies Office Commun's signature against their
    /// feed. Running it from a Copper build would replace Copper with Search.
    /// Until there is a Copper feed and a signing identity, it stays off.
    static let updates = false
    /// What the MCP server and the model clients say they are.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// A group name from a host: `docs.github.com` → `Github`. For "New
    /// Group from Tab", where a word is needed before anyone has typed one.
    static func brand(_ host: String?) -> String {
        guard let host = host?.lowercased(), !host.isEmpty else { return "Group" }
        var parts = host.split(separator: ".").map(String.init)
        if parts.first == "www" { parts.removeFirst() }
        // The registrable label: the one before the public suffix, roughly —
        // second from the end, or third when the end looks like `co.uk`.
        let two = Set(["co", "com", "org", "net", "ac", "gov", "edu"])
        let core: String
        if parts.count >= 3, two.contains(parts[parts.count - 2]), parts.last!.count == 2 { core = parts[parts.count - 3] }
        else if parts.count >= 2 { core = parts[parts.count - 2] }
        else { core = parts.first ?? "Group" }
        return core.prefix(1).uppercased() + core.dropFirst()
    }

    /// The bench verbs Copper adds; see Bench.swift's switch.
    @MainActor static func bench(_ verb: String, _ request: [String: Any], in browser: Browser) -> [String: Any] {
        switch verb {
        case "spaces": return Spaces.shared.bench(request, in: browser)
        case "groups": return Groups.shared.bench(request, in: browser)
        case "sections": return Sections.shared.bench(request, in: browser)
        case "agent":
            // `agent ask TEXT` / `agent chat|open|close|clear` are the pane's; the rest is the server's.
            if let op = request["op"] as? String, ["ask", "chat", "open", "close", "clear"].contains(op) { return Agent.shared.bench(request, in: browser) }
            if request["op"] as? String == "servers" { Task { await Servers.shared.reload() }; return ["reloading": true] }
            return MCP.shared.bench(request)
        case "ai":
            // `ai` reports; `ai mode off|ask|auto`; `ai last` is the grouper's last note.
            let arg = request["arg"] as? String ?? ""
            if request["op"] as? String == "mode", let mode = Intelligence.GroupingMode(rawValue: arg) { Intelligence.shared.keys.grouping = mode }
            let k = Intelligence.shared.keys
            return ["jev": Intelligence.shared.jevReady, "router": Intelligence.shared.routerReady, "routerModel": k.routerModel,
                    "routerURL": k.routerURL, "mode": k.grouping.rawValue, "threshold": k.threshold, "last": Grouper.shared.lastNote]
        case "split":
            // `split` toggles; `split ID` opens beside the active tab; `split off` closes.
            let arg = request["arg"] as? String ?? ""
            if arg == "off" { Split.shared.close() }
            else if arg.isEmpty { Split.shared.toggle(in: browser) }
            else if let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(arg.lowercased()) }) { Split.shared.open(with: tab, in: browser) }
            else { return ["error": "no tab \(arg)"] }
            return ["side": Split.shared.side.map { String($0.uuidString.prefix(8)).lowercased() } ?? "", "active": browser.activeID.map { String($0.uuidString.prefix(8)).lowercased() } ?? ""]
        case "bar":
            // What ⌘K would offer for this text, without the keyboard.
            browser.summon()
            browser.typed = request["text"] as? String ?? ""
            let rows = browser.offers.map { ["key": $0.key, "title": $0.title, "kind": "\($0.kind)", "url": $0.url.absoluteString] }
            if request["go"] as? Bool == true, !browser.offers.isEmpty { browser.picked = 0; browser.submit() }
            else { browser.editing = false; browser.typed = "" }
            return ["offers": rows]
        case "swipe": return SpaceSwipe.bench(request["arg"] as? String ?? "left", in: browser)
        case "summon":
            // ⌘K left open with this text in it, for a look at the bar itself.
            browser.summon()
            browser.typed = request["text"] as? String ?? ""
            return ["offers": browser.offers.count]
        case "window":
            // The whole window as the compositor shows it — sidebar, page,
            // panels — to a PNG. An app may always picture its own windows.
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.level == .normal }),
                  let path = request["path"] as? String else { return ["error": "window needs a path"] }
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return ["error": "no image"] }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
            return ["path": path, "size": [image.width, image.height]]
        default: return ["error": "unknown verb \(verb)"]
        }
    }
}
