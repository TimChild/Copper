import AppKit
import Darwin
import Foundation

// Every crash, kept where it can be read.
//
// macOS writes a report for each crash to ~/Library/Logs/DiagnosticReports
// (Copper-<time>.ips; ExcUserFault_Copper-<time>.ips for a fault the app
// lived through) and nothing ever read them. At launch — off the main thread,
// a few seconds after the window — the ones newer than the last taken are
// copied into `crashes/` in the data folder and summed up in
// `crashes/crashes.json`: when, which version, the exception and signal, how
// it ended, the crashed thread's top frames as the report has them, and the
// breadcrumbs (Breadcrumbs.swift) of that run up to the moment it died.
//
// A run that left a launch line and no quit line in the trail died even when
// no report shows up (jetsam, kill -9, a power cut, a force-quit hang): it
// gets an entry of its own, replaced by its report if one arrives later.
// Upstream's uncaught-exception handler still writes `crash.log` (Links.swift);
// its entries are folded in here and the file removed, so there is one story.
//
// Nothing leaves the Mac. `copper crashes` reads this, `browser_crashes` hands
// it to an agent, and Settings › About shows the last one.

enum Crashes {
    /// The process name the reports are filed under.
    static let process = Fork.name
    /// The newest this many are kept; older ones and their files go.
    static let keep = 50
    /// Frames kept from the crashed thread.
    static let depth = 20

    static var folder: URL { Store.folder.appendingPathComponent("crashes", isDirectory: true) }

    static var reports: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }

    // MARK: - what is kept

    struct Frame: Codable, Equatable {
        var image: String
        /// As the report has it; nil in a stripped release build.
        var symbol: String?
        /// Into the symbol when there is one, into the image otherwise.
        var offset: Int
        /// Where it was in the process: the image's load address plus its offset.
        var address: UInt64?

        var text: String {
            if let symbol { return "\(symbol) + \(offset)" }
            return "\(image) + \(offset)"
        }
    }

    /// The app's own binary in that run, for atos.
    struct Binary: Codable, Equatable {
        var uuid: String
        var base: UInt64
        var arch: String?
    }

    struct Entry: Codable {
        enum Kind: String, Codable {
            /// A crash report from macOS.
            case report
            /// A fault the app lived through (ExcUserFault_…).
            case fault
            /// An uncaught Objective-C exception, from crash.log.
            case exception
            /// The trail says the run died; macOS left no report.
            case unclean
        }

        var id: String
        var kind: Kind
        var time: Date
        /// Its copy in `crashes/`, when there is one.
        var file: String?
        /// The name it had in DiagnosticReports.
        var source: String?
        var version: String?
        var build: String?
        var os: String?
        /// The executable that crashed, as macOS wrote it (home folders as `/Users/USER/*/…`).
        var path: String?
        var pid: Int?
        var launched: Date?
        var exception: String?
        var signal: String?
        var codes: String?
        var termination: String?
        var reason: String?
        var thread: String?
        var frames: [Frame]?
        var binary: Binary?
        var trail: [String]?

        init(id: String, kind: Kind, time: Date) {
            self.id = id
            self.kind = kind
            self.time = time
        }

        /// A crash, rather than a fault it survived.
        var fatal: Bool { kind != .fault }

        /// What happened, in a few words.
        var headline: String {
            switch kind {
            case .unclean: return "quit unexpectedly, no report"
            case .exception: return exception ?? "uncaught exception"
            case .report, .fault:
                guard let exception else { return reason.map { String($0.prefix(60)) } ?? "crash" }
                return signal.map { "\(exception) (\($0))" } ?? exception
            }
        }

        /// The first frame in Copper's own code: usually where to look.
        var topFrame: Frame? { frames?.first { $0.image == Crashes.process } }
    }

    struct Index: Codable {
        /// The newest report taken so far, by its file's date.
        var through: Date?
        var entries: [Entry] = []
    }

    // MARK: - launch

    /// From a real app launch (Bridge.runIfAsked), never the CLI's. The trail
    /// is read before this launch's line goes in, then the reports are taken
    /// a few seconds later: the window comes first, and ReportCrash gets time
    /// to finish writing when launchd restarts a crashed headless Copper.
    static func launched() {
        Breadcrumbs.launched { before in
            let previous = unclean(before)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                let index = ingest(previous: previous)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { CrashLog.shared.adopt(index) }
                }
            }
        }
    }

    // MARK: - taking reports in

    /// Takes in what is new and returns the index as it now stands. Safe to
    /// run from the app and the CLI at once (a lock on the folder) and to run
    /// twice (what is already in is skipped).
    @discardableResult
    static func ingest(data: URL = Store.folder, from reports: URL = Crashes.reports, previous: Run? = nil,
                       binary: String? = Bundle.main.executablePath) -> Index {
        let folder = data.appendingPathComponent("crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return locked(folder) {
            var index = load(folder)
            let crumbs = Breadcrumbs.read(in: data.appendingPathComponent("logs", isDirectory: true))
            takeReports(from: reports, into: folder, &index, crumbs: crumbs, binary: binary)
            foldExceptions(data.appendingPathComponent("crash.log"), into: folder, &index, crumbs: crumbs)
            if let previous { note(previous, in: &index, crumbs: crumbs) }
            trim(&index, in: folder)
            save(index, in: folder)
            return index
        }
    }

    private static func takeReports(from reports: URL, into folder: URL, _ index: inout Index, crumbs: [Breadcrumbs.Crumb], binary: String?) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: reports.path) else { return }
        let known = Set(index.entries.compactMap(\.source))
        let fresh: [(URL, Date)] = names.filter(isOurs).compactMap { name in
            let url = reports.appendingPathComponent(name)
            guard let modified = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
            return (url, modified)
        }
        .filter { url, modified in !known.contains(url.lastPathComponent) && index.through.map { modified >= $0 } ?? true }
        .sorted { $0.1 < $1.1 }

        for (url, modified) in fresh {
            let name = url.lastPathComponent
            index.through = max(index.through ?? modified, modified)
            guard let data = files.contents(atPath: url.path), var entry = parse(report: data, name: name, modified: modified),
                  sameApp(entry.path, as: binary) else { continue }
            let copy = folder.appendingPathComponent(name)
            if files.fileExists(atPath: copy.path) || (try? files.copyItem(at: url, to: copy)) != nil { entry.file = name }
            entry.trail = trail(crumbs, pid: entry.pid.map(Int32.init), until: entry.time)
            // A run already put down as died-without-a-report has its report now.
            if let i = index.entries.firstIndex(where: { $0.kind == .unclean && $0.pid == entry.pid && explains(entry, launched: $0.launched ?? $0.time) }) {
                if entry.trail?.isEmpty ?? true { entry.trail = index.entries[i].trail }
                index.entries.remove(at: i)
            }
            index.entries.append(entry)
        }
    }

    /// Copper's own: `Copper-…ips`, and the faults it survived.
    static func isOurs(_ name: String) -> Bool {
        name.hasSuffix(".ips") && (name.hasPrefix("\(process)-") || name.hasPrefix("ExcUserFault_\(process)-"))
    }

    /// This copy of Copper rather than another one: every worktree build is
    /// a process called Copper too, and the installed app's Settings should
    /// not report a development build's crash. macOS hides a path under the
    /// home folder (and in /tmp) as `/Users/USER/*/Copper.app/…`; such a
    /// path matches any copy in the same place with the same name. No path
    /// in the report, or none of our own to compare: taken.
    static func sameApp(_ crashed: String?, as binary: String?) -> Bool {
        guard let crashed, let binary else { return true }
        // /tmp is /private/tmp, and macOS writes the latter.
        var ours = [binary]
        if let real = realpath(binary, nil) {
            ours.append(String(cString: real))
            free(real)
        }
        guard let star = crashed.range(of: "/*/") else { return ours.contains(crashed) }
        var head = String(crashed[..<star.lowerBound])
        if head == "/Users/USER" { head = NSHomeDirectory() }
        let tail = String(crashed[star.upperBound...])
        return ours.contains { $0.hasPrefix(head + "/") && $0.hasSuffix("/" + tail) }
    }

    // MARK: - reading a report

    /// A `.ips` file: one line of JSON (the header), then one JSON document
    /// (the report). A report this can't read — an older or newer format —
    /// still gets a minimal entry and its file kept. Nil for another app's.
    static func parse(report data: Data, name: String, modified: Date) -> Entry? {
        let text = String(decoding: data, as: UTF8.self)
        let halves = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let header = halves.first.flatMap(object)
        let body = halves.count > 1 ? object(halves[1]) : nil
        let app = (header?["app_name"] as? String) ?? (header?["name"] as? String) ?? (body?["procName"] as? String)
        if let app, app != process { return nil }

        let stem = (name as NSString).deletingPathExtension
        var entry = Entry(id: (header?["incident_id"] as? String) ?? stem,
                          kind: name.hasPrefix("ExcUserFault_") ? .fault : .report,
                          time: (header?["timestamp"] as? String).flatMap(reportDate) ?? modified)
        entry.source = name
        entry.version = header?["app_version"] as? String
        entry.build = header?["build_version"] as? String
        entry.os = header?["os_version"] as? String
        guard let body else {
            entry.reason = header == nil ? "a report format this version doesn't read; the file is kept" : "the report's body didn't parse; the file is kept"
            return entry
        }

        if let time = (body["captureTime"] as? String).flatMap(reportDate) { entry.time = time }
        entry.launched = (body["procLaunch"] as? String).flatMap(reportDate)
        entry.path = body["procPath"] as? String
        entry.pid = (body["pid"] as? NSNumber)?.intValue
        if let bundle = body["bundleInfo"] as? [String: Any] {
            entry.version = (bundle["CFBundleShortVersionString"] as? String) ?? entry.version
            entry.build = (bundle["CFBundleVersion"] as? String) ?? entry.build
        }
        if let os = body["osVersion"] as? [String: Any], let train = os["train"] as? String {
            entry.os = (os["build"] as? String).map { "\(train) (\($0))" } ?? train
        }
        if let exception = body["exception"] as? [String: Any] {
            entry.exception = exception["type"] as? String
            entry.signal = exception["signal"] as? String
            let codes = [exception["codes"] as? String, exception["subtype"] as? String].compactMap { $0 }
            entry.codes = codes.isEmpty ? nil : codes.joined(separator: " · ")
        }
        if let end = body["termination"] as? [String: Any] {
            let parts: [String?] = [
                [end["namespace"] as? String, (end["code"] as? NSNumber)?.stringValue].compactMap { $0 }.joined(separator: " "),
                end["indicator"] as? String,
                (end["byProc"] as? String).map { "by \($0)" },
                (end["reasons"] as? [String])?.joined(separator: "; "),
            ]
            entry.termination = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        // Application-specific information: an abort's message, an uncaught
        // exception's name and reason.
        if let asi = body["asi"] as? [String: Any] {
            let said = asi.values.compactMap { $0 as? [String] }.flatMap { $0 }
            if !said.isEmpty { entry.reason = String(said.joined(separator: " ").prefix(600)) }
        }

        let images = body["usedImages"] as? [[String: Any]] ?? []
        if let main = images.first(where: { ($0["name"] as? String) == process }),
           let uuid = main["uuid"] as? String, let base = (main["base"] as? NSNumber)?.uint64Value {
            entry.binary = Binary(uuid: uuid, base: base, arch: main["arch"] as? String)
        }
        let threads = body["threads"] as? [[String: Any]] ?? []
        if let n = (body["faultingThread"] as? NSNumber)?.intValue, threads.indices.contains(n) {
            let thread = threads[n]
            entry.thread = ([String(n)] + [thread["queue"] as? String ?? thread["name"] as? String].compactMap { $0 }).joined(separator: " · ")
            let frames = thread["frames"] as? [[String: Any]] ?? []
            entry.frames = frames.prefix(depth).map { frame in
                let index = (frame["imageIndex"] as? NSNumber)?.intValue ?? -1
                let image = images.indices.contains(index) ? images[index] : [:]
                let offset = (frame["imageOffset"] as? NSNumber)?.uint64Value ?? 0
                let symbol = frame["symbol"] as? String
                return Frame(image: image["name"] as? String ?? "???",
                             symbol: symbol,
                             offset: symbol == nil ? Int(offset) : (frame["symbolLocation"] as? NSNumber)?.intValue ?? 0,
                             address: (image["base"] as? NSNumber).map { $0.uint64Value &+ offset })
            }
        }
        return entry
    }

    private static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "2026-10-06 23:13:43.8544 -0500": the fraction has as many digits as
    /// the writer felt like, so it is read apart from the rest.
    static func reportDate(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let clock = parts[1].split(separator: ".", maxSplits: 1)
        guard let whole = plainDate("\(parts[0]) \(clock[0]) \(parts[2])") else { return nil }
        let fraction = clock.count > 1 ? Double("0.\(clock[1])") ?? 0 : 0
        return whole.addingTimeInterval(fraction)
    }

    private static func plainDate(_ text: String) -> Date? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return format.date(from: text)
    }

    // MARK: - crash.log

    /// Upstream's handler writes "<date> — <name>: <reason>", the call stack,
    /// and a blank line, per exception. Each becomes an entry — or, when
    /// macOS also wrote a report for the abort that followed, part of that.
    private static func foldExceptions(_ log: URL, into folder: URL, _ index: inout Index, crumbs: [Breadcrumbs.Crumb]) {
        guard let data = FileManager.default.contents(atPath: log.path), !data.isEmpty else { return }
        for (var entry, raw) in parse(exceptionLog: String(decoding: data, as: UTF8.self)) {
            guard !index.entries.contains(where: { $0.id == entry.id }) else { continue }
            // The abort that follows an uncaught exception has its own report
            // from macOS; the exception is its reason, not a second crash.
            if let i = index.entries.firstIndex(where: { $0.kind == .report && abs($0.time.timeIntervalSince(entry.time)) < 30 }) {
                if index.entries[i].reason == nil { index.entries[i].reason = [entry.exception, entry.reason].compactMap { $0 }.joined(separator: ": ") }
                continue
            }
            let name = "\(entry.id).log"
            if (try? Data(raw.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)) != nil { entry.file = name }
            entry.trail = trail(crumbs, pid: nil, until: entry.time)
            index.entries.append(entry)
        }
        try? FileManager.default.removeItem(at: log)
    }

    static func parse(exceptionLog text: String) -> [(Entry, String)] {
        text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n").map(String.init)
            guard let first = lines.first, let dash = first.range(of: " — "),
                  let time = plainDate(String(first[..<dash.lowerBound])) else { return nil }
            let said = first[dash.upperBound...]
            let colon = said.range(of: ": ")
            var entry = Entry(id: "exception-\(Int(time.timeIntervalSince1970))", kind: .exception, time: time)
            entry.exception = colon.map { String(said[..<$0.lowerBound]) } ?? String(said)
            entry.reason = colon.map { String(said[$0.upperBound...].prefix(600)) }
            entry.frames = lines.dropFirst().prefix(depth).compactMap(symbolLine)
            return (entry, block + "\n")
        }
    }

    /// "3   Copper   0x0000000100a1b2c3 $s6Search…F + 52", as callStackSymbols writes it.
    private static func symbolLine(_ line: String) -> Frame? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, Int(parts[0]) != nil, parts[2].hasPrefix("0x") else { return nil }
        let rest = parts[3]
        let plus = rest.range(of: " + ", options: .backwards)
        return Frame(image: String(parts[1]),
                     symbol: plus.map { String(rest[..<$0.lowerBound]) } ?? String(rest),
                     offset: plus.flatMap { Int(rest[$0.upperBound...]) } ?? 0,
                     address: UInt64(parts[2].dropFirst(2), radix: 16))
    }

    // MARK: - runs that died

    /// A run, as the trail tells it.
    struct Run: Equatable {
        var pid: Int32
        var launched: Date?
        /// Its last line: the last sign of life.
        var last: Date
        var version: String?
        var build: String?
    }

    /// The run before this launch, when it never wrote its quit line. Only
    /// the last line matters — the launch line may have rotated away on a
    /// long run — and only before this launch's own line is in.
    static func unclean(_ crumbs: [Breadcrumbs.Crumb]) -> Run? {
        guard let last = crumbs.last, last.event != "quit" else { return nil }
        let launch = crumbs.last { $0.pid == last.pid && $0.event == "launch" }
        return Run(pid: last.pid, launched: launch?.time, last: last.time,
                   version: launch?.fields["version"], build: launch?.fields["build"])
    }

    /// A report from the same process, after it started.
    private static func explains(_ entry: Entry, launched: Date) -> Bool {
        entry.fatal && entry.time >= launched.addingTimeInterval(-5)
    }

    private static func note(_ run: Run, in index: inout Index, crumbs: [Breadcrumbs.Crumb]) {
        let started = run.launched ?? run.last
        // Already down, or explained by a report. (The index keeps whole
        // seconds, so "the same line" is within one.)
        guard !index.entries.contains(where: { entry in
            entry.pid == Int(run.pid) && (entry.kind == .unclean ? abs(entry.time.timeIntervalSince(run.last)) < 1 : explains(entry, launched: started))
        }) else { return }
        var entry = Entry(id: "unclean-\(run.pid)-\(Int(run.last.timeIntervalSince1970))", kind: .unclean, time: run.last)
        entry.pid = Int(run.pid)
        entry.launched = run.launched
        entry.version = run.version
        entry.build = run.build
        entry.reason = "The trail's last line is from \(when(run.last)) and there is no clean quit after it; macOS left no crash report — killed for memory, force-quit, kill -9 or the Mac lost power."
        entry.trail = trail(crumbs, pid: run.pid, until: run.last)
        index.entries.append(entry)
    }

    // MARK: - breadcrumbs for one crash

    /// That run's lines up to the moment, newest `keep` of them. With no pid
    /// (crash.log), the run is whichever wrote the last line before `time`.
    static func trail(_ crumbs: [Breadcrumbs.Crumb], pid: Int32?, until time: Date, keep: Int = 40) -> [String] {
        let limit = time.addingTimeInterval(2)
        guard let pid = pid ?? crumbs.last(where: { $0.time <= limit })?.pid else { return [] }
        var run: [Breadcrumbs.Crumb] = []
        for crumb in crumbs where crumb.pid == pid && crumb.time <= limit {
            // An earlier process that had the same pid is not this run.
            if crumb.event == "launch" { run.removeAll() }
            run.append(crumb)
        }
        return run.suffix(keep).map(\.line)
    }

    // MARK: - the index

    private static func load(_ folder: URL) -> Index {
        let file = folder.appendingPathComponent("crashes.json")
        guard let data = FileManager.default.contents(atPath: file.path) else { return Index() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(Index.self, from: data) else {
            Store.quarantine(file)
            return Index()
        }
        return index
    }

    /// Newest first, `keep` of them; the files of those let go are removed.
    private static func trim(_ index: inout Index, in folder: URL) {
        index.entries.sort { $0.time > $1.time }
        guard index.entries.count > keep else { return }
        let gone = index.entries[keep...].compactMap(\.file)
        index.entries.removeSubrange(keep...)
        let still = Set(index.entries.compactMap(\.file))
        for file in gone where !still.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }

    private static func save(_ index: Index, in folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: folder.appendingPathComponent("crashes.json"), options: .atomic)
    }

    /// The index as it is on disk, without taking anything in.
    static func current(data: URL = Store.folder) -> Index {
        load(data.appendingPathComponent("crashes", isDirectory: true))
    }

    /// One writer at a time: the app at launch and `copper crashes` may meet.
    private static func locked<T>(_ folder: URL, _ body: () -> T) -> T {
        let fd = open(folder.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return body()
    }

    /// A time the way the CLI shows it: the Mac's own clock.
    static func when(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format.string(from: date)
    }
}
