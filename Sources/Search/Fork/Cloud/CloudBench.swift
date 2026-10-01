import AppKit
import Foundation

// `./bench cloud …` — drive Copper Cloud from a script, so two probe worlds
// can be linked, signed in and synced end to end without a click:
//
//   cloud status                     link, account, sync switches, state, devices (no secrets)
//   cloud link CODE                  connect with a link code (or http://127.0.0.1:PORT/#k=KEY)
//   cloud signup EMAIL PW NAME       create the account and sign in
//   cloud signin EMAIL PW            sign in
//   cloud signout | disconnect
//   cloud sync on DOMAINS            "Turn on sync" with these (spaces,settings,bookmarks,tabs,history | all)
//   cloud sync off | now
//   cloud devices                    other devices' open tabs
//   cloud doc DOMAIN                 this Mac's document for DOMAIN, as it would be pushed
//   cloud log                        the last lines of the log
//   cloud selftest                   the pure parts: link codes, the settings allowlist, merges
//   cloud bookmark URL [TITLE]       test worlds only: add a bookmark
//   cloud pin URL                    test worlds only: open URL as a pinned tab
//   cloud open URL                   test worlds only: open URL as an ordinary tab
//   cloud picture PATH [dark]        the whole Cloud page as a PNG, for a look at it
//   cloud wstest                     a canvas WebSocket through the pinned session: open, frames, close
//
// Passwords given here are used once and never echoed back.

@MainActor
enum CloudBench {
    static func handle(_ request: [String: Any], in browser: Browser, answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? "status"
        let words = (request["arg"] as? String ?? "").split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let cloud = Cloud.shared
        let sync = CloudSync.shared

        func run(_ body: @escaping () async throws -> Void) {
            Task { @MainActor in
                do {
                    try await body()
                    answer(status())
                } catch {
                    var out = status()
                    out["error"] = error.localizedDescription
                    if let failure = error as? Cloud.Failure { out["code"] = failure.code; out["status"] = failure.status }
                    answer(out)
                }
            }
        }

        switch op {
        case "status":
            answer(status())
        case "link":
            guard let code = words.first, let link = Cloud.parseLinkCode(code) else { return answer(["error": "usage: cloud link CODE (copper-cloud://HOST:PORT/#k=KEY&fp=HEX)"]) }
            run { try await cloud.connect(link) }
        case "signup":
            guard words.count >= 3 else { return answer(["error": "usage: cloud signup EMAIL PASSWORD NAME"]) }
            run { try await cloud.signUp(email: words[0], password: words[1], displayName: words[2...].joined(separator: " ")) }
        case "signin":
            guard words.count >= 2 else { return answer(["error": "usage: cloud signin EMAIL PASSWORD"]) }
            run { try await cloud.signIn(email: words[0], password: words[1]) }
        case "signout":
            run {
                await sync.signingOut()
                await cloud.signOut()
            }
        case "disconnect":
            sync.turnOff()
            cloud.disconnect()
            answer(status())
        case "sync":
            switch words.first ?? "now" {
            case "on":
                let list = words.dropFirst().flatMap { $0.split(separator: ",").map(String.init) }
                let domains: Set<CloudSync.Domain> = list.contains("all") || list.isEmpty
                    ? Set(CloudSync.Domain.allCases)
                    : Set(list.compactMap(CloudSync.Domain.init(rawValue:)))
                guard !domains.isEmpty else { return answer(["error": "usage: cloud sync on spaces,settings,bookmarks,tabs,history|all"]) }
                run { await sync.turnOn(domains) }
            case "off":
                sync.turnOff()
                answer(status())
            case "now":
                run { await sync.syncNow() }
            case "set":
                // cloud sync set DOMAIN on|off
                guard words.count == 3, let domain = CloudSync.Domain(rawValue: words[1]) else { return answer(["error": "usage: cloud sync set DOMAIN on|off"]) }
                sync.set(domain, words[2] == "on")
                answer(status())
            default:
                answer(["error": "usage: cloud sync on DOMAINS | off | now | set DOMAIN on|off"])
            }
        case "devices":
            run {
                await sync.refreshDevices()
            }
        case "doc":
            guard let domain = words.first.flatMap(CloudSync.Domain.init(rawValue:)) else { return answer(["error": "usage: cloud doc spaces|settings|bookmarks|tabs|history"]) }
            answer(["domain": domain.rawValue, "doc": sync.preview(domain) ?? NSNull()])
        case "log":
            answer(["log": sync.log.suffix(60).map { "\(CloudSync.stamp($0.at)) \($0.text)" }])
        case "selftest":
            answer(CloudSelfTest.run())
        case "bookmark":
            guard Store.testing, let raw = words.first, let url = URL(string: raw) else { return answer(["error": "usage (test worlds only): cloud bookmark URL [TITLE]"]) }
            browser.bookmarks.add(url, title: words.dropFirst().joined(separator: " "))
            answer(["bookmarks": Bookmarks.count(browser.bookmarks.roots)])
        case "wstest":
            // cloud wstest — open the first canvas's WebSocket through the pinned
            // session, wait for the server's first frame (y-sync step 1), close.
            Task { @MainActor in
                struct Canvas: Decodable { var id: UUID; var name: String }
                do {
                    let list: [Canvas] = try await cloud.requestJSON("GET", "/v1/canvases")
                    guard let canvas = list.first else { return answer(["error": "no canvas on this account"]) }
                    let socket = cloud.socket(path: "/v1/canvases/\(canvas.id.uuidString.lowercased())/ws")
                    var frames = 0, bytes = 0, opened = false
                    socket.onOpen = { opened = true }
                    socket.onData = { data in
                        frames += 1
                        bytes += data.count
                        if frames == 1 { socket.send(Data([0, 0, 1, 0])) } // y-sync step 1 with an empty state vector
                        if frames >= 2 { socket.close() }
                    }
                    socket.onClose = { error in
                        socket.onData = nil
                        socket.onOpen = nil
                        answer(["canvas": canvas.name, "opened": opened, "open": socket.isOpen, "frames": frames, "bytes": bytes,
                                "closedWith": error.map { $0.localizedDescription } ?? "close()"])
                    }
                    socket.connect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { socket.close() }
                } catch {
                    answer(["error": error.localizedDescription])
                }
            }
        case "picture":
            // cloud picture PATH [dark] — the whole Cloud page, laid out off screen.
            guard let path = words.first else { return answer(["error": "usage: cloud picture PATH [dark]"]) }
            guard let picture = SettingsPicture.draw(CloudPage(browser: browser), dark: words.dropFirst().first == "dark"),
                  let png = picture.representation(using: .png, properties: [:]) else { return answer(["error": "could not draw the page"]) }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { return answer(["error": error.localizedDescription]) }
            answer(["path": path, "size": [picture.pixelsWide, picture.pixelsHigh]])
        case "open":
            guard Store.testing, let raw = words.first, let url = URL(string: raw) else { return answer(["error": "usage (test worlds only): cloud open URL"]) }
            _ = browser.open(url, foreground: false, atEnd: true)
            answer(["opened": url.absoluteString, "tabs": browser.tabs.count])
        case "pin":
            guard Store.testing, let raw = words.first, let url = URL(string: raw) else { return answer(["error": "usage (test worlds only): cloud pin URL"]) }
            let tab = browser.open(url, foreground: false, atEnd: true)
            browser.pin(tab)
            answer(["pinned": url.absoluteString, "pins": browser.pinnedCount])
        default:
            answer(["error": "unknown cloud op \(op) — status|link|signup|signin|signout|disconnect|sync|devices|doc|log|selftest"])
        }
    }

    static func status() -> [String: Any] {
        let cloud = Cloud.shared
        var out: [String: Any] = [
            "linked": cloud.isLinked,
            "signedIn": cloud.isSignedIn,
            "reachable": cloud.reachable,
            "deviceId": cloud.deviceId.uuidString.lowercased(),
            "deviceName": cloud.deviceName,
        ]
        if let link = cloud.link {
            out["host"] = link.host
            out["url"] = link.url.absoluteString
            out["fingerprint"] = link.fingerprint ?? NSNull()
        }
        if let account = cloud.account {
            out["email"] = account.email
            out["displayName"] = account.displayName
            out["userId"] = account.userId.uuidString.lowercased()
        }
        out["sync"] = CloudSync.shared.status
        out["devices"] = CloudSync.shared.otherDevices.map { device in
            ["name": device.name, "domain": device.domain,
             "updated": device.updated.map { CloudSync.stamp($0) } ?? NSNull(),
             "tabs": device.tabs.map { ["url": $0.url, "title": $0.title, "space": $0.space.map { $0 as Any } ?? NSNull()] as [String: Any] }] as [String: Any]
        }
        return out
    }
}

/// The pure parts, checked with made-up inputs. The package has no test
/// target; this is what `bench cloud selftest` runs instead.
@MainActor
enum CloudSelfTest {
    static func run() -> [String: Any] {
        var failures: [String] = []
        var count = 0
        func check(_ ok: Bool, _ name: String) {
            count += 1
            if !ok { failures.append(name) }
        }
        let fp = String(repeating: "ab", count: 32)

        // Link codes.
        let a = Cloud.parseLinkCode("copper-cloud://cloud.example.com:8443/#k=KEY_abc-123&fp=\(fp)")
        check(a?.url.absoluteString == "https://cloud.example.com:8443" && a?.key == "KEY_abc-123" && a?.fingerprint == fp, "link: copper-cloud with fp")
        let b = Cloud.parseLinkCode("  copper-cloud://10.0.0.5:443/#k=abc\n")
        check(b?.url.absoluteString == "https://10.0.0.5:443" && b?.fingerprint == nil, "link: no fp, whitespace")
        let c = Cloud.parseLinkCode("copper-cloud://h:1/#k=x&fp=" + Array(repeating: "AB", count: 32).joined(separator: ":"))
        check(c?.fingerprint == fp, "link: colon-separated upper-case fp")
        check(Cloud.parseLinkCode("copper-cloud://h:1/#k=x&fp=1234") == nil, "link: short fp refused")
        check(Cloud.parseLinkCode("copper-cloud://h:1/") == nil, "link: no key refused")
        check(Cloud.parseLinkCode("http://evil.example.com:80/#k=x") == nil, "link: plain http off-loopback refused")
        check(Cloud.parseLinkCode("http://127.0.0.1:8443/#k=x")?.url.absoluteString == "http://127.0.0.1:8443", "link: loopback http allowed")
        check(Cloud.parseLinkCode("copper-cloud://127.0.0.1:8443/#k=x&tls=off")?.url.scheme == "http", "link: tls=off on loopback")
        check(Cloud.parseLinkCode("copper-cloud://[::1]:8443/#k=x")?.host == "[::1]:8443", "link: ipv6 host")
        check(Cloud.link(address: "cloud.example.com", key: "k", fingerprint: "")?.url.absoluteString == "https://cloud.example.com", "link: advanced fields")
        if let a { check(Cloud.parseLinkCode(a.code) == a, "link: code round trip") }

        // The settings allowlist.
        let filtered = CloudSettingsKeys.filter([
            "look": "dark", "sidebar": "true", "downloads": "/tmp", "passwords.save": "true", "bench": "true",
            "glyph": "weird", "shield": "false", "passkeys": "true", "sections.archive": "h48",
        ])
        check(filtered == ["look": "dark", "sidebar": "true", "shield": "false", "sections.archive": "h48"], "settings: allowlist + value shapes")

        // Lists, three ways.
        struct Item: Equatable { var id: String; var v: Int }
        let base = [Item(id: "a", v: 1), Item(id: "b", v: 1), Item(id: "c", v: 1)]
        let local = [Item(id: "a", v: 2), Item(id: "c", v: 1), Item(id: "d", v: 1)] // edited a, deleted b, added d
        let server = [Item(id: "a", v: 1), Item(id: "b", v: 3), Item(id: "c", v: 5), Item(id: "e", v: 1)] // edited b, c; added e
        let merged = CloudMerge.list(base: base, local: local, server: server) { $0.id }
        check(merged.first { $0.id == "a" }?.v == 2, "merge: local-only edit kept")
        check(merged.first { $0.id == "b" }?.v == 3, "merge: delete vs remote edit keeps the edit")
        check(merged.first { $0.id == "c" }?.v == 5, "merge: remote edit wins")
        check(merged.contains { $0.id == "d" } && merged.contains { $0.id == "e" }, "merge: both additions kept")
        let deleted = CloudMerge.list(base: base, local: [base[0], base[2]], server: base) { $0.id }
        check(deleted.map(\.id) == ["a", "c"], "merge: local delete sticks")
        let union = CloudMerge.list(base: nil, local: [Item(id: "x", v: 1), Item(id: "y", v: 1)], server: [Item(id: "y", v: 9)]) { $0.id }
        check(union.map(\.id) == ["y", "x"] && union[0].v == 9, "merge: first sync is a union, server wins")
        let reordered = CloudMerge.list(base: base, local: [base[2], base[0], base[1]], server: base) { $0.id }
        check(reordered.map(\.id) == ["c", "a", "b"], "merge: local reorder kept when server didn't move")

        // Settings, three ways.
        let s = CloudMerge.settings(base: .init(values: ["look": "light", "sidebar": "true"]),
                                    local: .init(values: ["look": "dark", "sidebar": "true"]),
                                    server: .init(values: ["look": "light", "sidebar": "false"]))
        check(s.values == ["look": "dark", "sidebar": "false"], "settings: each side's change kept")
        let s2 = CloudMerge.settings(base: .init(values: ["look": "light"]), local: .init(values: ["look": "dark"]), server: .init(values: ["look": "system"]))
        check(s2.values["look"] == "system", "settings: conflict, server wins")

        // Bookmarks: tree round trip, a folder moved, a site added on each side.
        let folder = UUID(), site1 = UUID(), site2 = UUID(), site3 = UUID(), site4 = UUID()
        let tree: [Bookmark] = [
            Bookmark(id: folder, title: "Work", url: nil, children: [Bookmark(id: site1, title: "One", url: "https://one.example", children: nil)]),
            Bookmark(id: site2, title: "Two", url: "https://two.example", children: nil),
        ]
        check(CloudMerge.tree(CloudMerge.flatten(tree)) == tree, "bookmarks: flatten/tree round trip")
        var mine = tree
        mine.append(Bookmark(id: site3, title: "Three", url: "https://three.example", children: nil))
        var theirs = tree
        theirs[0].children?.append(Bookmark(id: site4, title: "Four", url: "https://four.example", children: nil))
        theirs[1].title = "Two (renamed)"
        let mb = CloudMerge.bookmarks(base: .init(roots: tree), local: .init(roots: mine), server: .init(roots: theirs))
        let flat = CloudMerge.flatten(mb.roots)
        check(flat.count == 5, "bookmarks: union of additions")
        check(flat.first { $0.id == site4 }?.parent == folder, "bookmarks: addition stays in its folder")
        check(flat.first { $0.id == site2 }?.title == "Two (renamed)", "bookmarks: remote rename")
        let orphan = CloudMerge.tree([CloudMerge.Node(id: site1, parent: UUID(), title: "Lost", url: "https://x.example")])
        check(orphan.count == 1 && orphan[0].id == site1, "bookmarks: orphan surfaces at the top")
        let loop = CloudMerge.tree([CloudMerge.Node(id: folder, parent: site3, title: "A", url: nil),
                                    CloudMerge.Node(id: site3, parent: folder, title: "B", url: nil)])
        check(CloudMerge.flatten(loop).count == 2, "bookmarks: a loop is broken, nothing lost")

        // Spaces: a space deleted elsewhere takes its kept tabs.
        let home = Space(name: "Home"), work = Space(name: "Work")
        let pinA = CloudDocs.KeptTab(key: "\(work.id)|pin|a|0", space: work.id, url: "https://a.example", title: "A", pinned: true, pin: "A")
        let sb = CloudDocs.Spaces(spaces: [home, work], tabs: [pinA])
        let sm = CloudMerge.spaces(base: sb, local: sb, server: CloudDocs.Spaces(spaces: [home], tabs: [pinA]))
        check(sm.spaces == [home] && sm.tabs.isEmpty, "spaces: removed space drops its tabs")

        // Two fresh Macs, each with its own "Home": the first sync makes them one.
        let homeA = Space(name: "Home"), homeB = Space(name: "home")
        let pinB = CloudDocs.KeptTab(key: "\(homeB.id.uuidString.lowercased())|pin|b|https://b.example", space: homeB.id, url: "https://b.example", title: "B", pinned: true, pin: "B")
        let first = CloudMerge.spaces(base: nil, local: CloudDocs.Spaces(spaces: [homeB], tabs: [pinB]), server: CloudDocs.Spaces(spaces: [homeA], tabs: []))
        check(first.spaces.map(\.id) == [homeA.id] && first.tabs.first?.space == homeA.id
              && first.tabs.first?.key.hasPrefix(homeA.id.uuidString.lowercased()) == true, "spaces: same-named spaces join on first sync")

        // History de-duplication.
        let now = Date()
        check(CloudMerge.sameVisit(now, now.addingTimeInterval(0.6)) && !CloudMerge.sameVisit(now, now.addingTimeInterval(1.5)), "history: same visit within 1 s")
        check(CloudSync.date(CloudSync.stamp(now)).map { abs($0.timeIntervalSince(now)) < 0.01 } == true, "history: RFC 3339 round trip")

        return ["checks": count, "passed": count - failures.count, "failures": failures]
    }
}
