import Foundation
import WebKit

/// Puts another browser's localStorage into Copper's website store, from the
/// JSON `arc-localstorage` writes: `{"<origin>": {"<key>": "<value>"}}`.
///
/// WebKit has no API for writing another origin's localStorage, so the only
/// way in is to be that origin: one hidden web view loads an empty document
/// with the origin as its base URL — nothing is fetched, but the document's
/// origin (and so its storage) is the site's — and sets each key from a
/// script. One origin at a time, each awaited, so a failure is pinned to the
/// origin it happened in.
@MainActor final class StorageImport: NSObject, WKNavigationDelegate {
    static let shared = StorageImport()

    private(set) var running = false
    private var done = 0
    private var total = 0
    private var rows: [[String: Any]] = []
    private var error: String?
    private var landing: CheckedContinuation<Void, Error>?
    private var allowed: URL?
    private var attempt = 0

    /// Enough per script call to keep the number of round trips down without
    /// handing WebKit one enormous argument; a single bigger value goes alone.
    private static let chunk = 1_000_000

    /// `./bench storage import PATH [--only ORIGIN] [--profile-store NAME]`
    /// starts it and answers at once (a big import outlasts the bench's
    /// 25 s answer); `storage status` is the report so far. Not held to test
    /// runs: moving off Arc is what a real Copper wants it for, and the bench
    /// is already opt-in.
    func bench(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        switch request["op"] as? String ?? "status" {
        case "import":
            guard !running else { return ["error": "an import is already running", "status": status] }
            guard let path = request["path"] as? String else { return ["error": "storage import needs a PATH"] }
            let data: [String: [String: String]]
            do {
                let raw = try Data(contentsOf: URL(fileURLWithPath: path))
                guard let parsed = try JSONSerialization.jsonObject(with: raw) as? [String: [String: String]] else {
                    return ["error": "\(path) is not {origin: {key: value}}"]
                }
                data = parsed
            } catch { return ["error": error.localizedDescription] }
            var origins = data.keys.sorted()
            if let only = request["only"] as? String, !only.isEmpty {
                let wanted = only.hasSuffix("/") ? String(only.dropLast()) : only
                origins = origins.filter { $0 == wanted }
                if origins.isEmpty { return ["error": "\(only) is not in \(path)"] }
            }
            var stores: [(String, WKWebsiteDataStore)] = [("shared", Self.sharedStore)]
            if let name = request["profileStore"] as? String, !name.isEmpty {
                stores.append(("profile:\(name)", Spaces.store(forProfile: name)))
            }
            running = true
            done = 0
            total = origins.count * stores.count
            rows = []
            error = nil
            Task { await run(data, origins, stores) }
            return ["started": true, "origins": origins.count, "stores": stores.map(\.0)]
        default:
            return status
        }
    }

    var status: [String: Any] {
        let failed = rows.filter { ($0["failed"] as? [String])?.isEmpty == false || $0["error"] != nil }
        var answer: [String: Any] = [
            "running": running, "done": done, "total": total,
            "keys": rows.reduce(0) { $0 + ($1["set"] as? Int ?? 0) },
            "failedOrigins": failed.count, "origins": rows,
        ]
        if let error { answer["error"] = error }
        return answer
    }

    /// The store tabs in a space without a profile use. `Store.websites`
    /// answers for whichever space is current, so ask it while building for
    /// an id no space has — the same path upstream takes, profile left out.
    static var sharedStore: WKWebsiteDataStore {
        Spaces.shared.building(for: UUID()) { Store.websites }
    }

    private func run(_ data: [String: [String: String]], _ origins: [String], _ stores: [(String, WKWebsiteDataStore)]) async {
        defer { running = false }
        for (label, store) in stores {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = store
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16), configuration: configuration)
            view.navigationDelegate = self
            for origin in origins {
                let keys = data[origin] ?? [:]
                var row: [String: Any] = ["origin": origin, "store": label, "keys": keys.count]
                do {
                    let set = try await put(keys, at: origin, in: view)
                    row["set"] = keys.count - set.count
                    if !set.isEmpty { row["failed"] = Array(set.prefix(20)) }
                } catch {
                    row["set"] = 0
                    row["error"] = error.localizedDescription
                }
                rows.append(row)
                done += 1
            }
            // Leave the page on a blank document so the last origin's page
            // is not kept alive holding its storage area open.
            view.navigationDelegate = nil
            view.loadHTMLString("", baseURL: nil)
        }
    }

    /// Loads the origin's empty page, checks it really is that origin, and
    /// sets its keys; answers the keys (with the reason) that would not set.
    private func put(_ keys: [String: String], at origin: String, in view: WKWebView) async throws -> [String] {
        guard let base = URL(string: origin + "/"), ["http", "https"].contains(base.scheme ?? "") else {
            throw Failure("not an http(s) origin")
        }
        try await land(view, at: base)
        let there = try await view.evaluateJavaScript("location.origin") as? String
        guard there == origin else { throw Failure("page came up as \(there ?? "nothing"), not \(origin)") }
        var failed: [String] = []
        var batch: [String: String] = [:]
        var size = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            let answer = try await view.callAsyncJavaScript("""
                const failed = [];
                for (const [k, v] of Object.entries(items)) {
                    try { localStorage.setItem(k, v) } catch (e) { failed.push(k + ": " + e.name) }
                }
                return failed;
                """, arguments: ["items": batch], contentWorld: .page)
            failed += answer as? [String] ?? []
            batch = [:]
            size = 0
        }
        for (key, value) in keys.sorted(by: { $0.key < $1.key }) {
            let weight = key.utf16.count + value.utf16.count
            if size + weight > Self.chunk { try await flush() }
            batch[key] = value
            size += weight
        }
        try await flush()
        return failed
    }

    private func land(_ view: WKWebView, at base: URL) async throws {
        allowed = base
        attempt += 1
        let this = attempt
        try await withCheckedThrowingContinuation { (going: CheckedContinuation<Void, Error>) in
            landing = going
            view.loadHTMLString("<!doctype html><title>import</title>", baseURL: base)
            // Only this load's own timer may fail it, not one left from an
            // origin that loaded long ago.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.attempt == this else { return }
                self.finish(Failure("page did not load in 15 s"))
            }
        }
    }

    private func finish(_ failure: Error?) {
        guard let going = landing else { return }
        landing = nil
        if let failure { going.resume(throwing: failure) } else { going.resume() }
    }

    /// Only the empty document itself may load: nothing that would reach the
    /// network under the site's name.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url == allowed ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
