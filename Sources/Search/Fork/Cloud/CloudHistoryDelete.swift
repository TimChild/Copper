import Foundation

// Deleting this account's history on Copper Cloud — `DELETE
// /v1/sync/history`, on a copper-cloud that lists `history_delete` in
// `GET /v1/info`'s `features` (0.8.0).
//
// Only the person picks what goes, by what it is, and only this Mac reads
// history to find it. The server never opens history to filter it: it
// deletes the rows the client names by `seq`, or wholesale — a time window,
// a device, everything. So:
//
//   - a time window, a device, everything: one request, the server's own
//     filters (`since` inclusive, `until` exclusive, `device`; none at all is
//     everything);
//   - a site or a page: history is paged through here (`GET
//     /v1/sync/history` without `exclude_device`: every Mac's rows, by seq),
//     each row is matched here — a site with its subdomains, a page by its
//     History key, and the window or device too if asked — and the matches
//     are deleted by seq, 5,000 a request at most.
//
// Never seqs and filters in one request, and nothing chosen is never
// "everything". Nothing is deleted until the looking is done, so a stop
// while looking deletes nothing; once deleting starts it runs to the end.
// No Cloud and no main actor here: the asking is handed in, so the paging
// runs off the main thread and `bench cloud selftest` drives it against a
// pretend server. CloudSync runs it in the history lane and keeps a push
// from sending back what it deleted (`CloudSync.deleteHistory`).

enum CloudHistoryDelete {
    /// What `GET /v1/info`'s `features` lists when the server can delete.
    static let feature = "history_delete"
    /// The most seqs one request may name.
    static let batch = 5_000
    /// Rows asked for per page while looking.
    static let pageSize = 500
    /// Pages read at most in one delete — 500,000 visits — so it always ends.
    static let pageLimit = 1_000
    /// Said instead of the controls when the cloud can't.
    static let unsupported = "This cloud can't delete history — it needs copper-cloud 0.8.0 or later."

    /// What to delete. The window, the device and the sites or pages all have
    /// to agree; among themselves, sites and pages are either-or.
    struct Selector: Equatable, Sendable {
        /// `visited_at` from (inclusive)…
        var since: Date?
        /// …up to (not including).
        var until: Date?
        /// One Mac's rows only.
        var device: UUID?
        /// Sites as `site(_:)` writes them, each with its subdomains: `x.com`
        /// is also `www.x.com` and `a.x.com`, never `notx.com`.
        var hosts: [String] = []
        /// Pages, by History key (`CloudApply.historyKey`).
        var pages: [String] = []
        /// All of it. Has to be said: nothing chosen is never everything.
        var everything = false

        /// Sites or pages: only this Mac can tell which rows those are.
        var scans: Bool { !hosts.isEmpty || !pages.isEmpty }
        var narrowed: Bool { since != nil || until != nil || device != nil || scans }
        /// Something chosen, or everything — never both, never neither — and
        /// a window that isn't empty.
        var valid: Bool {
            if let since, let until, since >= until { return false }
            return narrowed != everything
        }
    }

    /// One request to `/v1/sync/history`.
    struct Ask: Equatable, Sendable {
        var method: String
        var query: [String: String] = [:]
        /// `{"seqs": […]}`, and then no query.
        var body: Data?
    }

    /// The page after `since`, every Mac's rows (no `exclude_device`).
    static func page(after since: Int64) -> Ask {
        Ask(method: "GET", query: ["since": String(since), "limit": String(pageSize)])
    }

    /// Deleting by the server's own filters. RFC 3339 in UTC, so a `+` never
    /// rides in a query string to be read as a space.
    static func window(_ selector: Selector) -> Ask {
        var query: [String: String] = [:]
        if let since = selector.since { query["since"] = CloudSync.stamp(since) }
        if let until = selector.until { query["until"] = CloudSync.stamp(until) }
        if let device = selector.device { query["device"] = device.uuidString.lowercased() }
        return Ask(method: "DELETE", query: query)
    }

    /// Deleting rows by name. Written by hand: an encoder that could fail
    /// would leave a body-less, query-less DELETE — which is everything.
    static func seqs(_ seqs: [Int64]) -> Ask {
        Ask(method: "DELETE", body: Data(("{\"seqs\":[" + seqs.map(String.init).joined(separator: ",") + "]}").utf8))
    }

    static func batches(_ seqs: [Int64], size: Int = batch) -> [[Int64]] {
        stride(from: 0, to: seqs.count, by: max(1, size)).map { Array(seqs[$0..<min($0 + max(1, size), seqs.count)]) }
    }

    /// `{"deleted": n}`.
    static func deleted(in answer: Data) -> Int {
        let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        return (object?["deleted"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - looking

    /// A row as `GET /v1/sync/history` sends it. Read leniently: one odd row
    /// mustn't stop a delete — it just matches nothing it can't show. Its
    /// time stays text until a window asks for it (`Clock`).
    struct Row: Decodable, Sendable {
        var seq: Int64
        var device: UUID?
        var url: String?
        /// The server's own `visited_at` — what its filters read.
        var stamp: String?
        /// The payload's, as a fallback: RFC 3339, or Unix seconds.
        var payloadStamp: String?
        var payloadSeconds: Double?

        private enum Keys: String, CodingKey { case seq, device_id, visited_at, payload }
        private enum PayloadKeys: String, CodingKey { case url, visited_at }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            seq = try c.decode(Int64.self, forKey: .seq)
            device = try? c.decode(UUID.self, forKey: .device_id)
            stamp = try? c.decode(String.self, forKey: .visited_at)
            let payload = try? c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            url = try? payload?.decode(String.self, forKey: .url)
            payloadStamp = try? payload?.decode(String.self, forKey: .visited_at)
            payloadSeconds = try? payload?.decode(Double.self, forKey: .visited_at)
        }

        func at(_ clock: Clock) -> Date? {
            stamp.flatMap(clock.date) ?? payloadStamp.flatMap(clock.date)
                ?? payloadSeconds.map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
        }
    }

    /// Reads RFC 3339 like `CloudSync.date`, with formatters made once per
    /// delete rather than once per row: making one costs far more than using
    /// it, and a site delete may read hundreds of thousands of rows.
    final class Clock: @unchecked Sendable {
        // Used by one scan, on one task at a time.
        private let fractional = ISO8601DateFormatter()
        private let whole = ISO8601DateFormatter()

        init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            whole.formatOptions = [.withInternetDateTime]
        }

        func date(_ text: String) -> Date? { fractional.date(from: text) ?? whole.date(from: text) }
    }

    struct Page: Decodable, Sendable {
        var entries: [Row]
        var next: Int64
        var more: Bool?
    }

    /// Whether a place, visited at `at` from `device`, is one `selector`
    /// names. Decided here, never by the server; the time is only read when
    /// there is a window.
    static func covers(_ selector: Selector, url raw: String?, at time: @autoclosure () -> Date?, device: UUID?) -> Bool {
        if let wanted = selector.device, device != wanted { return false }
        if selector.since != nil || selector.until != nil {
            // No time it can read: in no window.
            guard let at = time() else { return false }
            if let since = selector.since, at < since { return false }
            if let until = selector.until, at >= until { return false }
        }
        guard selector.scans else { return true }
        guard let raw, let url = URL(string: raw), let host = url.host() else { return false }
        let here = bare(host)
        if selector.hosts.contains(where: { within(here, $0) }) { return true }
        return !selector.pages.isEmpty && selector.pages.contains(CloudApply.historyKey(url))
    }

    /// `host` is `site` or one of its subdomains — `www.x.com` is in `x.com`,
    /// `notx.com` and `x.com.evil.org` are not.
    static func within(_ host: String, _ site: String) -> Bool {
        host == site || host.hasSuffix("." + site)
    }

    private static func bare(_ host: String) -> String {
        var out = host.lowercased()
        while out.hasSuffix(".") { out.removeLast() }
        return out
    }

    /// A site as typed — `x.com`, `https://www.x.com/a`, `X.COM.`, `*.x.com` —
    /// as `Selector.hosts` keeps it: lower case, no `www.`, no trailing dot.
    /// Nil for what isn't one.
    static func site(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("*.") { text.removeFirst(2) }
        guard !text.isEmpty, !text.contains(" "),
              let host = URL(string: text.contains("://") ? text : "https://" + text)?.host() else { return nil }
        var site = bare(host)
        if site.hasPrefix("www.") { site.removeFirst(4) }
        guard site == "localhost" || (site.contains(".") && !site.hasPrefix(".") && !site.contains("..")) else { return nil }
        return site
    }

    /// `30m`, `1h`, `24h`, `7d`, `2w` before `now`, or an RFC 3339 time.
    static func time(_ text: String, now: Date) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let unit = text.last, let count = Double(text.dropLast()), count >= 0, count.isFinite {
            let seconds: Double
            switch unit {
            case "m": seconds = 60
            case "h": seconds = 3_600
            case "d": seconds = 86_400
            case "w": seconds = 604_800
            default: return CloudSync.date(text)
            }
            return now.addingTimeInterval(-count * seconds)
        }
        return CloudSync.date(text)
    }

    /// Paging through every row, oldest first, keeping the seqs that match.
    /// The network is the caller's: ask `next`, hand the answer to `take`.
    struct Scan {
        let selector: Selector
        let limit: Int
        private let clock = Clock()
        private(set) var since: Int64 = 0
        private(set) var pages = 0
        private(set) var looked = 0
        private(set) var seqs: [Int64] = []
        private(set) var finished = false
        /// Stopped at `limit` with history still unread.
        private(set) var cut = false

        init(_ selector: Selector, limit: Int = pageLimit) {
            self.selector = selector
            self.limit = limit
        }

        var next: Ask? { finished ? nil : CloudHistoryDelete.page(after: since) }

        mutating func take(_ page: Page) {
            pages += 1
            looked += page.entries.count
            for row in page.entries where CloudHistoryDelete.covers(selector, url: row.url, at: row.at(clock), device: row.device) {
                seqs.append(row.seq)
            }
            // A cursor that doesn't move would ask for the same page for ever.
            let moved = page.next > since
            since = max(since, page.next)
            if page.more != true || page.entries.isEmpty || !moved {
                finished = true
            } else if pages >= limit {
                finished = true
                cut = true
            }
        }
    }

    // MARK: - deleting

    struct Outcome: Equatable, Sendable {
        var deleted = 0
        /// Rows read here while looking (none for a window).
        var looked = 0
        var matched = 0
        var requests = 0
        /// Looked through here, rather than left to the server's filters.
        var scanned = false
        /// Looked through the first `pageLimit` pages only.
        var cut = false

        var json: [String: Any] {
            ["deleted": deleted, "looked": looked, "matched": matched, "requests": requests,
             "scanned": scanned, "complete": !cut]
        }
    }

    private struct Deleting: Sendable {
        var count = 0
        var requests = 0
        var failure: Error?
    }

    /// One delete, start to end, off the main actor. `ask` makes one request
    /// and returns the answer's bytes, throwing the server's refusal.
    static func run(_ selector: Selector, pageLimit: Int = pageLimit,
                    ask: @escaping @Sendable (Ask) async throws -> Data) async throws -> Outcome {
        guard selector.valid else {
            throw Cloud.Failure(status: 0, code: "bad_selector", message: "Say what to delete — a time, a site, a page, a device — or ask for everything")
        }
        var outcome = Outcome()
        guard selector.scans else {
            try Task.checkCancellation()
            outcome.deleted = deleted(in: try await ask(window(selector)))
            outcome.requests = 1
            return outcome
        }
        outcome.scanned = true
        var scan = Scan(selector, limit: pageLimit)
        while let next = scan.next {
            try Task.checkCancellation()
            let data: Data
            do {
                data = try await ask(next)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
            outcome.requests += 1
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else {
                throw Cloud.Failure(status: 200, code: "decode", message: "The cloud's history didn't read — nothing was deleted")
            }
            scan.take(page)
        }
        try Task.checkCancellation()
        outcome.looked = scan.looked
        outcome.matched = scan.seqs.count
        outcome.cut = scan.cut
        // From here it runs to the end, stopped or not (a task of its own
        // isn't cancelled with this one): cut off halfway, some would be
        // gone and the count unsaid.
        let found = scan.seqs
        let done = await Task {
            var done = Deleting()
            for group in batches(found) {
                do {
                    done.count += deleted(in: try await ask(seqs(group)))
                    done.requests += 1
                } catch {
                    done.failure = error
                    break
                }
            }
            return done
        }.value
        outcome.deleted = done.count
        outcome.requests += done.requests
        if let failure = done.failure {
            guard done.count > 0 else { throw failure }
            let why = (failure as? Cloud.Failure)?.message ?? failure.localizedDescription
            throw Cloud.Failure(status: 0, code: "partial", message: "Deleted \(done.count) visit\(done.count == 1 ? "" : "s"), then: \(why)")
        }
        return outcome
    }

    // MARK: - mirroring History here

    /// History cleared here (History.forget()): everything there.
    static let cleared = Selector(everything: true)

    /// A page forgotten in the History window: its rows there, every Mac's.
    static func forgot(_ key: String) -> Selector { Selector(pages: [key]) }

    // MARK: - not sending it back

    /// What became of History here.
    enum Here {
        /// Left as it was: a delete from Settings, the CLI or an agent.
        case kept
        /// Cleared, all of it.
        case cleared
        /// One page forgotten.
        case forgot
    }

    /// The push's cursor and `remote` (places on the server already, at
    /// their time) once a delete has gone through, so the next push sends
    /// back nothing it deleted. What went up is behind the cursor and is
    /// never offered again, whatever the delete; what follows is about the
    /// rest:
    ///   - kept: covered visits here not pushed yet join `remote`, so the
    ///     push passes over them, and the cursor with them;
    ///   - cleared: the cursor goes to now — a history.json not yet rewritten
    ///     can't send the old visits back — and `remote` goes with them;
    ///   - forgot: the page is gone here; `unforgotten` covers the file.
    static func push(after selector: Selector, here: Here, visits: [CloudHistory.Visit], through: Double?,
                     remote: [String: Double], device: UUID?, now: Double) -> (through: Double?, remote: [String: Double]) {
        switch here {
        case .kept:
            let held = held(visits, by: selector, after: min(through ?? 0, now), device: device)
            return (through, remote.merging(held) { _, ours in ours })
        case .cleared:
            return (max(through ?? 0, now), [:])
        case .forgot:
            return (through, remote)
        }
    }

    /// Visits on this Mac that a delete covers and that haven't gone up yet —
    /// newer than `through`, the push cursor — at their time. `device` is
    /// this Mac's: its visits go up as its rows.
    static func held(_ visits: [CloudHistory.Visit], by selector: Selector, after through: Double, device: UUID?) -> [String: Double] {
        var out: [String: Double] = [:]
        for visit in visits where visit.at > through
            && covers(selector, url: visit.url, at: Date(timeIntervalSince1970: visit.at), device: device) {
            out[visit.key] = visit.at
        }
        return out
    }

    /// Visits without the pages forgotten here this run (key → when), unless
    /// visited again since: history.json is rewritten a moment after a forget,
    /// and a push reading it before then mustn't send the page back.
    static func unforgotten(_ visits: [CloudHistory.Visit], _ forgotten: [String: Double]) -> [CloudHistory.Visit] {
        guard !forgotten.isEmpty else { return visits }
        return visits.filter { visit in forgotten[visit.key].map { visit.at > $0 } ?? true }
    }

    // MARK: - asked for in words

    /// What an agent or `copper cloud-history delete` asked for: `since`,
    /// `until` (`1h`, `7d`, RFC 3339), `host` and `page` (one or a list),
    /// `device` (an id, or `this` for `me`), `all`.
    static func selector(from args: [String: Any], now: Date, me: UUID?) throws -> Selector {
        func refuse(_ text: String) -> Cloud.Failure { Cloud.Failure(status: 0, code: "bad_selector", message: text) }
        func strings(_ key: String) -> [String] {
            if let one = args[key] as? String { return one.isEmpty ? [] : [one] }
            return (args[key] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
        var selector = Selector()
        for key in ["since", "until"] {
            guard let text = strings(key).first else { continue }
            guard let date = time(text, now: now) else { throw refuse("\(key): \(text) isn't a time — say 1h, 24h, 7d or an RFC 3339 time") }
            if key == "since" { selector.since = date } else { selector.until = date }
        }
        for typed in strings("host") {
            guard let site = site(typed) else { throw refuse("host: \(typed) isn't a site — say example.com") }
            if !selector.hosts.contains(site) { selector.hosts.append(site) }
        }
        for typed in strings("page") {
            guard let url = Address.url(from: typed), ["http", "https"].contains(url.scheme ?? ""), url.host() != nil else {
                throw refuse("page: \(typed) isn't a web address")
            }
            let key = CloudApply.historyKey(url)
            if !selector.pages.contains(key) { selector.pages.append(key) }
        }
        if let typed = strings("device").first {
            if typed.lowercased() == "this" {
                guard let me else { throw refuse("device: this Mac isn't signed in") }
                selector.device = me
            } else {
                guard let id = UUID(uuidString: typed) else { throw refuse("device: \(typed) isn't a device id") }
                selector.device = id
            }
        }
        selector.everything = (args["all"] as? Bool) == true
        if let since = selector.since, let until = selector.until, since >= until { throw refuse("since has to be before until") }
        if selector.everything && selector.narrowed { throw refuse("all deletes everything — leave out since, until, host, page and device, or leave out all") }
        guard selector.valid else { throw refuse("Say what to delete — since, until, host, page or device — or all: true for everything") }
        return selector
    }

    /// The choice in a few words, for the log and an agent. A page is said by
    /// its site only: an address can carry a token.
    static func words(_ selector: Selector) -> String {
        guard !selector.everything else { return "all history" }
        var what: [String] = []
        if !selector.hosts.isEmpty { what.append("visits to " + selector.hosts.joined(separator: ", ")) }
        let pageSites = Set(selector.pages.map { String($0.prefix { $0 != "/" }) })
        if let site = pageSites.first {
            let on = pageSites.count == 1 ? " on \(site)" : ""
            what.append(selector.pages.count == 1 ? "a page\(on)" : "\(selector.pages.count) pages\(on)")
        }
        var parts = [what.isEmpty ? "visits" : what.joined(separator: " and ")]
        let shown: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
        switch (selector.since, selector.until) {
        case let (since?, until?): parts.append("between \(shown(since)) and \(shown(until))")
        case let (since?, nil): parts.append("since \(shown(since))")
        case let (nil, until?): parts.append("before \(shown(until))")
        default: break
        }
        if let device = selector.device { parts.append("from device \(device.uuidString.prefix(8).lowercased())") }
        return parts.joined(separator: " ")
    }
}
