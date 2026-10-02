import AppKit
import Combine
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

    var normalizedCloud: String { Self.normalize(cloud) }

    /// `host[:port]` compared the way HTTPS does: case-insensitive, and the
    /// default port 443 is the same as none. A link code keeps an explicit
    /// `:443` (`copper-cloud://1.2.3.4:443/…`, so the linked host reads
    /// `1.2.3.4:443`) while a landing page served on 443 names its host
    /// without one, so both sides of every comparison go through this.
    static func normalize(_ cloud: String) -> String {
        var host = cloud.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(":443") { host.removeLast(4) }
        return host
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
        checks.append(("web form on 443 matches a link code with :443",
                       parses("https://100.57.251.123/join/tok789")?.normalizedCloud == normalize("100.57.251.123:443")))
        checks.append(("copper form without a port matches :443",
                       parses("copper://canvas/join/tok789?cloud=100.57.251.123")?.normalizedCloud == normalize("100.57.251.123:443")))
        checks.append(("another port still differs", normalize("cloud.exowatt.com:8443") != normalize("cloud.exowatt.com")))
        let failed = checks.filter { !$0.1 }.map(\.0)
        return ["passed": checks.count - failed.count, "failed": failed]
    }
}

@MainActor
enum CanvasJoinFlow {
    private static let pendingFile = Store.file("canvas/pending-join.json")
    private static var pending: CanvasJoinLink? = loadPending()

    static func handle(_ url: URL, in browser: Browser) -> Bool {
        guard let link = accepts(url) else { return false }
        Task { await join(link, in: browser) }
        return true
    }

    /// The link `handle` would take: either form, except a web landing page
    /// on another cloud, which belongs in the normal browser (the Copper
    /// form is unambiguous and always comes here).
    static func accepts(_ url: URL) -> CanvasJoinLink? {
        guard let link = CanvasJoinLink.parse(url) else { return nil }
        if !link.copper, Cloud.shared.link.map({ CanvasJoinLink.normalize($0.host) }) != link.normalizedCloud { return nil }
        return link
    }

    static func resumePending() {
        guard let link = pending, Cloud.shared.isSignedIn,
              let browser = Windows.all.first
        else { return }
        pending = nil
        removePending()
        Task { await join(link, in: browser) }
    }

    /// Opens the canvas a link names. Nil when it opened; otherwise the one
    /// sentence the window announced (also what `canvas_join` answers).
    @discardableResult
    static func join(_ link: CanvasJoinLink, in browser: Browser) async -> String? {
        func say(_ text: String) -> String { browser.announce(text); return text }
        guard let linked = Cloud.shared.link else {
            pending = link; savePending(link)
            CanvasUI.openCloudSettings(in: browser)
            return say("This canvas is on \(link.cloud). Connect to that Copper Cloud to open it.")
        }
        guard CanvasJoinLink.normalize(linked.host) == link.normalizedCloud else {
            CanvasUI.openCloudSettings(in: browser)
            return say("This canvas is on \(link.cloud). Connect to that Copper Cloud to open it.")
        }
        guard Cloud.shared.isSignedIn else {
            pending = link; savePending(link)
            CanvasUI.openCloudSettings(in: browser)
            return say("Sign in to Copper Cloud to open this canvas.")
        }
        // An instance from before share links has no such token to look up:
        // say so, rather than that a perfectly good link stopped working.
        await Cloud.shared.loadInfo()
        if Cloud.shared.supports(.shareLinks) == false { return say(Canvases.joinUnsupported) }
        do {
            let (previewData, _) = try await Cloud.shared.request("GET", "/v1/canvas-links/\(link.token)")
            let preview = Canvases.object(previewData) ?? [:]
            let member = (preview["member"] as? Bool) ?? false
            let row: [String: Any]
            if member, let id = Canvases.string(preview["canvas_id"]), let existing = Canvases.shared.entry(id) {
                CanvasHost.show(existing.id, in: browser, foreground: true)
                return nil
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
            return nil
        } catch let failure as Cloud.Failure where failure.status == 404 {
            // 0.3.0 and later refuse a revoked or unknown token with
            // `link_not_found`; a bare `not_found` is the router's "no such
            // route" — an instance that predates share links.
            if failure.code != "link_not_found" {
                await Cloud.shared.loadInfo(force: true)
                if Cloud.shared.supports(.shareLinks) != true {
                    Cloud.shared.lacks(.shareLinks)
                    return say(Canvases.joinUnsupported)
                }
            }
            return say("This invite link no longer works — ask for a new one.")
        } catch {
            return say(Canvases.plain(error, while: .joining))
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

    // MARK: what this cloud can do

    /// The code a refusal carries when the instance predates share links:
    /// its message is already the sentence to show.
    static let linksUnsupportedCode = "links_unsupported"

    /// The linked cloud as people read it — the default `:443` left off.
    static var cloudHost: String {
        guard let host = Cloud.shared.link?.host else { return "your Copper Cloud" }
        return host.hasSuffix(":443") ? String(host.dropLast(4)) : host
    }

    /// "runs 0.2.0" — or, when it only refused, "runs an older version".
    private static var runs: String { Cloud.shared.serverVersion.map { "runs \($0)" } ?? "runs an older version" }

    /// The Share sheet's one quiet line on an instance without share links.
    static var linksUnsupported: String {
        "Invite links need Copper Cloud \(Cloud.Feature.shareLinks.since) — \(cloudHost) \(runs). You can still invite people by email."
    }

    /// What opening a join link against such an instance says.
    static var joinUnsupported: String { "This Copper Cloud doesn't support invite links yet (\(runs))." }

    private static var linksRefused: Cloud.Failure {
        Cloud.Failure(status: 404, code: linksUnsupportedCode, message: linksUnsupported)
    }

    /// Ask the instance what it runs if nobody has yet, and refuse up front
    /// when that predates share links — no request to a route it hasn't got.
    private func requireShareLinks() async throws {
        if Cloud.shared.supports(.shareLinks) == nil { await Cloud.shared.loadInfo() }
        if Cloud.shared.supports(.shareLinks) == false { throw Canvases.linksRefused }
    }

    /// A share-link route answered `404 not_found`. 0.3.0 says that too for
    /// a canvas this account can't reach, so the version decides: asked
    /// again, and only an old (or silent) instance is taken not to have them.
    private func linksMissing(_ failure: Cloud.Failure) async -> Cloud.Failure {
        guard failure.status == 404, failure.code == "not_found" else { return failure }
        await Cloud.shared.loadInfo(force: true)
        guard Cloud.shared.supports(.shareLinks) != true else { return failure }
        Cloud.shared.lacks(.shareLinks)
        return Canvases.linksRefused
    }

    /// Returns the primary Copper form and the HTTPS landing form.
    func shareLinks(_ id: String) async throws -> (link: String, webLink: String) {
        guard let entry = entry(id), entry.isShared, let remote = entry.remoteId else {
            throw Cloud.Failure(status: 400, code: "local", message: "This canvas is on this Mac only and can't be shared")
        }
        guard cloudReady, let cloud = Cloud.shared.link else { throw Canvases.offline }
        try await requireShareLinks()
        var tokens = cachedTokens()
        let token: String
        if let saved = tokens[remote], !saved.isEmpty {
            token = saved
        } else {
            let data: Data
            do {
                (data, _) = try await Cloud.shared.request("POST", "/v1/canvases/\(remote)/links", json: [:])
            } catch let failure as Cloud.Failure {
                throw await linksMissing(failure)
            }
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
        try await requireShareLinks()
        do {
            _ = try await Cloud.shared.request("DELETE", "/v1/canvases/\(remote)/links")
        } catch let failure as Cloud.Failure {
            throw await linksMissing(failure)
        }
        var tokens = cachedTokens(); tokens.removeValue(forKey: remote); saveTokens(tokens)
    }

    /// The instance's people directory. Before 0.3.0 there is none: nothing
    /// is asked and nothing is said — inviting by email still works.
    func people(query: String) async throws -> [CloudPerson] {
        guard cloudReady else { throw Canvases.offline }
        if Cloud.shared.supports(.people) == nil { await Cloud.shared.loadInfo() }
        guard Cloud.shared.supports(.people) != false else { return [] }
        let data: Data
        do {
            (data, _) = try await Cloud.shared.request("GET", "/v1/people", query: ["q": query, "limit": "50"])
        } catch let failure as Cloud.Failure where failure.status == 404 && failure.code == "not_found" {
            // An instance with a directory never answers it so: this one
            // predates it, and share links came in the same release.
            Cloud.shared.lacks(.people)
            Cloud.shared.lacks(.shareLinks)
            return []
        }
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

    // MARK: refusals, in words

    /// What the sheet (or a join) was doing when something went wrong.
    enum ShareAction {
        case inviting(String)
        case linking
        case resetting
        case removing(String)
        case joining
    }

    /// One plain sentence for a sharing failure — never the server's own
    /// short code or status text ("not found", "conflict", "forbidden").
    /// Checked against copper-cloud 0.2.0's and 0.3.0's invite refusals:
    /// 400 for a bad address, the Personal canvas or inviting yourself, 409
    /// for someone already a member, 404 for a canvas this account can't
    /// reach, 403 for an action only its owner may take.
    static func plain(_ error: Error, while action: ShareAction) -> String {
        let host = cloudHost
        let fallback: String
        switch action {
        case .inviting(let email): fallback = "Couldn't invite \(email) — try again."
        case .linking: fallback = "Couldn't make an invite link — try again."
        case .resetting: fallback = "Couldn't reset the link — try again."
        case .removing(let name): fallback = "Couldn't remove \(name) — try again."
        case .joining: fallback = "Couldn't open that invite — try again."
        }
        guard let failure = error as? Cloud.Failure else { return fallback }
        let said = failure.message.lowercased()
        switch (failure.status, failure.code) {
        case (_, linksUnsupportedCode):
            return failure.message
        case (_, "not_signed_in"), (_, "not_linked"), (401, _):
            return "Sign in at Settings › Cloud to share canvases."
        case (_, "local"), (_, "missing"):
            return sentence(failure.message)
        case (_, "personal"):
            return "The Personal canvas can't be shared."
        case (_, "email"):
            if case .inviting(let email) = action { return "“\(email)” isn't an email address." }
            return "That isn't an email address."
        case (400, _):
            if said.contains("email") {
                if case .inviting(let email) = action { return "“\(email)” isn't an email address." }
                return "That isn't an email address."
            }
            if said.contains("already a member") { return "That's your own address — you're already on this canvas." }
            if said.contains("personal") { return "The Personal canvas can't be shared." }
            return fallback
        case (409, _), (_, "conflict"):
            if case .inviting(let email) = action { return "\(email) is already a member of this canvas." }
            return "That changed somewhere else first — try again."
        case (403, _):
            switch action {
            case .inviting: return "Only members of this canvas can invite people to it."
            case .linking: return "Only members of this canvas can make an invite link."
            case .resetting: return "Only the canvas's owner can reset its link."
            case .removing: return "Only the canvas's owner can remove people."
            case .joining: return "\(host) won't open that canvas for this account."
            }
        case (404, _):
            if case .joining = action { return "This invite link no longer works — ask for a new one." }
            return "This canvas isn't on \(host) any more."
        case (429, _), (_, "rate_limited"):
            return "Too many tries — wait a minute and try again."
        case (0, "fingerprint"), (0, "tls"):
            return "\(host)'s certificate isn't the one this Mac trusts — check Settings › Cloud."
        case (0, "network"):
            return "Can't reach \(host) right now — check the connection and try again."
        case (500..., _):
            return "\(host) had a problem — try again in a moment."
        default:
            return fallback
        }
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }
}

// MARK: - native share card

/// The Share sheet's state, kept outside the view so it survives the
/// sheet being drawn again (a picture, a re-render) and so `bench canvas ui
/// share …` can type into it and press its buttons the way a person would.
/// One per sheet shown: `CanvasUI.mode` makes it, and drops it on leaving.
@MainActor
final class CanvasShareModel: ObservableObject {
    let canvasId: String
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            if !query.isEmpty { said = nil }
            searchSoon()
        }
    }
    @Published private(set) var people: [Canvases.CloudPerson] = []
    /// The query `people` is the directory's answer to.
    @Published private(set) var searched: String?
    @Published private(set) var members: [Canvases.Member] = []
    @Published private(set) var madeLink: (link: String, webLink: String)?
    @Published private(set) var copied = false
    @Published private(set) var working = false
    /// Under the invite field: what the last invite or removal came to, and
    /// whether it went wrong (orange) or right (muted).
    @Published private(set) var said: (text: String, failed: Bool)?
    /// Under the link buttons: why the last copy or reset didn't work.
    @Published private(set) var linkFailure: String?
    /// Still hearing what the instance runs, the first time round.
    @Published private(set) var checking = true
    private var search: Task<Void, Never>?
    private var watching: AnyCancellable?

    init(canvasId: String) {
        self.canvasId = canvasId
        Task { await self.load() }
        // Someone accepting, leaving or being removed shows while the sheet is open.
        watching = Canvases.shared.$refreshed.dropFirst().sink { [weak self] _ in
            Task { @MainActor in await self?.reloadMembers() }
        }
    }

    var entry: Canvases.Entry? { Canvases.shared.entry(canvasId) }
    var canShare: Bool { (entry?.isShared ?? false) && Cloud.shared.isLinked && Cloud.shared.isSignedIn }
    /// Share links: true, false, or nil while unknown — then the buttons
    /// show and a refusal teaches the answer.
    var links: Bool? { Cloud.shared.supports(.shareLinks) }
    /// The people directory: everything but a known "no".
    var directory: Bool { Cloud.shared.supports(.people) != false }

    func load() async {
        guard canShare else { checking = false; return }
        await Cloud.shared.loadInfo()
        checking = false
        await reloadMembers()
        // As before: with nothing typed, the directory's first page.
        if directory { await runSearch(query) }
    }

    func reloadMembers() async {
        if let fresh = try? await Canvases.shared.members(canvasId) { members = fresh }
    }

    private func searchSoon() {
        search?.cancel()
        let wanted = query
        search = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.runSearch(wanted)
        }
    }

    private func runSearch(_ text: String) async {
        guard canShare, directory else { people = []; searched = text; return }
        let found = (try? await Canvases.shared.people(query: text.trimmingCharacters(in: .whitespacesAndNewlines))) ?? []
        guard text == query else { return }
        people = found
        searched = text
    }

    /// The typed text, when it is an address.
    var typedEmail: String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Canvases.isEmail(text) ? text : nil
    }

    func isMember(_ email: String) -> Bool {
        let key = email.lowercased()
        return members.contains { $0.email.lowercased() == key }
    }

    private var isMe: Bool { typedEmail?.lowercased() == Cloud.shared.account?.email.lowercased() }

    /// "Invite <email>": a typed address that isn't on the canvas, isn't
    /// yours, and isn't already a directory row below.
    var emailRow: String? {
        guard let email = typedEmail, !isMember(email), !isMe else { return nil }
        let key = email.lowercased()
        if people.contains(where: { $0.email.lowercased() == key }) { return nil }
        return email
    }

    /// The muted line instead of a row, when the typed address is already in.
    var emailNote: String? {
        guard let email = typedEmail else { return nil }
        if isMe { return "That's you — you're already on this canvas." }
        if isMember(email) { return "\(email) is already on this canvas." }
        return nil
    }

    /// Return in the field: invite the typed address, if it is one.
    func submit() {
        if let email = emailRow { invite(email) }
    }

    func invite(_ email: String) {
        guard !working else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = address.lowercased()
        // The directory looked this exact address up and found nobody: the
        // invite waits for an account with it.
        let nobody = Cloud.shared.supports(.people) == true
            && searched?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
            && !people.contains { $0.email.lowercased() == key }
        working = true
        said = nil
        Task {
            do {
                let made = try await Canvases.shared.invite(canvasId, email: address)
                let when = nobody ? " once they have an account on \(Canvases.cloudHost)" : ""
                query = ""
                said = (made ? "Invited \(address) — they'll see it in Copper\(when)" : "\(address) is already invited — they'll see it in Copper\(when)", false)
                CanvasUI.shared.note = "Invited \(address)"
            } catch {
                said = (Canvases.plain(error, while: .inviting(address)), true)
            }
            working = false
        }
    }

    func copyLink() {
        guard !working else { return }
        working = true
        linkFailure = nil
        Task {
            do {
                let value = try await Canvases.shared.shareLinks(canvasId)
                madeLink = value
                copy(value.link)
                copied = true
            } catch let failure as Cloud.Failure where failure.code == Canvases.linksUnsupportedCode {
                // The note takes the buttons' place; there is nothing to add.
            } catch {
                linkFailure = Canvases.plain(error, while: .linking)
            }
            working = false
        }
    }

    func copyWebLink() {
        guard let madeLink else { return }
        copy(madeLink.webLink)
        copied = true
    }

    func reset() {
        linkFailure = nil
        Task {
            do {
                try await Canvases.shared.resetShareLink(canvasId)
                madeLink = nil
                copied = false
            } catch let failure as Cloud.Failure where failure.code == Canvases.linksUnsupportedCode {
            } catch {
                linkFailure = Canvases.plain(error, while: .resetting)
            }
        }
    }

    func remove(_ member: Canvases.Member) {
        let name = member.name.isEmpty ? member.email : member.name
        Task {
            do {
                try await Canvases.shared.removeMember(canvasId, member: member.id)
                await reloadMembers()
            } catch {
                said = (Canvases.plain(error, while: .removing(name)), true)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// "Only you here" with the canvas open and nobody else in it; "3 here
    /// now" counting you among the people in the room; nothing at all when
    /// the canvas isn't open here and nobody else is in it.
    static func presenceLine(others: Int, here: Bool) -> String? {
        if here { return others == 0 ? "Only you here" : "\(others + 1) here now" }
        return others == 0 ? nil : "\(others) here now"
    }

    /// The people in the room besides you, once each.
    static func others(in id: String) -> [Canvases.PresencePerson] {
        let me = Canvases.shared.identity.id
        var seen = Set<String>()
        return (Canvases.shared.presence[id] ?? []).filter { $0.id != me && seen.insert($0.id).inserted }
    }

    /// For `bench canvas ui share state`: what the sheet shows, as data.
    var describe: [String: Any] {
        let others = CanvasShareModel.others(in: canvasId)
        let here = CanvasPresence.shared.open.contains(canvasId)
        var out: [String: Any] = [
            "canvas": canvasId, "canShare": canShare, "checking": checking,
            "serverVersion": Cloud.shared.serverVersion ?? NSNull(),
            "links": links.map { $0 as Any } ?? NSNull(), "directory": directory,
            "query": query, "people": people.map { ["name": $0.name, "email": $0.email] },
            "members": members.map { ["name": $0.name, "email": $0.email, "role": $0.role] },
            "presence": CanvasShareModel.presenceLine(others: others.count, here: here) ?? NSNull(),
            "emailRow": emailRow ?? NSNull(), "emailNote": emailNote ?? NSNull(),
            "working": working, "copied": copied,
        ]
        if links == false { out["note"] = Canvases.linksUnsupported }
        if let said { out["said"] = said.text; out["failed"] = said.failed }
        if let linkFailure { out["linkFailure"] = linkFailure }
        return out
    }
}

struct CanvasShareSheet: View {
    let entry: Canvases.Entry
    @ObservedObject var model: CanvasShareModel
    @ObservedObject private var canvases = Canvases.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var ui = CanvasUI.shared
    @ObservedObject private var presence = CanvasPresence.shared

    private var canShare: Bool { entry.isShared && cloud.isLinked && cloud.isSignedIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CanvasFormTitle(text: "Share canvas")
            CanvasSubject(name: entry.name)
            if !canShare {
                Text(entry.isPersonal ? "Personal canvases can't be shared." : "This canvas is on this Mac only and can't be shared.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if cloud.isSignedIn { Button("New shared canvas") { ui.mode = .new } }
                    else { Button("Connect to Copper Cloud") { ui.popoverOpen = false; CanvasUI.openCloudSettings(in: Windows.all.first ?? Windows.main) } }
                }.buttonStyle(CanvasButtonStyle(kind: .primary))
            } else {
                presenceRow
                linkSection
                peopleSection
                membersSection
                if entry.isOwner, model.links != false, !model.checking {
                    Button("Reset link", role: .destructive) { model.reset() }.buttonStyle(CanvasButtonStyle(kind: .plain))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var presenceRow: some View {
        let others = CanvasShareModel.others(in: entry.id)
        let here = presence.open.contains(entry.id)
        if let line = CanvasShareModel.presenceLine(others: others.count, here: here) {
            HStack(spacing: 6) {
                if here {
                    let me = canvases.identity
                    face(me.name, color: me.color).help("You")
                }
                ForEach(others.prefix(8)) { person in face(person.name, color: person.color).help(person.name) }
                Text(line).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
        }
    }

    private func face(_ name: String, color: String) -> some View {
        Circle().fill(Color(hex: color)).frame(width: 22, height: 22)
            .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white))
    }

    @ViewBuilder private var linkSection: some View {
        if model.links == false {
            Text(Canvases.linksUnsupported)
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else if !(model.checking && model.links == nil) {
            Button(model.copied ? "Copied" : "Copy invite link") { model.copyLink() }
                .buttonStyle(CanvasButtonStyle(kind: .primary)).disabled(model.working)
            if model.madeLink != nil { Button("Copy web link") { model.copyWebLink() }.buttonStyle(CanvasButtonStyle(kind: .plain)) }
            if let failure = model.linkFailure {
                Text(failure).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.directory ? "People on this cloud" : "Invite by email").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            TextField(model.directory ? "Search people or type an email" : "Type an email to invite", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submit() }
                .disabled(model.working)
            if let email = model.emailRow {
                HStack(spacing: 6) {
                    Image(systemName: "envelope").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                    Text("Invite \(email)").font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if model.working { ProgressView().controlSize(.mini) }
                    Button("Invite") { model.invite(email) }.buttonStyle(CanvasButtonStyle(kind: .plain)).disabled(model.working)
                }
            } else if let note = model.emailNote {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if model.directory {
                ForEach(model.people.prefix(6)) { person in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(person.name.isEmpty ? person.email : person.name).font(.system(size: 11.5))
                            Text(person.email).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if model.isMember(person.email) {
                            Text("Member").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        } else {
                            Button("Invite") { model.invite(person.email) }.buttonStyle(CanvasButtonStyle(kind: .plain)).disabled(model.working)
                        }
                    }
                }
            }
            if let said = model.said {
                Text(said.text).font(.system(size: 11)).foregroundStyle(said.failed ? Color.orange : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Members").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            ForEach(model.members) { member in
                HStack { Text(member.name.isEmpty ? member.email : member.name).font(.system(size: 11.5)); Spacer(); Text(member.role.capitalized).font(.system(size: 10)).foregroundStyle(Palette.muted); if entry.isOwner && member.role != "owner" { Button("Remove") { model.remove(member) }.buttonStyle(CanvasButtonStyle(kind: .plain)) } }
            }
        }
    }
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
