import SwiftUI

// The pane beside the page while Jev drives it: one run, read top to bottom.
//
// The shape is AgentPane's — header, hairline, scroll, hairline, footer, in
// the sidebar's palette — but nothing here is a conversation. It is a
// timeline: a numbered rail down the left, a row per thing the loop did, the
// time it took in monospace on the right. What Jev saw, what it chose, what
// the page did about it. No JSON reaches this view; JevTrace has already put
// everything into the page's own words, and the pane only reads it.

/// The one warm note in an otherwise grey pane: the live dot, the stop, the
/// ring around a page under control. Shared with the trail drawn in the page.
enum JevStyle {
    static let accent = Color(red: 0.78, green: 0.45, blue: 0.24)
}

struct JevPane: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var trace = JevTrace.shared
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
            timeline
            Rectangle().fill(Palette.hairline).frame(height: 1)
            footer
        }
        .frame(width: JevPane.width)
        .background(Palette.ground)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Jev").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
            if let run = trace.run {
                Text(run.goal)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .help(run.goal)
            }
            Spacer(minLength: 6)
            elapsed
            if trace.live {
                Button { trace.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(JevStyle.accent).help("Stop the run")
            }
            Button { close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Close")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    /// Ticking while the run is, still after it ends.
    @ViewBuilder
    private var elapsed: some View {
        if let run = trace.run {
            if trace.live {
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
            .foregroundStyle(trace.live ? Palette.ink : Palette.muted)
            .monospacedDigit()
    }

    /// m:ss.s — short enough to read at a glance, precise enough to watch.
    private func clock(_ seconds: TimeInterval) -> String {
        let t = max(seconds, 0)
        let whole = Int(t)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((t - Double(whole)) * 10))
    }

    // MARK: - body

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let run = trace.run {
                        ForEach(Array(run.cycles.enumerated()), id: \.element.id) { index, cycle in
                            if index > 0 {
                                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, 9)
                            }
                            cycleRows(cycle).id(cycle.id)
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
                guard trace.live else { return }
                withAnimation(Motion.quick) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Every row the trace has drawn so far — enough of a number to know when
    /// something new landed, without making Cycle equatable.
    private var progress: Int {
        guard let run = trace.run else { return 0 }
        return run.cycles.reduce(run.cycles.count) { $0 + $1.phases.count + ($1.outcome == nil ? 0 : 1) }
    }

    private var empty: some View {
        Text("Jev is not driving this tab.")
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
    }

    private func cycleRows(_ cycle: JevTrace.Cycle) -> some View {
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

    private func phaseRow(_ phase: JevTrace.Phase) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The title says what is happening; the detail is a fragment and
            // gives way first when the pane is narrow.
            Text(phase.title).font(.system(size: 12)).foregroundStyle(Palette.ink)
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            if let detail = phase.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if let ms = phase.ms {
                Text(JevPane.ms(ms))
                    .font(.system(size: 10.5, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(Palette.muted)
            } else {
                Ring(size: 9)
            }
        }
    }

    /// What the cycle amounted to: the operation, the page's own name for the
    /// thing it touched, how sure Jev was, and what the page did about it.
    /// This is the answer of the cycle, so it carries a little more weight
    /// than the phases above it. DONE and BLOCKED have no target to name, so
    /// they read as a sentence instead.
    @ViewBuilder
    private func outcomeRows(_ outcome: JevTrace.Outcome, of cycle: JevTrace.Cycle) -> some View {
        let spoken = outcome.operation == "DONE" || outcome.operation == "BLOCKED"
        VStack(alignment: .leading, spacing: 5) {
            if spoken {
                Text("Jev said \(outcome.operation) — \(percent(outcome.probability)) sure")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A cycle that ended without an answer: Jev was asked, the page had
    /// moved on by the time it replied, and the loop went back to read it
    /// again. Without this the cycle just stops mid-sentence.
    private func rereading(_ cycle: JevTrace.Cycle) -> Bool {
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
    private func tail(_ outcome: JevTrace.Outcome) -> some View {
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

    private func target(_ outcome: JevTrace.Outcome) -> String {
        guard outcome.operation == "TYPE_TEXT", let text = outcome.text, !text.isEmpty else { return outcome.label }
        return "\(outcome.label) = \"\(text)\""
    }

    /// The other moves Jev was offered, folded away — interesting when a
    /// choice looks wrong, noise the rest of the time.
    @ViewBuilder
    private func candidates(_ outcome: JevTrace.Outcome, of cycle: JevTrace.Cycle) -> some View {
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
            if trace.live { Circle().fill(JevStyle.accent).frame(width: 5, height: 5) }
            Text(status).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if !trace.live, trace.run != nil {
                Button { trace.dismiss() } label: {
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
        guard let run = trace.run else { return "Idle" }
        if run.status == .running {
            let acted = run.cycles.filter { $0.outcome != nil }.count
            return "Running · \(acted) action\(acted == 1 ? "" : "s")"
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
        case .stopped: return run.note.isEmpty ? "Stopped by the user" : run.note
        }
    }

    /// The cross puts the pane away; when nothing is running it puts the run
    /// away with it, which is the same thing the footer's Clear does.
    private func close() {
        if trace.live { trace.paneOpen = false } else { trace.dismiss() }
    }
}

/// Over the page while a run is live: a word that it is not your hands on the
/// wheel, and the one button that takes it back. Small enough to ignore,
/// close enough to hit.
struct JevPill: View {
    @ObservedObject private var trace = JevTrace.shared
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(JevStyle.accent)
                .frame(width: 6, height: 6)
                .opacity(breathing ? 0.35 : 1)
            Button { trace.paneOpen.toggle() } label: {
                Text("Jev is driving")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
            .help("Show what Jev is doing")
            Button { trace.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(JevStyle.accent)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop the run")
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
