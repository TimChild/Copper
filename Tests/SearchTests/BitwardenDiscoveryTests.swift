import Foundation
import Testing
@testable import Search

// Where Copper looks for `bw` beyond Homebrew: the Node version managers'
// folders (Volta's shim was the one a relaunched Copper missed), nvm's newest
// Node first, and a path read out of a shell's answer.

@Suite("Finding bw")
struct BitwardenDiscoveryTests {
    @Test func versionManagersAreLooked() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let paths = Bitwarden.managedLocations(home: home)
        #expect(paths.first == "/Users/someone/.local/bin/bw")
        #expect(paths.contains("/Users/someone/.volta/bin/bw"))
        #expect(paths.contains("/Users/someone/.npm-global/bin/bw"))
        #expect(paths.contains("/Users/someone/.bun/bin/bw"))
        #expect(paths.contains("/Users/someone/.local/share/mise/shims/bw"))
    }

    @Test func newestNodeFirstForNvm() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bwhome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["v18.20.4", "v22.11.0", "v20.9.0"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/\(version)/bin"), withIntermediateDirectories: true)
        }
        let nvm = Bitwarden.managedLocations(home: home).filter { $0.contains(".nvm/") }
        #expect(nvm.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
                == ["v22.11.0", "v20.9.0", "v18.20.4"])
    }

    @Test func readsThePathOutOfAShellsAnswer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bwbin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bw = folder.appendingPathComponent("bw")
        try "#!/bin/sh\necho 2026.8.0\n".write(to: bw, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bw.path)
        // A shell that greets first, as an interactive one may.
        let found = Bitwarden.lookUp(["/bin/sh", "-c", "echo 'Last login: today'; echo \(bw.path)"])
        #expect(found == bw.path)
        #expect(Bitwarden.lookUp(["/bin/sh", "-c", "echo /nowhere/bw"]) == nil)
        #expect(Bitwarden.lookUp(["/bin/sh", "-c", "sleep 5"], timeout: 0.3) == nil)
    }
}
