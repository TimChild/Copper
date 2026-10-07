import CoreML
import Foundation

// Copper Voice: speech to text on this Mac, with Fermion Research's Phonon-2
// on Core ML (the runner is vendored in Fork/Voice/Phonon; its header says
// what changed). Audio goes in as 16 kHz mono samples and text comes back;
// nothing is recorded and nothing leaves the Mac. The one write is the
// compiled model, beside the package, the first time a folder is loaded.
//
// `Swift.Float`, not `Float`: in this module `Float` is the picture-in-
// picture window (Float.swift).
//
// The model is one multifunction package with an encoder per window length
// (5, 10, 15 and 35 s). Each one the Neural Engine runs has to be prepared
// for this Mac first — about a minute, once per function, per compiled-model
// path, per app (macOS keeps that cache under the app's own Caches folder,
// so a model another program prepared is prepared again here). The engine
// loads the 15 s function only: one minute of preparation instead of four,
// and every utterance up to 15 s decodes in 20–50 ms on an M5 regardless,
// because a short clip is masked inside the same window (measured: T-001
// handoff, assumption A-2). Longer audio is cut at pauses into windows that
// fit it, by the runner.
//
// Loading and decoding block a thread for their whole length, so they run on
// a serial queue of the engine's own — never on the main thread, and never
// on the cooperative pool the rest of the app's async work shares. Serial
// also because the runner's long-audio decoder pool belongs to one call.

/// One word as heard, with its time in seconds from the start of the audio.
struct VoiceWord: Sendable, Equatable { let text: String; let start: Double; let end: Double }

/// What was said: the text (the model writes its own casing and punctuation)
/// and its words.
struct VoiceHypothesis: Sendable, Equatable { let text: String; let words: [VoiceWord] }

/// Why the engine said no, in words a person can act on.
enum VoiceEngineError: LocalizedError, Equatable {
    /// `transcribe` before `prepare` finished (or after `unload`).
    case notReady
    /// The model folder lacks one of its files.
    case missingFile(String)
    /// The compiled model has to be written beside the package, and the folder can't be written.
    case notWritable(String)
    case compileFailed(String)
    /// The folder holds something other than the Phonon-2 Core ML model this runner expects.
    case unexpectedModel(String)
    /// A later `prepare` (another folder) or `unload` replaced this one before it finished.
    case superseded

    var errorDescription: String? {
        switch self {
        case .notReady: return "The speech model isn't loaded yet."
        case .missingFile(let name): return "The speech model folder is missing \(name)."
        case .notWritable(let path): return "The speech model needs compiling, and \(path) can't be written to."
        case .compileFailed(let why): return "The speech model didn't compile: \(why)"
        case .unexpectedModel(let why): return "That isn't the Phonon-2 speech model: \(why)"
        case .superseded: return "The speech model was unloaded or replaced while it loaded."
        }
    }
}

@available(macOS 15, *)
actor VoiceEngine {
    static let shared = VoiceEngine()

    /// The runner, loaded. It has locks of its own and is only ever called
    /// on `work`, which is what makes handing it between threads sound.
    private final class Loaded: @unchecked Sendable {
        let transcriber: Transcriber
        let dir: URL
        let key: String
        let seconds: Double
        init(transcriber: Transcriber, dir: URL, key: String, seconds: Double) {
            self.transcriber = transcriber
            self.dir = dir
            self.key = key
            self.seconds = seconds
        }
    }

    private struct Pending {
        let key: String
        let generation: Int
        let task: Task<Loaded, Error>
    }

    private var loaded: Loaded?
    private var pending: Pending?
    /// Bumped by every load and unload, so a load that finishes after it
    /// was replaced is dropped rather than installed.
    private var generation = 0

    private static let work = DispatchQueue(label: "copper.voice.engine", qos: .userInitiated)

    /// The window the engine loads (seconds), and the longest audio decoded
    /// as one window: a hair under 15 s, because 15.000 s of samples makes
    /// 1,500 mel frames plus the runner's 20 ms margin, which no longer fits
    /// the 15 s function (the runner's own long-audio windows stop 400
    /// samples short for the same reason). Longer goes to its windowing.
    static let function: Double = 15
    static let singleWindowSeconds = 14.975

    var isReady: Bool { loaded != nil }
    /// The folder the loaded model came from.
    var modelDir: URL? { loaded?.dir }
    /// How long the last finished load took, in seconds — a minute and more
    /// the first time on this Mac, a third of a second after.
    var loadSeconds: Double? { loaded?.seconds }

    /// Loads the model in `modelDir` (manifest.json, decoder.bin,
    /// Phonon-2.mlpackage and, once compiled, Phonon-2.mlmodelc beside it).
    /// Compiles in place only when Phonon-2.mlmodelc is missing. Idempotent:
    /// the same folder again is a no-op (or joins the load in flight); a
    /// different folder unloads the current model and loads that one.
    ///
    /// `progress` hears, in order and from a background thread: "compiling"
    /// and "compiled" (only when the package had to be compiled),
    /// "loading enc_15s" (the long step, the first time on this Mac),
    /// "loaded enc_15s", "warming", "ready".
    func prepare(modelDir: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        let dir = modelDir.standardizedFileURL
        let key = dir.resolvingSymlinksInPath().path
        if let loaded, loaded.key == key { return }
        if let pending, pending.key == key { try await finish(pending); return }
        loaded = nil
        generation += 1
        let job = Pending(key: key, generation: generation, task: Task.detached(priority: .userInitiated) {
            try await VoiceEngine.load(dir, key: key, progress: progress)
        })
        pending = job
        try await finish(job)
    }

    /// Every caller waiting on a load installs its result the same way, so
    /// whichever of them resumes first leaves the engine ready for all.
    private func finish(_ job: Pending) async throws {
        do {
            let done = try await job.task.value
            guard job.generation == generation else { throw VoiceEngineError.superseded }
            loaded = done
            if pending?.generation == job.generation { pending = nil }
        } catch {
            if pending?.generation == job.generation { pending = nil }
            throw error
        }
    }

    /// 16 kHz mono samples, any length, to text. Empty or silent audio is
    /// "" without asking the model (the runner's own silence rule: nothing
    /// louder than 1e-4); near-silence the model hears as nothing, too.
    func transcribe(_ samples16k: [Swift.Float]) async throws -> VoiceHypothesis {
        if Segmenter.isSilent(samples16k[...]) { return VoiceHypothesis(text: "", words: []) }
        guard let loaded else { throw VoiceEngineError.notReady }
        return try await withCheckedThrowingContinuation { continuation in
            VoiceEngine.work.async {
                do {
                    let heard = try loaded.transcriber.transcribe(samples16k)
                    continuation.resume(returning: VoiceEngine.hypothesis(heard))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Lets the model go (100–200 MB). A load still in flight finishes on
    /// its queue and is dropped; a decode in flight finishes first.
    func unload() {
        generation += 1
        pending = nil
        loaded = nil
    }

    // MARK: - loading

    private static func load(_ dir: URL, key: String, progress: @escaping @Sendable (String) -> Void) async throws -> Loaded {
        let started = Date()
        let files = FileManager.default
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard files.fileExists(atPath: manifestURL.path) else { throw VoiceEngineError.missingFile("manifest.json") }
        guard files.fileExists(atPath: dir.appendingPathComponent("decoder.bin").path) else { throw VoiceEngineError.missingFile("decoder.bin") }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw VoiceEngineError.unexpectedModel("manifest.json doesn't read (\(error.localizedDescription))")
        }
        guard manifest.functions_s.contains(function) else {
            throw VoiceEngineError.unexpectedModel("it has no \(Int(function)) s encoder")
        }
        // The runner prefers a compiled model beside the package, under the
        // package's name; it is only compiled when that isn't there yet.
        let package = dir.appendingPathComponent(manifest.multifunction)
        let compiled = dir.appendingPathComponent((manifest.multifunction as NSString).deletingPathExtension)
            .appendingPathExtension("mlmodelc")
        if !files.fileExists(atPath: compiled.path) {
            guard files.fileExists(atPath: package.path) else { throw VoiceEngineError.missingFile(manifest.multifunction) }
            guard files.isWritableFile(atPath: dir.path) else { throw VoiceEngineError.notWritable(dir.path) }
            progress("compiling")
            try await compile(package, to: compiled)
            progress("compiled")
        }
        return try await withCheckedThrowingContinuation { continuation in
            work.async {
                do {
                    var options = Transcriber.Options()
                    options.functions = [function]
                    options.eagerFunctions = [function]
                    options.singleShotMaxSeconds = singleWindowSeconds
                    // The runner's own "compiled" (said even when nothing was)
                    // stays out; its loading lines are the ones worth hearing.
                    options.progress = { phase, _ in if phase.hasPrefix("load") { progress(phase) } }
                    let transcriber = try Transcriber(bundle: dir, options: options)
                    // The runner reads its one output by name and trusts it;
                    // a package that lacks it is turned away here instead.
                    guard try transcriber.loadFunction(Int(function)).modelDescription.outputDescriptionsByName["enc"] != nil else {
                        throw VoiceEngineError.unexpectedModel("its encoder has no `enc` output")
                    }
                    // One decode now, so the first one a person waits on is
                    // as quick as every later one.
                    progress("warming")
                    _ = try transcriber.transcribe(warmUp)
                    progress("ready")
                    continuation.resume(returning: Loaded(transcriber: transcriber, dir: dir, key: key, seconds: Date().timeIntervalSince(started)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Compiles the package and puts the result in place in two steps — a
    /// move beside it under a temporary name, then a rename — so an
    /// interrupted install never leaves a half-written model the runner
    /// would take for a whole one.
    private static func compile(_ package: URL, to compiled: URL) async throws {
        let built: URL
        do { built = try await MLModel.compileModel(at: package) } catch {
            throw VoiceEngineError.compileFailed(error.localizedDescription)
        }
        let files = FileManager.default
        let staging = compiled.deletingLastPathComponent()
            .appendingPathComponent(".\(compiled.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try files.moveItem(at: built, to: staging)
            try files.moveItem(at: staging, to: compiled)
        } catch {
            try? files.removeItem(at: staging)
            try? files.removeItem(at: built)
            // Another load got there first: theirs is as good as ours.
            if !files.fileExists(atPath: compiled.path) { throw VoiceEngineError.notWritable(compiled.deletingLastPathComponent().path) }
        }
    }

    /// A second of quiet noise: enough to run the encoder and the decoder
    /// once. What it decodes to is thrown away.
    private static let warmUp: [Swift.Float] = {
        var state: UInt32 = 0x9E37_79B9
        return (0..<16_000).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Swift.Float(state >> 8) / Swift.Float(1 << 24) - 0.5) * 0.02
        }
    }()

    private static func hypothesis(_ heard: PhononTranscript) -> VoiceHypothesis {
        VoiceHypothesis(
            text: heard.text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: heard.words.map { VoiceWord(text: $0.text, start: $0.start, end: $0.end) }
        )
    }
}
