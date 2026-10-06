import Foundation

// History going up — `POST /v1/sync/history`, from where the last push
// stopped (`SyncPrefs.pushedThrough`). Kept apart from CloudSync, and free of
// the network, so its rules can be checked against a pretend server
// (`bench cloud selftest`).
//
// A copper-cloud measures each entry as the JSON text it receives. Up to
// 0.4.0 it refuses the whole request (400) when one entry is over
// `max_history_entry_bytes`, isn't an object or has a `visited_at` it can't
// read, and when a request carries more than `max_history_batch` entries.
// Copper used to resend the same 500 visits after such a refusal, on every
// visit, for ever: nothing after the bad one ever went up. Now:
//
//   - the limits come from `GET /v1/info` (`Cloud.historyLimits`);
//   - each entry is encoded here, once, exactly as it is sent, and measured.
//     A title too long is shortened to fit; a place whose address alone is
//     too big is left out and said in the log — a cut address is another
//     place. `visited_at` is never a time the server can't read, nor one
//     still to come;
//   - a refused request is split until what is refused stands alone, and
//     that is skipped, said in the log, while the rest goes up. A server that
//     names the entry (`entry 3 …`) saves the splitting; one that names a
//     smaller limit (`exceeds N bytes`, `at most N entries`) or turns a body
//     away as too large (413) gets smaller requests from then on;
//   - eight refusals in a row with nothing taken between them is the server
//     refusing history, not an entry: nothing more is skipped, the push stops,
//     and CloudSync tries again later, waiting longer each time.
//
// The cursor only moves past visits that went up or were deliberately left
// out — never past one still to send, and never past now: a visit stamped in
// the future (a bad import, another Mac's clock) goes up with the time now
// and is remembered, so it isn't sent again and nothing visited before that
// moment comes is passed over.

enum CloudHistory {
    /// The most visits Copper sends in one request, whatever the server allows.
    static let most = 500
    /// Refusals in a row, with nothing accepted between them, that stop a push.
    static let brake = 8

    struct Limits: Equatable {
        /// `max_history_entry_bytes`: the most one entry's JSON may weigh.
        var entryBytes: Int
        /// `max_history_batch`, never more than `most`.
        var batch: Int
        /// One request's body at most, so it is sent well inside a request's
        /// 15 s on a slow line.
        var requestBytes: Int

        /// copper-cloud's own defaults, for a server that hasn't said.
        static let standard = Limits(entryBytes: 16_384, batch: most, requestBytes: 1 << 20)

        init(entryBytes: Int, batch: Int, requestBytes: Int) {
            self.entryBytes = entryBytes
            self.batch = batch
            self.requestBytes = requestBytes
        }

        /// `/v1/info`'s `limits`; the standard ones for what it doesn't say.
        init(info: [String: Any]?) {
            let limits = info?["limits"] as? [String: Any]
            func number(_ key: String) -> Int? {
                guard let value = (limits?[key] as? NSNumber)?.intValue, value > 0 else { return nil }
                return value
            }
            let standard = Limits.standard
            // copper-cloud allows nothing under 256 B; a smaller answer would
            // leave every place out.
            entryBytes = max(256, number("max_history_entry_bytes") ?? standard.entryBytes)
            let most = number("max_history_batch") ?? 2_000
            batch = min(CloudHistory.most, most)
            // The body copper-cloud reads at most (`history_body_limit`).
            requestBytes = max(entryBytes + 64, min(standard.requestBytes, most * (entryBytes + 8) + 1_024))
        }
    }

    /// A place as history.json has it, reduced to what goes up.
    struct Visit {
        var key: String
        var url: String
        var title: String
        /// The last visit, Unix seconds.
        var at: Double
    }

    /// One visit ready to go: its entry as it will be sent.
    struct Item {
        var visit: Visit
        /// `visited_at`: the visit's time, never later than now.
        var sentAt: Double
        var data: Data
        var shortened: Bool
    }

    /// A visit that doesn't go up, and why — for the log. Never the address
    /// itself: one this long usually carries a token.
    struct Skip: Equatable {
        var host: String
        var bytes: Int
        var why: String
    }

    /// What `item` makes of a visit.
    enum Fit {
        case fits(Item)
        case tooBig(Skip)
    }

    /// Each visit newer than the cursor, oldest first: to send, already on
    /// the server, or left out.
    enum Slot {
        case send(Item)
        case known
        case left(Skip)
    }

    /// The JSON of one entry — keys sorted, slashes as they are — so a
    /// request is the same bytes each time and an address weighs what it reads.
    struct Entry: Encodable {
        var url: String
        var title: String
        var visited_at: String
    }

    /// Writes entries, one for a whole push: an ISO 8601 formatter costs far
    /// more to make than to use (making one per visit held the main thread
    /// four seconds for a 20,000-place first push).
    final class Writer {
        private let encoder = JSONEncoder()
        private let stamps = ISO8601DateFormatter()

        init() {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            stamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }

        /// As `CloudSync.stamp`.
        func stamp(_ at: Double) -> String { stamps.string(from: Date(timeIntervalSince1970: at)) }

        func encode(_ entry: Entry) -> Data? { try? encoder.encode(entry) }
    }

    /// Chromium's epoch, 1601: no visit is older, and an import that says so
    /// is reading a broken clock.
    static let earliest: Double = -11_644_473_600

    static func host(_ url: String) -> String {
        URL(string: url)?.host() ?? String(url.prefix(40))
    }

    /// The entry for `visit`, its title shortened if that is what it takes to
    /// fit `limit`. A `Skip` when even the address alone is too big.
    static func item(_ visit: Visit, now: Double, limit: Int, writer: Writer = Writer()) -> Fit {
        let sentAt = min(max(visit.at, earliest), now)
        let stamp = writer.stamp(sentAt)
        func encode(_ title: String) -> Data? {
            writer.encode(Entry(url: visit.url, title: title, visited_at: stamp))
        }
        guard let full = encode(visit.title) else {
            return .tooBig(Skip(host: host(visit.url), bytes: 0, why: "couldn't be written as JSON"))
        }
        if full.count <= limit {
            return .fits(Item(visit: visit, sentAt: sentAt, data: full, shortened: false))
        }
        guard let bare = encode(""), bare.count <= limit else {
            return .tooBig(Skip(host: host(visit.url), bytes: full.count, why: "over the cloud's \(limit) bytes per visit"))
        }
        // The longest start of the title that fits with an ellipsis after it.
        let characters = Array(visit.title)
        var low = 0, high = characters.count - 1
        var best = (title: "", data: bare)
        while low <= high {
            let middle = (low + high) / 2
            let title = String(characters[..<middle]) + "…"
            if let data = encode(title), data.count <= limit {
                best = (title, data)
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        var shortened = visit
        shortened.title = best.title
        return .fits(Item(visit: shortened, sentAt: sentAt, data: best.data, shortened: true))
    }

    /// Every visit newer than `through`, oldest first (ties by key, so the
    /// order is the same each time). `known` is what is on the server
    /// already at that time — merged in from elsewhere, or sent before with
    /// the time clamped.
    static func plan(_ visits: [Visit], after through: Double, known: [String: Double], now: Double, limits: Limits) -> [(visit: Visit, slot: Slot)] {
        let writer = Writer()
        return visits
            .filter { $0.at > through }
            .sorted { $0.at == $1.at ? $0.key < $1.key : $0.at < $1.at }
            .map { visit -> (visit: Visit, slot: Slot) in
                if let theirs = known[visit.key], abs(theirs - visit.at) < 1 { return (visit, .known) }
                switch item(visit, now: now, limit: limits.entryBytes, writer: writer) {
                case .fits(let item): return (visit, .send(item))
                case .tooBig(let skip): return (visit, .left(skip))
                }
            }
    }

    /// `{"entries":[…]}` from entries already encoded: what was measured is
    /// what is sent.
    static func body(_ entries: [Data]) -> Data {
        var out = Data("{\"entries\":[".utf8)
        for (index, entry) in entries.enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            out.append(entry)
        }
        out.append(contentsOf: Array("]}".utf8))
        return out
    }

    /// A 0.5.0 server stores what it can and lists the entries it skipped:
    /// `{"rejected": [{"index", "reason", "message"}]}`.
    static func rejected(in answer: Data) -> [(index: Int, why: String)] {
        guard let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
              let list = object["rejected"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let index = (row["index"] as? NSNumber)?.intValue else { return nil }
            return (index, row["message"] as? String ?? row["reason"] as? String ?? "refused")
        }
    }

    /// A refusal of what was sent rather than of the asking: split, or skip.
    static func refuses(_ failure: Cloud.Failure) -> Bool {
        [400, 413, 422].contains(failure.status)
    }

    /// The number after `word` in a server message: `entry 3 …`, `at most 500`,
    /// `exceeds 16384 bytes`.
    static func number(after word: String, in text: String) -> Int? {
        guard let range = text.range(of: word) else { return nil }
        let digits = text[range.upperBound...].drop { $0 == " " }.prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    /// One push: hands out requests (`next`), is told how each went
    /// (`accepted`, `refused`), and says how far the cursor may go
    /// (`through`). No network here; CloudSync does the asking.
    final class Upload {
        private(set) var limits: Limits
        private let now: Double
        private let start: Double
        private var visits: [Visit]
        private var slots: [Slot]
        /// Dealt with: accepted, already known, or left out for good.
        private var done: [Bool]
        /// How many slots from the start are done.
        private var prefix = 0
        /// Requests still to make, as slot indexes, the first next.
        private var queue: [[Int]] = []
        /// The request handed out and not yet answered.
        private var asked: [Int]?
        /// Refused alone, waiting for something to be accepted after them
        /// before they count as skipped: a server refusing everything mustn't
        /// make history quietly vanish one visit at a time.
        private var held: [(index: Int, why: String)] = []
        private let writer = Writer()

        /// Visits that went up.
        private(set) var sent = 0
        /// Titles shortened to fit.
        private(set) var shortened = 0
        /// Visits left out or refused, in the order it happened.
        private(set) var skipped: [Skip] = []
        /// Requests made.
        private(set) var requests = 0

        init(_ plan: [(visit: Visit, slot: Slot)], limits: Limits, from through: Double, now: Double) {
            self.limits = limits
            self.now = now
            start = through
            visits = plan.map { $0.visit }
            slots = plan.map { $0.slot }
            done = slots.map { if case .send = $0 { return false } else { return true } }
            for slot in slots {
                if case .left(let skip) = slot { skipped.append(skip) }
                if case .send(let item) = slot, item.shortened { shortened += 1 }
            }
            queue = chunks(slots.indices.filter { !done[$0] })
            advance()
        }

        /// The entries of the next request, or nil when every visit is dealt with.
        func next() -> [Data]? {
            precondition(asked == nil, "answer the last request first")
            guard !queue.isEmpty else {
                // Refused at the very end, with fewer than `brake` of them: skipped.
                settleHeld()
                advance()
                return nil
            }
            let indexes = queue.removeFirst()
            asked = indexes
            requests += 1
            return indexes.compactMap { if case .send(let item) = slots[$0] { return item.data } else { return nil } }
        }

        /// 2xx. `rejected`: entries a newer server skipped while storing the rest.
        func accepted(rejected: [(index: Int, why: String)] = []) {
            guard let indexes = asked else { return }
            asked = nil
            let refusedHere = Set(rejected.map { $0.index })
            for (position, index) in indexes.enumerated() {
                done[index] = true
                if let why = rejected.first(where: { $0.index == position })?.why {
                    skipped.append(skip(index, why: "the cloud skipped it: \(why)"))
                }
            }
            sent += indexes.count - refusedHere.filter { $0 < indexes.count }.count
            settleHeld()
            advance()
        }

        /// A 400/413 for the last request (see `refuses`). Throws when it is
        /// the server refusing history rather than an entry.
        func refused(_ failure: Cloud.Failure) throws {
            guard let indexes = asked else { return }
            asked = nil
            let text = failure.message
            // 413: more than the server reads in one body. Requests half that
            // size from now on.
            if failure.status == 413, indexes.count > 1 {
                let size = indexes.reduce(14) { total, index in
                    if case .send(let item) = slots[index] { return total + item.data.count + 1 }
                    return total
                }
                limits.requestBytes = max(limits.entryBytes + 64, min(limits.requestBytes, size / 2))
                requeue(indexes)
                return
            }
            let named = CloudHistory.number(after: "entry ", in: text)
            // "at most 100 entries per request": smaller requests, nothing skipped.
            if named == nil, let most = CloudHistory.number(after: "at most ", in: text), most >= 1, most < indexes.count {
                limits.batch = min(limits.batch, most)
                requeue(indexes)
                return
            }
            if let position = named, position < indexes.count {
                // "entry 3 exceeds 4096 bytes": that limit from now on, every
                // entry measured against it again.
                if let size = CloudHistory.number(after: "exceeds ", in: text), size >= 64, size < limits.entryBytes {
                    limits.entryBytes = size
                    limits.requestBytes = max(limits.requestBytes, size + 64)
                    refit()
                    requeue(indexes)
                    return
                }
                // The server named it: skip that one, send the rest again.
                try hold(indexes[position], why: text)
                var rest = indexes
                rest.remove(at: position)
                if !rest.isEmpty { queue.insert(rest, at: 0) }
                return
            }
            if indexes.count == 1 {
                try hold(indexes[0], why: text)
                return
            }
            // Unnamed: halves, the older first, until the refused one stands alone.
            let middle = indexes.count / 2
            queue.insert(contentsOf: [Array(indexes[..<middle]), Array(indexes[middle...])], at: 0)
        }

        /// How far `pushedThrough` may go: past every visit dealt with from
        /// the start, never past one still to send — a later visit at the
        /// same instant keeps the cursor just short of it — and never past now.
        var through: Double {
            guard prefix > 0 else { return start }
            var through = max(start, min(visits[prefix - 1].at, now))
            if prefix < visits.count, visits[prefix].at <= through {
                through = max(start, visits[prefix].at.nextDown)
            }
            return through
        }

        /// Visits dealt with that are stamped later than now: the cursor
        /// stops at now, so they are remembered instead (`CloudSync.remote`).
        var ahead: [(key: String, at: Double)] {
            visits.indices.filter { done[$0] && visits[$0].at > now }.map { (visits[$0].key, visits[$0].at) }
        }

        // MARK: -

        private func skip(_ index: Int, why: String) -> Skip {
            let size: Int
            if case .send(let item) = slots[index] { size = item.data.count } else { size = 0 }
            return Skip(host: CloudHistory.host(visits[index].url), bytes: size, why: why)
        }

        private func hold(_ index: Int, why: String) throws {
            held.append((index, why))
            guard held.count < CloudHistory.brake else {
                throw Cloud.Failure(status: 400, code: "history_refused",
                                    message: "The cloud refused \(held.count) visits in a row (\(why)) — none skipped; will try again later")
            }
        }

        private func settleHeld() {
            for (index, why) in held {
                done[index] = true
                skipped.append(skip(index, why: "the cloud refused it: \(why)"))
            }
            held = []
        }

        private func advance() {
            while prefix < done.count, done[prefix] { prefix += 1 }
        }

        /// Everything not yet sent, in requests the limits allow, oldest first.
        private func requeue(_ indexes: [Int]) {
            let waiting = (indexes + queue.flatMap { $0 }).filter { !done[$0] }
            queue = chunks(waiting.sorted())
        }

        /// The entry limit went down: shorten or leave out what no longer fits.
        private func refit() {
            let holding = Set(held.map { $0.index })
            for index in slots.indices where !done[index] && !holding.contains(index) {
                guard case .send(let item) = slots[index], item.data.count > limits.entryBytes else { continue }
                switch CloudHistory.item(visits[index], now: now, limit: limits.entryBytes, writer: writer) {
                case .fits(let fitted):
                    if !item.shortened && fitted.shortened { shortened += 1 }
                    slots[index] = .send(fitted)
                case .tooBig(let skip):
                    slots[index] = .left(skip)
                    done[index] = true
                    skipped.append(skip)
                }
            }
            advance()
        }

        private func chunks(_ indexes: [Int]) -> [[Int]] {
            var out: [[Int]] = []
            var group: [Int] = []
            var bytes = 14
            for index in indexes {
                guard case .send(let item) = slots[index] else { continue }
                let size = item.data.count + 1
                if !group.isEmpty, group.count >= limits.batch || bytes + size > limits.requestBytes {
                    out.append(group)
                    group = []
                    bytes = 14
                }
                group.append(index)
                bytes += size
            }
            if !group.isEmpty { out.append(group) }
            return out
        }
    }
}
