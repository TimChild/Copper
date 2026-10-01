import SwiftUI

// The pane beside the page while something other than you drives it: one
// run, read top to bottom, whoever the driver is — Jev on a goal, an agent
// on the loopback server calling tools one by one, a bot through a link,
// the agent in Copper's own pane.
//
// The shape is AgentPane's — header, hairline, scroll, hairline, footer, in
// the sidebar's palette — but nothing here is a conversation. It is a
// timeline: a numbered rail down the left, a row per thing the driver did,
// the time it took in monospace on the right. What it saw, what it chose,
// what the page did about it. Under the header, the latest thing the driver
// said about what it is doing, when it said anything. No JSON reaches this
// view; Drive has already put everything into the page's own words.

/// The one warm note in an otherwise grey pane: the live dot, the stop, the
/// ring around a page under control. Shared with the trail drawn in the page.
enum DriveStyle {
    static let accent = Color(red: 0.78, green: 0.45, blue: 0.24)
}

struct DrivePane: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var drive = Drive.shared
    /// Which cycles have had their candidate list opened.
    @State private var shown: Set<UUID> = []

    static let width: CGFloat = 360

    /// A duration as a person reads it: milliseconds until a second, then
    /// one decimal of seconds. No thousands separators anywhere.
    static func ms(_ n: Int) -> String {
        n < 1000 ? "\(n) ms" : String(format: "%.1f s", Double(n) / 1000)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if let thought = drive.run?.thought, !thought.isEmpty {
                saying(thought)
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            timeline
            Rectangle().fill(Palette.hairline).frame(height: 1)
            footer
        }
        .frame(width: DrivePane.width)
        .background(Palette.ground)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            Text(drive.run?.driver.name ?? "Driver").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            if let run = drive.run, !run.goal.isEmpty {
                Text(run.goal)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .help(run.goal)
            }
            Spacer(minLength: 6)
            elapsed
            // Real doors, not bare glyphs: a square each, washed under the
            // pointer (PaneDoor). "Close all" only shows beside a second pane.
            HStack(spacing: 2) {
                if drive.live {
                    PaneDoor(icon: "stop.fill", help: stopHelp, tint: DriveStyle.accent) { drive.stop() }
                }
                if several {
                    PaneDoor(icon: "xmark.square", help: "Close all panes (⌘⌥E)") { Panes.closeAll(in: browser) }
                }
                PaneDoor(icon: "xmark", help: "Close (⌘⌥J)") { close() }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    private var stopHelp: String {
        drive.run?.driver == .jev ? "Stop the run" : "Take the browser back — the agent's next calls are refused"
    }

    /// Whether another pane is open beside this one — read off the three
    /// objects so the header redraws as they change.
    @ObservedObject private var agent = Agent.shared
    @ObservedObject private var split = Split.shared
    private var several: Bool { (agent.open ? 1 : 0) + (split.on ? 1 : 0) > 0 }

    /// Ticking while the run is, still after it ends.
    @ViewBuilder
    private var elapsed: some View {
        if let run = drive.run {
            if drive.live {
                TimelineView(.periodic(from: run.started, by: 0.1)) { beat in
                    clockText(beat.date.timeIntervalSince(run.started))
                }
            } else {
                clockText((run.ended ?? Date()).timeIntervalSince(run.started))
            }
        }
    }

    private func clockText(_ seconds: TimeInterval) -> some View {
        Text(clock(seconds))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(drive.live ? Palette.ink : Palette.muted)
            .monospacedDigit()
    }

    /// m:ss.s — short enough to read at a glance, precise enough to watch.
    private func clock(_ seconds: TimeInterval) -> String {
        let t = max(seconds, 0)
        let whole = Int(t)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((t - Double(whole)) * 10))
    }

    // MARK: - what the driver said

    /// The latest reason the driver gave, in its own words: an agent's
    /// `reason` on a call, or what the model wrote before it acted. The one
    /// place in the pane that quotes the driver rather than the page.
    private func saying(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(DriveStyle.accent.opacity(drive.live ? 0.7 : 0.3)).frame(width: 2)
                .padding(.vertical, 1)
            Text(text)
                .font(.system(size: 12)).foregroundStyle(Palette.ink)
                .lineLimit(4).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // As tall as the words, no taller: the bar beside them would
        // otherwise take whatever height the column offers.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - body

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let run = drive.run {
                        ForEach(Array(run.cycles.enumerated()), id: \.element.id) { index, cycle in
                            if index > 0 {
                                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, 9)
                            }
                            cycleRows(cycle).id(cycle.id)
                        }
                        if drive.live, !drive.busy, run.driver != .jev {
                            thinking(after: run.cycles.isEmpty)
                        }
                    } else {
                        empty
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: progress) { _, _ in
                guard drive.live else { return }
                withAnimation(Motion.quick) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Every row the trace has drawn so far — enough of a number to know when
    /// something new landed, without making Cycle equatable.
    private var progress: Int {
        guard let run = drive.run else { return 0 }
        return run.cycles.reduce(run.cycles.count) { $0 + $1.phases.count + ($1.outcome == nil ? 0 : 1) }
            + (drive.busy ? 1 : 0)
    }

    private var empty: some View {
        Text("Nothing is driving this tab.")
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
    }

    /// Between an agent's calls: it has the page's answer and is deciding.
    /// Reads as a row without a number, so the rail stays honest.
    private func thinking(after first: Bool) -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 16)
            Ring(size: 9)
            Text("Thinking…").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        .padding(.top, first ? 0 : 9)
    }

    private func cycleRows(_ cycle: Drive.Cycle) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", cycle.number))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.faint)
                .frame(width: 16, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cycle.phases) { phase in phaseRow(phase) }
                if let outcome = cycle.outcome {
                    outcomeRows(outcome, of: cycle)
                } else if rereading(cycle) {
                    Text("re-reading")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func phaseRow(_ phase: Drive.Phase) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The title says what is happening; the detail is a fragment and
                // gives way first when the pane is narrow.
                Text(phase.title).font(.system(size: 12)).foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                if let detail = phase.detail, !detail.isEmpty, !isCall {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if let ms = phase.ms {
                    Text(DrivePane.ms(ms))
                        .font(.system(size: 10.5, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(Palette.muted)
                } else {
                    Ring(size: 9)
                }
            }
            // An agent's reason for the call is a sentence, not a fragment:
            // it gets its own line under the title, wrapped, never cut to a word.
            if isCall, let detail = phase.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(3).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Rows of a tool call, as against a Jev cycle: one phase, the call.
    private var isCall: Bool { drive.run?.driver != .jev }

    /// What the cycle amounted to: the operation, the page's own name for the
    /// thing it touched, how sure Jev was, and what the page did about it.
    /// This is the answer of the cycle, so it carries a little more weight
    /// than the phases above it. DONE and BLOCKED have no target to name, so
    /// they read as a sentence instead. A failed call reads as its error.
    @ViewBuilder
    private func outcomeRows(_ outcome: Drive.Outcome, of cycle: Drive.Cycle) -> some View {
        let spoken = outcome.operation == "DONE" || outcome.operation == "BLOCKED"
        VStack(alignment: .leading, spacing: 5) {
            if let error = outcome.error, !error.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    chip(outcome.operation)
                    Text(firstLine(error))
                        .font(.system(size: 12)).foregroundStyle(Color.red.opacity(0.8))
                        .lineLimit(2).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(error)
                }
            } else if spoken {
                Text("Jev said \(outcome.operation) — \(percent(outcome.probability)) sure")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isCall {
                // A call's title already said what it did; the outcome row is
                // only the chip, what was typed, and whether the page moved.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    chip(outcome.operation)
                    if let text = outcome.text, !text.isEmpty {
                        Text("“\(text)”")
                            .font(.system(size: 12)).foregroundStyle(Palette.ink)
                            .lineLimit(1).truncationMode(.tail)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 6)
                    if let result = outcome.result {
                        // What the tool said it did leads; a long canvas
                        // name after it gives way first.
                        Text("→ \(result)")
                            .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                            .lineLimit(2).truncationMode(.tail)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(result)
                    } else if let changed = outcome.pageChanged {
                        Text(changed ? "→ page changed" : "→ no change")
                            .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                            .fixedSize()
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    chip(outcome.operation)
                    Text(target(outcome))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    tail(outcome)
                }
            }
            candidates(outcome, of: cycle)
        }
        .padding(.top, 2)
    }

    private func firstLine(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? text
    }

    /// A cycle that ended without an answer: Jev was asked, the page had
    /// moved on by the time it replied, and the loop went back to read it
    /// again. Without this the cycle just stops mid-sentence.
    private func rereading(_ cycle: Drive.Cycle) -> Bool {
        cycle.ended != nil
            && !cycle.phases.contains { $0.ended == nil }
            && cycle.phases.contains { $0.kind == .ask }
    }

    private func chip(_ operation: String) -> some View {
        Text(operation)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.25), lineWidth: 1)
            )
    }

    /// What became of the move. Nothing here ever truncates: a number no one
    /// can read is worse than a label cut short, so the label gives way
    /// first. When the page moved under the decision there is no probability
    /// to show — nothing was executed to be sure about.
    @ViewBuilder
    private func tail(_ outcome: Drive.Outcome) -> some View {
        if outcome.stale {
            Text("page moved · re-read")
                .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                .fixedSize()
        } else {
            HStack(spacing: 5) {
                Text(percent(outcome.probability))
                    .font(.system(size: 10.5, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(Palette.muted)
                if let changed = outcome.pageChanged {
                    Text(changed ? "→ page changed" : "→ no change")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
            }
            .fixedSize()
        }
    }

    private func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    private func target(_ outcome: Drive.Outcome) -> String {
        guard outcome.operation == "TYPE_TEXT", let text = outcome.text, !text.isEmpty else { return outcome.label }
        return "\(outcome.label) = \"\(text)\""
    }

    /// The other moves Jev was offered, folded away — interesting when a
    /// choice looks wrong, noise the rest of the time.
    @ViewBuilder
    private func candidates(_ outcome: Drive.Outcome, of cycle: Drive.Cycle) -> some View {
        if !outcome.candidates.isEmpty {
            let open = shown.contains(cycle.id)
            Button {
                withAnimation(Motion.quick) {
                    if open { shown.remove(cycle.id) } else { shown.insert(cycle.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("\(outcome.candidates.count) offered").font(.system(size: 10.5))
                }
                .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(outcome.candidates.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack(spacing: 7) {
            if drive.live { Circle().fill(DriveStyle.accent).frame(width: 5, height: 5) }
            Text(status).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if drive.refusingUntil != nil {
                Button { drive.resume() } label: {
                    Text("Let it back in").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("Accept the agent's calls again now")
            } else if !drive.live, drive.run != nil {
                Button { drive.dismiss() } label: {
                    Text("Clear").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("Put this run away")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private var status: String {
        guard let run = drive.run else { return "Idle" }
        let acted = run.cycles.filter { $0.outcome != nil }.count
        let word = run.driver == .jev ? "action" : "call"
        if run.status == .running {
            if run.driver != .jev {
                return drive.busy ? "Driving · \(acted) \(word)\(acted == 1 ? "" : "s")" : "Driving · thinking · \(acted) \(word)\(acted == 1 ? "" : "s")"
            }
            return "Running · \(acted) \(word)\(acted == 1 ? "" : "s")"
        }
        // The note is already a sentence; the head only says which kind of
        // ending it was. "Stopped by the user" says both, so it stands alone.
        func said(_ head: String) -> String { run.note.isEmpty ? head : "\(head) — \(run.note)" }
        switch run.status {
        case .running: return "Running"
        case .done: return said("Done")
        case .blocked: return said("Blocked")
        case .budget: return said("Budget")
        case .error: return said("Error")
        case .ended: return said("Let go")
        case .stopped: return run.note.isEmpty ? "Stopped by the user" : run.note
        }
    }

    /// The cross puts the pane away; when nothing is running it puts the run
    /// away with it, which is the same thing the footer's Clear does.
    private func close() {
        if drive.live { drive.paneOpen = false } else { drive.dismiss() }
    }
}

/// Over the page while a run is live: a word that it is not your hands on the
/// wheel — whose they are — and the one button that takes it back. Small
/// enough to ignore, close enough to hit. The dot is solid while a call is
/// in flight and breathes while the driver thinks between calls.
struct DrivePill: View {
    @ObservedObject private var drive = Drive.shared
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DriveStyle.accent)
                .frame(width: 6, height: 6)
                .opacity(drive.busy ? 1 : (breathing ? 0.35 : 1))
            Button { drive.paneOpen.toggle() } label: {
                Text("\(drive.run?.driver.name ?? "Agent") is driving")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Show what it is doing")
            Button { drive.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(DriveStyle.accent)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(drive.run?.driver == .jev ? "Stop the run" : "Take the browser back")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(Palette.ground.opacity(0.92), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}
