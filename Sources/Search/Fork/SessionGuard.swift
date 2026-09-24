import Foundation

/// The session file is the one piece of browser state that must never be
/// replaced by a half-built launch. Restore owns the small state machine;
/// writes stay here so every caller (debounced saves, pin edits, and quit)
/// gets the same refusal and backup rules.
enum SessionGuard {
    private static let lock = NSLock()
    private static var restored = false

    /// A restore is beginning. Empty shapes are unsafe until the complete
    /// restore path has returned, because WebKit can ask for a save while the
    /// rows are still being built.
    static func beginRestore() {
        lock.lock()
        restored = false
        lock.unlock()
    }

    /// Restore has finished. From this point an empty shape is a real user
    /// choice (closing the last tab), not launch-time scaffolding.
    static func finishRestore() {
        lock.lock()
        restored = true
        lock.unlock()
    }

    /// Used by the small standalone harness as well as tests in this module.
    static func resetForTesting(restored: Bool = false) {
        lock.lock()
        self.restored = restored
        lock.unlock()
    }

    /// Encode first, then call this once for the actual write. The lock covers
    /// the rotation and atomic replacement together, so concurrent debounced
    /// saves cannot overwrite the one retained previous session.
    @discardableResult
    static func write(_ data: Data, tabCount newTabCount: Int, file: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let oldCount = tabCount(in: file) ?? 0
        if newTabCount == 0, oldCount > 0, !restored {
            NSLog("Copper: refused empty session write before restore completed (session has %d tabs)", oldCount)
            return false
        }

        if oldCount > 0, (newTabCount == 0 || newTabCount * 2 < oldCount) {
            let previous = file.deletingLastPathComponent().appendingPathComponent("session.previous.json")
            do {
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.copyItem(at: file, to: previous)
            } catch {
                NSLog("Copper: could not rotate session.previous.json: %@", error.localizedDescription)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Data.write(.atomic) writes a sibling temporary and renames it,
            // so a crash cannot leave a truncated session.json.
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            NSLog("Copper: could not write session.json: %@", error.localizedDescription)
            return false
        }
    }

    static func tabCount(in file: URL) -> Int? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tabs = object["tabs"] as? [Any]
        else { return nil }
        return tabs.count
    }
}
