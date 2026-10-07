import Foundation

// The Move-in sheet's decisions, kept apart from AppKit and SwiftUI so each
// one can be tested on its own (Tests/SearchTests/FlowStateTests.swift).
//
// The sheet used to cycle in front of people: it was presented once per
// window, torn down and presented again whenever the page area behind it
// was rebuilt, and every presentation (and every return to the app, which a
// keychain prompt causes once per item) re-listed the sources and could
// start another scan. These rules make each of those things happen once:
// the sheet is presented by one owner (`FlowPresenter`), the source list is
// read when the sheet opens and only re-checked while a source is locked, a
// selection is never switched under the person, and a stale scan never lands.

/// What a Move-in source is called and whether it can be read. The pure
/// rules below see only this much of a `FlowSource`.
struct FlowCandidate: Equatable {
    var id: String
    var readable: Bool
}

enum FlowMachine {
    /// What the sheet should select, and what (if anything) it should read,
    /// after the list of sources was refreshed.
    struct Decision: Equatable {
        var selected: String?
        var scan: String?
        /// The preview on screen belongs to a source that can't be read any
        /// more (or is gone): back to the picker.
        var resetPreview = false
    }

    /// - Parameters:
    ///   - sources: the sources in the picker, in order.
    ///   - selected: the source selected before the refresh.
    ///   - previewed: the source whose counts are on screen (or being read).
    ///   - busy: a move is running — nothing changes under it.
    static func reconcile(sources: [FlowCandidate], selected: String?, previewed: String?, busy: Bool) -> Decision {
        if busy { return Decision(selected: selected, scan: nil) }
        let readable = sources.filter(\.readable)
        if let selected, readable.contains(where: { $0.id == selected }) {
            // Keep it. Read it only if what is on screen is someone else's.
            return Decision(selected: selected, scan: previewed == selected ? nil : selected)
        }
        // Nothing selected, or the selection went away / got locked. Pick
        // the only readable source; with two or more, the person chooses.
        let reset = previewed != nil && !readable.contains(where: { $0.id == previewed })
        if readable.count == 1, let only = readable.first {
            return Decision(selected: only.id, scan: previewed == only.id ? nil : only.id, resetPreview: reset)
        }
        return Decision(selected: nil, scan: nil, resetPreview: reset || (selected != nil && previewed != nil))
    }

    /// Whether a refresh that produced `new` changes anything the sheet draws.
    /// Equal lists are not republished, so an app activation that finds the
    /// same browsers does not redraw the sheet.
    static func changed(_ old: [FlowCandidate], _ new: [FlowCandidate]) -> Bool { old != new }

    /// Whether a source list needs re-checking when Copper becomes active
    /// again — only while the sheet is up and something is locked: the one
    /// thing the person may have just changed in System Settings.
    static func recheckOnActivation(sources: [FlowCandidate], open: Bool) -> Bool {
        open && sources.contains { !$0.readable }
    }
}

/// A scan ticket. A scan's result lands only if it is the newest ticket and
/// still for the selected source; a slower earlier read never overwrites a
/// later one, and a read for a source the person has left is dropped.
struct FlowScanTicket: Equatable {
    private(set) var generation = 0
    private(set) var source: String?

    mutating func issue(for source: String) -> Int {
        generation += 1
        self.source = source
        return generation
    }

    mutating func cancel() {
        generation += 1
        source = nil
    }

    func accepts(_ ticket: Int, for source: String, selected: String?) -> Bool {
        ticket == generation && self.source == source && selected == source
    }
}

/// The record of what the sheet did, for `bench flow events` and the
/// regression check: every open and close asked for, every present and
/// dismiss of the sheet, every refresh, scan and phase. Kept in memory, at
/// most `limit` entries.
struct FlowEvents {
    struct Entry: Equatable {
        var at: Double   // seconds of system uptime
        var kind: String
        var detail: String
    }

    static let limit = 400
    private(set) var entries: [Entry] = []

    mutating func record(_ kind: String, _ detail: String = "", at: Double) {
        entries.append(Entry(at: at, kind: kind, detail: detail))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    mutating func clear() { entries.removeAll() }

    func count(_ kind: String) -> Int { entries.filter { $0.kind == kind }.count }

    /// Presents minus dismisses never goes above one: one sheet at a time.
    var overlapping: Bool {
        var shown = 0
        for entry in entries {
            if entry.kind == "present" { shown += 1 }
            if entry.kind == "dismiss" { shown -= 1 }
            if shown > 1 { return true }
        }
        return false
    }

    /// The most scans started between one open and the next. A sheet that
    /// re-reads a browser behind the person's back shows up here.
    var scansPerOpen: Int {
        var most = 0
        var current = 0
        for entry in entries {
            if entry.kind == "open" { current = 0 }
            if entry.kind == "scan" { current += 1; most = max(most, current) }
        }
        return most
    }
}
