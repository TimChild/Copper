import Foundation

/// What a Jev run looks like from the outside: one Run, a list of Cycles,
/// each Cycle a few timed Phases and an Outcome. Wording is for people.
///
/// The loop in Ultrafast.swift writes here as it goes — a phase opens when
/// the work starts and closes when it returns, so every row carries a real
/// duration. Nothing the model said in JSON reaches this model: operations,
/// labels and candidate lines are the page's own words. The pane beside the
/// page (JevPane) and the control pill only read it, and `stop()` is the one
/// thing that travels the other way: the Session checks `stopRequested`
/// before its next action and ends the run as "stopped".
@MainActor
final class JevTrace: ObservableObject {
    static let shared = JevTrace()

    /// The live run, or the last one until a new one starts or `dismiss()`.
    @Published private(set) var run: Run?
    /// True from `begin` until `finish`.
    @Published private(set) var live = false
    /// The pane beside the page. Set true by `begin`; the user may close it.
    @Published var paneOpen = false
    /// Set by `stop()`; Session reads it and ends with status "stopped".
    @Published private(set) var stopRequested = false

    struct Run: Identifiable {
        let id: UUID
        let goal: String
        let tabID: UUID
        let started: Date
        var ended: Date?
        var status: Status
        var note: String
        var cycles: [Cycle]
        var url: String               // last seen
        var title: String             // last seen
    }

    enum Status: String { case running, done, blocked, budget, error, stopped }

    struct Cycle: Identifiable {
        let id: UUID
        let number: Int               // 1-based
        let started: Date
        var phases: [Phase]
        var outcome: Outcome?
        var ended: Date?
    }

    struct Phase: Identifiable {
        let id: UUID
        let kind: Kind
        var title: String             // "Reading the page"
        var detail: String?           // "38 controls · Google Flights"
        let started: Date
        var ended: Date?
        var ms: Int? { ended.map { Int($0.timeIntervalSince(started) * 1000) } }
        enum Kind: String { case observe, ask, write, act, settle }
    }

    struct Outcome {
        var operation: String         // CLICK / TYPE_TEXT / SELECT / SCROLL / WAIT / DONE / BLOCKED
        var label: String             // target label as the page names it
        var text: String?             // typed value if any
        var probability: Double       // 0…1
        var confidence: Double
        var pageChanged: Bool?        // nil until the settle read
        var stale: Bool               // the page moved under the decision; nothing executed
        var candidates: [String]      // up to 5 "[7] button Search" lines Jev was offered
    }

    // MARK: - lifecycle

    /// A fresh run. The pane opens itself; a stop asked for during the last
    /// one does not carry over.
    func begin(goal: String, tab: Tab) {
        run = Run(id: UUID(), goal: goal, tabID: tab.id, started: Date(), ended: nil,
                  status: .running, note: "", cycles: [], url: tab.address?.absoluteString ?? "", title: tab.title)
        stopRequested = false
        live = true
        paneOpen = true
    }

    /// Opens a cycle and returns its id.
    ///
    /// Not every cycle reaches an outcome: the page can move under the
    /// decision, or the budget can run out mid-read. The one before this
    /// ends here either way, so nothing is left spinning behind the new one.
    @discardableResult
    func cycle() -> UUID {
        let id = UUID()
        guard let run else { return id }
        if let last = run.cycles.indices.last, run.cycles[last].ended == nil {
            let now = Date()
            for p in run.cycles[last].phases.indices where run.cycles[last].phases[p].ended == nil {
                self.run?.cycles[last].phases[p].ended = now
            }
            self.run?.cycles[last].ended = now
        }
        self.run?.cycles.append(Cycle(id: id, number: run.cycles.count + 1, started: Date(), phases: [], outcome: nil, ended: nil))
        return id
    }

    /// Opens a phase in the current cycle and returns its id.
    @discardableResult
    func phase(_ kind: Phase.Kind, _ title: String, detail: String? = nil) -> UUID {
        let id = UUID()
        guard let run, !run.cycles.isEmpty else { return id }
        self.run?.cycles[run.cycles.count - 1].phases.append(
            Phase(id: id, kind: kind, title: title, detail: detail, started: Date(), ended: nil))
        return id
    }

    /// Closes a phase; a detail given here replaces the one it opened with.
    func close(phase id: UUID, detail: String? = nil) {
        guard let run else { return }
        for c in run.cycles.indices.reversed() {
            guard let p = run.cycles[c].phases.lastIndex(where: { $0.id == id }) else { continue }
            self.run?.cycles[c].phases[p].ended = Date()
            if let detail { self.run?.cycles[c].phases[p].detail = detail }
            return
        }
    }

    /// What the cycle amounted to. The cycle closes with it.
    func outcome(_ o: Outcome) {
        guard let run, !run.cycles.isEmpty else { return }
        let last = run.cycles.count - 1
        self.run?.cycles[last].outcome = o
        self.run?.cycles[last].ended = Date()
    }

    /// Where the page stands, as of the last read.
    func page(url: String, title: String) {
        guard run != nil else { return }
        run?.url = url
        run?.title = title
    }

    /// The end state. The pane stays open so the trace can be read after.
    func finish(_ status: Status, note: String) {
        guard let run else { live = false; return }
        // Whatever was still in flight ended here; nothing is left spinning.
        let now = Date()
        for c in run.cycles.indices {
            for p in run.cycles[c].phases.indices where run.cycles[c].phases[p].ended == nil {
                self.run?.cycles[c].phases[p].ended = now
            }
            if run.cycles[c].ended == nil { self.run?.cycles[c].ended = now }
        }
        self.run?.ended = Date()
        self.run?.status = status
        self.run?.note = note
        live = false
        stopRequested = false
    }

    /// The hard stop: the loop ends before its next action.
    func stop() {
        guard live else { return }
        stopRequested = true
    }

    /// Put the last run away. Only when nothing is running.
    func dismiss() {
        guard !live else { return }
        run = nil
        paneOpen = false
    }
}
