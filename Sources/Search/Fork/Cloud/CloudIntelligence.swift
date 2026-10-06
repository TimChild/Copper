import Foundation

// Copper Cloud-provided model keys: `GET /v1/intelligence` on the linked
// instance, so a person signed in to their team's cloud has a working agent
// pane and Jev with nothing pasted. What it answers is kept in memory
// (`Intelligence.cloud`) and in `cloud-intelligence.json` (0600) so an
// offline launch still has them; it is never written into
// intelligence.json. Its gateway key, while provided, is the one every model
// call uses (gateway lane, its address), whatever this Mac chose; a Jev key
// typed on this Mac wins (`Intelligence.merge`). Signed out or unlinked,
// both go, and this Mac's own choice is back.
//
// Asked after a sign-in, at launch when linked and signed in, when Settings
// opens, and every 30 minutes. A 404 (a cloud from before this route), 401
// or 403 means "nothing provided" — no error anywhere. A network failure
// keeps what was known.

/// The answer to `GET /v1/intelligence`, plus where and when it came from.
struct CloudProvided: Codable, Equatable {
    struct JevPart: Codable, Equatable {
        var key: String?
        var endpoint: String?
        var model: String?
    }
    struct RouterPart: Codable, Equatable {
        var key: String?
        var url: String?
    }
    var jev: JevPart?
    var router: RouterPart?
    /// The server's own `updated_at` (RFC 3339), as sent.
    var updatedAt: String?
    /// The cloud it came from, as people read it (`host:port`).
    var host: String?
    /// `link URL|user id`: a cache is only good for the account that fetched it.
    var owner: String?
    var fetchedAt: Date?

    enum CodingKeys: String, CodingKey {
        case jev, router, updatedAt = "updated_at", host, owner, fetchedAt = "fetched_at"
    }

    /// The parts that carry a key: `jev`, `router`. Never the key itself.
    var provides: [String] {
        var out: [String] = []
        if !(jev?.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("jev") }
        if !(router?.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("router") }
        return out
    }

    var isEmpty: Bool {
        provides.isEmpty && (jev?.endpoint ?? "").isEmpty && (jev?.model ?? "").isEmpty && (router?.url ?? "").isEmpty
    }

    /// The server's body, read leniently: any field may be null, absent or
    /// the wrong type, and is then simply not provided. Nil only when the
    /// body is not a JSON object at all.
    static func parse(_ data: Data) -> CloudProvided? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ any: Any?) -> String? {
            guard let s = any as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var out = CloudProvided()
        if let jev = object["jev"] as? [String: Any] {
            let part = JevPart(key: text(jev["key"]), endpoint: text(jev["endpoint"]), model: text(jev["model"]))
            if part.key != nil || part.endpoint != nil || part.model != nil { out.jev = part }
        }
        if let router = object["router"] as? [String: Any] {
            let part = RouterPart(key: text(router["key"]), url: text(router["url"]))
            if part.key != nil || part.url != nil { out.router = part }
        }
        out.updatedAt = text(object["updated_at"])
        return out
    }

    /// Partial-key display for Settings: the first 3 and last 4 characters.
    static func masked(_ key: String?) -> String {
        let k = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count > 10 else { return k.isEmpty ? "" : "••••" }
        return "\(k.prefix(3))…\(k.suffix(4))"
    }
}

@MainActor
final class CloudIntelligence {
    static let shared = CloudIntelligence()

    static var file: URL { Store.file("cloud-intelligence.json") }
    static let interval: TimeInterval = 30 * 60

    /// What the last ask came to: `never`, `ok`, `none (404)`, `offline`, …
    private(set) var lastOutcome = "never"
    private(set) var lastAsked: Date?

    private var started = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var inFlight: Task<Void, Never>?
    /// The link and account the in-memory answer is for.
    private var current: String?
    /// The last ask failed on the network; asked again when the cloud answers.
    private var offline = false

    private init() {}

    private var cloud: Cloud { Cloud.shared }

    /// `link URL|user id` while linked and signed in; nil otherwise.
    private var identity: String? {
        guard let link = cloud.link, let account = cloud.account else { return nil }
        return "\(link.url.absoluteString)|\(account.userId.uuidString.lowercased())"
    }

    /// Once, at launch (MCP.start). Idempotent.
    func start() {
        guard !started else { return }
        started = true
        observer = NotificationCenter.default.addObserver(forName: Cloud.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CloudIntelligence.shared.cloudChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: CloudIntelligence.interval, repeats: true) { _ in
            MainActor.assumeIsolated { CloudIntelligence.shared.refresh(force: true) }
        }
        timer?.tolerance = 60
        guard let identity else {
            // Signed out or unlinked while Copper was closed: nothing kept.
            forget()
            return
        }
        current = identity
        if let cached = readCache(), cached.owner == identity { Intelligence.shared.adoptCloud(cached) }
        else { removeCache() }
        refresh(force: true)
    }

    /// Settings opened (any page): ask again unless asked within a minute.
    func settingsOpened() {
        refresh(force: false)
    }

    /// Ask the cloud now. `force: false` skips an ask made in the last minute.
    func refresh(force: Bool) {
        guard identity != nil, inFlight == nil else { return }
        if !force, let lastAsked, Date().timeIntervalSince(lastAsked) < 60 { return }
        inFlight = Task { @MainActor in
            await self.fetch()
            self.inFlight = nil
        }
    }

    private func cloudChanged() {
        guard let identity else {
            if current != nil || Intelligence.shared.cloud != nil || FileManager.default.fileExists(atPath: CloudIntelligence.file.path) {
                forget()
            }
            current = nil
            return
        }
        if identity != current {
            // Signed in (again), or as someone else: their keys, not the last ones.
            if current != nil || Intelligence.shared.cloud?.owner != identity { forget() }
            current = identity
            refresh(force: true)
        } else if offline, cloud.reachable {
            refresh(force: true)
        }
    }

    private func fetch() async {
        guard let identity, let host = cloud.link?.host else { return }
        lastAsked = Date()
        do {
            let (data, _) = try await cloud.request("GET", "/v1/intelligence")
            guard self.identity == identity else { return }
            offline = false
            var provided = CloudProvided.parse(data) ?? CloudProvided()
            provided.host = host
            provided.owner = identity
            provided.fetchedAt = Date()
            if provided.isEmpty {
                lastOutcome = "ok (nothing provided)"
                Intelligence.shared.adoptCloud(nil)
                removeCache()
            } else {
                lastOutcome = "ok"
                let before = Intelligence.shared.cloud
                Intelligence.shared.adoptCloud(provided)
                writeCache(provided)
                if before?.provides != provided.provides {
                    CloudLog.note(provided.provides.isEmpty ? "Copper Cloud provides no model keys"
                                  : "Copper Cloud provides model keys: \(provided.provides.joined(separator: ", "))")
                }
            }
        } catch let failure as Cloud.Failure {
            guard self.identity == identity else { return }
            switch failure.status {
            case 404, 401, 403:
                // An older cloud, or one that won't say: nothing provided.
                offline = false
                lastOutcome = "none (\(failure.status))"
                Intelligence.shared.adoptCloud(nil)
                removeCache()
            default:
                // Offline or the server is having a moment: keep what is known.
                offline = failure.status == 0
                lastOutcome = failure.status == 0 ? "offline" : "error (\(failure.status))"
            }
        } catch {
            offline = true
            lastOutcome = "offline"
        }
    }

    /// Signed out or unlinked: the keys go from memory and disk.
    private func forget() {
        inFlight?.cancel()
        inFlight = nil
        Intelligence.shared.adoptCloud(nil)
        removeCache()
        lastOutcome = "never"
        lastAsked = nil
        offline = false
    }

    private func readCache() -> CloudProvided? {
        guard let data = try? Data(contentsOf: CloudIntelligence.file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CloudProvided.self, from: data)
    }

    /// Atomic and 0600 from the first byte, like cloud.json.
    private func writeCache(_ provided: CloudProvided) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(provided) else { return }
        let file = CloudIntelligence.file
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".cloud-intelligence.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, file.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func removeCache() {
        try? FileManager.default.removeItem(at: CloudIntelligence.file)
    }
}
