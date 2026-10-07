import Foundation
import Testing
@testable import Search

// Chrome's session files (Fork/Flow/FlowChromeTabs.swift): Session_* is the
// open windows and tabs; Tabs_* is the recently-closed list and is never
// replayed as open tabs.

/// SNSS v1, written the way the e2e fixtures' perl writes it.
private enum SNSS {
    static func u16(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)] }
    static func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) } }
    static func pad(_ bytes: [UInt8]) -> [UInt8] { bytes + Array(repeating: 0, count: (4 - bytes.count % 4) % 4) }
    static func field(_ text: String) -> [UInt8] { let bytes = Array(text.utf8); return u32(bytes.count) + pad(bytes) }
    static func field16(_ text: String) -> [UInt8] {
        let units = Array(text.utf16)
        return u32(units.count) + pad(units.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
    }
    static func command(_ id: UInt8, _ payload: [UInt8]) -> [UInt8] { u16(payload.count + 1) + [id] + payload }
    static func navigation(tab: Int, url: String, title: String) -> [UInt8] {
        let body = u32(tab) + u32(0) + field(url) + field16(title) + u32(0) + u32(0)
        return u32(body.count) + body
    }

    /// One window, a tab per address (Session_*).
    static func session(_ urls: [String]) -> Data {
        var out = Array("SNSS".utf8) + u32(1)
        for (index, url) in urls.enumerated() {
            let tab = 7 + index
            out += command(0, u32(1) + u32(tab))          // tab in window 1
            out += command(2, u32(tab) + u32(index))      // at this index
            out += command(6, navigation(tab: tab, url: url, title: "Open"))
        }
        out += command(8, u32(1) + u32(0))               // window 1's selected tab
        return Data(out)
    }

    /// A recently-closed list (Tabs_*): navigations, under the same small
    /// tab ids an open window uses — they restart every launch.
    static func closed(_ urls: [String]) -> Data {
        var out = Array("SNSS".utf8) + u32(1)
        for (index, url) in urls.enumerated() {
            out += command(1, navigation(tab: 7 + index, url: url, title: "Closed"))
        }
        return Data(out)
    }
}

private func profile(session: [String]?, closed: [String]?) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("flow-tabs-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("Default/Sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appendingPathComponent("Default/Preferences"))
    if let session { try SNSS.session(session).write(to: sessions.appendingPathComponent("Session_13400000000000001")) }
    if let closed { try SNSS.closed(closed).write(to: sessions.appendingPathComponent("Tabs_13400000000000001")) }
    return root
}

@Suite("Flow Chrome tabs: open, never recently closed")
struct FlowChromeTabsTests {
    @Test("A profile with only a recently-closed list has no open tabs, and says it was read")
    func closedOnly() throws {
        let root = try profile(session: nil, closed: ["https://closed.invalid/one", "https://closed.invalid/two"])
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = try FlowChromeTabs.read(sessionsFolder: root, profile: "Default")
        #expect(spaces.flatMap(\.tabs).isEmpty)
    }

    @Test("Closed tabs under the same ids don't change or add to the open ones")
    func closedBesideOpen() throws {
        let root = try profile(session: ["https://open.invalid/a", "https://open.invalid/b"],
                               closed: ["https://closed.invalid/x", "https://closed.invalid/y", "https://closed.invalid/z"])
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = try FlowChromeTabs.read(sessionsFolder: root, profile: "Default")
        let urls = spaces.flatMap(\.tabs).map(\.url.absoluteString)
        #expect(urls == ["https://open.invalid/a", "https://open.invalid/b"])
    }

    @Test("Profiles come in Chrome's order: Default, then Profile 1, 2 … 10 as numbers; guest and picker left out")
    func profileOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flow-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Profile 10", "Profile 2", "Default", "Profile 1", "Guest Profile", "System Profile", "Crashpad"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if name != "Crashpad" { try Data("{}".utf8).write(to: folder.appendingPathComponent("Preferences")) }
        }
        // Guest and the profile picker have Preferences but nothing to move;
        // a folder without Preferences isn't a profile.
        #expect(FlowChromeTabs.profiles(at: root) == ["Default", "Profile 1", "Profile 2", "Profile 10"])
    }
}
