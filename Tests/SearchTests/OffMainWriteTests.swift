import Foundation
import Testing
@testable import Search

// A caller-named file write never blocks its caller past the bound: a write
// stuck in open() (a macOS privacy prompt nobody answers) times out with an
// error that says what to try. Fork/MCP/OffMainWrite.swift.

private let blocked: OffMainWrite.Writer = { _, _ in Thread.sleep(forTimeInterval: 3) }

@Test func offMainWriteTimesOutOnABlockedWriter() async {
    let started = Date()
    do {
        try await OffMainWrite.write(Data([1]), to: URL(fileURLWithPath: "/Volumes/Stuck/x.png"), timeout: 0.2, writer: blocked)
        Issue.record("a blocked write returned")
    } catch let timedOut as OffMainWrite.TimedOut {
        #expect(timedOut.path == "/Volumes/Stuck/x.png")
        #expect(timedOut.description.contains("couldn't write /Volumes/Stuck/x.png within"))
        #expect(timedOut.description.contains("/tmp"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
    #expect(Date().timeIntervalSince(started) < 2)
}

@MainActor
@Test func offMainWriteLeavesTheMainActorFreeWhileItWaits() async throws {
    // The main actor keeps running work while a write is stuck.
    var ticks = 0
    let ticker = Task { @MainActor in
        for _ in 0..<5 { ticks += 1; try? await Task.sleep(nanoseconds: 20_000_000) }
    }
    await #expect(throws: OffMainWrite.TimedOut.self) {
        try await OffMainWrite.write(Data(), to: URL(fileURLWithPath: "/x"), timeout: 0.3, writer: blocked)
    }
    await ticker.value
    #expect(ticks == 5)
}

@Test func offMainWriteBlockingTimesOutToo() {
    let started = Date()
    #expect(throws: OffMainWrite.TimedOut.self) {
        try OffMainWrite.writeBlocking(Data(), to: URL(fileURLWithPath: "/x"), timeout: 0.2, writer: blocked)
    }
    #expect(Date().timeIntervalSince(started) < 2)
}

@Test func offMainWriteWritesAndPassesErrorsThrough() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("offmain-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    try await OffMainWrite.write(Data([1, 2, 3]), to: url)
    #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    try OffMainWrite.writeBlocking(Data([4]), to: url)
    #expect(try Data(contentsOf: url) == Data([4]))

    struct Boom: Error {}
    await #expect(throws: Boom.self) {
        try await OffMainWrite.write(Data(), to: url, writer: { _, _ in throw Boom() })
    }
    #expect(throws: Boom.self) {
        try OffMainWrite.writeBlocking(Data(), to: url, writer: { _, _ in throw Boom() })
    }
}
