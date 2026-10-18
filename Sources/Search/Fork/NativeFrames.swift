import Foundation

// Native-messaging frames, written down for a probe world.
//
// What an extension and its native host said to each other is the first
// thing to know when they don't get along (1Password's "Waiting for
// 1Password…" that never ends), and nothing else in the app sees it: the
// host's own log may be out of reach, and WebKit hands the extension the
// message without saying what it looked like on the wire.
//
// Only a test world (`Store.testing`) given `SEARCH_NATIVE_LOG=<file>`
// writes anything — a released Copper never does. Each line is the
// direction, the host's program name, the frame's length and its first
// bytes (`SEARCH_NATIVE_LOG_BYTES`, 160 unless set), so a probe can check a
// message's shape without the log becoming a copy of what passed through.

enum NativeFrames {
    private static let file: URL? = {
        guard Store.testing, let path = ProcessInfo.processInfo.environment["SEARCH_NATIVE_LOG"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }()
    private static let head: Int = {
        Int(ProcessInfo.processInfo.environment["SEARCH_NATIVE_LOG_BYTES"] ?? "") ?? 160
    }()
    private static let lock = NSLock()

    static var on: Bool { file != nil }

    /// `direction` is `>` toward the host, `<` from it, `!` for an event
    /// (started, exited, a frame that wasn't JSON).
    static func note(_ direction: String, _ host: String, _ body: Data) {
        guard let file else { return }
        let shown = String(decoding: body.prefix(head), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\\n")
        let line = "\(Date().timeIntervalSince1970) \(direction) \(host) \(body.count) \(shown)\n"
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    static func event(_ host: String, _ text: String) {
        note("!", host, Data(text.utf8))
    }
}
