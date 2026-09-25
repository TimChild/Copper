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

    /// Copper owns the unentitled authenticator. Migrate the old upstream
    /// default once, without overriding a person's later Settings choice.
    @MainActor static func migratePasskeysPreference() {
        guard !Preferences.entitledToPasskeys,
              !Store.settings.bool(forKey: "passkeys.copper") else { return }
        Store.settings.set(true, forKey: "passkeys")
        Store.settings.set(true, forKey: "passkeys.copper")
    }
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

    /// The last thing Bitwarden refused over the bench, for `bw status`.
    @MainActor static var bwLastError: String?

    /// The bench verbs Copper adds; see Bench.swift's switch.
    @MainActor static func bench(_ verb: String, _ request: [String: Any], in browser: Browser) -> [String: Any] {
        switch verb {
        case "flow": return Flow.shared.bench(request, in: browser)
        case "spaces": return Spaces.shared.bench(request, in: browser)
        case "groups": return Groups.shared.bench(request, in: browser)
        case "sections": return Sections.shared.bench(request, in: browser)
        case "passkeys": return PasskeysBench.handle(request)
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
        case "heat": return Heat.shared.bench(request, in: browser)
        case "bw":
            // Bitwarden without the Settings card, for a probe run: `bw status`,
            // `bw server URL`, `bw login EMAIL PASSWORD [OTP]`, `bw unlock PASSWORD`,
            // `bw lock`, `bw sync`, `bw candidates HOST`, `bw choose ID`,
            // `bw share ID on|off|all on|off`, `bw backend keychain|bitwarden`,
            // `bw settings passwords`, and `bw offer keep`.
            // Long ones start and return; `bw status` says where they got to.
            let op = request["op"] as? String ?? "status"
            let words = (request["arg"] as? String ?? "").split(separator: " ").map(String.init)
            let bw = Bitwarden.shared
            func describe() -> [String: Any] {
                let state: String
                switch bw.state {
                case .missing: state = "missing"
                case .unauthenticated: state = "unauthenticated"
                case .locked: state = "locked"
                case .unlocked: state = "unlocked"
                }
                return ["state": state, "server": bw.serverURL, "installed": Bitwarden.installed, "lastError": Fork.bwLastError ?? ""]
            }
            switch op {
            case "status": return describe()
            case "server":
                guard let url = words.first else { return ["error": "bw server needs a URL"] }
                Task { do { try await bw.configure(server: url) } catch { Fork.bwLastError = error.localizedDescription } }
                return ["started": true]
            case "login":
                guard words.count >= 2 else { return ["error": "bw login EMAIL PASSWORD [OTP]"] }
                Fork.bwLastError = nil
                Task { do { try await bw.login(email: words[0], password: words[1], otp: words.count > 2 ? words[2] : nil) } catch { Fork.bwLastError = error.localizedDescription } }
                return ["started": true]
            case "unlock":
                guard let password = words.first else { return ["error": "bw unlock PASSWORD"] }
                Fork.bwLastError = nil
                Task { do { try await bw.unlock(password: password) } catch { Fork.bwLastError = error.localizedDescription } }
                return ["started": true]
            case "lock": Task { await bw.lock() }; return ["started": true]
            case "sync": Task { do { try await bw.sync() } catch { Fork.bwLastError = error.localizedDescription } }; return ["started": true]
            case "settings":
                guard words.first == "passwords" else { return ["error": "bw settings passwords"] }
                // SettingsPanel reads its page once when mounted. Close and
                // reopen so a probe can land directly on Passwords without a
                // native click, while a human still gets the normal panel.
                browser.tuning = false
                browser.settingsPage = .passwords
                Store.settings.set(SettingsPanel.Page.passwords.rawValue, forKey: "settings.page")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { browser.tuning = true }
                return ["started": true, "page": browser.settingsPage.rawValue]
            case "backend":
                guard let value = words.first, let backend = Credentials.Backend(rawValue: value) else {
                    return ["error": "bw backend keychain|bitwarden"]
                }
                browser.prefs.passwordsBackend = backend
                return ["backend": backend.rawValue]
            case "choose":
                guard let id = words.first else { return ["error": "bw choose ID"] }
                guard let tab = browser.active, let host = tab.address?.host() else {
                    return ["error": "no active page"]
                }
                guard let credential = Credentials.candidates(for: host).first(where: { $0.id.string == id }) else {
                    return ["error": "no credential \(id) for \(host)"]
                }
                browser.choose(credential)
                return ["started": true, "id": id]
            case "offer":
                guard words.first == "keep" else { return ["error": "bw offer keep"] }
                guard browser.offering != nil else { return ["error": "no save offer"] }
                browser.keepOffer()
                return ["started": true]
            case "candidates":
                guard let host = words.first else { return ["error": "bw candidates HOST"] }
                return ["candidates": Credentials.candidates(for: host).map { ["id": $0.id.string, "user": $0.user, "host": $0.host, "source": "\($0.source)", "totp": $0.hasTOTP, "agent": AgentAccess.isAllowed($0)] }]
            case "share":
                // `bw share all on|off` or `bw share <id> on|off`
                guard words.count == 2 else { return ["error": "bw share all|ID on|off"] }
                let on = ["on", "true", "1", "yes"].contains(words[1])
                if words[0] == "all" { AgentAccess.shareAll = on; return ["shareAll": on] }
                guard let c = Credentials.all().first(where: { $0.id.string == words[0] }) else { return ["error": "no credential \(words[0])"] }
                AgentAccess.set(c, allowed: on)
                return ["id": c.id.string, "agent": AgentAccess.isAllowed(c)]
            default: return ["error": "unknown bw operation \(op)"]
            }
        case "updates":
            let op = request["op"] as? String ?? "status"
            switch op {
            case "status": return Updates.shared.status
            case "check":
                Updates.shared.check(force: true)
                return ["checking": true]
            case "stub":
                guard let raw = request["arg"] as? String, let url = URL(string: raw) else { return ["error": "updates stub needs a URL"] }
                Updates.shared.manifestURL = url
                return ["manifestURL": url.absoluteString]
            case "dry-run":
                Updates.shared.dryRun = (request["arg"] as? String ?? "off") == "on"
                return ["dryRun": Updates.shared.dryRun]
            case "upgrade":
                Updates.shared.upgrade()
                return ["state": Updates.shared.state == .upgrading ? "upgrading" : "idle", "lastScript": Updates.shared.lastScript?.path ?? ""]
            default: return ["error": "unknown updates operation \(op)"]
            }
        case "summon":
            // ⌘K left open with this text in it, for a look at the bar itself.
            browser.summon()
            browser.typed = request["text"] as? String ?? ""
            return ["offers": browser.offers.count]
        case "window":
            // The whole window as the compositor shows it — sidebar, page,
            // panels — to a PNG. An app may always picture its own windows.
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal && $0.sheetParent == nil })
                    ?? NSApp.keyWindow,
                  let path = request["path"] as? String else { return ["error": "window needs a path"] }
            // A probe may be behind the user's normal Copper window. Bring
            // only this isolated process forward before asking WindowServer
            // for its pixels; otherwise the PNG can be a stale surface.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // The window and whatever hangs off it — a sheet, a popover — in
            // one picture, bottom to top, so a test can see the sheet it opened.
            var ids: [CGWindowID] = [CGWindowID(window.windowNumber)]
            if let sheet = window.attachedSheet { ids.append(CGWindowID(sheet.windowNumber)) }
            for child in window.childWindows ?? [] where child.isVisible { ids.append(CGWindowID(child.windowNumber)) }
            let list = ids.reversed().map { NSNumber(value: $0) } as CFArray
            // Compositing several windows can come back empty without the
            // screen-recording grant; then the frontmost one alone.
            guard let image = CGImage(windowListFromArrayScreenBounds: .null, windowArray: list, imageOption: [.boundsIgnoreFraming, .bestResolution])
                    ?? CGWindowListCreateImage(.null, .optionIncludingWindow, ids.last ?? 0, [.boundsIgnoreFraming, .bestResolution])
            else { return ["error": "no image", "windows": ids.map { Int($0) }] }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
            return ["path": path, "size": [image.width, image.height]]
        default: return ["error": "unknown verb \(verb)"]
        }
    }
}
