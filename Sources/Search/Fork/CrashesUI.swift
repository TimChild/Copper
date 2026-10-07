import AppKit
import SwiftUI

// Settings › About › Diagnostics: the last crash, in a line, with the report
// one click away. Nothing at all is drawn while there has never been one, and
// nothing is ever put in front of anyone at launch — a crash is looked up, not
// announced.

/// The index as the app last took it in (Crashes.launched), for the line.
@MainActor
final class CrashLog: ObservableObject {
    static let shared = CrashLog()

    /// The newest crash — a fault the app lived through doesn't count.
    @Published private(set) var latest: Crashes.Entry?
    /// Its number in `copper crashes`, and how many that lists.
    private(set) var position = 1
    private(set) var total = 0
    /// Crashes, faults left out.
    @Published private(set) var count = 0

    func adopt(_ index: Crashes.Index) {
        let first = index.entries.firstIndex { $0.fatal }
        latest = first.map { index.entries[$0] }
        position = (first ?? 0) + 1
        total = index.entries.count
        count = index.entries.filter(\.fatal).count
    }
}

struct CrashesSection: View {
    @ObservedObject private var log = CrashLog.shared
    @State private var copied = false

    var body: some View {
        if let crash = log.latest {
            SettingsSection("Diagnostics", note: "Crash reports stay on this Mac; nothing is sent. In Terminal, copper crashes lists every one.") {
                Line("Last crash: \(crash.time.formatted(.relative(presentation: .named))), \(crash.headline)", detail(crash)) {
                    HStack(spacing: 6) {
                        Pill("Reveal in Finder") { reveal(crash) }
                        Pill(copied ? "Copied" : "Copy Report") { copy(crash) }
                    }
                }
                .settingsAnchor("about.crash")
            }
        }
    }

    private func detail(_ crash: Crashes.Entry) -> String {
        let version = crash.version.map { "Version \($0)" } ?? "Version unknown"
        return log.count > 1 ? "\(version) · \(log.count) kept" : version
    }

    private func reveal(_ crash: Crashes.Entry) {
        let file = crash.file.map { Crashes.folder.appendingPathComponent($0) }
        if let file, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([Crashes.folder])
        }
    }

    /// The readable summary — how it ended, the frames, the breadcrumbs —
    /// with the full report's path in it, the same as `copper crashes show N`.
    private func copy(_ crash: Crashes.Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Crashes.text(crash, n: log.position, of: max(log.total, 1)), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
