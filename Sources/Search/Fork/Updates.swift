import AppKit
import Combine
import CryptoKit
import Foundation

/// Copper's own update path. This deliberately does not use Updater.swift:
/// that feed and its signature belong to Search, and a fork must never let an
/// upstream release replace the browser that is running here.
///
/// The shape is: everything that can fail happens *before* anyone is asked.
/// A check that finds a newer release downloads it from the internal feed,
/// checks the archive against the manifest's SHA-256, unpacks it, and checks
/// that the bundle is Copper, is that version, and carries a signature that
/// verifies. Only then does Settings say "ready" and offer Update — which
/// backs up the tab session, swaps the verified bundle in where this one
/// runs, and relaunches. Whatever fails, fails in a sentence in Settings ›
/// Updates and a toast, never as a quiet "Updated" that was not.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()

    struct Latest: Codable, Equatable {
        let version: String
        let releaseId: String
        let commit: String
        let publishedAt: String
        let sha256: String?
        let archiveUrl: String?
    }

    /// A release that has been downloaded, verified and unpacked, waiting for
    /// the swap. `path` is the bundle itself.
    struct Staged: Codable, Equatable {
        let version: String
        let path: String
        let sha256: String
        let at: Date
    }

    /// What the last update left behind, kept so Settings › Updates can say
    /// why an update did not land instead of a toast that is gone in two
    /// seconds. `detail` is the version on success, the reason otherwise.
    struct Outcome: Codable, Equatable {
        let ok: Bool
        let detail: String
        let at: Date
    }

    /// Written just before the swapped-in Copper is launched; the next process
    /// turns it into an Outcome by checking which version it is.
    struct Pending: Codable, Equatable {
        let version: String
        let from: String
        let at: Date
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let product: String
        let version: String
        let releaseId: String
        let commit: String
        let publishedAt: String
        let sha256: String?
        let archiveUrl: String?
    }

    private struct Saved: Codable {
        var checkedAt: Date?
        var lastSeenVersion: String?
        var announcedVersion: String?
        var readyAnnounced: String?
        var troubleAnnounced: String?
        var latest: Latest?
        var staged: Staged?
        var outcome: Outcome?
        var pending: Pending?
    }

    enum State: Equatable {
        case idle
        case upgrading
    }

    @Published private(set) var latest: Latest?
    @Published private(set) var checkedAt: Date?
    /// Why the last check did not get an answer. Offline is the usual reason.
    @Published private(set) var error: String?
    /// Why the last update could not start or finish here, in this process.
    @Published private(set) var problem: String?
    @Published private(set) var state: State = .idle
    @Published private(set) var checking = false
    @Published private(set) var downloading = false
    /// Why the download or the verification of the latest release failed.
    @Published private(set) var stageError: String?
    @Published private(set) var staged: Staged?
    @Published private(set) var outcome: Outcome?

    /// Bench can point this at a local HTTP server. The shipped value is the
    /// GitHub releases feed, not a user preference and not a command-line override.
    var manifestURL: URL = Updates.defaultManifestURL
    private nonisolated static let defaultManifestURL = URL(string: Setup.feed + "/copper-version.json")!
    /// Everything up to the swap: verify, back up, then stop and log what
    /// would have happened instead of replacing the bundle and quitting.
    var dryRun = false

    private weak var browser: Browser?
    private var timer: Timer?
    private var saved = Saved()

    var current: String { Fork.version }
    var available: Bool {
        guard let latest else { return false }
        return Self.compare(latest.version, current) > 0
    }

    /// The staged bundle is the latest release and is still where it was put.
    /// This is what puts the Update button on screen.
    var ready: Bool {
        guard available, let latest, let staged, staged.version == latest.version else { return false }
        return Self.bundleVersion(at: URL(fileURLWithPath: staged.path)) == staged.version
    }

    /// A Homebrew install is only a fact worth showing; the update itself no
    /// longer goes through brew. Both pieces of evidence are needed: a stray
    /// brew binary is not an install, and an abandoned Caskroom is not one
    /// either.
    var managedByBrew: Bool {
        let files = FileManager.default
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let brew = URL(fileURLWithPath: prefix).appendingPathComponent("bin/brew")
            let caskroom = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom/copper", isDirectory: true)
            if files.isExecutableFile(atPath: brew.path), files.fileExists(atPath: caskroom.path) { return true }
        }
        return false
    }

    /// The host releases come from, for the sentence under the card.
    var feedHost: String { manifestURL.host ?? Setup.feed }

    /// Where every step is written down, this process's and the bundle swap's.
    /// Settings offers to open it when an update did not finish.
    nonisolated static let log: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Copper/update.log")

    /// Downloads are unpacked here, one folder per version, and the bundle an
    /// update replaced is kept in `previous` until the next one is staged.
    nonisolated static var updatesFolder: URL { Store.file("updates") }
    nonisolated static var previousFolder: URL { updatesFolder.appendingPathComponent("previous", isDirectory: true) }

    private init() {
        load()
    }

    // MARK: - launch and checking

    /// Attach once the Browser exists. The five-second delay leaves session
    /// restoration and the first window draw alone; after that, a long-lived
    /// Copper checks every six hours without asking the user to remember.
    func start(for browser: Browser) {
        self.browser = browser
        settleAtLaunch()
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.check(force: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(force: false) }
        }
        timer?.tolerance = 15 * 60
    }

    /// `force` is the Settings/⌘K action. Automatic calls are ignored for six
    /// hours after the previous attempt, including a failed/offline attempt.
    /// A newer release is staged as soon as it is seen.
    func check(force: Bool = false) {
        guard !checking else { return }
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < 6 * 60 * 60 { return }
        checking = true
        let url = manifestURL
        Task { [weak self] in
            let result = await Self.fetch(url)
            guard let self else { return }
            let now = Date()
            checking = false
            checkedAt = now
            saved.checkedAt = now
            switch result {
            case .success(let found):
                latest = found
                error = nil
                saved.lastSeenVersion = found.version
                saved.latest = found
                persist()
                if available {
                    stage()
                } else {
                    discardStaged()
                }
            case .failure(let sentence):
                error = sentence
                persist()
            }
        }
    }

    private enum FetchResult {
        case success(Latest)
        case failure(String)
    }

    private nonisolated static func fetch(_ url: URL) async -> FetchResult {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failure("The update feed did not respond successfully.")
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schemaVersion == 1, manifest.product.lowercased() == "copper",
                  !manifest.version.isEmpty, !manifest.releaseId.isEmpty
            else { return .failure("The update feed was not a Copper release.") }
            return .success(Latest(version: manifest.version, releaseId: manifest.releaseId,
                                   commit: manifest.commit, publishedAt: manifest.publishedAt,
                                   sha256: manifest.sha256, archiveUrl: manifest.archiveUrl))
        } catch is URLError {
            return .failure("Couldn’t reach the Copper update feed.")
        } catch is DecodingError {
            return .failure("The Copper update feed could not be read.")
        } catch {
            return .failure("Couldn’t check for Copper updates.")
        }
    }

    // MARK: - staging: download, verify, unpack

    /// Get the latest release onto disk and verified, unless it already is.
    /// `force` re-does it: the Retry button, and the bench.
    func stage(force: Bool = false) {
        guard let latest, available, !downloading else { return }
        // A test world reaches the real feed too; it must not fill up with
        // real releases it will never install, unless the bench pointed it
        // at a feed of its own.
        if Store.testing, manifestURL == Self.defaultManifestURL, !force { return }
        if !force, let staged, staged.version == latest.version,
           Self.bundleVersion(at: URL(fileURLWithPath: staged.path)) == staged.version {
            return
        }
        downloading = true
        stageError = nil
        let want = latest
        let folder = Self.updatesFolder
        Self.note("staging \(want.version) from \(want.archiveUrl ?? "no archive URL")")
        Task { [weak self] in
            let result = await Self.fetchAndStage(want, into: folder)
            guard let self else { return }
            downloading = false
            switch result {
            case .success(let done):
                staged = done
                stageError = nil
                saved.staged = done
                persist()
                Self.note("staged \(done.version) at \(done.path)")
                if saved.readyAnnounced != done.version {
                    saved.readyAnnounced = done.version
                    persist()
                    browser?.announce("Copper \(done.version) is ready — ⌘K “Update Copper” or Settings › Updates")
                }
            case .failure(let why):
                stageError = why
                Self.note("staging \(want.version) failed: \(why)")
                // Once per version: the feed answered a moment ago, so this is
                // not the quiet offline case, and it should be seen.
                if saved.troubleAnnounced != want.version {
                    saved.troubleAnnounced = want.version
                    persist()
                    browser?.announce("Couldn’t download Copper \(want.version) — see Settings › Updates")
                }
            }
        }
    }

    private enum StageResult {
        case success(Staged)
        case failure(String)
    }

    /// Off the main actor: the download, the hash, ditto, codesign. Nothing
    /// here touches the running bundle; a failure leaves at most a folder
    /// under `updates/` that the next attempt clears.
    private nonisolated static func fetchAndStage(_ latest: Latest, into folder: URL) async -> StageResult {
        let files = FileManager.default
        let version = latest.version
        guard let raw = latest.archiveUrl, let url = URL(string: raw) else {
            return .failure("The feed did not say where Copper \(version) is.")
        }
        guard let want = latest.sha256?.lowercased(), want.count == 64 else {
            return .failure("The feed did not publish a checksum for Copper \(version).")
        }

        // 1. Download. Two minutes is generous for six megabytes over a VPN
        // and short enough that a stalled transfer is reported, not waited on.
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        let zip: URL
        do {
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? files.removeItem(at: downloaded)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failure("\(url.host ?? "The feed") answered \(code) for Copper \(version).")
            }
            zip = downloaded
        } catch {
            return .failure("Couldn’t download Copper \(version) from \(url.host ?? "the feed"): \(error.localizedDescription)")
        }
        defer { try? files.removeItem(at: zip) }

        // 2. The bytes are the manifest's bytes, or they are nothing.
        guard let have = try? sha256(of: zip) else {
            return .failure("The download of Copper \(version) could not be read back.")
        }
        guard have == want else {
            return .failure("The download of Copper \(version) did not match the feed's checksum.")
        }

        // 3. Unpack into a folder of its own; older staged versions go.
        let target = folder.appendingPathComponent(version, isDirectory: true)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for entry in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent != "previous" {
                try? files.removeItem(at: entry)
            }
            try files.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            return .failure("Couldn’t make room for Copper \(version): \(error.localizedDescription)")
        }
        let unpack = run("/usr/bin/ditto", ["-x", "-k", zip.path, target.path])
        guard unpack.status == 0 else {
            return .failure("The archive of Copper \(version) could not be unpacked: \(unpack.output)")
        }
        let apps = ((try? files.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        guard let app = apps.first(where: { $0.lastPathComponent == "\(Fork.name).app" }) ?? apps.first else {
            return .failure("The archive of Copper \(version) did not contain \(Fork.name).app.")
        }

        // 4. It is Copper, it is this version, and its signature holds.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let bundleID = info?["CFBundleIdentifier"] as? String ?? ""
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        guard bundleID == Fork.bundle else {
            return .failure("The download is not Copper (bundle id \(bundleID.isEmpty ? "missing" : bundleID)).")
        }
        guard shortVersion == version else {
            return .failure("The download says it is \(shortVersion.isEmpty ? "no version" : shortVersion), not \(version).")
        }
        let signature = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard signature.status == 0 else {
            return .failure("The signature of Copper \(version) did not verify: \(signature.output)")
        }
        // Ad-hoc builds may carry a quarantine flag from the download; the
        // launch after the swap must not be Gatekeeper's to refuse.
        _ = run("/usr/bin/xattr", ["-cr", app.path])

        return .success(Staged(version: version, path: app.path, sha256: have, at: Date()))
    }

    private nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            sha.update(data: chunk)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A tool with its output, one line, for a sentence.
    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (process.terminationStatus, text.last ?? "")
    }

    nonisolated static func bundleVersion(at app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    private func discardStaged() {
        if let staged {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: staged.path).deletingLastPathComponent())
        }
        staged = nil
        saved.staged = nil
        persist()
    }

    // MARK: - the update: back up, swap, relaunch

    enum Refused: Error {
        case notStaged, gone(String), wrongVersion(String, String), signature(String), session(String)
        case readOnly(String), moveAside(String), moveIn(String), verify(String)

        var sentence: String {
            switch self {
            case .notStaged: return "The new Copper isn’t downloaded yet — getting it now."
            case .gone(let path): return "The downloaded Copper is no longer at \(path) — downloading it again."
            case .wrongVersion(let have, let want): return "The downloaded bundle is \(have), not \(want) — downloading again."
            case .signature(let why): return "The downloaded bundle’s signature no longer verifies: \(why)"
            case .session(let why): return "Couldn’t back up the tab session, so nothing was changed: \(why)"
            case .readOnly(let folder): return "\(folder) does not allow replacing the app from here."
            case .moveAside(let why): return "Couldn’t move the current Copper aside: \(why) If macOS asked about App Management, allow it in System Settings › Privacy & Security."
            case .moveIn(let why): return "Couldn’t move the new Copper into place, so the current one was put back: \(why)"
            case .verify(let why): return "The swap did not leave the expected version in place, so the current one was put back: \(why)"
            }
        }
    }

    /// The Update button and ⌘K. Everything risky already happened in
    /// `stage`; this re-checks the staged bundle, backs up the session, swaps
    /// the bundles where this app runs and relaunches. Any refusal is a
    /// sentence in Settings and the bundle on disk is the one that was there.
    func upgrade() {
        guard state != .upgrading, let latest, available else { return }
        state = .upgrading
        problem = nil
        do {
            guard let staged, staged.version == latest.version else { throw Refused.notStaged }
            let bundle = URL(fileURLWithPath: staged.path)
            try Self.reverify(bundle, version: staged.version)
            try backUpSession()
            let target = Bundle.main.bundleURL
            Self.note("update \(current) -> \(staged.version): swapping \(bundle.path) into \(target.path)\(dryRun ? " (dry run: stopping here)" : "")")
            if dryRun {
                state = .idle
                return
            }
            try Self.swap(bundle, into: target, keeping: Self.previousFolder, version: staged.version)
            saved.pending = Pending(version: staged.version, from: current, at: Date())
            saved.staged = nil
            persist()
            Self.note("swapped; relaunching \(target.path)")
            relaunch(target)
        } catch let refused as Refused {
            state = .idle
            problem = refused.sentence
            Self.note("update refused: \(refused.sentence)")
            switch refused {
            case .notStaged, .gone, .wrongVersion, .signature:
                // The staged copy is not to be trusted any more; fetch afresh.
                discardStaged()
                stage(force: true)
            case .session, .readOnly, .moveAside, .moveIn, .verify:
                record(Outcome(ok: false, detail: refused.sentence, at: Date()))
            }
        } catch {
            state = .idle
            problem = error.localizedDescription
            Self.note("update failed: \(error.localizedDescription)")
            record(Outcome(ok: false, detail: error.localizedDescription, at: Date()))
        }
    }

    /// The same checks as staging did, on what is on disk now.
    private nonisolated static func reverify(_ app: URL, version: String) throws {
        guard FileManager.default.fileExists(atPath: app.path) else { throw Refused.gone(app.path) }
        let have = bundleVersion(at: app) ?? ""
        guard have == version else { throw Refused.wrongVersion(have.isEmpty ? "unreadable" : have, version) }
        let signature = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard signature.status == 0 else { throw Refused.signature(signature.output) }
    }

    /// A copy of session.json beside it, because tabs are the thing an update
    /// must preserve. Ten copies are kept; the folder should not grow with
    /// every update. No session yet (a first run) is nothing to protect.
    private func backUpSession() throws {
        let files = FileManager.default
        let session = Store.file("session.json")
        guard files.fileExists(atPath: session.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = session.deletingLastPathComponent().appendingPathComponent("session.backup-\(stamp).json")
        do {
            // A retry within the same second replaces its own copy.
            if files.fileExists(atPath: copy.path) { try files.removeItem(at: copy) }
            try files.copyItem(at: session, to: copy)
        } catch {
            throw Refused.session(error.localizedDescription)
        }
        let backups = ((try? files.contentsOfDirectory(at: session.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session.backup-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(10) { try? files.removeItem(at: old) }
    }

    /// Two renames on one volume: the running bundle goes to `previous`, the
    /// staged one takes its place. Either one failing puts things back as they
    /// were. The bundle that was replaced stays in `previous` until the next
    /// release is staged, in case the new one has to be put back by hand.
    private nonisolated static func swap(_ staged: URL, into target: URL, keeping previous: URL, version: String) throws {
        let files = FileManager.default
        let folder = target.deletingLastPathComponent()
        guard files.isWritableFile(atPath: folder.path) else { throw Refused.readOnly(folder.path) }
        let aside = previous.appendingPathComponent(target.lastPathComponent)
        try? files.removeItem(at: previous)
        do {
            try files.createDirectory(at: previous, withIntermediateDirectories: true)
            try files.moveItem(at: target, to: aside)
        } catch {
            throw Refused.moveAside(error.localizedDescription)
        }
        do {
            try files.moveItem(at: staged, to: target)
        } catch {
            try? files.moveItem(at: aside, to: target)
            throw Refused.moveIn(error.localizedDescription)
        }
        let have = bundleVersion(at: target) ?? ""
        guard have == version else {
            try? files.removeItem(at: target)
            try? files.moveItem(at: aside, to: target)
            throw Refused.verify("\(target.lastPathComponent) reads \(have.isEmpty ? "no version" : have), expected \(version)")
        }
        _ = run("/usr/bin/xattr", ["-cr", target.path])
        // The version folder the bundle came out of is spent.
        try? files.removeItem(at: staged.deletingLastPathComponent())
    }

    /// Quit, and come back as the new one. A shell waits for this process to
    /// be gone before asking macOS to open the bundle again — `open` on a
    /// running app only brings it forward. A test world comes back as the
    /// same test world.
    private func relaunch(_ target: URL) {
        var open = ["/usr/bin/open"]
        for key in ["SEARCH_PROBE", "SEARCH_MCP_PORT", "SEARCH_MEASURE"] {
            if let value = ProcessInfo.processInfo.environment[key] { open += ["--env", "\(key)=\(value)"] }
        }
        open.append(target.path)
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; shift; exec \"$@\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier),
        ] + open
        do {
            try waiter.run()
        } catch {
            // The swap is done; this process just cannot arrange its own
            // return. Say so, and leave the user to open Copper again.
            problem = "Copper \(saved.pending?.version ?? "") is installed, but the relaunch could not be started — open Copper again."
            Self.note("relaunch could not start: \(error.localizedDescription)")
            state = .idle
            return
        }
        browser?.announce("Relaunching as Copper \(saved.pending?.version ?? "")")
        NSApp.terminate(nil)
    }

    // MARK: - the next launch

    /// The process that comes back after a swap says what it is. A pending
    /// record that matches is the update landing; one that does not is the
    /// wrong bundle running, and is said so.
    private func settleAtLaunch() {
        if let pending = saved.pending {
            saved.pending = nil
            if pending.version == current {
                record(Outcome(ok: true, detail: pending.version, at: Date()))
                Self.note("launched as \(current): update from \(pending.from) landed")
                browser?.announce("Updated to \(current)")
            } else {
                let why = "\(pending.version) was put in place, but this is \(current) — the bundle at \(Bundle.main.bundleURL.path) is not the one that was installed."
                record(Outcome(ok: false, detail: why, at: Date()))
                Self.note("launched as \(current) after installing \(pending.version)")
                browser?.announce("Update did not take — see Settings › Updates")
            }
            persist()
        }
        // An older Copper's helper left its verdict in a file; read it once.
        let legacy = Store.file("update-result.txt")
        if let text = try? String(contentsOf: legacy, encoding: .utf8) {
            try? FileManager.default.removeItem(at: legacy)
            let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
            if pieces.first == "ok", pieces.count >= 2 {
                let version = String(pieces[1].split(separator: " ").first ?? "")
                record(Outcome(ok: version == current, detail: version == current ? version : "\(version) was reported installed, but this is \(current)", at: Date()))
            } else if pieces.first == "failed" {
                record(Outcome(ok: false, detail: pieces.count >= 2 ? pieces[1] : "no reason was recorded", at: Date()))
            }
        }
        // A staged bundle that is not newer than what is running is spent.
        if let staged, Self.compare(staged.version, current) <= 0 { discardStaged() }
    }

    private func record(_ result: Outcome) {
        outcome = result
        saved.outcome = result
        persist()
    }

    // MARK: - versions, persistence, the log

    /// Numeric dotted versions are compared component by component. Missing
    /// components are zero, so a local `1.0` build is older than every feed
    /// release. If a component is not numeric, comparing the component text is
    /// the least surprising fallback and still gives a total ordering.
    nonisolated static func compare(_ left: String, _ right: String) -> Int {
        let a = left.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let b = right.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : "0"
            let y = index < b.count ? b[index] : "0"
            if let xi = Int(x), let yi = Int(y) {
                if xi < yi { return -1 }
                if xi > yi { return 1 }
                continue
            }
            if x < y { return -1 }
            if x > y { return 1 }
        }
        return 0
    }

    private func load() {
        guard let data = try? Data(contentsOf: Store.file("updates.json")),
              let loaded = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        saved = loaded
        checkedAt = loaded.checkedAt
        latest = loaded.latest
        outcome = loaded.outcome
        // A staged bundle counts only if it is still there and still itself.
        if let kept = loaded.staged, Self.bundleVersion(at: URL(fileURLWithPath: kept.path)) == kept.version {
            staged = kept
        } else {
            saved.staged = nil
        }
    }

    private func persist() {
        let file = Store.file("updates.json")
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// One dated line per step, appended. The log is the record of what
    /// happened to someone's install; nothing here ever truncates it.
    nonisolated static func note(_ line: String) {
        let files = FileManager.default
        try? files.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: log.path) { files.createFile(atPath: log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? handle.write(contentsOf: Data("\(stamp) copper-update: \(line)\n".utf8))
    }

    var status: [String: Any] {
        [
            "current": current,
            "latest": latest?.version ?? "",
            "available": available,
            "ready": ready,
            "downloading": downloading,
            "stageError": stageError ?? "",
            "staged": staged.map { ["version": $0.version, "path": $0.path, "sha256": $0.sha256] } ?? [:],
            "managedByBrew": managedByBrew,
            "checkedAt": checkedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "error": error ?? "",
            "problem": problem ?? "",
            "state": state == .upgrading ? "upgrading" : "idle",
            "outcome": outcome.map { ["ok": $0.ok, "detail": $0.detail, "at": ISO8601DateFormatter().string(from: $0.at)] } ?? [:],
            "log": Self.log.path,
        ]
    }
}
