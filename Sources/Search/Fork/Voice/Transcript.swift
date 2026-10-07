// Fork (voice): the Listen transcript — finalized speech, in memory only.
//
// Listen (started only from the ⌘E agent pane) appends a segment here each
// time the speaker pauses; the pane's agent and, when the person allows it,
// agents on this Mac (MCP `voice_transcript`, `copper transcript`) read it.
// Partials never get here. Nothing here is written to disk, logged, or
// synced: quitting Copper, Forget, or a new chat drops it.

import Combine
import Foundation

/// One finalized stretch of speech.
struct TranscriptSegment: Equatable, Sendable {
    /// 1, 2, 3… across one transcript; pauses and resumes keep counting.
    let seq: Int
    /// Wall-clock start and end of the speech.
    let start: Date
    let end: Date
    let text: String
}

@MainActor
final class Transcript: ObservableObject {
    static let shared = Transcript()

    /// A new value each time a transcript begins; nil when there is none
    /// (never started, or forgotten). Readers use it to tell transcripts apart.
    @Published private(set) var id: String?
    @Published private(set) var segments: [TranscriptSegment] = []
    /// A Listen capture is running right now (false while paused or stopped).
    @Published private(set) var live = false
    @Published private(set) var startedAt: Date?

    /// The highest seq ever appended to this transcript (0 = none yet).
    private(set) var latestSeq = 0
    /// The lowest seq still held; anything older was dropped by the caps.
    var oldestSeq: Int { segments.first?.seq ?? latestSeq + 1 }

    /// Caps: the last hour, and 2 MB of text, whichever is smaller.
    static let maxAge: TimeInterval = 60 * 60
    static let maxBytes = 2_000_000

    private var bytes = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init() {}

    /// Starts a new, empty transcript, dropping the previous one.
    @discardableResult
    func begin(at date: Date = Date()) -> String {
        let fresh = UUID().uuidString.lowercased()
        id = fresh
        segments = []
        latestSeq = 0
        bytes = 0
        startedAt = date
        live = false
        wake()
        return fresh
    }

    /// Whether a Listen capture is running into this transcript.
    func setLive(_ on: Bool) {
        guard live != on else { return }
        live = on
        wake()
    }

    /// Appends one finalized segment; empty text and a missing transcript are ignored.
    @discardableResult
    func append(_ text: String, start: Date, end: Date) -> TranscriptSegment? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != nil, !clean.isEmpty else { return nil }
        latestSeq += 1
        let segment = TranscriptSegment(seq: latestSeq, start: start, end: end, text: clean)
        segments.append(segment)
        bytes += clean.utf8.count
        trim(now: end)
        wake()
        return segment
    }

    /// Drops the transcript entirely.
    func forget() {
        id = nil
        segments = []
        latestSeq = 0
        bytes = 0
        startedAt = nil
        live = false
        wake()
    }

    /// Segments with seq > `seq`, oldest first, at most `limit`. `gap` is true
    /// when some segments after `seq` were already dropped by the caps.
    func since(_ seq: Int, limit: Int = 100) -> (segments: [TranscriptSegment], gap: Bool) {
        let after = segments.drop { $0.seq <= seq }
        let gap = latestSeq > seq && seq + 1 < oldestSeq
        return (Array(after.prefix(max(0, limit))), gap)
    }

    /// Returns once a segment newer than `seq` exists, the transcript begins,
    /// is forgotten or goes live/not live, or `timeout` seconds pass — whichever
    /// comes first. Never throws; callers re-read with `since` afterwards.
    func wait(since seq: Int, timeout: TimeInterval) async {
        guard latestSeq <= seq, timeout > 0 else { return }
        let key = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[key] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resume(key)
            }
        }
    }

    private func resume(_ key: UUID) {
        waiters.removeValue(forKey: key)?.resume()
    }

    private func wake() {
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume() }
    }

    private func trim(now: Date) {
        while let first = segments.first,
              bytes > Self.maxBytes || now.timeIntervalSince(first.end) > Self.maxAge {
            bytes -= first.text.utf8.count
            segments.removeFirst()
        }
    }
}
