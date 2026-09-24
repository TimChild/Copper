import AppKit
import Combine
import Foundation

/// Copper's own update path. This deliberately does not use Updater.swift:
/// that feed and its signature belong to Search, and a fork must never let an
/// upstream release replace the browser that is running here.
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
        var latest: Latest?
    }

    enum State: Equatable {
        case idle
        case upgrading
    }

    @Published private(set) var latest: Latest?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var state: State = .idle
    @Published private(set) var checking = false
    @Published private(set) var lastScript: URL?

    /// Bench can point this at a local HTTP server. The shipped value is the
    /// internal feed, not a user preference and not a command-line override.
    var manifestURL: URL = URL(string: Setup.feed + "/downloads/copper-version.json")!
    var dryRun = false

    private weak var browser: Browser?
    private var timer: Timer?
    private var saved = Saved(checkedAt: nil, lastSeenVersion: nil, announcedVersion: nil, latest: nil)

    var current: String { Fork.version }
    var available: Bool {
        guard let latest else { return false }
        return Self.compare(latest.version, current) > 0
    }

    /// A Copper install is Homebrew-managed only when both pieces of evidence
    /// are present. A stray brew binary must not make the feed installer lose
    /// its place, and an abandoned Caskroom must not make us run a command
    /// that is no longer installed.
    var managedByBrew: Bool {
        brewPath() != nil
    }

    private init() {
        load()
    }

    // MARK: - launch and checking

    /// Attach once the Browser exists. The five-second delay leaves session
    /// restoration and the first window draw alone; after that, a long-lived
    /// Copper checks every six hours without asking the user to remember.
    func start(for browser: Browser) {
        self.browser = browser
        consumeResult()
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
                if !force, available, saved.announcedVersion != found.version {
                    saved.announcedVersion = found.version
                    persist()
                    browser?.announce("Copper \(found.version) is out — ⌘K “Update Copper” or Settings › Updates")
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

    // MARK: - versions and persistence

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
    }

    private func persist() {
        let file = Store.file("updates.json")
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func consumeResult() {
        let file = Store.file("update-result.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = line.split(separator: " ", maxSplits: 2).map(String.init)
        if pieces.first == "ok", pieces.count >= 2 {
            browser?.announce("Updated to \(pieces[1])")
        } else if pieces.first == "failed" {
            browser?.announce("Update failed — see Settings › Updates")
        }
    }

    // MARK: - upgrading

    private func brewPath() -> URL? {
        let files = FileManager.default
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let brew = URL(fileURLWithPath: prefix).appendingPathComponent("bin/brew")
            let caskroom = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom/copper", isDirectory: true)
            if files.isExecutableFile(atPath: brew.path), files.fileExists(atPath: caskroom.path) { return brew }
        }
        return nil
    }

    private var brew: URL? { brewPath() }

    /// Write a detached POSIX helper. It owns quitting and relaunching so the
    /// current process can terminate without taking the upgrade with it.
    func upgrade() {
        guard available, state != .upgrading, let latest else { return }
        let method = brew == nil ? "feed" : "brew"
        let brewPath = brew?.path ?? ""
        let script = helperScript(for: latest, method: method, brewPath: brewPath)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("copper-update-\(UUID().uuidString).sh")
        do {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            self.error = "Could not prepare the Copper update."
            return
        }
        lastScript = scriptURL
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Copper/update.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if dryRun {
            try? Data("dry-run helper: \(scriptURL.path)\n".utf8).write(to: log, options: .atomic)
            return
        }

        browser?.announce("Updating to \(latest.version) — Copper will relaunch")
        state = .upgrading
        let command = "nohup /bin/sh \(shellQuote(scriptURL.path)) >> \(shellQuote(log.path)) 2>&1 &"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
        } catch {
            state = .idle
            self.error = "Could not start the Copper update."
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// The helper is intentionally plain POSIX sh: it runs after Copper quits,
    /// with no Swift process left to supervise it. Every path can be replaced
    /// through COPPER_UPDATE_* variables for a sandbox, while the defaults are
    /// the real Copper install and session.
    private func helperScript(for latest: Latest, method: String, brewPath: String) -> String {
        let session = Store.file("session.json").path
        let result = Store.file("update-result.txt").path
        let install = "/Applications"
        let bin = brewPath.isEmpty ? "/usr/local/bin" : URL(fileURLWithPath: brewPath).deletingLastPathComponent().path
        return """
        #!/bin/sh
        # Copper update helper. It is detached before Copper quits.
        # 1. Back up the session, because tabs are the thing this operation must preserve.
        # 2. Ask Copper to quit, then wait and finally stop a stuck process.
        # 3. Upgrade through Homebrew, or run the feed installer without its launch.
        # 4. Clear quarantine, relaunch even after a failure, and leave one result line.
        # The COPPER_UPDATE_* overrides make this exact script safe to exercise in a sandbox.
        set -u
        PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
        export PATH
        VERSION=\(shellQuote(latest.version))
        METHOD="${COPPER_UPDATE_METHOD:-\(method)}"
        BREW="${COPPER_UPDATE_BREW:-\(brewPath)}"
        FEED="${COPPER_UPDATE_FEED:-\(Setup.feed)}"
        SESSION_PATH="${COPPER_UPDATE_SESSION_PATH:-\(session)}"
        RESULT_PATH="${COPPER_UPDATE_RESULT_PATH:-\(result)}"
        APP_NAME="${COPPER_UPDATE_APP_NAME:-Copper}"
        APP_PATH="${COPPER_UPDATE_APP_PATH:-/Applications/Copper.app}"
        INSTALL_DIR="${COPPER_UPDATE_INSTALL_DIR:-\(install)}"
        BIN_DIR="${COPPER_UPDATE_BIN_DIR:-\(bin)}"
        OPEN_COMMAND="${COPPER_UPDATE_OPEN:-/usr/bin/open}"
        OPEN_TARGET="${COPPER_UPDATE_OPEN_TARGET:-$APP_PATH}"
        TEST_MODE="${COPPER_UPDATE_TEST_MODE:-0}"
        failure=""
        note_failure() {
          if [ -z "$failure" ]; then failure="$1"; fi
          printf 'copper-update: %s\\n' "$1" >&2
        }
        result_dir=$(dirname "$RESULT_PATH")
        /bin/mkdir -p "$result_dir" 2>/dev/null || note_failure "could not create result directory"

        # 1. A missing or uncopyable session is a failure, not a reason to risk tabs.
        session_dir=$(dirname "$SESSION_PATH")
        stamp=$(/bin/date +%s)
        if [ -f "$SESSION_PATH" ]; then
          if ! /bin/cp "$SESSION_PATH" "$session_dir/session.backup-$stamp.json"; then
            note_failure "session backup failed"
          fi
        else
          note_failure "session file was not found"
        fi

        # 2. Test mode skips only process control; a normal run waits for a clean quit.
        if [ "$TEST_MODE" != "1" ]; then
          /usr/bin/osascript -e "tell application \\\"$APP_NAME\\\" to quit" 2>/dev/null || :
          quit_by=$(( $(/bin/date +%s) + 20 ))
          while /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1 && [ $(/bin/date +%s) -lt "$quit_by" ]; do /bin/sleep 1; done
          if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            /usr/bin/pkill -x "$APP_NAME" 2>/dev/null || :
            kill_by=$(( $(/bin/date +%s) + 10 ))
            while /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1 && [ $(/bin/date +%s) -lt "$kill_by" ]; do /bin/sleep 1; done
          fi
        fi

        # 3. Homebrew's successful "already up-to-date" is not enough when the
        # feed has a newer manifest, so reinstall in that case. A failed upgrade
        # gets the same reinstall chance before we call it failed.
        if [ "$METHOD" = "brew" ]; then
          update_log=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/copper-brew-update.XXXXXX")
          upgrade_log=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/copper-brew-upgrade.XXXXXX")
          if ! "$BREW" update >"$update_log" 2>&1; then
            note_failure "brew update: $(/usr/bin/tail -1 "$update_log")"
          fi
          if "$BREW" upgrade --cask copper >"$upgrade_log" 2>&1; then
            # Homebrew can report success while the cask is already current;
            # only the upgrade output counts here (not `brew update`'s own
            # "Already up-to-date" line), so that path gets a reinstall.
            if /usr/bin/grep -Eiq 'already installed|already up[- ]to[- ]date|up to date' "$upgrade_log"; then
              if ! "$BREW" reinstall --cask copper >>"$upgrade_log" 2>&1; then note_failure "brew reinstall: $(/usr/bin/tail -1 "$upgrade_log")"; fi
            fi
          else
            if ! "$BREW" reinstall --cask copper >>"$upgrade_log" 2>&1; then note_failure "brew upgrade: $(/usr/bin/tail -1 "$upgrade_log")"; fi
          fi
          /bin/rm -f "$update_log" "$upgrade_log"
        else
          installer=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/copper-installer.XXXXXX")
          if ! /usr/bin/curl -fsSL "$FEED/downloads/copper-install.sh" -o "$installer"; then
            note_failure "feed installer download failed"
          elif ! COPPER_NO_LAUNCH=1 COPPER_INSTALL_DIR="$INSTALL_DIR" COPPER_BIN_DIR="$BIN_DIR" /bin/sh "$installer" --no-launch; then
            note_failure "feed installer failed"
          fi
          /bin/rm -f "$installer"
        fi

        # 4. Ad-hoc builds can carry a quarantine bit; clearing it is harmless after brew.
        /usr/bin/xattr -cr "$APP_PATH" 2>/dev/null || :

        # 5. Write the result before opening Copper: the new process must see it
        # during launch, not race the shell that is bringing it back.
        if [ -z "$failure" ]; then
          printf 'ok %s %s\\n' "$VERSION" "$METHOD" >"$RESULT_PATH"
        else
          printf 'failed %s\\n' "$failure" >"$RESULT_PATH"
        fi
        # 6. Relaunch no matter what happened above. A test can replace open
        # with a recording stub; a failed relaunch rewrites the result honestly.
        if [ "$TEST_MODE" != "1" ]; then
          if ! "$OPEN_COMMAND" -a "$APP_NAME" >/dev/null 2>&1; then
            if ! "$OPEN_COMMAND" "$OPEN_TARGET" >/dev/null 2>&1; then
              note_failure "relaunch failed"
              printf 'failed %s\\n' "$failure" >"$RESULT_PATH"
            fi
          fi
        fi
        """
    }

    var status: [String: Any] {
        [
            "current": current,
            "latest": latest?.version ?? "",
            "available": available,
            "managedByBrew": managedByBrew,
            "checkedAt": checkedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "error": error ?? "",
            "lastScript": lastScript?.path ?? "",
        ]
    }
}
