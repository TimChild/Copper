import Foundation
import Testing
@testable import Search

// The crash-report reader, the breadcrumb trail and the died-without-quitting
// check (Fork/Crashes.swift, Fork/Breadcrumbs.swift). The fixture is the real
// report of the 2026-10-06 crash, trimmed to the crashed thread and the images
// it names, with identifiers and paths scrubbed.

private func fixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Copper-2026-10-06-231345", withExtension: "ips", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// A folder of its own per test, gone when the test is.
private final class Scratch {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("copper-crashes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Where the fixture's Copper ran from.
private let installed = "/Applications/Copper.app/Contents/MacOS/Copper"

private func utc(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text) ?? .distantPast
}

/// A trail line as Breadcrumbs writes it, at a chosen time and pid.
private func line(_ event: String, _ time: String, pid: Int32, _ fields: [(String, String)] = []) -> String {
    Breadcrumbs.format(event, fields, at: utc(time), pid: pid)
}

private func writeTrail(_ lines: [String], in data: URL) throws {
    let logs = data.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: logs.appendingPathComponent("trail.log"))
}

@Suite struct ReportParsing {
    @Test func readsTheRealReportShape() throws {
        let entry = try #require(Crashes.parse(report: fixture(), name: "Copper-2026-10-06-231345.ips", modified: Date()))
        #expect(entry.kind == .report)
        #expect(entry.version == "1.0.20261007.31")
        #expect(entry.build == "202610070207")
        #expect(entry.os == "macOS 27.0 (26A428)")
        #expect(entry.pid == 5511)
        #expect(entry.exception == "EXC_BREAKPOINT")
        #expect(entry.signal == "SIGTRAP")
        #expect(entry.codes?.contains("0x0000000000000001") == true)
        #expect(entry.termination?.contains("Trace/BPT trap: 5") == true)
        #expect(entry.headline == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(entry.thread == "1 · com.apple.root.user-initiated-qos.cooperative")
        // captureTime, not the header's rounded timestamp.
        #expect(abs(entry.time.timeIntervalSince(utc("2026-10-07T04:13:43Z")) - 0.8544) < 0.001)
        #expect(abs((entry.launched ?? .distantPast).timeIntervalSince(utc("2026-10-07T02:35:22Z")) - 0.0668) < 0.001)

        let frames = try #require(entry.frames)
        #expect(frames.count == 12)
        #expect(frames[0].image == "libdispatch.dylib")
        #expect(frames[0].symbol == "_dispatch_assert_queue_fail")
        #expect(frames[5].image == "WebKit" && frames[5].symbol == nil && frames[5].offset == 20_572_300)

        let binary = try #require(entry.binary)
        #expect(binary.uuid == "d49a7245-c237-36a4-a379-f31aa7241115")
        let top = try #require(entry.topFrame)
        #expect(top.image == "Copper" && top.symbol == nil && top.offset == 7_565_752)
        #expect(top.address == binary.base + 7_565_752)
        #expect(top.text == "Copper + 7565752")
    }

    @Test func anotherAppsReportIsNotOurs() throws {
        let text = String(decoding: try fixture(), as: UTF8.self).replacingOccurrences(of: "\"app_name\":\"Copper\"", with: "\"app_name\":\"Safari\"")
        #expect(Crashes.parse(report: Data(text.utf8), name: "Safari-2026-10-06-231345.ips", modified: Date()) == nil)
        #expect(Crashes.isOurs("Copper-2026-10-06-231345.ips"))
        #expect(Crashes.isOurs("ExcUserFault_Copper-2026-10-06-113139.ips"))
        #expect(!Crashes.isOurs("CopperHelper-2026-10-06-231345.ips"))
        #expect(!Crashes.isOurs("Safari-2026-10-06-231345.ips"))
        #expect(!Crashes.isOurs("Copper-2026-10-06-231345.diag"))
    }

    @Test func onlyThisCopysReports() throws {
        let worktree = NSHomeDirectory() + "/src/copper-crash/build/Copper.app/Contents/MacOS/Copper"
        #expect(Crashes.sameApp(installed, as: installed))
        #expect(!Crashes.sameApp(installed, as: worktree))
        // macOS writes a path under the home folder with the middle hidden.
        #expect(Crashes.sameApp("/Users/USER/*/Copper.app/Contents/MacOS/Copper", as: worktree))
        #expect(!Crashes.sameApp("/Users/USER/*/Copper.app/Contents/MacOS/Copper", as: installed))
        #expect(Crashes.sameApp(nil, as: installed) && Crashes.sameApp(installed, as: nil))

        let entry = try #require(Crashes.parse(report: fixture(), name: "Copper-2026-10-06-231345.ips", modified: Date()))
        #expect(entry.path == installed)
        let scratch = try Scratch()
        let data = try scratch.folder("data"), reports = try scratch.folder("reports")
        try fixture().write(to: reports.appendingPathComponent("Copper-2026-10-06-231345.ips"))
        #expect(Crashes.ingest(data: data, from: reports, binary: worktree).entries.isEmpty)
    }

    @Test func aFaultIsKeptButNotACrash() throws {
        let entry = try #require(Crashes.parse(report: fixture(), name: "ExcUserFault_Copper-2026-10-06-231345.ips", modified: Date()))
        #expect(entry.kind == .fault)
        #expect(!entry.fatal)
    }

    @Test func aFormatItCantReadStillGetsAnEntry() throws {
        let modified = utc("2026-10-01T00:00:00Z")
        let header = String(decoding: try fixture(), as: UTF8.self).split(separator: "\n", maxSplits: 1)[0]
        let half = try #require(Crashes.parse(report: Data((header + "\n{ not json").utf8), name: "Copper-x.ips", modified: modified))
        #expect(half.version == "1.0.20261007.31")
        #expect(half.frames == nil && half.reason != nil)

        let old = try #require(Crashes.parse(report: Data("Process: Copper [123]\nPath: /x\n".utf8), name: "Copper-y.ips", modified: modified))
        #expect(old.time == modified && old.kind == .report && old.reason != nil)
    }

    @Test func readsUpstreamsExceptionLog() throws {
        let log = """
        2026-10-05 10:00:00 +0000 — NSInvalidArgumentException: -[NSNull length]: unrecognized selector sent to instance 0x1
        0   CoreFoundation                      0x000000018a1b2c3d __exceptionPreprocess + 176
        1   libobjc.A.dylib                     0x0000000189a1b2c3 objc_exception_throw + 60
        2   Copper                              0x0000000100123456 Copper + 1193046


        """
        let found = Crashes.parse(exceptionLog: log)
        #expect(found.count == 1)
        let entry = try #require(found.first?.0)
        #expect(entry.kind == .exception)
        #expect(entry.time == utc("2026-10-05T10:00:00Z"))
        #expect(entry.exception == "NSInvalidArgumentException")
        #expect(entry.reason == "-[NSNull length]: unrecognized selector sent to instance 0x1")
        #expect(entry.frames?.count == 3)
        #expect(entry.frames?[1].symbol == "objc_exception_throw" && entry.frames?[1].offset == 60)
        #expect(entry.frames?[2].image == "Copper" && entry.frames?[2].address == 0x1_0012_3456)
    }
}

@Suite struct Ingest {
    @Test func takesEachReportOnceWithItsBreadcrumbs() throws {
        let scratch = try Scratch()
        let data = try scratch.folder("data"), reports = try scratch.folder("reports")
        try fixture().write(to: reports.appendingPathComponent("Copper-2026-10-06-231345.ips"))
        try Data("{}\n{}".utf8).write(to: reports.appendingPathComponent("Safari-2026-10-06-231345.ips"))
        let before = [
            line("launch", "2026-10-07T02:35:22Z", pid: 5511, [("version", "1.0.20261007.31")]),
            line("tool", "2026-10-07T04:13:40Z", pid: 5511, [("name", "browser_perf_probe"), ("ms", "3012"), ("result", "ok")]),
        ]
        try writeTrail(before + [
            line("pulse", "2026-10-07T04:13:41Z", pid: 777),
            line("tool", "2026-10-07T04:14:30Z", pid: 5511, [("name", "browser_click")]),
        ], in: data)
        try Data("2026-09-30 10:00:00 +0000 — NSRangeException: index 3 beyond bounds\n0   Copper   0x0000000100000010 Copper + 16\n\n".utf8)
            .write(to: data.appendingPathComponent("crash.log"))

        let index = Crashes.ingest(data: data, from: reports, binary: installed)
        #expect(index.entries.count == 2)
        let report = try #require(index.entries.first)
        #expect(report.kind == .report && report.source == "Copper-2026-10-06-231345.ips")
        #expect(report.trail == before)
        let copy = data.appendingPathComponent("crashes/Copper-2026-10-06-231345.ips")
        #expect(FileManager.default.contentsEqual(atPath: copy.path, andPath: reports.appendingPathComponent("Copper-2026-10-06-231345.ips").path))
        #expect(index.entries[1].kind == .exception && index.entries[1].exception == "NSRangeException")
        // crash.log is folded in, not left as a second story.
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("crash.log").path))

        let again = Crashes.ingest(data: data, from: reports, binary: installed)
        #expect(again.entries.count == 2)
        #expect(Crashes.current(data: data).entries.map(\.id) == index.entries.map(\.id))
    }

    @Test func keepsTheNewestFifty() throws {
        let scratch = try Scratch()
        let data = try scratch.folder("data"), reports = try scratch.folder("reports")
        let text = String(decoding: try fixture(), as: UTF8.self)
        for n in 0..<(Crashes.keep + 2) {
            let day = String(format: "%02d", n / 24 + 1), hour = String(format: "%02d", n % 24)
            let report = text.replacingOccurrences(of: "\"captureTime\": \"2026-10-06 23:13:43.8544 -0500\"",
                                                   with: "\"captureTime\": \"2026-09-\(day) \(hour):00:00.0 -0500\"")
            try Data(report.utf8).write(to: reports.appendingPathComponent("Copper-2026-09-\(day)-\(hour)0000.ips"))
        }
        let index = Crashes.ingest(data: data, from: reports, binary: installed)
        #expect(index.entries.count == Crashes.keep)
        #expect(index.entries.first?.source == "Copper-2026-09-03-030000.ips")
        let kept = try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("crashes").path).filter { $0.hasSuffix(".ips") }
        #expect(kept.count == Crashes.keep)
        #expect(!kept.contains("Copper-2026-09-01-000000.ips"))
    }
}

@Suite struct Trail {
    @Test func rotatesKeepingOnePreviousFile() throws {
        let scratch = try Scratch()
        let folder = try scratch.folder("logs")
        let log = Breadcrumbs.Log(folder: folder, cap: 1_000)
        let lines = (0..<60).map { n in
            Breadcrumbs.format("tool", [("name", "browser_click"), ("n", String(n))], at: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)), pid: 42)
        }
        for line in lines { log.append(line) }

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["trail.log", "trail.previous.log"])
        for name in files {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int)
            #expect(size <= 1_000)
        }
        // Oldest first across both files, ending with the last line written;
        // what rotated out twice is gone.
        let read = Breadcrumbs.read(in: folder).map(\.line)
        #expect(read.last == lines.last)
        #expect(read == Array(lines.suffix(read.count)))
        #expect(read.count < lines.count)
    }

    @Test func linesCarryNoSpacesInValues() {
        let text = Breadcrumbs.format("webcontent-gone", [("host", "a b\nc")], at: Date(timeIntervalSince1970: 0), pid: 7)
        let crumb = Breadcrumbs.Crumb(text)
        #expect(crumb?.fields["host"] == "a_b_c")
        #expect(crumb?.pid == 7 && crumb?.event == "webcontent-gone")
    }
}

@Suite struct UncleanShutdown {
    private let earlier = [
        line("launch", "2026-10-07T01:00:00Z", pid: 100, [("version", "1.0.20261006.30")]),
        line("pulse", "2026-10-07T01:01:00Z", pid: 100),
        line("quit", "2026-10-07T01:02:00Z", pid: 100),
    ]

    @Test func aLaunchWithNoQuitAfterItIsARunThatDied() throws {
        let died = earlier + [
            line("launch", "2026-10-07T02:35:22Z", pid: 5511, [("version", "1.0.20261007.31"), ("build", "202610070207")]),
            line("tool", "2026-10-07T04:13:40Z", pid: 5511, [("name", "browser_evaluate")]),
        ]
        let run = try #require(Crashes.unclean(died.compactMap(Breadcrumbs.Crumb.init)))
        #expect(run.pid == 5511)
        #expect(run.version == "1.0.20261007.31" && run.build == "202610070207")
        #expect(run.launched == utc("2026-10-07T02:35:22Z"))
        #expect(run.last == utc("2026-10-07T04:13:40Z"))

        #expect(Crashes.unclean(earlier.compactMap(Breadcrumbs.Crumb.init)) == nil)
        #expect(Crashes.unclean([]) == nil)
    }

    @Test func itIsRecordedAndThenExplainedByItsReport() throws {
        let scratch = try Scratch()
        let data = try scratch.folder("data"), reports = try scratch.folder("reports")
        let lines = earlier + [
            line("launch", "2026-10-07T02:35:22Z", pid: 5511, [("version", "1.0.20261007.31")]),
            line("tool", "2026-10-07T04:13:40Z", pid: 5511, [("name", "browser_evaluate")]),
        ]
        try writeTrail(lines, in: data)
        let run = try #require(Crashes.unclean(lines.compactMap(Breadcrumbs.Crumb.init)))

        // No report yet (jetsam, kill -9, or ReportCrash still writing).
        let first = Crashes.ingest(data: data, from: reports, previous: run, binary: installed)
        #expect(first.entries.count == 1)
        let unclean = try #require(first.entries.first)
        #expect(unclean.kind == .unclean && unclean.pid == 5511 && unclean.version == "1.0.20261007.31")
        #expect(unclean.headline == "quit unexpectedly, no report")
        #expect(unclean.trail == Array(lines.suffix(2)))
        // The same run again (a second ingest that's told of it) is not a second entry.
        #expect(Crashes.ingest(data: data, from: reports, previous: run, binary: installed).entries.count == 1)

        // Its report turns up: it takes the entry's place.
        try fixture().write(to: reports.appendingPathComponent("Copper-2026-10-06-231345.ips"))
        let second = Crashes.ingest(data: data, from: reports, binary: installed)
        #expect(second.entries.count == 1)
        #expect(second.entries.first?.kind == .report)
        #expect(second.entries.first?.trail == Array(lines.suffix(2)))
    }

    @Test func aReportAlreadyThereMeansNoUncleanEntry() throws {
        let scratch = try Scratch()
        let data = try scratch.folder("data"), reports = try scratch.folder("reports")
        try fixture().write(to: reports.appendingPathComponent("Copper-2026-10-06-231345.ips"))
        let run = Crashes.Run(pid: 5511, launched: utc("2026-10-07T02:35:22Z"), last: utc("2026-10-07T04:13:40Z"))
        let index = Crashes.ingest(data: data, from: reports, previous: run, binary: installed)
        #expect(index.entries.map(\.kind) == [.report])
    }
}

@Suite struct Reading {
    /// Only the refusals that come before anything is read: the rest of
    /// `copper crashes` takes reports into the real data folder.
    @Test func cliRefusesBadArgumentsWithUsageExit() {
        #expect(Crashes.cli(["help"], json: false) == 0)
        #expect(Crashes.cli(["frobnicate"], json: false) == 2)
        #expect(Crashes.cli(["list", "extra"], json: false) == 2)
        #expect(Crashes.cli(["show", "1", "2"], json: false) == 2)
    }

    @Test func withoutADSYMItSaysWhichAssetAndWhere() throws {
        let scratch = try Scratch()
        let entry = try #require(Crashes.parse(report: fixture(), name: "Copper-2026-10-06-231345.ips", modified: Date()))
        #expect(Crashes.isRelease("1.0.20261007.31") && !Crashes.isRelease("1.0"))
        let said = Crashes.symbolicated(entry, data: scratch.root)
        #expect(said.contains("No dSYM with UUID d49a7245-c237-36a4-a379-f31aa7241115"))
        #expect(said.contains("https://github.com/copper-browser/Copper/releases/download/v1.0.20261007.31/copper-1.0.20261007.31-macos-arm64.dSYM.zip"))
        #expect(said.contains(scratch.root.appendingPathComponent("dsyms/1.0.20261007.31").path))
    }
}
