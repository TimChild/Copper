import AppKit
import SwiftUI
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
    /// What the last `bench bw login` / `bw code` came to: signedIn, needsCode:…, chooseMethod:…, failed, cancelled.
    @MainActor static var bwLastStep: String?

    /// The bench verbs Copper adds; see Bench.swift's switch.
    @MainActor static func bench(_ verb: String, _ request: [String: Any], in browser: Browser) -> [String: Any] {
        switch verb {
        case "flow": return Flow.shared.bench(request, in: browser)
        case "history": return Flow.shared.bench(request, in: browser)
        case "spaces": return Spaces.shared.bench(request, in: browser)
        case "ext-manager": return ExtensionManager.shared.bench(request, in: browser)
        case "groups": return Groups.shared.bench(request, in: browser)
        case "sections": return Sections.shared.bench(request, in: browser)
        case "storage": return StorageImport.shared.bench(request, in: browser)
        case "passkeys": return PasskeysBench.handle(request)
        case "agent":
            // `agent ask TEXT` / `agent chat|open|close|clear` are the pane's; the rest is the server's.
            if let op = request["op"] as? String, ["ask", "chat", "open", "close", "clear", "stop", "selftest"].contains(op) { return Agent.shared.bench(request, in: Windows.current) }
            if request["op"] as? String == "servers" { Task { await Servers.shared.reload() }; return ["reloading": true] }
            return MCP.shared.bench(request)
        case "windows": return Windows.bench(request)
        case "easels": return Easels.bench(request, in: browser)
        case "ai":
            // `ai` reports; `ai mode off|ask|auto`; `ai lane key|claude`; `ai tier haiku|sonnet|opus`;
            // `ai last` is the grouper's last note.
            let arg = request["arg"] as? String ?? ""
            let op = request["op"] as? String ?? ""
            if op == "mode", let mode = Intelligence.GroupingMode(rawValue: arg) {
                Intelligence.shared.keys.grouping = mode
            } else if op == "lane", let lane = Intelligence.Lane(rawValue: arg.lowercased()) {
                Intelligence.shared.keys.lane = lane
            } else if op == "router" {
                // `ai router URL KEY MODEL`: a stand-in router for a probe world's agent tests.
                let bits = arg.split(separator: " ").map(String.init)
                if bits.count >= 3 {
                    Intelligence.shared.keys.routerURL = bits[0]
                    Intelligence.shared.keys.routerKey = bits[1]
                    Intelligence.shared.keys.routerModel = bits[2]
                    Intelligence.shared.keys.lane = .key
                }
            } else if op == "tier", let tier = Intelligence.Tier(rawValue: arg.lowercased()) {
                Intelligence.shared.keys.tier = tier
            }
            let k = Intelligence.shared.keys
            return ["jev": Intelligence.shared.jevReady, "router": Intelligence.shared.routerReady, "routerModel": k.routerModel,
                    "routerURL": k.routerURL, "lane": k.lane.rawValue, "tier": k.tier.rawValue,
                    "model": Intelligence.shared.modelName, "modelReady": Intelligence.shared.modelReady,
                    "claudeReady": Intelligence.shared.claudeReady, "mode": k.grouping.rawValue,
                    "threshold": k.threshold, "last": Grouper.shared.lastNote]
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
            let started = DispatchTime.now().uptimeNanoseconds
            browser.summon()
            browser.typed = request["text"] as? String ?? ""
            let rows = browser.offers.map { ["key": $0.key, "title": $0.title, "kind": "\($0.kind)", "url": $0.url.absoluteString, "badge": $0.badge, "detail": $0.detail] }
            let completion = browser.ending ?? ""
            if request["go"] as? Bool == true, !browser.offers.isEmpty { browser.picked = 0; browser.submit() }
            else { browser.editing = false; browser.typed = "" }
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            return ["offers": rows, "completion": completion, "milliseconds": milliseconds]
        case "swipe": return SpaceSwipe.bench(request["arg"] as? String ?? "left", in: browser)
        case "mouse": return MouseButtons.bench(request, in: browser)
        case "heat": return Heat.shared.bench(request, in: browser)
        case "downloads":
            let op = request["op"] as? String ?? "list"
            let argument = request["arg"] as? String ?? ""
            func state(_ item: Downloads.Item) -> String {
                switch item.state {
                case .running: return "running"
                case .finished: return "finished"
                case .failed: return "failed"
                case .cancelled: return "cancelled"
                }
            }
            func describe(_ item: Downloads.Item) -> [String: Any] {
                let fraction: Any = item.total.map { $0 > 0 ? Double(item.done) / Double($0) : 0 } ?? NSNull()
                return ["id": item.id.uuidString, "name": item.name, "state": state(item),
                        "done": item.done, "total": item.total ?? NSNull(), "fraction": fraction,
                        "speed": item.speed, "file": item.file?.path ?? ""]
            }
            let downloads = Downloads.shared
            switch op {
            case "open": downloads.popoverOpen = true; downloads.seen()
            case "close": downloads.popoverOpen = false
            case "cancel", "retry":
                // An id, or the start of one — never nothing, which would
                // match the first row and act on a download nobody named.
                let key = argument.lowercased()
                guard !key.isEmpty, let item = downloads.items.first(where: { $0.id.uuidString.lowercased().hasPrefix(key) }) else { return ["error": "no download \(argument)"] }
                if op == "cancel" { downloads.cancel(item) } else { downloads.retry(item, in: browser) }
            case "clear": downloads.clearFinished()
            case "start":
                guard Store.testing, let raw = URL(string: argument), let tab = browser.active else {
                    return ["error": "downloads start needs a URL in a probe world"]
                }
                tab.web.startDownload(using: URLRequest(url: raw)) { download in
                    browser.keep(download)
                }
                return ["started": true]
            case "list": break
            default: return ["error": "unknown downloads operation \(op)"]
            }
            return ["items": downloads.items.map(describe), "unseen": downloads.unseen,
                    "doorShowing": downloads.doorShowing, "popoverOpen": downloads.popoverOpen]
        case "bw":
            // Bitwarden without the Settings card, for a probe run: `bw status`,
            // `bw server URL`, `bw login EMAIL PASSWORD [OTP]`, `bw unlock PASSWORD`,
            // `bw lock`, `bw sync`, `bw candidates HOST`, `bw choose ID`,
            // `bw share ID on|off|all on|off`, `bw backend keychain|bitwarden`,
            // `bw settings passwords`, and `bw offer keep`.
            // `bw identities`, `bw cards`, `bw fields HOST`, `bw usernames`,
            // `bw counts`, and `bw autofill card|identity ID` expose the
            // unlocked autofill cache to an isolated probe world. Long ones
            // start and return; `bw status` says where they got to.
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
                var out: [String: Any] = ["state": state, "server": bw.serverURL, "installed": Bitwarden.installed, "lastError": Fork.bwLastError ?? ""]
                // A sign-in `bw` is holding open for a code, and what kind.
                if let pending = bw.pendingLogin {
                    var waiting: [String: Any] = ["email": pending.email]
                    switch pending.prompt {
                    case .newDevice: waiting["prompt"] = "newDevice"
                    case .twoStep(let method): waiting["prompt"] = "twoStep"; waiting["method"] = method.map { $0 as Any } ?? NSNull()
                    }
                    out["pending"] = waiting
                }
                if let step = Fork.bwLastStep { out["step"] = step }
                return out
            }
            switch op {
            case "status": return describe()
            case "server":
                guard let url = words.first else { return ["error": "bw server needs a URL"] }
                Task { do { try await bw.configure(server: url) } catch { Fork.bwLastError = error.localizedDescription } }
                return ["started": true]
            case "login":
                // bw login EMAIL PASSWORD [OTP] [--method N]: the sign-in as
                // Settings runs it. `status` then says `step`: signedIn, or
                // needsCode / chooseMethod with the prompt `bw` is holding.
                var rest = words
                var method: Int?
                if let at = rest.firstIndex(of: "--method"), at + 1 < rest.count {
                    method = Int(rest[at + 1])
                    rest.removeSubrange(at...(at + 1))
                }
                guard rest.count >= 2 else { return ["error": "bw login EMAIL PASSWORD [OTP] [--method N]"] }
                Fork.bwLastError = nil
                Fork.bwLastStep = nil
                Task {
                    do {
                        let outcome = try await bw.login(email: rest[0], password: rest[1], otp: rest.count > 2 ? rest[2] : nil, method: method)
                        switch outcome {
                        case .signedIn: Fork.bwLastStep = "signedIn"
                        case .step(.chooseMethod(let methods)): Fork.bwLastStep = "chooseMethod:" + methods.map { String($0.id) }.joined(separator: ",")
                        case .step(.needsCode(.newDevice)): Fork.bwLastStep = "needsCode:newDevice"
                        case .step(.needsCode(.twoStep(let m))): Fork.bwLastStep = "needsCode:twoStep:" + (m.map(String.init) ?? "-")
                        }
                    } catch { Fork.bwLastError = error.localizedDescription; Fork.bwLastStep = "failed" }
                }
                return ["started": true]
            case "code":
                // bw code OTP: the code for the sign-in `bw` is holding open.
                guard let code = words.first else { return ["error": "bw code OTP"] }
                Fork.bwLastError = nil
                Fork.bwLastStep = nil
                Task {
                    do { try await bw.submit(code: code); Fork.bwLastStep = "signedIn" }
                    catch { Fork.bwLastError = error.localizedDescription; Fork.bwLastStep = "failed" }
                }
                return ["started": true]
            case "cancel":
                bw.cancelPendingLogin()
                Fork.bwLastStep = "cancelled"
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
            case "identities":
                return ["identities": Autofill.identities.map { identity in
                    ["id": identity.id, "name": identity.name, "fullName": identity.fullName,
                     "summary": identity.summary, "agent": Autofill.isAllowed(identity.id)]
                }]
            case "cards":
                return ["cards": Autofill.cards.map { card in
                    ["id": card.id, "name": card.name, "label": card.label,
                     "holder": card.cardholderName, "agent": Autofill.isAllowed(card.id)]
                }]
            case "fields":
                guard let host = words.first else { return ["error": "bw fields HOST"] }
                return ["fields": Autofill.fields(for: host).map { field in
                    ["item": field.itemName, "name": field.name, "hidden": field.hidden]
                }]
            case "usernames":
                return ["usernames": Autofill.topUsernames]
            case "counts":
                let counts = bw.counts
                return ["counts": ["logins": counts.logins, "identities": counts.identities,
                                   "cards": counts.cards, "notes": counts.notes]]
            case "autofill":
                guard words.count == 2, let tab = browser.active else {
                    return ["error": "bw autofill card|identity ID (requires an active page)"]
                }
                let kind = words[0].lowercased()
                let id = words[1].hasPrefix("bw:") ? String(words[1].dropFirst(3)) : words[1]
                if kind == "card", let card = Autofill.cards.first(where: { $0.id == id }) {
                    // Use the page-side path directly until Browser's Suggestion
                    // picker API lands; it has the same in-process semantics.
                    tab.fillValues(card.values())
                    return ["started": true, "kind": kind, "id": card.id]
                }
                if kind == "identity", let identity = Autofill.identities.first(where: { $0.id == id }) {
                    tab.fillValues(identity.values())
                    return ["started": true, "kind": kind, "id": identity.id]
                }
                return ["error": "no \(kind) \(words[1])"]
            case "share":
                // `bw share all on|off` or `bw share <id> on|off`
                guard words.count == 2 else { return ["error": "bw share all|ID on|off"] }
                let on = ["on", "true", "1", "yes"].contains(words[1])
                if words[0] == "all" { AgentAccess.shareAll = on; return ["shareAll": on] }
                let rawID = words[0].hasPrefix("bw:") ? String(words[0].dropFirst(3)) : words[0]
                if let c = Credentials.all().first(where: {
                    $0.id.string == words[0] || $0.id.string == "bw:\(rawID)"
                }) {
                    AgentAccess.set(c, allowed: on)
                    return ["id": c.id.string, "agent": AgentAccess.isAllowed(c)]
                }
                if Autofill.identities.contains(where: { $0.id == rawID })
                    || Autofill.cards.contains(where: { $0.id == rawID }) {
                    var ids = AgentAccess.allowed
                    let stableID = "bw:\(rawID)"
                    if on { ids.insert(stableID) } else { ids.remove(stableID) }
                    AgentAccess.allowed = ids
                    return ["id": stableID, "agent": Autofill.isAllowed(rawID)]
                }
                return ["error": "no credential \(words[0])"]
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
            case "stage":
                Updates.shared.stage(force: true)
                return ["downloading": Updates.shared.downloading]
            case "upgrade":
                Updates.shared.upgrade()
                return Updates.shared.status
            default: return ["error": "unknown updates operation \(op)"]
            }
        case "drive":
            // The driver timeline as data: who is driving, live/busy, the
            // rows; `stop` / `resume` / `pane on|off` / `clear` do what the
            // pill and the pane do.
            let drive = Drive.shared
            switch request["op"] as? String ?? "status" {
            case "stop": drive.stop()
            case "resume": drive.resume()
            case "clear": drive.dismiss()
            case "pane": drive.paneOpen = (request["arg"] as? String ?? "on") != "off"
            default: break
            }
            var out: [String: Any] = ["live": drive.live, "busy": drive.busy, "paneOpen": drive.paneOpen,
                                      "refusing": drive.refusingUntil != nil, "stopRequested": drive.stopRequested]
            if let run = drive.run {
                out["run"] = [
                    "driver": run.driver.name, "goal": run.goal, "status": run.status.rawValue, "note": run.note,
                    "thought": run.thought ?? "", "url": run.url, "title": run.title,
                    "cycles": run.cycles.map { c -> [String: Any] in
                        var row: [String: Any] = ["n": c.number, "phases": c.phases.map { ["kind": $0.kind.rawValue, "title": $0.title, "detail": $0.detail ?? "", "ms": $0.ms ?? -1] as [String: Any] }]
                        if let o = c.outcome {
                            row["outcome"] = ["operation": o.operation, "label": o.label, "text": o.text ?? "", "pageChanged": o.pageChanged.map { $0 as Any } ?? NSNull(), "error": o.error ?? ""] as [String: Any]
                        }
                        return row
                    },
                ] as [String: Any]
            }
            return out
        case "render":
            // One SwiftUI card drawn to a PNG on its own, off any window —
            // for looking at a Settings card or the driver pane without
            // scrolling a panel to it or bringing a window forward.
            guard let path = request["path"] as? String else { return ["error": "render needs a path"] }
            let which = request["op"] as? String ?? ""
            let view: AnyView
            switch which {
            case "bitwarden": view = AnyView(BitwardenCard(browser: browser).frame(width: 460).padding(12).background(Palette.wash))
            case "drive": view = AnyView(DrivePane(browser: browser).frame(height: 560))
            default: return ["error": "render bitwarden|drive PATH"]
            }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return ["error": "no image"] }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
            return ["path": path, "size": [image.width, image.height]]
        case "summon":
            // ⌘K left open with this text in it, for a look at the bar itself.
            browser.summon()
            browser.typed = request["text"] as? String ?? ""
            return ["offers": browser.offers.count]
        case "window":
            // The whole window as the compositor shows it — sidebar, page,
            // panels — to a PNG. An app may always picture its own windows.
            let nth = (request["index"] as? Int).flatMap { i in Windows.all.indices.contains(i) ? Windows.window(of: Windows.all[i]) : nil }
            guard let window = nth ?? Links.window
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.level == .normal && $0.sheetParent == nil })
                    ?? NSApp.keyWindow,
                  let path = request["path"] as? String else { return ["error": "window needs a path"] }
            // A probe may be behind the user's normal Copper window. Bring
            // only this isolated process forward before asking WindowServer
            // for its pixels; otherwise the PNG can be a stale surface.
            // With several browser windows, the one asked for alone. (Fork: windows)
            let hasPopover = nth == nil && NSApp.windows.contains { $0 !== window && $0.isVisible && $0.level == .normal && Windows.owner(of: $0) == nil }
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            // Making the main window key dismisses SwiftUI's popover. Leave
            // the already-visible door popover alone for its evidence shot.
            if !hasPopover { window.makeKeyAndOrderFront(nil) }
            // The window and whatever hangs off it — a sheet, a popover — in
            // one picture, bottom to top, so a test can see the sheet it opened.
            var ids: [CGWindowID] = [CGWindowID(window.windowNumber)]
            if let sheet = window.attachedSheet { ids.append(CGWindowID(sheet.windowNumber)) }
            for child in window.childWindows ?? [] where child.isVisible { ids.append(CGWindowID(child.windowNumber)) }
            // SwiftUI popovers are sibling windows rather than child windows;
            // include the visible one so a probe picture is the same thing a
            // person sees, not just the page beneath its door.
            for other in NSApp.windows where other !== window && other.isVisible && other.level == .normal && Windows.owner(of: other) == nil {
                ids.append(CGWindowID(other.windowNumber))
            }
            let list = ids.reversed().map { NSNumber(value: $0) } as CFArray
            // Compositing several windows can come back empty without the
            // screen-recording grant; then the frontmost one alone.
            // Without the grant the composite can also come back as a 2×1
            // placeholder, or as the main window with the popover missing;
            // so with more than one window each is pictured on its own —
            // which an app may always do — and they are laid together here.
            let composite = ids.count > 1 ? nil
                : CGImage(windowListFromArrayScreenBounds: .null, windowArray: list, imageOption: [.boundsIgnoreFraming, .bestResolution])
            guard let image = (composite.flatMap { $0.width > 8 ? $0 : nil })
                    ?? Fork.layered(ids)
                    ?? CGWindowListCreateImage(.null, .optionIncludingWindow, ids.last ?? 0, [.boundsIgnoreFraming, .bestResolution])
            else { return ["error": "no image", "windows": ids.map { Int($0) }] }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
            return ["path": path, "size": [image.width, image.height], "windows": ids.map { Int($0) }]
        default: return ["error": "unknown verb \(verb)"]
        }
    }
}

extension Fork {
    /// The windows `ids` (bottom first), each pictured alone and laid where
    /// it sits on screen — the composite WindowServer will only hand over
    /// with the screen-recording grant, made from pictures it hands over
    /// without one. Nil when none of them could be pictured.
    static func layered(_ ids: [CGWindowID]) -> CGImage? {
        let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        var layers: [(CGImage, CGRect)] = []
        var seen = Set<CGWindowID>()
        for id in ids where seen.insert(id).inserted {
            guard !layers.isEmpty || id == ids.first,
                  let row = info.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
                  let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw), bounds.width > 4, bounds.height > 4,
                  let picture = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])
                    .flatMap({ $0.width > 8 ? $0 : nil }) ?? drawn(id)
            else { continue }
            layers.append((picture, bounds))
        }
        guard let first = layers.first else { return nil }
        let union = layers.dropFirst().reduce(first.1) { $0.union($1.1) }
        let scale = CGFloat(first.0.width) / first.1.width
        guard let context = CGContext(data: nil, width: Int(union.width * scale), height: Int(union.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Window bounds count down from the top of the screen; the context
        // counts up from the bottom.
        for (picture, bounds) in layers {
            let x = (bounds.minX - union.minX) * scale
            let y = (union.maxY - bounds.maxY) * scale
            context.draw(picture, in: CGRect(x: x, y: y, width: bounds.width * scale, height: bounds.height * scale))
        }
        return context.makeImage()
    }

    /// A window WindowServer will not picture — a popover, without the
    /// grant — drawn by its own views instead, on the window's background.
    /// The frosted material comes out flat, which is fine for a check.
    private static func drawn(_ id: CGWindowID) -> CGImage? {
        guard let window = NSApp.windows.first(where: { CGWindowID($0.windowNumber) == id }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let drawn = rep.cgImage,
              let context = CGContext(data: nil, width: drawn.width, height: drawn.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let whole = CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height)
        let ground = window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            || NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        context.setFillColor(ground ? CGColor(gray: 0.17, alpha: 1) : CGColor(gray: 0.97, alpha: 1))
        context.fill(whole.insetBy(dx: 14, dy: 14))
        context.draw(drawn, in: whole)
        return context.makeImage()
    }
}
