import Combine
import Foundation

/// Watches Drive while one agent-link request (a `jev_run` or `jev_step`
/// tools/call) is being served, and hands `progress` frames to `post` — so
/// the owner's thread shows the run live and can stop it.
///
/// Only the run that belongs to this request is reported. Drive holds one
/// run at a time: the run is ours when it starts after the call did (a new
/// id), or — for a `jev_step` that continues a live session with the same
/// goal — the run already live when the call came in. Anything else (a run
/// the loopback started meanwhile) is ignored.
///
/// Pacing: at most one frame per 400 ms, except at once when a cycle opens,
/// when an outcome lands, and when the run finishes — that one carries
/// `final: true` and the finished trace. A frame waiting behind a slow post
/// is replaced by the newer one (seq still only rises), so a slow network
/// never builds a queue. `finish()` sends the final frame if the run did not
/// end during the call (a single `jev_step`) and waits until everything is
/// posted, so the reply always comes after the last progress.
@MainActor
final class JevProgressReporter {
    let requestId: String
    let tool: String
    static let interval: TimeInterval = 0.4

    private let post: ([String: Any]) async -> Void
    private let baseline: UUID?
    private(set) var runID: UUID?
    private var subscription: AnyCancellable?
    private var latest: Drive.Run?
    private var seq = 0
    private var lastSent = Date.distantPast
    private var lastCycles = 0
    private var lastOutcomes = 0
    private var trailing: Task<Void, Never>?
    private var queued: [String: Any]?
    private var pump: Task<Void, Never>?
    private var finalQueued = false
    private var finished = false
    private var cancelWanted = false

    init(requestId: String, tool: String, goal: String, post: @escaping ([String: Any]) async -> Void) {
        self.requestId = requestId
        self.tool = tool
        self.post = post
        let trace = Drive.shared
        baseline = trace.run?.id
        if tool == "jev_step", trace.live, let run = trace.run, run.goal == goal {
            runID = run.id // continuing the live session
        }
        // @Published emits in willSet with the new value, on the main actor
        // (every Drive write is main-actor), the current value first.
        subscription = trace.$run.sink { [weak self] run in
            MainActor.assumeIsolated { self?.observe(run) }
        }
    }

    /// The owner pressed Stop. Stops our run only; a stop that arrives
    /// before the run has begun is kept until it does.
    func cancel() {
        if let runID {
            if Drive.shared.run?.id == runID { Drive.shared.stop() }
        } else {
            cancelWanted = true
        }
    }

    /// The call returned: the last frame (if not already sent), then wait
    /// for the posts to drain.
    func finish() async {
        guard !finished else { return }
        finished = true
        subscription?.cancel()
        subscription = nil
        trailing?.cancel()
        trailing = nil
        if runID != nil, !finalQueued {
            if let run = Drive.shared.run, run.id == runID { latest = run }
            emit(final: true)
        }
        await pump?.value
    }

    private func observe(_ run: Drive.Run?) {
        guard !finished, let run else { return }
        if runID == nil {
            guard run.id != baseline else { return }
            runID = run.id
            if cancelWanted {
                // Not from inside begin()'s own write: stop() needs the run
                // live, and begin() clears a stop made before it finished.
                Task { @MainActor in
                    if Drive.shared.run?.id == run.id { Drive.shared.stop() }
                }
            }
        }
        guard run.id == runID, !finalQueued else { return }
        latest = run
        if run.status != .running {
            emit(final: true)
            return
        }
        let outcomes = run.cycles.reduce(0) { $0 + ($1.outcome == nil ? 0 : 1) }
        let urgent = run.cycles.count > lastCycles || outcomes > lastOutcomes
        let since = Date().timeIntervalSince(lastSent)
        if urgent || since >= Self.interval {
            emit(final: false)
        } else if trailing == nil {
            let wait = Self.interval - since
            trailing = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(wait * 1000) + 1))
                guard let self, !Task.isCancelled else { return }
                self.trailing = nil
                if !self.finalQueued, !self.finished { self.emit(final: false) }
            }
        }
    }

    private func emit(final: Bool) {
        guard let run = latest, !finalQueued else { return }
        trailing?.cancel()
        trailing = nil
        lastSent = Date()
        lastCycles = run.cycles.count
        lastOutcomes = run.cycles.reduce(0) { $0 + ($1.outcome == nil ? 0 : 1) }
        let frame = LinkWire.progress(requestId: requestId, seq: seq, at: Date(), tool: tool,
                                      progress: JevProgress.build(run), final: final)
        seq += 1
        if final { finalQueued = true }
        queued = frame
        if pump == nil {
            pump = Task { @MainActor [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while let next = queued {
            queued = nil
            await post(next)
        }
        pump = nil
    }
}
