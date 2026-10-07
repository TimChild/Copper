import CoreML
import CryptoKit
import Foundation

// The speech model on this Mac: Fermion Research's Phonon-2 for Core ML,
// fetched once when someone turns voice on and kept until they press Remove.
//
// Nothing about it is taken on trust. The revision is a pinned commit of the
// Hugging Face repo, and every file it needs has its size and SHA-256 written
// down below; bytes that don't hash to those are thrown away, never installed.
// The shape follows Fork/Updates.swift — everything that can fail happens
// before anything is made visible — with two things a 345 MB download needs
// that a 6 MB update doesn't: it resumes (HTTP Range into a `.partial` folder
// that survives a quit), and it is compiled for Core ML before it counts.
//
// On disk, under the world's own folder (a probe world never shares it):
//
//     Models/                          excluded from Time Machine
//       voice-model.log                what was fetched, resumed, refused — never speech
//       phonon-2-coreml/
//         <revision>.partial/          a download in progress, kept to resume
//         <revision>/                  the installed model (the partial, renamed whole)
//           manifest.json, decoder.bin, Phonon-2.mlpackage/, Phonon-2.mlmodelc/, NOTICE, licences
//         current -> <revision>        which revision is installed
//
// The engine is reached only through `prepareHook` / `unloadHook`, which the
// app sets at launch; this file never names it.

@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    enum State: Equatable {
        case absent
        case downloading(Double)
        case verifying
        case compiling
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .absent
    /// A complete model is on disk (or `SEARCH_VOICE_MODEL_DIR` names one).
    @Published private(set) var onDisk = false
    /// What an unfinished download has kept so far, to carry on from.
    @Published private(set) var partialBytes: Int64 = 0

    /// The folder to load: the installed revision, or `SEARCH_VOICE_MODEL_DIR`
    /// when that names a ready folder. Nil while there is no complete model.
    var modelDir: URL? {
        if let override { return override }
        return onDisk ? installedDir : nil
    }

    /// Set by the app at launch: load the model in a folder (compile if need
    /// be, warm the Neural Engine), and let it go again. Setting it wakes the
    /// store, so a download a quit cut short carries on from launch.
    static var prepareHook: ((URL, @escaping @Sendable (String) -> Void) async throws -> Void)? {
        didSet { _ = shared }
    }
    static var unloadHook: (() async -> Void)?

    // MARK: - the pin

    struct ModelFile: Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    nonisolated static let repo = "FermionResearch/Phonon-2-CoreML"
    /// huggingface.co/api/models/FermionResearch/Phonon-2-CoreML → sha, 2026-10-06.
    nonisolated static let revision = "e931079df1f6bff26f5f416c1c8880e76a0cf2a3"
    /// Every file the runner reads, and the licence and notice that travel
    /// with the weights (CC BY 4.0 asks for them). The LFS hashes are the
    /// tree API's `lfs.oid`; the small files were fetched once and hashed,
    /// and all of them match the repo's own SHA256SUMS. The Python helpers
    /// and test clips in the repo are left behind.
    nonisolated static let files: [ModelFile] = [
        ModelFile(path: "manifest.json", size: 1_428,
                  sha256: "ab3fb5dfd3fc07b1d8a24379d04418f458d0443ba6359d3a5ab2f098a7d64089"),
        ModelFile(path: "decoder.bin", size: 13_301_279,
                  sha256: "36fa7202dda85c603af60d930ab88d7e9f0d2a619490aff46f5384db924cfa70"),
        ModelFile(path: "Phonon-2.mlpackage/Manifest.json", size: 617,
                  sha256: "6ebc9309aea0e16bda9c7558521fef6307fac0afba9a5b4959fea45ed7cd0429"),
        ModelFile(path: "Phonon-2.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 2_500_482,
                  sha256: "4f6790ec94fe4429b10397c013563d0a51119953ff6d3da466bbcb23a25dee2a"),
        ModelFile(path: "Phonon-2.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 329_186_560,
                  sha256: "93aa991318a00ed492fdbb724e7bca4e6a69c6cf671ab4f14a14ef6101e7648b"),
        ModelFile(path: "NOTICE", size: 3_084,
                  sha256: "b468a23a1ce2c5181ea4050432bb68713a6468ce2e452927228d24f3d56226be"),
        ModelFile(path: "LICENSE-WEIGHTS-CC-BY-4.0.txt", size: 18_657,
                  sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"),
        ModelFile(path: "LICENSE-CODE-Apache-2.0.txt", size: 11_358,
                  sha256: "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"),
        ModelFile(path: "README.md", size: 5_531,
                  sha256: "0a645586a7399e786db7b7eaca51b59c8590242a5cfe4ae6840f7932bed42229"),
    ]
    nonisolated static let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }
    nonisolated static let package = "Phonon-2.mlpackage"
    nonisolated static let compiled = "Phonon-2.mlmodelc"
    /// `<base>/<revision>/<path>` is a file's address.
    nonisolated static let defaultBase = "https://huggingface.co/FermionResearch/Phonon-2-CoreML/resolve"

    /// "345 MB", the way Finder would say it.
    nonisolated static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - where

    let models: URL
    let home: URL
    var installedDir: URL { home.appendingPathComponent(Self.revision, isDirectory: true) }
    var stagingDir: URL { home.appendingPathComponent(Self.revision + ".partial", isDirectory: true) }
    var log: URL { journal.url }

    private let journal: ModelLog
    private let override: URL?
    private let base: URL?

    // MARK: - the one job at a time

    /// The download, the preparation or the removal under way, if any.
    private var job: Task<Void, Never>?
    /// Bumped for every job; an answer from an older one is dropped.
    private var ticket = 0
    private var cancelling = false
    /// Voice was turned back on while a download was still stopping.
    private var again = false

    private init() {
        models = Store.folder.appendingPathComponent("Models", isDirectory: true)
        home = models.appendingPathComponent("phonon-2-coreml", isDirectory: true)
        journal = ModelLog(models.appendingPathComponent("voice-model.log"))
        let environment = ProcessInfo.processInfo.environment
        override = environment["SEARCH_VOICE_MODEL_DIR"].flatMap { raw -> URL? in
            let dir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            return ModelStore.complete(dir, pinned: false) ? dir : nil
        }
        base = ModelStore.base(environment["SEARCH_VOICE_MODEL_BASE"])
        refresh()
        state = onDisk ? .ready : .absent
        // A download a quit or a crash cut short carries on by itself the
        // first time the store is reached with voice on.
        if state == .absent, VoicePrefs.shared.enabled {
            Task { @MainActor in ModelStore.shared.install() }
        }
    }

    // MARK: - asking

    /// Download, verify, compile and prepare the model. Nothing happens while
    /// something already is, or once it is ready.
    func install() {
        if job != nil {
            if cancelling { again = true }
            return
        }
        if state == .ready { return }
        guard VoicePrefs.supported else {
            note("install refused: voice needs macOS 15")
            return
        }
        refresh()
        if let dir = modelDir {
            prepare(dir)
            return
        }
        if let refusal = downloadRefusal {
            note("install refused: \(refusal)")
            state = .failed(refusal)
            return
        }
        guard let base else { return }
        ticket &+= 1
        let id = ticket
        let plan = Plan(base: base, home: home, models: models, staging: stagingDir, installed: installedDir,
                        journal: journal, plainHTTP: Self.isLoopback(base))
        state = .downloading(Double(partialBytes) / Double(Self.totalBytes))
        note("install \(Self.revision) from \(base.absoluteString) — \(partialBytes) of \(Self.totalBytes) bytes already here")
        job = Task {
            let outcome = await Self.fetchVerifyCompile(plan, moved: { done in
                Task { @MainActor in ModelStore.shared.moved(id, done) }
            }, entered: { phase in
                await MainActor.run { ModelStore.shared.entered(id, phase) }
            })
            ModelStore.shared.landed(id, outcome)
        }
    }

    /// Stop a download (or its check, or the compile) where it is. What has
    /// arrived stays in the `.partial` folder for the next try. Preparing
    /// isn't stopped: by then the model is installed and the one-time warm-up
    /// is cheaper finished than repeated.
    func cancel() {
        again = false
        guard let job else { return }
        switch state {
        case .downloading, .verifying, .compiling: break
        default: return
        }
        cancelling = true
        note("cancel")
        job.cancel()
    }

    /// Unload the model, then delete it and anything half-downloaded. Voice
    /// goes off with it, so the next launch doesn't fetch it all again.
    func remove() {
        ticket &+= 1
        let id = ticket
        let running = job
        running?.cancel()
        cancelling = false
        again = false
        state = .absent
        if VoicePrefs.shared.enabled { VoicePrefs.shared.enabled = false }
        note("remove")
        let home = home
        let journal = journal
        job = Task {
            _ = await running?.value
            if let unload = ModelStore.unloadHook { await unload() }
            await Self.delete(home, journal: journal)
            ModelStore.shared.removed(id)
        }
    }

    /// VoicePrefs' switch: on fetches a model that isn't here, off stops a
    /// download in flight. Neither ever deletes one.
    func voiceTurned(on: Bool) {
        if on {
            if cancelling {
                again = true
                return
            }
            switch state {
            case .absent, .failed: install()
            default: break
            }
        } else {
            cancel()
        }
    }

    // MARK: - answers from the job

    private func moved(_ id: Int, _ done: Int64) {
        guard id == ticket, case .downloading = state else { return }
        state = .downloading(min(1, Double(done) / Double(Self.totalBytes)))
    }

    private func entered(_ id: Int, _ phase: Phase) {
        guard id == ticket else { return }
        switch phase {
        case .verifying: state = .verifying
        case .compiling: state = .compiling
        }
    }

    private func landed(_ id: Int, _ outcome: Outcome) {
        guard id == ticket else { return }
        job = nil
        cancelling = false
        refresh()
        switch outcome {
        case .installed(let dir):
            note("installed at \(dir.path)")
            prepare(dir)
        case .cancelled:
            note("stopped with \(partialBytes) of \(Self.totalBytes) bytes kept")
            state = onDisk ? .ready : .absent
            if again {
                again = false
                if VoicePrefs.shared.enabled { install() }
            }
        case .failed(let why):
            note("failed: \(why)")
            state = .failed(why)
        }
    }

    /// The engine's one-time warm-up, when the app has given us one.
    private func prepare(_ dir: URL) {
        guard Self.prepareHook != nil else {
            state = .ready
            note("ready")
            return
        }
        ticket &+= 1
        let id = ticket
        state = .preparing
        note("preparing \(dir.path)")
        let journal = journal
        job = Task {
            var failure: String?
            if let hook = ModelStore.prepareHook {
                do {
                    try await hook(dir) { step in journal.write("prepare: \(step)") }
                } catch {
                    failure = error.localizedDescription
                }
            }
            ModelStore.shared.prepared(id, failure: failure)
        }
    }

    private func prepared(_ id: Int, failure: String?) {
        guard id == ticket else { return }
        job = nil
        if let failure {
            note("prepare failed: \(failure)")
            state = .failed("Couldn't prepare the speech model")
        } else {
            note("ready")
            state = .ready
        }
    }

    private func removed(_ id: Int) {
        guard id == ticket else { return }
        job = nil
        refresh()
        state = onDisk ? .ready : .absent
        note("removed")
    }

    // MARK: - what is on disk

    private func refresh() {
        onDisk = override != nil || Self.complete(installedDir, pinned: true)
        partialBytes = Self.bytesHere(stagingDir)
    }

    /// A probe world never pulls 345 MB from the internet on its own: it
    /// needs a stub (`SEARCH_VOICE_MODEL_BASE`) or `SEARCH_VOICE_ALLOW_DOWNLOAD=1`.
    private var downloadRefusal: String? {
        let environment = ProcessInfo.processInfo.environment
        if Store.testing, environment["SEARCH_VOICE_MODEL_BASE"] == nil, environment["SEARCH_VOICE_ALLOW_DOWNLOAD"] != "1" {
            return "Downloads are off in test worlds"
        }
        guard let base, Self.trusted(base, plainHTTP: Self.isLoopback(base)) else { return "Couldn't download" }
        return nil
    }

    private func note(_ line: String) { journal.write(line) }

    // MARK: - bench

    /// For a `voice model [status|install|cancel|remove]` bench verb (the
    /// `voice` verb's dispatch is wired in with the engine's): what the store
    /// is doing, as JSON, after doing `op`.
    func bench(_ op: String) -> [String: Any] {
        switch op {
        case "install": install()
        case "cancel": cancel()
        case "remove": remove()
        case "", "status": break
        default: return ["error": "voice model status|install|cancel|remove"]
        }
        var answer: [String: Any] = [
            "state": stateName,
            "onDisk": onDisk,
            "partialBytes": partialBytes,
            "totalBytes": Self.totalBytes,
            "revision": Self.revision,
            "home": home.path,
            "modelDir": modelDir?.path ?? NSNull(),
            "base": base?.absoluteString ?? NSNull(),
            "busy": job != nil,
            "enabled": VoicePrefs.shared.enabled,
            "supported": VoicePrefs.supported,
            "log": log.path,
        ]
        switch state {
        case .downloading(let fraction): answer["fraction"] = (fraction * 1000).rounded() / 1000
        case .failed(let why): answer["failure"] = why
        default: break
        }
        return answer
    }

    var stateName: String {
        switch state {
        case .absent: return "absent"
        case .downloading: return "downloading"
        case .verifying: return "verifying"
        case .compiling: return "compiling"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }

    private nonisolated static func base(_ raw: String?) -> URL? {
        var text = (raw ?? defaultBase).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    /// Only https leaves the Mac; plain http is for a stub on this one.
    nonisolated static func trusted(_ url: URL, plainHTTP: Bool) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return plainHTTP && isLoopback(url)
        default: return false
        }
    }

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    /// A folder the engine can load: the compiled model beside its manifest
    /// and decoder — and, for our own install, every pinned file at its size.
    nonisolated static func complete(_ dir: URL, pinned: Bool) -> Bool {
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(compiled).path, isDirectory: &folder),
              folder.boolValue else { return false }
        if pinned {
            return files.allSatisfy { size(of: dir.appendingPathComponent($0.path)) == $0.size }
        }
        return size(of: dir.appendingPathComponent("manifest.json")) != nil
            && size(of: dir.appendingPathComponent("decoder.bin")) != nil
    }

    nonisolated static func size(of file: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    nonisolated static func bytesHere(_ staging: URL) -> Int64 {
        files.reduce(0) { sum, file in
            sum + min(file.size, size(of: staging.appendingPathComponent(file.path)) ?? 0)
        }
    }
}

// MARK: - the work, off the main thread

extension ModelStore {
    fileprivate enum Phase: Sendable { case verifying, compiling }

    fileprivate enum Outcome: Sendable {
        case installed(URL)
        case cancelled
        case failed(String)
    }

    fileprivate struct Plan: Sendable {
        let base: URL
        let home: URL
        let models: URL
        let staging: URL
        let installed: URL
        let journal: ModelLog
        let plainHTTP: Bool
    }

    /// Room for the compiled copy beside the package, and some to spare.
    private nonisolated static let compiledBytes: Int64 = 360_000_000

    fileprivate nonisolated static func fetchVerifyCompile(
        _ plan: Plan,
        moved: @escaping @Sendable (Int64) -> Void,
        entered: @escaping @Sendable (Phase) async -> Void
    ) async -> Outcome {
        let fm = FileManager.default
        let journal = plan.journal
        do {
            try fm.createDirectory(at: plan.models, withIntermediateDirectories: true)
            // Downloadable, and big: no reason for Time Machine to keep it.
            var models = plan.models
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? models.setResourceValues(values)
            try fm.createDirectory(at: plan.staging, withIntermediateDirectories: true)
        } catch {
            journal.write("couldn't make \(plan.staging.path): \(error.localizedDescription)")
            return .failed("Couldn't make room for the speech model")
        }

        let here = bytesHere(plan.staging)
        let need = totalBytes - here + compiledBytes
        if let free = try? plan.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < need {
            journal.write("only \(free) bytes free, \(need) needed")
            return .failed("Not enough free space — the speech model needs about \(megabytes(need))")
        }

        // 1. Every file, carrying on from whatever the partial folder holds.
        let tags = ResumeTags(plan.staging.appendingPathComponent(".resume.json"))
        var before: Int64 = 0
        for file in files {
            if Task.isCancelled { return .cancelled }
            let dest = plan.staging.appendingPathComponent(file.path)
            let url = plan.base.appendingPathComponent(revision).appendingPathComponent(file.path)
            var attempt = 0
            while true {
                attempt += 1
                var have = size(of: dest) ?? 0
                if have > file.size {
                    try? fm.removeItem(at: dest)
                    have = 0
                }
                if have == file.size { break }
                if have == 0 { tags.set(file.path, nil) }
                let offset = before
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let answer = try await fetch(url, to: dest, file: file, from: have, tag: tags.tag(file.path),
                                                 plainHTTP: plan.plainHTTP,
                                                 began: { tag in tags.set(file.path, tag) },
                                                 moved: { written in moved(offset + written) })
                    journal.write("\(file.path): \(answer.how) → \(answer.status), \(file.size) bytes")
                    break
                } catch is CancellationError {
                    journal.write("\(file.path): stopped at \(size(of: dest) ?? 0) of \(file.size)")
                    return .cancelled
                } catch let failure as Fetch.Failure {
                    // The server's copy isn't the one the partial started
                    // from: that file begins again, once.
                    if case .changed(let why) = failure, attempt == 1 {
                        journal.write("\(file.path): resume refused (\(why)) — starting the file over")
                        try? fm.removeItem(at: dest)
                        continue
                    }
                    journal.write("\(file.path): \(failure.text)")
                    return .failed("Couldn't download")
                } catch {
                    journal.write("\(file.path): \(error.localizedDescription)")
                    return .failed("Couldn't download")
                }
            }
            before += file.size
        }

        // 2. The bytes are the pinned bytes, or they are nothing.
        await entered(.verifying)
        for file in files {
            if Task.isCancelled { return .cancelled }
            let dest = plan.staging.appendingPathComponent(file.path)
            let have = size(of: dest)
            let sum = have == file.size ? (try? sha256(of: dest)) : nil
            guard sum == file.sha256 else {
                journal.write("\(file.path): \(have ?? -1) bytes, sha256 \(sum ?? "unread") — expected \(file.sha256); partial deleted")
                try? fm.removeItem(at: plan.staging)
                return .failed("Couldn't verify the download")
            }
        }
        journal.write("verified \(files.count) files, \(totalBytes) bytes")

        // 3. Compiled for this Mac's Core ML, beside the package.
        if Task.isCancelled { return .cancelled }
        await entered(.compiling)
        let compiledHere = plan.staging.appendingPathComponent(compiled, isDirectory: true)
        try? fm.removeItem(at: compiledHere)
        let started = Date()
        let made: URL
        do {
            made = try await MLModel.compileModel(at: plan.staging.appendingPathComponent(package, isDirectory: true))
        } catch {
            journal.write("compile failed: \(error.localizedDescription)")
            return .failed("Couldn't prepare the speech model")
        }
        if Task.isCancelled {
            try? fm.removeItem(at: made)
            return .cancelled
        }
        do {
            try fm.moveItem(at: made, to: compiledHere)
        } catch {
            try? fm.removeItem(at: made)
            journal.write("couldn't keep the compiled model: \(error.localizedDescription)")
            return .failed("Couldn't prepare the speech model")
        }
        journal.write(String(format: "compiled in %.1f s", Date().timeIntervalSince(started)))

        // 4. In place in one rename, then `current` repointed in another.
        try? fm.removeItem(at: plan.staging.appendingPathComponent(".resume.json"))
        do {
            if fm.fileExists(atPath: plan.installed.path) { try fm.removeItem(at: plan.installed) }
            try fm.moveItem(at: plan.staging, to: plan.installed)
            try pointCurrent(in: plan.home)
        } catch {
            journal.write("install failed: \(error.localizedDescription)")
            return .failed("Couldn't install the speech model")
        }
        // Other revisions and their partials: an older pin's leftovers.
        for entry in (try? fm.contentsOfDirectory(at: plan.home, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent != revision && entry.lastPathComponent != "current" {
            try? fm.removeItem(at: entry)
        }
        return .installed(plan.installed)
    }

    /// `current` → the revision, swapped with rename(2) so a reader sees the
    /// old pointer or the new one, never none.
    private nonisolated static func pointCurrent(in home: URL) throws {
        let link = home.appendingPathComponent("current")
        let temp = home.appendingPathComponent(".current-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: temp)
        try FileManager.default.createSymbolicLink(atPath: temp.path, withDestinationPath: revision)
        guard rename(temp.path, link.path) == 0 else {
            let why = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: "ModelStore", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: why])
        }
    }

    fileprivate nonisolated static func delete(_ home: URL, journal: ModelLog) async {
        do {
            if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
        } catch {
            journal.write("remove failed: \(error.localizedDescription)")
        }
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

    /// One file over HTTP, appended to `dest` as it arrives.
    private nonisolated static func fetch(
        _ url: URL, to dest: URL, file: ModelFile, from have: Int64, tag: String?, plainHTTP: Bool,
        began: @escaping @Sendable (String?) -> Void, moved: @escaping @Sendable (Int64) -> Void
    ) async throws -> Fetch.Answer {
        let transfer = Fetch(dest: dest, have: have, expected: file.size, knownTag: tag, plainHTTP: plainHTTP,
                             began: began, moved: moved)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A stall is reported after a minute; a slow line is let finish.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 4 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        Fetch.dress(&request, from: have)
        return try await transfer.run(session.dataTask(with: request))
    }
}

// MARK: - one transfer

/// A data task's bytes written straight to disk as they arrive, so the
/// 329 MB weight never sits in memory and a cut-off one resumes from its
/// length: `Range: bytes=N-`, taken only as a 206 for exactly that range of
/// a file of exactly the pinned size (and the same ETag, when one was seen);
/// a 200 means the server sent it whole, so the file starts over.
private final class Fetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error {
        case status(Int)
        case changed(String)
        case size(Int64)
        case disk(String)
        case redirect(String)

        var text: String {
            switch self {
            case .status(let code): return "answered \(code)"
            case .changed(let why): return "changed: \(why)"
            case .size(let n): return "wrong size: \(n) bytes"
            case .disk(let why): return "couldn't write: \(why)"
            case .redirect(let to): return "redirect refused: \(to)"
            }
        }
    }

    struct Answer: Sendable {
        let status: Int
        let how: String
    }

    private let dest: URL
    private let have: Int64
    private let expected: Int64
    private let knownTag: String?
    private let plainHTTP: Bool
    private let began: @Sendable (String?) -> Void
    private let moved: @Sendable (Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Answer, Error>?
    private var task: URLSessionTask?
    private var cancelled = false

    // The delegate queue's alone.
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var reported: Int64 = 0
    private var status = 0
    private var how = ""
    private var failure: Failure?

    init(dest: URL, have: Int64, expected: Int64, knownTag: String?, plainHTTP: Bool,
         began: @escaping @Sendable (String?) -> Void, moved: @escaping @Sendable (Int64) -> Void) {
        self.dest = dest
        self.have = have
        self.expected = expected
        self.knownTag = knownTag
        self.plainHTTP = plainHTTP
        self.began = began
        self.moved = moved
    }

    static func dress(_ request: inout URLRequest, from have: Int64) {
        // Byte offsets must be the file's own, not a compressed stream's.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
    }

    func run(_ task: URLSessionDataTask) async throws -> Answer {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Answer, Error>) in
                let stop: Bool = lock.withLock {
                    self.continuation = continuation
                    self.task = task
                    return cancelled
                }
                task.resume()
                if stop { task.cancel() }
            }
        } onCancel: {
            let task: URLSessionTask? = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, ModelStore.trusted(next, plainHTTP: plainHTTP) else {
            failure = .redirect(request.url?.scheme ?? "nowhere")
            completionHandler(nil)
            return
        }
        // Hugging Face sends large files on to its CDN; the range goes too.
        var request = request
        Fetch.dress(&request, from: have)
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            failure = .status(0)
            completionHandler(.cancel)
            return
        }
        status = http.statusCode
        let tag = http.value(forHTTPHeaderField: "ETag")
        do {
            switch http.statusCode {
            case 206 where have > 0:
                let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range"))
                guard let range, range.start == have, range.total == expected else {
                    throw Failure.changed("Content-Range \(http.value(forHTTPHeaderField: "Content-Range") ?? "missing")")
                }
                if let knownTag, let tag, knownTag != tag { throw Failure.changed("ETag \(tag), was \(knownTag)") }
                let file = try FileHandle(forWritingTo: dest)
                try file.seekToEnd()
                handle = file
                written = have
                how = "resumed at \(have)"
            case 200:
                if http.expectedContentLength >= 0, http.expectedContentLength != expected {
                    throw Failure.size(http.expectedContentLength)
                }
                guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
                    throw Failure.disk(dest.lastPathComponent)
                }
                handle = try FileHandle(forWritingTo: dest)
                written = 0
                how = have > 0 ? "sent whole (asked from \(have)), started over" : "fetched"
            default:
                throw Failure.status(http.statusCode)
            }
            began(tag)
            completionHandler(.allow)
        } catch let error as Failure {
            failure = error
            completionHandler(.cancel)
        } catch {
            failure = .disk(error.localizedDescription)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = .disk(error.localizedDescription)
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        if written > expected {
            failure = .size(written)
            dataTask.cancel()
            return
        }
        // Whole percents of this file, or the last byte: plenty for a bar.
        if written == expected || (written - reported) * 100 >= expected || written - reported >= 4 << 20 {
            reported = written
            moved(written)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let stopped = lock.withLock { cancelled }
        let result: Result<Answer, Error>
        if stopped {
            result = .failure(CancellationError())
        } else if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(error)
        } else if written != expected {
            result = .failure(Failure.size(written))
        } else {
            result = .success(Answer(status: status, how: how))
        }
        let waiting: CheckedContinuation<Answer, Error>? = lock.withLock {
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }

    /// "bytes 100-199/200" → (100, 200).
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64)? {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst(6)
        let halves = spec.split(separator: "/", maxSplits: 1)
        guard halves.count == 2, let total = Int64(halves[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        guard let dash = halves[0].firstIndex(of: "-"),
              let start = Int64(halves[0][..<dash].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (start, total)
    }
}

// MARK: - small pieces

/// Which ETag each partial file was begun under, kept beside them so a resume
/// after a relaunch can tell the server's copy hasn't changed underneath it.
private final class ResumeTags: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var tags: [String: String]

    init(_ url: URL) {
        self.url = url
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        tags = saved ?? [:]
    }

    func tag(_ path: String) -> String? { lock.withLock { tags[path] } }

    func set(_ path: String, _ tag: String?) {
        lock.withLock {
            guard tags[path] != tag else { return }
            tags[path] = tag
            if let data = try? JSONEncoder().encode(tags) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// `Models/voice-model.log`: each download, resume, refusal and install, one
/// line each. Never a word of speech — there is none here to write.
final class ModelLog: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    init(_ url: URL) { self.url = url }

    func write(_ line: String) {
        lock.withLock {
            let files = FileManager.default
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Small and current: past 256 KB the old half goes aside.
            if let size = ModelStore.size(of: url), size > 256 << 10 {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? files.removeItem(at: old)
                try? files.moveItem(at: url, to: old)
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(stamp) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
