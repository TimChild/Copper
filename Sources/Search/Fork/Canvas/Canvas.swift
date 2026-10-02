import AppKit
import Foundation

// Canvas: an infinite whiteboard that lives in a tab. This file is the part
// with no page in it — which canvases there are, where each one's history is
// kept on disk, and how the list follows the cloud when there is one.
//
// Every canvas is a Yjs document. Copper never reads the document itself;
// it keeps the page's updates, in order, and hands them back when the page
// opens again (CanvasHost.swift does the handing). That is the whole of
// "offline first": a canvas works with no network and no account, and when
// a cloud is linked and signed in the same updates also go to its room,
// where Yjs merges them with everyone else's.
//
// The Personal canvas always exists, is never shared and never deleted. It
// is local until the person chooses Personal canvas in Settings › Cloud ›
// Choose what syncs (`CloudSync.syncs(.canvas)`); then, signed in, it follows
// the account's own Personal canvas on the server. Other canvases are either
// local (made with no account) or shared (made on the server, with members
// and invites) — a shared one is a cloud document by definition and is
// relayed whenever its account is signed in. See docs/canvas.md.

// MARK: - addresses

/// `copper://canvas/<id>` — what a canvas tab says it is showing. There is
/// no URL scheme handler behind it: the address is intercepted on its way into
/// WebKit (CanvasHost.decide) and the bundled page is loaded in its place.
enum CanvasLinks {
    static let scheme = "copper"
    static let host = "canvas"

    static func url(_ id: String) -> URL {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        return URL(string: "\(scheme)://\(host)/\(safe)")!
    }

    /// The canvas a `copper://canvas…` address names: `copper://canvas` alone is Personal.
    static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == host else { return nil }
        let path = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return Canvases.personalID }
        return path.split(separator: "/").first.map(String.init)
    }

    static func isCanvas(_ url: URL?) -> Bool { url.flatMap(id(from:)) != nil }

    /// Typed or pasted into the field: `copper://canvas/<id>` (any case).
    static func typed(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("\(scheme)://\(host)"), let url = URL(string: trimmed), id(from: url) != nil else { return nil }
        return url
    }

    /// "Canvas · Personal", for the address pill and ⌘T's open row.
    @MainActor static func label(_ url: URL) -> String? {
        guard let id = id(from: url) else { return nil }
        if let entry = Canvases.shared.entry(id) { return "Canvas · \(entry.name)" }
        return id == Canvases.personalID ? "Canvas · Personal" : "Canvas"
    }

    /// The tab's title: the canvas's name, as a board's row says it. The
    /// row wears the Canvas mark, so the word itself would only repeat it.
    static func title(_ name: String) -> String { name }
}

// MARK: - colours

/// Presence colours: one per person or agent, the same every time for the
/// same name, readable on both the light and the dark board.
enum CanvasColors {
    static let presence = ["#E5484D", "#F76B15", "#D6A400", "#30A46C", "#12A594", "#0090FF", "#3E63DD", "#8E4EC6", "#D6409F"]

    static func stable(_ seed: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in seed.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return presence[Int(hash % UInt32(presence.count))]
    }
}

// MARK: - the registry

@MainActor
final class Canvases: ObservableObject {
    static let shared = Canvases()
    nonisolated static let personalID = "personal"

    enum Kind: String, Codable {
        case personal, shared, local
    }

    /// One canvas, as `canvas/canvases.json` keeps it.
    struct Entry: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var kind: Kind
        /// The server's id — the Personal canvas's own once signed in, the
        /// same as `id` for a shared one, nil for a local one.
        var remoteId: String?
        var createdAt: Date
        var updatedAt: Date
        /// Shared canvases: `owner` or `editor`, the owner's name, how many
        /// members, and which account (user id) this row came from.
        var role: String?
        var owner: String?
        var members: Int?
        var account: String?

        var isPersonal: Bool { kind == .personal }
        var isShared: Bool { kind == .shared }
        var isLocal: Bool { kind == .local }
        /// Can rename / delete / invite rather than only leave.
        var isOwner: Bool { kind != .shared || role == nil || role == "owner" }
    }

    struct Invite: Identifiable, Equatable {
        let id: String
        let canvasId: String
        let canvasName: String
        let from: String
        let createdAt: Date?
    }

    struct Member: Identifiable, Equatable {
        let id: String
        let name: String
        let email: String
        let role: String
    }

    /// A person currently visible in the canvas room. The page sends this
    /// debounced, rather than making SwiftUI inspect Yjs awareness itself.
    struct PresencePerson: Identifiable, Equatable {
        let id: String
        let name: String
        let color: String
        let kind: String
    }

    struct CloudPerson: Identifiable, Equatable {
        let id: String
        let name: String
        let email: String
    }

    /// This Mac's stand-in for an account: how a signed-out user appears on
    /// their own canvases (and to the agents drawing beside them).
    struct Persona: Codable, Equatable {
        var id: String
        var color: String
    }

    private struct Me: Codable {
        var persona: Persona
        /// The first account the local Personal history was handed to. A
        /// different account signing in later gets a Personal history of its
        /// own on this Mac, so one account's private board never merges into
        /// another's.
        var personalAccount: String?
    }

    @Published private(set) var all: [Entry] = []
    @Published private(set) var invites: [Invite] = []
    /// Invites newly observed by refresh, consumed by the in-app banner.
    @Published var newInvite: Invite?
    /// Presence reported by each open canvas page, keyed by canvas id.
    @Published private(set) var presence: [String: [PresencePerson]] = [:]
    /// A cloud round trip is in flight.
    @Published private(set) var busy = false
    /// The last cloud failure, in one line, until the next success.
    @Published var problem: String?
    @Published private(set) var refreshed: Date?

    private var me: Me
    private var observers: [NSObjectProtocol] = []
    private var refreshing: Task<Void, Never>?
    /// The account the list was last read for: a different one signing in
    /// starts over (no list read yet, no invites).
    private var listAccount: String?

    static var folder: URL { Store.file("canvas") }
    private static var listFile: URL { folder.appendingPathComponent("canvases.json") }
    private static var meFile: URL { folder.appendingPathComponent("me.json") }

    private init() {
        try? FileManager.default.createDirectory(at: Canvases.folder, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var made = false
        if let data = try? Data(contentsOf: Canvases.meFile), let saved = try? decoder.decode(Me.self, from: data) {
            me = saved
        } else {
            let id = UUID().uuidString.lowercased()
            me = Me(persona: Persona(id: id, color: CanvasColors.stable(id)))
            made = true
        }
        if let data = try? Data(contentsOf: Canvases.listFile) {
            if let list = try? decoder.decode([Entry].self, from: data) { all = list } else { Store.quarantine(Canvases.listFile) }
        }
        ensurePersonal()
        save()
        if made { saveMe() }
        observers.append(NotificationCenter.default.addObserver(forName: Cloud.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Canvases.shared.cloudChanged() }
        })
        // The Personal canvas switch (or sync as a whole) going on or off.
        observers.append(NotificationCenter.default.addObserver(forName: CloudSync.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Canvases.shared.objectWillChange.send()
                CanvasHost.cloudChanged()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Cloud.event, object: nil, queue: .main) { note in
            let type = (note.userInfo?["event"] as? [String: Any])?["type"] as? String
            MainActor.assumeIsolated {
                // `open` is the stream coming (back) up: anything may have been missed.
                if type == "canvas" || type == "open" { Canvases.shared.refreshSoon() }
            }
        })
        listAccount = Canvases.account
        if Cloud.shared.isSignedIn { refreshSoon() }
    }

    /// The signed-in account's user id, lowercased, as rows keep it.
    static var account: String? { Cloud.shared.account?.userId.uuidString.lowercased() }

    // MARK: lookups

    var personal: Entry { all.first { $0.isPersonal }! }

    func entry(_ id: String) -> Entry? { all.first { $0.id == id } }

    /// By id, by remote id, or by name (case-insensitive) — what an agent passes.
    func find(_ key: String) -> Entry? {
        let wanted = key.trimmingCharacters(in: .whitespaces)
        if let hit = all.first(where: { $0.id == wanted || $0.remoteId == wanted }) { return hit }
        if wanted.lowercased() == "personal" { return personal }
        return visible.first { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// What the sidebar lists: Personal, the local canvases, and — signed in
    /// — the shared ones of the account that is signed in.
    var visible: [Entry] {
        let account = Canvases.account
        return all.filter { entry in
            guard entry.isShared else { return true }
            return account != nil && entry.account == account
        }
    }

    /// Shared canvases kept on this Mac for an account that isn't signed in
    /// now. Their copy here still opens (offline) while nobody is signed in;
    /// with another account signed in they are only counted, never named.
    var signedOut: [Entry] {
        let account = Canvases.account
        return all.filter { $0.isShared && $0.account != account }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The Personal canvas may use its room: chosen in Settings › Cloud.
    var personalSyncs: Bool { CloudSync.shared.syncs(.canvas) }

    var mine: [Entry] { visible.filter { !$0.isPersonal && $0.isOwner }.sorted { $0.updatedAt > $1.updatedAt } }
    var sharedWithMe: [Entry] { visible.filter { $0.isShared && !$0.isOwner }.sorted { $0.updatedAt > $1.updatedAt } }

    /// Signed in on a linked cloud: sharing is possible.
    var cloudReady: Bool { Cloud.shared.isLinked && Cloud.shared.isSignedIn }

    /// Who the user is on a canvas: the cloud account, or this Mac's persona.
    var identity: (id: String, name: String, color: String) {
        if let account = Cloud.shared.account {
            let id = account.userId.uuidString.lowercased()
            let name = account.displayName.isEmpty ? account.email : account.displayName
            return (id, name, CanvasColors.stable(id))
        }
        let full = NSFullUserName()
        return (me.persona.id, full.isEmpty ? NSUserName() : full, me.persona.color)
    }

    /// Where a canvas's history is kept on this Mac (`canvas/<key>/`).
    func storeKey(_ entry: Entry) -> String {
        guard entry.isPersonal else { return entry.id }
        guard let account = Cloud.shared.account?.userId.uuidString.lowercased(),
              let bound = me.personalAccount, bound != account
        else { return entry.id }
        return "personal-\(account)"
    }

    /// The room a canvas relays to, when it has one and the cloud is up —
    /// and only for the account signed in now: a row read for another
    /// account (Personal's remote id is the last account's until the list is
    /// read again) has none. Personal has one only when its sync is chosen:
    /// with every switch off, nothing on it leaves this Mac.
    func room(for entry: Entry) -> String? {
        guard cloudReady, let remote = entry.remoteId else { return nil }
        if entry.isShared || entry.isPersonal {
            guard let account = Canvases.account, entry.account == account else { return nil }
        }
        if entry.isPersonal, !personalSyncs { return nil }
        return remote
    }

    /// The first time the local Personal history goes to an account, it is bound to it.
    func bindPersonal() {
        guard let account = Cloud.shared.account?.userId.uuidString.lowercased(), me.personalAccount == nil else { return }
        me.personalAccount = account
        saveMe()
    }

    // MARK: local changes

    private func ensurePersonal() {
        if let index = all.firstIndex(where: { $0.isPersonal }) {
            all[index].id = Canvases.personalID
            all[index].name = "Personal"
            // Exactly one.
            all.removeAll { $0.isPersonal && $0.id != Canvases.personalID }
            if let first = all.firstIndex(where: { $0.isPersonal }), first != 0 { all.insert(all.remove(at: first), at: 0) }
        } else {
            let now = Date()
            all.insert(Entry(id: Canvases.personalID, name: "Personal", kind: .personal, remoteId: nil, createdAt: now, updatedAt: now), at: 0)
        }
    }

    /// A canvas on this Mac only — what "New canvas" makes when signed out.
    @discardableResult
    /// Dated as given when it stands for something older (an easel brought
    /// over by CanvasImport), so the newest-first lists keep their order.
    func createLocal(named name: String, createdAt: Date? = nil, updatedAt: Date? = nil) -> Entry {
        let now = Date()
        let entry = Entry(id: UUID().uuidString.lowercased(), name: Canvases.clean(name), kind: .local, remoteId: nil,
                          createdAt: createdAt ?? now, updatedAt: updatedAt ?? createdAt ?? now)
        all.append(entry)
        save()
        return entry
    }

    /// The page saw a change: the list sorts recent first.
    func touched(_ id: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        guard Date().timeIntervalSince(all[index].updatedAt) > 30 else { return }
        all[index].updatedAt = Date()
        save()
    }

    static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled canvas" : String(trimmed.prefix(80))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(at: Canvases.folder, withIntermediateDirectories: true)
        try? data.write(to: Canvases.listFile, options: .atomic)
        objectWillChange.send()
    }

    private func saveMe() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(me) else { return }
        try? data.write(to: Canvases.meFile, options: .atomic)
    }

    // MARK: the cloud

    private func cloudChanged() {
        let account = Canvases.account
        if account != listAccount {
            // Another account (or none): its list and invites are not this one's.
            listAccount = account
            refreshed = nil
            invites = []
            problem = nil
        }
        if cloudReady {
            refreshSoon()
        } else {
            invites = []
        }
        if Cloud.shared.isSignedIn { CanvasJoinFlow.resumePending() }
        CanvasHost.cloudChanged()
    }

    /// Coalesced: a burst of events is one round trip.
    func refreshSoon() {
        guard cloudReady else { return }
        if refreshing != nil { again = true; return }
        refreshing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.refresh()
            self?.refreshing = nil
            // Asked for again while that one was in flight (an account
            // switch in the middle of a read): once more, for what is now.
            if self?.again == true {
                self?.again = false
                self?.refreshSoon()
            }
        }
    }

    private var again = false

    /// The server's list and the invites waiting for this account.
    func refresh() async {
        guard cloudReady, let account = Canvases.account else { return }
        busy = true
        defer { busy = false }
        do {
            let (data, _) = try await Cloud.shared.request("GET", "/v1/canvases")
            // Signed out or switched while the answer was on its way: it is
            // the old account's list, and goes nowhere.
            guard Canvases.account == account else { again = true; return }
            adopt(remote: Canvases.rows(data), account: account)
            let (pending, _) = try await Cloud.shared.request("GET", "/v1/invites")
            guard Canvases.account == account else { again = true; return }
            let incoming = Canvases.rows(pending).compactMap(Canvases.invite)
            let known = Set(invites.map(\.id))
            invites = incoming
            if let fresh = incoming.first(where: { !known.contains($0.id) }) {
                newInvite = fresh
            }
            problem = nil
            refreshed = Date()
            CanvasHost.cloudChanged()
        } catch {
            problem = Canvases.explain(error)
        }
    }

    private func adopt(remote rows: [[String: Any]], account: String) {
        var seen = Set<String>()
        var renamed: [String] = []
        for row in rows {
            guard let id = Canvases.string(row["id"]) else { continue }
            let kind = Canvases.string(row["kind"]) ?? "shared"
            let name = Canvases.string(row["name"]) ?? "Untitled canvas"
            let updated = Canvases.date(row["updated_at"]) ?? Date()
            if kind == "personal" {
                if let index = all.firstIndex(where: { $0.isPersonal }) {
                    all[index].remoteId = id
                    all[index].account = account
                }
                continue
            }
            seen.insert(id)
            let role = Canvases.string(row["role"])
            let owner = Canvases.person(row["owner"])
            let members = (row["member_count"] as? NSNumber)?.intValue
            if let index = all.firstIndex(where: { $0.id == id }) {
                if all[index].name != name { renamed.append(id) }
                all[index].name = name
                all[index].kind = .shared
                all[index].remoteId = id
                all[index].role = role
                all[index].owner = owner
                all[index].members = members
                all[index].account = account
                all[index].updatedAt = max(all[index].updatedAt, updated)
            } else {
                all.append(Entry(id: id, name: name, kind: .shared, remoteId: id, createdAt: Canvases.date(row["created_at"]) ?? updated,
                                 updatedAt: updated, role: role, owner: owner, members: members, account: account))
            }
        }
        // Gone from the server for this account: left, removed, deleted.
        // The local history stays on disk, it just isn't listed.
        let gone = all.filter { $0.isShared && $0.account == account && !seen.contains($0.id) }
        all.removeAll { $0.isShared && $0.account == account && !seen.contains($0.id) }
        save()
        renamed.forEach(CanvasHost.renamed)
        for id in seen { CanvasHost.shareChanged(id) }
        // Removed, revoked or deleted by someone else: its open tabs close.
        gone.forEach { CanvasHost.removed($0.id) }
    }

    /// Made on the server, the owner's first row with it. Signed out, a local one.
    func create(named name: String) async throws -> Entry {
        let clean = Canvases.clean(name)
        guard cloudReady, let account = Cloud.shared.account?.userId.uuidString.lowercased() else { return createLocal(named: clean) }
        busy = true
        defer { busy = false }
        do {
            let (data, _) = try await Cloud.shared.request("POST", "/v1/canvases", json: ["name": clean])
            guard let row = Canvases.object(data), let id = Canvases.string(row["id"]) else {
                throw Cloud.Failure(status: 0, code: "shape", message: "The server's answer had no canvas in it")
            }
            let now = Date()
            let entry = Entry(id: id, name: Canvases.string(row["name"]) ?? clean, kind: .shared, remoteId: id, createdAt: now, updatedAt: now,
                              role: "owner", owner: Cloud.shared.account?.displayName, members: 1, account: account)
            all.removeAll { $0.id == id }
            all.append(entry)
            save()
            problem = nil
            return entry
        } catch {
            problem = Canvases.explain(error)
            throw error
        }
    }

    func rename(_ id: String, to name: String) async throws {
        guard let index = all.firstIndex(where: { $0.id == id }), !all[index].isPersonal else { return }
        let clean = Canvases.clean(name)
        if all[index].isShared {
            guard cloudReady, let remote = all[index].remoteId else { throw Canvases.offline }
            _ = try await Cloud.shared.request("PATCH", "/v1/canvases/\(remote)", json: ["name": clean])
        }
        guard let again = all.firstIndex(where: { $0.id == id }) else { return }
        all[again].name = clean
        all[again].updatedAt = Date()
        save()
        CanvasHost.renamed(id)
    }

    /// Owner: the canvas goes for everyone. A local one: its history goes too.
    func delete(_ id: String) async throws {
        guard let entry = entry(id), !entry.isPersonal else { return }
        if entry.isShared {
            guard cloudReady, let remote = entry.remoteId else { throw Canvases.offline }
            _ = try await Cloud.shared.request("DELETE", "/v1/canvases/\(remote)")
        }
        forget(entry)
    }

    /// A member who isn't the owner steps out.
    func leave(_ id: String) async throws {
        guard let entry = entry(id), entry.isShared, let remote = entry.remoteId else { return }
        guard cloudReady, let me = Cloud.shared.account?.userId.uuidString.lowercased() else { throw Canvases.offline }
        _ = try await Cloud.shared.request("DELETE", "/v1/canvases/\(remote)/members/\(me)")
        forget(entry)
    }

    private func forget(_ entry: Entry) {
        CanvasHost.removed(entry.id)
        all.removeAll { $0.id == entry.id }
        CanvasStore.store(for: storeKey(entry)).erase()
        save()
    }

    /// An email invite (`POST /v1/canvases/:id/invites`, every copper-cloud
    /// has it). True when the server made a new one (201), false when that
    /// address already had one waiting (200).
    @discardableResult
    func invite(_ id: String, email: String) async throws -> Bool {
        guard let entry = entry(id) else { throw Cloud.Failure(status: 404, code: "missing", message: "No canvas \(id)") }
        guard !entry.isPersonal else { throw Cloud.Failure(status: 400, code: "personal", message: "The Personal canvas can't be shared") }
        guard cloudReady else { throw Canvases.offline }
        guard entry.isShared, let remote = entry.remoteId else {
            throw Cloud.Failure(status: 400, code: "local", message: "“\(entry.name)” is on this Mac only — make a new canvas while signed in to share")
        }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Canvases.isEmail(address) else { throw Cloud.Failure(status: 400, code: "email", message: "That isn't an email address") }
        let (_, response) = try await Cloud.shared.request("POST", "/v1/canvases/\(remote)/invites", json: ["email": address])
        return response.statusCode == 201
    }

    /// Shaped like an address the way copper-cloud checks one before it
    /// takes an invite: something before one `@`, a dotted domain after it,
    /// no spaces.
    nonisolated static func isEmail(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...254).contains(value.count), !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    func members(_ id: String) async throws -> [Member] {
        guard let entry = entry(id), entry.isShared, let remote = entry.remoteId else { return [] }
        guard cloudReady else { throw Canvases.offline }
        let (data, _) = try await Cloud.shared.request("GET", "/v1/canvases/\(remote)/members")
        return Canvases.rows(data).compactMap { row in
            guard let user = Canvases.string(row["user_id"]) ?? Canvases.string(row["id"]) else { return nil }
            let email = Canvases.string(row["email"]) ?? ""
            let name = Canvases.string(row["display_name"]) ?? Canvases.string(row["name"]) ?? email
            return Member(id: user, name: name, email: email, role: Canvases.string(row["role"]) ?? "editor")
        }
    }

    func answer(_ invite: Invite, accept: Bool) async throws {
        guard cloudReady else { throw Canvases.offline }
        _ = try await Cloud.shared.request("POST", "/v1/invites/\(invite.id)/\(accept ? "accept" : "decline")")
        invites.removeAll { $0.id == invite.id }
        if newInvite?.id == invite.id { newInvite = nil }
        await refresh()
    }

    /// Called by CanvasHost when the page reports the people in its room.
    func setPresence(_ people: [PresencePerson], for id: String) {
        presence[id] = people
        objectWillChange.send()
    }

    func clearPresence(for id: String) {
        presence[id] = nil
        objectWillChange.send()
    }

    /// Upsert one row returned by the canvas-link join endpoint. The response
    /// deliberately has the same shape as a /v1/canvases list item.
    @discardableResult
    func upsert(remote row: [String: Any], account: String) -> Entry? {
        guard let id = Canvases.string(row["id"]) ?? Canvases.string(row["canvas_id"]) else { return nil }
        let now = Date()
        let name = Canvases.string(row["name"]) ?? "Untitled canvas"
        let role = Canvases.string(row["role"]) ?? "editor"
        let owner = Canvases.person(row["owner"])
        let members = (row["member_count"] as? NSNumber)?.intValue
        let index = all.firstIndex { $0.id == id }
        let value = Entry(id: id, name: name, kind: .shared, remoteId: id,
                          createdAt: index.map { all[$0].createdAt } ?? now,
                          updatedAt: Canvases.date(row["updated_at"]) ?? now,
                          role: role, owner: owner, members: members, account: account)
        if let index { all[index] = value } else { all.append(value) }
        save()
        CanvasHost.shareChanged(id)
        return value
    }

    // MARK: reading the server's answers

    static let offline = Cloud.Failure(status: 0, code: "not_signed_in", message: "Sign in at Settings › Cloud to share canvases")

    static func explain(_ error: Error) -> String {
        if let failure = error as? Cloud.Failure { return failure.message }
        return error.localizedDescription
    }

    /// An array at the top, or under the first key that holds one.
    static func rows(_ data: Data) -> [[String: Any]] {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let list = value as? [[String: Any]] { return list }
        if let object = value as? [String: Any] {
            for key in ["canvases", "invites", "members", "items", "data"] {
                if let list = object[key] as? [[String: Any]] { return list }
            }
        }
        return []
    }

    static func object(_ data: Data) -> [String: Any]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let inner = object["canvas"] as? [String: Any] { return inner }
        return object
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text.isEmpty ? nil : text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// A person as the server names one: a string, or `{display_name, email, id}`.
    static func person(_ value: Any?) -> String? {
        if let object = value as? [String: Any] {
            return string(object["display_name"]) ?? string(object["name"]) ?? string(object["email"])
        }
        return string(value)
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue) }
        guard let text = value as? String else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    static func invite(_ row: [String: Any]) -> Invite? {
        guard let id = string(row["id"]) else { return nil }
        if let status = string(row["status"]), status != "pending" { return nil }
        let canvas = row["canvas"] as? [String: Any]
        let canvasId = string(row["canvas_id"]) ?? string(canvas?["id"]) ?? ""
        let name = string(row["canvas_name"]) ?? string(canvas?["name"]) ?? "A canvas"
        let from = person(row["invited_by_name"]) ?? person(row["invited_by"]) ?? person(row["from"]) ?? ""
        return Invite(id: id, canvasId: canvasId, canvasName: name, from: from, createdAt: date(row["created_at"]))
    }
}

// MARK: - the history on disk

/// One canvas's Yjs history: `updates.log` (each update as a 4-byte
/// big-endian length and its bytes, in the order the page made them or the
/// room handed them to the page — see CanvasHost.deliver) and,
/// once that grows past 2 MB or 500 entries, `snapshot.bin` — the whole
/// document as one update, from the page's `exportState()` — with the log
/// cut back to what came after it. Opening a canvas is the snapshot, then
/// every logged update on top: Yjs makes applying the same update twice
/// harmless, so the cut only ever errs on the side of keeping too much.
@MainActor
final class CanvasStore {
    static let maxEntries = 500
    static let maxBytes = 2 * 1024 * 1024

    private static var open: [String: CanvasStore] = [:]

    static func store(for key: String) -> CanvasStore {
        if let known = open[key] { return known }
        let made = CanvasStore(key: key)
        open[key] = made
        return made
    }

    let key: String
    let folder: URL
    private var log: URL { folder.appendingPathComponent("updates.log") }
    private var snapshot: URL { folder.appendingPathComponent("snapshot.bin") }
    /// Every write happens here, in order; reads wait their turn.
    private let queue: DispatchQueue
    private let io: CanvasIO

    /// Entries and bytes in the log right now (main-actor bookkeeping).
    private(set) var entries = 0
    private(set) var bytes = 0
    private var counted = false

    private init(key: String) {
        self.key = key
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        folder = Canvases.folder.appendingPathComponent(safe, isDirectory: true)
        queue = DispatchQueue(label: "copper.canvas.store.\(safe)")
        io = CanvasIO()
    }

    /// The snapshot and the updates after it, as they are on disk now.
    func load() -> (snapshot: Data?, updates: [Data]) {
        let folder = folder, log = log, snapshot = snapshot, io = io
        let result = queue.sync { () -> (Data?, [Data]) in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = try? Data(contentsOf: snapshot)
            let updates = io.read(log)
            return (base, updates)
        }
        entries = result.1.count
        bytes = result.1.reduce(0) { $0 + $1.count + 4 }
        counted = true
        return (result.0, result.1)
    }

    func append(_ update: Data) {
        guard !update.isEmpty else { return }
        if !counted { _ = load() }
        entries += 1
        bytes += update.count + 4
        let folder = folder, log = log, io = io
        queue.async { io.append(update, to: log, in: folder) }
    }

    /// Hashes of the room's updates kept lately: two tabs on one canvas each
    /// hold a room and each hand the page the same update; it is kept once.
    private var remoteSeen: [Int] = []

    /// An update the room handed the page. The page never reports those
    /// back (they are the provider's), so the host keeps them itself, as
    /// they arrive — what a collaborator wrote is on disk the moment it is on
    /// the board, and survives a disconnect, a sleep or a quit.
    func appendRemote(_ update: Data) {
        let hash = CanvasStore.fingerprint(update)
        if remoteSeen.contains(hash) { return }
        remoteSeen.append(hash)
        if remoteSeen.count > 128 { remoteSeen.removeFirst(remoteSeen.count - 128) }
        append(update)
    }

    /// Changes made here since the room last confirmed a sync (shared
    /// canvases): what the page shows as waiting to go. Lives as long as
    /// the app — a reload of the page doesn't forget it.
    var pending = 0

    /// A hash of every byte. (`Data.hashValue` reads only the length and the
    /// first 80 bytes — two updates can share those.)
    static func fingerprint(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    /// Every write queued so far is on disk when this returns.
    func flush() {
        let io = io
        queue.sync { io.synchronize() }
    }

    /// The app is quitting: every open canvas's history, written down.
    static func flushAll() {
        for store in open.values { store.flush() }
    }

    /// Past the size the log should be cut back at.
    var wantsCompaction: Bool { entries > CanvasStore.maxEntries || bytes > CanvasStore.maxBytes }

    /// `state` holds everything up to the first `dropping` entries of the log.
    func compact(state: Data, dropping count: Int) {
        guard !state.isEmpty else { return }
        let folder = folder, log = log, snapshot = snapshot, io = io
        entries = max(0, entries - count)
        queue.async {
            let temp = folder.appendingPathComponent("snapshot.bin.tmp")
            do {
                try state.write(to: temp, options: .atomic)
                try CanvasIO.swap(temp, into: snapshot)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                return
            }
            if count > 0 { io.drop(count, from: log, in: folder) }
        }
        // Recount from disk once the cut has landed.
        queue.async { [weak self] in
            let left = io.read(log)
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.entries = left.count
                    self.bytes = left.reduce(0) { $0 + $1.count + 4 }
                }
            }
        }
    }

    /// Everything kept for this canvas, gone (a deleted local canvas, a shared one left).
    func erase() {
        let folder = folder, io = io
        entries = 0
        bytes = 0
        queue.async {
            io.close()
            try? FileManager.default.removeItem(at: folder)
        }
        CanvasStore.open[key] = nil
    }

    /// For the bench and the tools: what is on disk.
    var describe: [String: Any] {
        ["key": key, "entries": entries, "bytes": bytes, "pending": pending,
         "snapshot": (try? FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as? NSNumber)?.intValue ?? 0]
    }
}

/// The file work, off the main thread, on the store's own queue.
private final class CanvasIO: @unchecked Sendable {
    private var handle: FileHandle?

    func read(_ log: URL) -> [Data] {
        close()
        guard let data = try? Data(contentsOf: log) else { return [] }
        var out: [Data] = []
        var at = 0
        while at + 4 <= data.count {
            let length = data[data.startIndex + at ..< data.startIndex + at + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, at + 4 + length <= data.count else { break }
            out.append(data.subdata(in: data.startIndex + at + 4 ..< data.startIndex + at + 4 + length))
            at += 4 + length
        }
        // A record cut short by a crash mid-write: the file is put back to
        // the last whole one so the next append lines up.
        if at < data.count { try? data.prefix(at).write(to: log, options: .atomic) }
        return out
    }

    func append(_ update: Data, to log: URL, in folder: URL) {
        if handle == nil {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: log)
            _ = try? handle?.seekToEnd()
        }
        var length = UInt32(update.count).bigEndian
        var record = Data(bytes: &length, count: 4)
        record.append(update)
        do { try handle?.write(contentsOf: record) } catch { close() }
    }

    func drop(_ count: Int, from log: URL, in folder: URL) {
        let all = read(log)
        let kept = all.dropFirst(min(count, all.count))
        var data = Data()
        for update in kept {
            var length = UInt32(update.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(update)
        }
        let temp = folder.appendingPathComponent("updates.log.tmp")
        do {
            try data.write(to: temp, options: .atomic)
            try CanvasIO.swap(temp, into: log)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    /// `temp` takes `target`'s place in one rename (there may be no target yet).
    static func swap(_ temp: URL, into target: URL) throws {
        if rename(temp.path, target.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    /// What was written reaches the disk, not just the kernel.
    func synchronize() {
        try? handle?.synchronize()
    }
}
