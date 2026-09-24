import AppKit
import Foundation

/// The in-app recovery action is detached before asking Copper to quit. The
/// helper is deliberately boring POSIX sh, like the feed updater: no Swift
/// process remains behind to race the relaunch or the final session write.
enum SessionRecovery {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func script(session: URL, previous: URL, appName: String, replacedDirectory: URL) -> String {
        let app = shellQuote(appName)
        let sessionPath = shellQuote(session.path)
        let previousPath = shellQuote(previous.path)
        let replacedPath = shellQuote(replacedDirectory.path)
        return """
        #!/bin/sh
        set -u
        SESSION=\(sessionPath)
        PREVIOUS=\(previousPath)
        REPLACED_DIR=\(replacedPath)
        APP=\(app)
        if [ -f "$SESSION" ]; then
          stamp=$(/bin/date +%s)
          /bin/cp "$SESSION" "$REPLACED_DIR/session.replaced-$stamp.json" || exit 2
        fi
        /usr/bin/osascript -e "tell application \\\"$APP\\\" to quit" 2>/dev/null || :
        deadline=$(( $(/bin/date +%s) + 20 ))
        while /usr/bin/pgrep -x "$APP" >/dev/null 2>&1 && [ $(/bin/date +%s) -lt "$deadline" ]; do
          /bin/sleep 1
        done
        /usr/bin/pgrep -x "$APP" >/dev/null 2>&1 && exit 3
        temporary="$SESSION.restore-$$"
        /bin/cp "$PREVIOUS" "$temporary" || exit 4
        /bin/mv -f "$temporary" "$SESSION" || exit 5
        /usr/bin/open -a "$APP" >/dev/null 2>&1 || exit 6
        """
    }
}

@MainActor
extension Browser {
    /// ⌘K → Restore previous session. The command exists only while the
    /// one-retained backup exists, and the helper takes over before quitting
    /// so this process can finish normally.
    func restorePreviousSession() {
        let previous = Store.file("session.previous.json")
        guard FileManager.default.fileExists(atPath: previous.path) else { return }
        let session = Store.file("session.json")
        let directory = session.deletingLastPathComponent()
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("copper-session-restore-\(UUID().uuidString).sh")
        let script = SessionRecovery.script(
            session: session,
            previous: previous,
            appName: "Copper",
            replacedDirectory: directory
        )
        do {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            announce("Could not prepare session restore")
            return
        }

        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Copper/session-restore.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let command = "nohup /bin/sh \(SessionRecovery.shellQuote(scriptURL.path)) >> \(SessionRecovery.shellQuote(log.path)) 2>&1 &"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
            announce("Restoring previous session — Copper will relaunch")
        } catch {
            announce("Could not start session restore")
        }
    }
}
