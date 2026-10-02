import AppKit
import Foundation
import SwiftUI

// Native canvas links and the Share surface. The bundled page never receives
// a cloud token: it asks its host for the native sheet, and Copper's pinned
// Cloud client owns every request below.

struct CanvasJoinLink: Equatable {
    let token: String
    let cloud: String
    let name: String?
    let copper: Bool

    /// Pure parser used by LaunchServices, navigation policy, and the
    /// omnibox. It intentionally accepts only the two contract forms.
    static func parse(_ url: URL) -> CanvasJoinLink? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let path = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.count == 2, path[0].lowercased() == "join", !path[1].isEmpty else { return nil }
        let cloud: String
        let copper: Bool
        if scheme == "copper" {
            guard url.host()?.lowercased() == "canvas",
                  let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cloud" })?.value,
                  !value.isEmpty else { return nil }
            cloud = value
            copper = true
        } else if scheme == "https", let host = url.host(), !host.isEmpty {
            let port = url.port.map { ":\($0)" } ?? ""
            cloud = host + port
            copper = false
        } else {
            return nil
        }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "n" })?.value
        return CanvasJoinLink(token: path[1], cloud: cloud, name: name, copper: copper)
    }

    var normalizedCloud: String {
        cloud.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A pure check of `parse` against the contract's two forms and the
    /// shapes that must be refused — no window, no network, no probe.
    /// `bench canvas parsetest` runs this standing still.
    static func selfTest() -> [String: Any] {
        func parses(_ text: String) -> CanvasJoinLink? { URL(string: text).flatMap(parse) }
        var checks: [(String, Bool)] = []
        let copper = parses("copper://canvas/join/tok123?cloud=cloud.exowatt.com%3A8443&n=Roadmap")
        checks.append(("copper form token", copper?.token == "tok123"))
        checks.append(("copper form cloud", copper?.cloud == "cloud.exowatt.com:8443"))
        checks.append(("copper form name", copper?.name == "Roadmap"))
        checks.append(("copper form marked copper", copper?.copper == true))
        let web = parses("https://cloud.exowatt.com:8443/join/tok456")
        checks.append(("web form token", web?.token == "tok456"))
        checks.append(("web form cloud", web?.cloud == "cloud.exowatt.com:8443"))
        checks.append(("web form not copper", web?.copper == false))
        checks.append(("plain canvas address is not a join link", parses("copper://canvas/personal") == nil))
        checks.append(("copper form without cloud is refused", parses("copper://canvas/join/tok") == nil))
        checks.append(("join with no token is refused", parses("copper://canvas/join/?cloud=x") == nil))
        checks.append(("an unrelated scheme is refused", parses("mailto:join/tok?cloud=x") == nil))
        checks.append(("a bare host, no path, is refused", parses("https://cloud.exowatt.com") == nil))
        let failed = checks.filter { !$0.1 }.map(\.0)
        return ["passed": checks.count - failed.count, "failed": failed]
    }
}

@MainActor
enum CanvasJoinFlow {
    private static let pendingFile = Store.file("canvas/pending-join.json")
    private static var pending: CanvasJoinLink? = loadPending()

    static func handle(_ url: URL, in browser: Browser) -> Bool {
        guard let link = CanvasJoinLink.parse(url) else { return false }
        // A web landing page on another cloud belongs in the normal browser;
        // the Copper form is unambiguous and always comes here.
        if !link.copper, Cloud.shared.link?.host.lowercased() != link.normalizedCloud { return false }
        Task { await join(link, in: browser) }
        return true
    }

    static func resumePending() {
        guard let link = pending, Cloud.shared.isSignedIn,
              let browser = Windows.all.first
        else { return }
        pending = nil
        removePending()
        Task { await join(link, in: browser) }
    }

    private static func join(_ link: CanvasJoinLink, in browser: Browser) async {
        guard let linked = Cloud.shared.link else {
            pending = link; savePending(link)
            browser.announce("This canvas is on \(link.cloud). Connect to that Copper Cloud to open it.")
            CanvasUI.openCloudSettings(in: browser)
            return
        }
        guard linked.host.lowercased() == link.normalizedCloud else {
            browser.announce("This canvas is on \(link.cloud). Connect to that Copper Cloud to open it.")
            CanvasUI.openCloudSettings(in: browser)
            return
        }
        guard Cloud.shared.isSignedIn else {
            pending = link; savePending(link)
            browser.announce("Sign in to Copper Cloud to open this canvas.")
            CanvasUI.openCloudSettings(in: browser)
            return
        }
        do {
            let (previewData, _) = try await Cloud.shared.request("GET", "/v1/canvas-links/\(link.token)")
            let preview = Canvases.object(previewData) ?? [:]
            let member = (preview["member"] as? Bool) ?? false
            let row: [String: Any]
            if member, let id = Canvases.string(preview["canvas_id"]), let existing = Canvases.shared.entry(id) {
                CanvasHost.show(existing.id, in: browser, foreground: true)
                return
            }
            let (joined, _) = try await Cloud.shared.request("POST", "/v1/canvas-links/\(link.token)/join")
            row = Canvases.object(joined) ?? preview
            guard let entry = Canvases.shared.upsert(remote: row, account: Canvases.account ?? "") else {
                throw Cloud.Failure(status: 0, code: "shape", message: "The invite did not contain a canvas")
            }
            await Canvases.shared.refresh()
            CanvasHost.show(entry.id, in: browser, foreground: true)
            pending = nil
            removePending()
        } catch let failure as Cloud.Failure where failure.status == 404 {
            browser.announce("This invite link no longer works — ask for a new one.")
        } catch {
            browser.announce(Canvases.explain(error))
        }
    }

    private static func savePending(_ value: CanvasJoinLink) {
        let object: [String: Any] = ["token": value.token, "cloud": value.cloud, "name": value.name ?? "", "copper": value.copper]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: pendingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: pendingFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingFile.path)
    }

    private static func loadPending() -> CanvasJoinLink? {
        guard let data = try? Data(contentsOf: pendingFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, let cloud = object["cloud"] as? String else { return nil }
        return CanvasJoinLink(token: token, cloud: cloud, name: object["name"] as? String, copper: object["copper"] as? Bool ?? true)
    }

    private static func removePending() { try? FileManager.default.removeItem(at: pendingFile) }
}

// MARK: - cloud link storage

extension Canvases {
    private struct LinkCache: Codable { var tokens: [String: String] = [:] }
    private static var linkCacheFile: URL { folder.appendingPathComponent("share-links.json") }

    private func cachedTokens() -> [String: String] {
        guard let data = try? Data(contentsOf: Self.linkCacheFile), let value = try? JSONDecoder().decode(LinkCache.self, from: data) else { return [:] }
        return value.tokens
    }

    private func saveTokens(_ tokens: [String: String]) {
        guard let data = try? JSONEncoder().encode(LinkCache(tokens: tokens)) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: Self.linkCacheFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.linkCacheFile.path)
    }

    /// Returns the primary Copper form and the HTTPS landing form.
    func shareLinks(_ id: String) async throws -> (link: String, webLink: String) {
        guard let entry = entry(id), entry.isShared, let remote = entry.remoteId else {
            throw Cloud.Failure(status: 400, code: "local", message: "This canvas is on this Mac only and can't be shared")
        }
        guard cloudReady, let cloud = Cloud.shared.link else { throw Canvases.offline }
        var tokens = cachedTokens()
        let token: String
        if let saved = tokens[remote], !saved.isEmpty {
            token = saved
        } else {
            let (data, _) = try await Cloud.shared.request("POST", "/v1/canvases/\(remote)/links", json: [:])
            guard let value = Canvases.object(data), let made = Canvases.string(value["token"]), !made.isEmpty else {
                throw Cloud.Failure(status: 0, code: "shape", message: "The server did not return an invite link")
            }
            token = made
            tokens[remote] = made
            saveTokens(tokens)
        }
        let host = cloud.host
        let name = entry.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entry.name
        return ("copper://canvas/join/\(token)?cloud=\(host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host)&n=\(name)",
                "https://\(host)/join/\(token)")
    }

    func resetShareLink(_ id: String) async throws {
        guard let entry = entry(id), entry.isShared, let remote = entry.remoteId else { return }
        guard cloudReady else { throw Canvases.offline }
        _ = try await Cloud.shared.request("DELETE", "/v1/canvases/\(remote)/links")
        var tokens = cachedTokens(); tokens.removeValue(forKey: remote); saveTokens(tokens)
    }

    func people(query: String) async throws -> [CloudPerson] {
        guard cloudReady else { throw Canvases.offline }
        let (data, _) = try await Cloud.shared.request("GET", "/v1/people", query: ["q": query, "limit": "50"])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["people"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = Canvases.string(row["id"]) else { return nil }
            return CloudPerson(id: id, name: Canvases.string(row["display_name"]) ?? "", email: Canvases.string(row["email"]) ?? "")
        }
    }

    func removeMember(_ id: String, member: String) async throws {
        guard let entry = entry(id), entry.isShared, let remote = entry.remoteId else { return }
        guard entry.isOwner, cloudReady else { throw Canvases.offline }
        _ = try await Cloud.shared.request("DELETE", "/v1/canvases/\(remote)/members/\(member)")
        refreshSoon()
    }
}

// MARK: - native share card

struct CanvasShareSheet: View {
    let entry: Canvases.Entry
    @ObservedObject private var canvases = Canvases.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var ui = CanvasUI.shared
    @State private var copied = false
    @State private var madeLink: (link: String, webLink: String)?
    @State private var failure: String?
    @State private var query = ""
    @State private var people: [Canvases.CloudPerson] = []
    @State private var members: [Canvases.Member] = []
    @State private var working = false

    private var canShare: Bool { entry.isShared && cloud.isLinked && cloud.isSignedIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CanvasFormTitle(text: "Share canvas")
            CanvasSubject(name: entry.name)
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if !canShare {
                Text(entry.isPersonal ? "Personal canvases can't be shared." : "This canvas is on this Mac only and can't be shared.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if cloud.isSignedIn { Button("New shared canvas") { ui.mode = .new } }
                    else { Button("Connect to Copper Cloud") { ui.popoverOpen = false; CanvasUI.openCloudSettings(in: Windows.all.first ?? Windows.main) } }
                }.buttonStyle(CanvasButtonStyle(kind: .primary))
            } else {
                let live = canvases.presence[entry.id] ?? []
                HStack(spacing: 6) {
                    ForEach(live.prefix(8)) { person in
                        Circle().fill(Color(hex: person.color)).frame(width: 22, height: 22)
                            .overlay(Text(String(person.name.prefix(1)).uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white))
                            .help(person.name)
                    }
                    Text("\(live.count) here now").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Button(copied ? "Copied" : "Copy invite link") { copyInvite() }
                    .buttonStyle(CanvasButtonStyle(kind: .primary)).disabled(working)
                if let madeLink { Button("Copy web link") { copy(madeLink.webLink); copied = true }.buttonStyle(CanvasButtonStyle(kind: .plain)) }
                peopleSection
                membersSection
                if entry.isOwner { Button("Reset link", role: .destructive) { reset() }.buttonStyle(CanvasButtonStyle(kind: .plain)) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .task { if canShare { members = (try? await canvases.members(entry.id)) ?? [] } }
        .task(id: query) {
            guard canShare else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            people = (try? await canvases.people(query: query)) ?? []
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("People on this cloud").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            TextField("Search name or email", text: $query).textFieldStyle(.roundedBorder)
            ForEach(people.prefix(6)) { person in
                HStack { VStack(alignment: .leading) { Text(person.name.isEmpty ? person.email : person.name).font(.system(size: 11.5)); Text(person.email).font(.system(size: 10)).foregroundStyle(Palette.muted) }; Spacer(); Button("Invite") { inviteByEmail(person) }.buttonStyle(CanvasButtonStyle(kind: .plain)) }
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Members").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            ForEach(members) { member in
                HStack { Text(member.name.isEmpty ? member.email : member.name).font(.system(size: 11.5)); Spacer(); Text(member.role.capitalized).font(.system(size: 10)).foregroundStyle(Palette.muted); if entry.isOwner && member.role != "owner" { Button("Remove") { remove(member) }.buttonStyle(CanvasButtonStyle(kind: .plain)) } }
            }
        }
    }

    private func copyInvite() {
        working = true
        Task {
            do { let value = try await canvases.shareLinks(entry.id); madeLink = value; copy(value.link); copied = true }
            catch { failure = Canvases.explain(error) }
            working = false
        }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func inviteByEmail(_ person: Canvases.CloudPerson) { Task { try? await canvases.invite(entry.id, email: person.email); ui.note = "Invited \(person.email)" } }
    private func remove(_ member: Canvases.Member) { Task { try? await canvases.removeMember(entry.id, member: member.id); members = (try? await canvases.members(entry.id)) ?? members } }
    private func reset() { Task { do { try await canvases.resetShareLink(entry.id); madeLink = nil; copied = false } catch { failure = Canvases.explain(error) } } }
}

private extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}
