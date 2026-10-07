import AVFoundation
import Foundation

// `./bench --world W voice …` — the speech engine, checked from the shell
// without a microphone anywhere near it (VoiceEngine.swift).
//
//   voice selftest      pure checks; then, with SEARCH_VOICE_MODEL_DIR set to a
//                       ready model folder, three clips spoken in-process (a
//                       dictation with technical words, a ~12 s paragraph,
//                       5 s of room-quiet) transcribed and scored; then every
//                       check in `extraChecks`. Answers
//                       {failures, checks, timings, clips, model, skipped?}.
//   voice replay PATH   one audio file → {text, words, audio_s, decode_ms}
//   voice status        what the engine has loaded
//   voice result        the last selftest/replay's answer, for a run that
//                       outlasted the bench's 25 s (./bench asks for it)
//
// The first load on a Mac prepares the Neural Engine for about a minute, so
// a selftest or replay runs as a job: the answer comes within 20 s when the
// job is done by then, and otherwise `{"running": true}`, after which
// ./bench polls `voice result` until it is.

enum VoiceBench {
    /// Checks the other voice pieces add; `voice selftest` runs every one and
    /// reports each one's failures (an empty list is a pass). Dictation adds
    /// its own at launch (VoiceChecks in DictationBench.swift): the live
    /// session on the real decoder, a 15.00 s clip, the composer insert, keys.
    static var extraChecks: [(name: String, run: () async -> [String])] = []

    /// The model folder tests use: SEARCH_VOICE_MODEL_DIR, when it names a
    /// folder. In the app, ModelStore decides.
    static var testModelDir: URL? {
        guard let path = ProcessInfo.processInfo.environment["SEARCH_VOICE_MODEL_DIR"], !path.isEmpty else { return nil }
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &folder), folder.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - the verb

    @MainActor static func handle(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        let op = request["op"] as? String ?? "status"
        switch op {
        case "selftest":
            run("selftest", answer: answer) { await selftest() }
        case "replay":
            let path = (request["path"] as? String) ?? (request["arg"] as? String) ?? ""
            guard !path.isEmpty else { answer(["error": "usage: voice replay PATH"]); return }
            run("replay", answer: answer) { await replay(URL(fileURLWithPath: path)) }
        case "result":
            if let job { answer(["running": true, "job": job.name]) }
            else if let last { answer(last.answer) }
            else { answer(["error": "no voice selftest or replay has run in this process"]) }
        case "status":
            Task { @MainActor in answer(await status()) }
        default:
            // Dictation's verbs (DictationBench.swift): dictate, source, key, warm, seed, render, prefs, model, state, editor.
            let args = request["args"] as? [String] ?? []
            let handled = DictationBench.handle(op, args, in: Windows.main, answer: answer) { name, work in
                run(name, answer: answer, work)
            }
            if !handled {
                answer(["error": "unknown voice operation \(op) — selftest, replay PATH, status, result, dictate PATH, source, key, warm, seed, render, prefs, model, state, editor"])
            }
        }
    }

    @MainActor private static var job: (name: String, task: Task<Void, Never>)?
    @MainActor private static var last: (name: String, answer: [String: Any])?

    /// One job at a time. The answer comes when the job is done or after
    /// 20 s, whichever is first; after that, `voice result` has it.
    @MainActor private static func run(_ name: String, answer: @escaping ([String: Any]) -> Void, _ work: @escaping @MainActor () async -> [String: Any]) {
        if let job {
            answer(["error": "voice \(job.name) is still running — `voice result` answers when it is done"])
            return
        }
        last = nil
        let task = Task { @MainActor in
            let finished = await work()
            last = (name, finished)
            job = nil
        }
        job = (name, task)
        var given = false
        let give: ([String: Any]) -> Void = { reply in
            guard !given else { return }
            given = true
            answer(reply)
        }
        Task { @MainActor in
            await task.value
            if let last { give(last.answer) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { give(["running": true, "job": name]) }
    }

    @MainActor private static func status() async -> [String: Any] {
        var out: [String: Any] = ["supported": false, "testModelDir": testModelDir?.path ?? "", "job": job?.name ?? ""]
        if #available(macOS 15, *) {
            let engine = VoiceEngine.shared
            out["supported"] = true
            out["ready"] = await engine.isReady
            out["modelDir"] = await engine.modelDir?.path ?? ""
            if let seconds = await engine.loadSeconds { out["load_s"] = rounded(seconds, 3) }
        }
        return out
    }

    // MARK: - selftest

    /// One clip the selftest speaks and scores.
    private struct Clip {
        let name: String
        let text: String       // what is spoken; "" for the quiet clip
        let quiet: Double      // seconds of room-quiet instead of speech
    }

    private static let clips = [
        Clip(name: "dictation",
             text: "Open the Copper agent pane, check the API logs on the staging server, and file a bug for the failing Swift build.",
             quiet: 0),
        Clip(name: "paragraph",
             text: "This morning the release manager opened the agent pane and checked the dashboard. The first card showed a pending "
                 + "pull request for a small accessibility fix. She asked the assistant to compare the colors with the design guide.",
             quiet: 0),
        Clip(name: "silence", text: "", quiet: 5),
    ]

    @MainActor static func selftest() async -> [String: Any] {
        var failures: [String] = []
        var checks: [[String: Any]] = []
        var timings: [String: Any] = [:]
        var out: [String: Any] = [:]
        func check(_ name: String, _ problems: [String], _ detail: String = "") {
            failures += problems.map { "\(name): \($0)" }
            var row: [String: Any] = ["name": name, "ok": problems.isEmpty]
            if !detail.isEmpty { row["detail"] = detail }
            checks.append(row)
        }

        // (a) Pure: nothing here needs the model. Off the main thread, like
        // everything here that computes.
        let started = Date()
        for (name, problems, detail) in await Task.detached(priority: .userInitiated, operation: { pureChecks() }).value {
            check(name, problems, detail)
        }
        if #available(macOS 15, *) {
            for (name, problems, detail) in await engineChecks() { check(name, problems, detail) }
        }
        timings["pure_ms"] = rounded(Date().timeIntervalSince(started) * 1000, 1)

        // (b) The model, when a ready folder is named.
        if #available(macOS 15, *) {
            if let dir = testModelDir {
                await modelChecks(dir, check: check, timings: &timings, out: &out)
            } else {
                out["skipped"] = "model absent"
                checks.append(["name": "model", "ok": true, "skipped": "model absent (set SEARCH_VOICE_MODEL_DIR to a ready model folder)"])
            }
        } else {
            out["skipped"] = "requires macOS 15"
            checks.append(["name": "model", "ok": true, "skipped": "requires macOS 15"])
        }

        // (c) Everything the other voice pieces registered.
        for extra in extraChecks {
            let t = Date()
            let problems = await extra.run()
            check(extra.name, problems, "\(rounded(Date().timeIntervalSince(t) * 1000, 1)) ms")
        }

        out["failures"] = failures
        out["checks"] = checks
        out["timings"] = timings
        return out
    }

    /// The arithmetic around the model: resampling, word assembly, the
    /// 15 s window's frame budget, scoring.
    private static func pureChecks() -> [(String, [String], String)] {
        var rows: [(String, [String], String)] = []

        // A 44.1 kHz stereo Int16 tone, both channels the same, comes out a
        // 16 kHz mono tone of the same level and pitch.
        do {
            var problems: [String] = []
            var detail = ""
            let rate = 44_100.0, pitch = 440.0, level: Swift.Float = 0.5
            if let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 2, interleaved: false),
               let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)),
               let channels = buffer.int16ChannelData {
                for i in 0..<Int(rate) {
                    let v = Int16((level * sin(Swift.Float(2 * Double.pi * pitch * Double(i) / rate))) * 32_767)
                    channels[0][i] = v
                    channels[1][i] = v
                }
                buffer.frameLength = AVAudioFrameCount(rate)
                if let mono = mono16k(buffer) {
                    let rms = (mono.reduce(0) { $0 + $1 * $1 } / Swift.Float(max(1, mono.count))).squareRoot()
                    let middle = mono.dropFirst(800).dropLast(800)
                    var crossings = 0
                    var previous = middle.first ?? 0
                    for v in middle.dropFirst() { if (previous < 0) != (v < 0) { crossings += 1 }; previous = v }
                    let perSecond = Double(crossings) / (Double(middle.count) / 16_000)
                    detail = "\(mono.count) samples, rms \(rounded(Double(rms), 4)), \(Int(perSecond.rounded())) zero crossings/s"
                    if abs(mono.count - 16_000) > 2 { problems.append("\(mono.count) samples for 1 s, wanted 16000") }
                    if abs(Double(rms) - Double(level) / 2.squareRoot()) > 0.02 { problems.append("rms \(rms), wanted ≈ \(Double(level) / 2.squareRoot())") }
                    if abs(perSecond - 2 * pitch) > 10 { problems.append("\(perSecond) zero crossings/s, wanted ≈ \(2 * pitch)") }
                } else {
                    problems.append("the converter refused it")
                }
            } else {
                problems.append("couldn't make the test buffer")
            }
            rows.append(("resample 44.1 kHz stereo → 16 kHz mono", problems, detail))
        }

        // Already 16 kHz: handed back as it is.
        do {
            let ramp = (0..<1600).map { Swift.Float($0) / 1600 }
            let same = resample(ramp, from: 16_000)
            rows.append(("resample 16 kHz passthrough", same == ramp ? [] : ["16 kHz input changed"], ""))
        }

        // Scoring the transcripts: normalisation and word error rate.
        do {
            var problems: [String] = []
            if normalized("Hello, World! It's 5 o'clock.") != ["hello", "world", "its", "5", "oclock"] {
                problems.append("normalized gave \(normalized("Hello, World! It's 5 o'clock."))")
            }
            if wordErrorRate(reference: "the cat sat on the mat", heard: "The cat sat on the mat.") != 0 { problems.append("identical text scored above 0") }
            let wer = wordErrorRate(reference: "a b c d", heard: "a x c")
            if abs(wer - 0.5) > 1e-9 { problems.append("one substitution and one deletion in four words scored \(wer), wanted 0.5") }
            rows.append(("word error rate", problems, ""))
        }

        if #available(macOS 15, *) {
            // The 15 s window: 15.000 s of samples is one window too many
            // frames for the 15 s function (1,500 + the runner's 20 ms margin),
            // so audio past 14.975 s is windowed, and every window fits.
            do {
                var problems: [String] = []
                if Transcriber.framesFor(seconds: 15) != 1501 { problems.append("framesFor(15) = \(Transcriber.framesFor(seconds: 15)), wanted 1501") }
                if Transcriber.subLen(1501) != 188 { problems.append("subLen(1501) = \(Transcriber.subLen(1501)), wanted 188") }
                var longest = 0
                for seconds in [14.9, 14.975, 15.0, 15.02, 22.5, 31.0, 61.0] {
                    let n = Int(seconds * 16_000)
                    let rms = [Swift.Float](repeating: 0.1, count: (n + 799) / 800)
                    let windows = Windower.plan(rms: rms, count: n, singleShotMaxS: VoiceEngine.singleWindowSeconds)
                    for w in windows {
                        let frames = (w.end - w.start) / 160
                        longest = max(longest, w.end - w.start)
                        if Double(frames) * 0.01 + 0.02 > VoiceEngine.function {
                            problems.append("a \(seconds) s clip makes a \(w.end - w.start)-sample window, too long for the 15 s function")
                        }
                    }
                    if windows.first?.start != 0 || windows.last?.end != n { problems.append("windows for \(seconds) s don't cover it") }
                }
                rows.append(("15 s window frame budget", problems, "longest window \(longest) samples"))
            }

            // Words from tokens: a leading space starts a word, punctuation
            // joins the word before, times are seconds plus the window's offset.
            do {
                let tokens = [TimedToken(piece: " Hello", start: 0.08, duration: 0.24),
                              TimedToken(piece: ",", start: 0.32, duration: 0.08),
                              TimedToken(piece: " wor", start: 0.48, duration: 0.16),
                              TimedToken(piece: "ld", start: 0.64, duration: 0.16),
                              TimedToken(piece: ".", start: 0.80, duration: 0.08)]
                let words = Words.fromTokens(tokens, offset: 1.0, limit: nil)
                let wanted = [Word(text: "Hello,", start: 1.08, end: 1.4), Word(text: "world.", start: 1.48, end: 1.88)]
                rows.append(("words from tokens", words == wanted ? [] : ["got \(words)"], ""))
            }

            // The front end: a second of tone is 100 frames of 128 finite values.
            do {
                let tone = (0..<16_000).map { Swift.Float(0.3 * sin(2 * Double.pi * 300 * Double($0) / 16_000)) }
                let (features, frames) = LogMel().features(tone)
                var problems: [String] = []
                if frames != 100 { problems.append("\(frames) frames for 1 s, wanted 100") }
                if features.count != 128 * frames { problems.append("\(features.count) values for \(frames) frames") }
                if features.contains(where: { !$0.isFinite }) { problems.append("non-finite features") }
                rows.append(("log-mel front end", problems, ""))
            }
        }
        return rows
    }

    /// What the engine promises without a model: empty and silent audio is
    /// "" and costs nothing.
    @available(macOS 15, *)
    private static func engineChecks() async -> [(String, [String], String)] {
        var problems: [String] = []
        for (label, samples) in [("empty", [Swift.Float]()), ("5 s of digital silence", [Swift.Float](repeating: 0, count: 80_000))] {
            do {
                let heard = try await VoiceEngine.shared.transcribe(samples)
                if heard != VoiceHypothesis(text: "", words: []) { problems.append("\(label) gave “\(heard.text)”") }
            } catch {
                problems.append("\(label) threw \(error.localizedDescription)")
            }
        }
        return [("empty and silent audio → \"\"", problems, "")]
    }

    @available(macOS 15, *)
    @MainActor private static func modelChecks(_ dir: URL, check: (String, [String], String) -> Void,
                                               timings: inout [String: Any], out: inout [String: Any]) async {
        let engine = VoiceEngine.shared
        let wasReady = await engine.isReady
        let loading = Date()
        do {
            try await engine.prepare(modelDir: dir) { _ in }
        } catch {
            check("prepare", [error.localizedDescription], dir.path)
            return
        }
        timings["prepare_s"] = rounded(Date().timeIntervalSince(loading), 3)
        if let seconds = await engine.loadSeconds { timings["load_s"] = rounded(seconds, 3) }
        out["model"] = ["dir": dir.path, "function_s": VoiceEngine.function, "already_loaded": wasReady]
        check("prepare", [], "\(rounded(Date().timeIntervalSince(loading), 2)) s" + (wasReady ? " (already loaded)" : ""))

        var reports: [[String: Any]] = []
        for clip in clips {
            var problems: [String] = []
            let making = Date()
            let made: (samples: [Swift.Float], how: String)?
            if clip.text.isEmpty { made = (roomQuiet(seconds: clip.quiet), "generated") } else { made = await speak(clip.text) }
            guard let made, !made.samples.isEmpty else {
                check("clip \(clip.name)", ["couldn't synthesize it (AVSpeechSynthesizer and /usr/bin/say both failed)"], "")
                continue
            }
            let synthMs = rounded(Date().timeIntervalSince(making) * 1000, 1)
            let decoding = Date()
            let heard: VoiceHypothesis
            do { heard = try await engine.transcribe(made.samples) } catch {
                check("clip \(clip.name)", ["transcribe threw \(error.localizedDescription)"], "")
                continue
            }
            let decodeMs = rounded(Date().timeIntervalSince(decoding) * 1000, 1)
            let audio = rounded(Double(made.samples.count) / 16_000, 2)
            var report: [String: Any] = ["name": clip.name, "audio_s": audio, "decode_ms": decodeMs, "synth_ms": synthMs,
                                         "synth": made.how, "text": heard.text, "words": heard.words.count]
            if clip.text.isEmpty {
                if !heard.text.isEmpty { problems.append("\(audio) s of quiet gave “\(heard.text)”") }
            } else {
                let wer = wordErrorRate(reference: clip.text, heard: heard.text)
                report["expected"] = clip.text
                report["wer"] = rounded(wer, 4)
                if wer > 0.15 { problems.append("word error rate \(rounded(wer * 100, 1))% > 15%: heard “\(heard.text)”") }
                if heard.words.isEmpty || heard.words.contains(where: { $0.end < $0.start }) { problems.append("words missing or timed backwards") }
            }
            if decodeMs >= 200 { problems.append("decode took \(decodeMs) ms, wanted < 200 ms warm") }
            timings["\(clip.name)_decode_ms"] = decodeMs
            reports.append(report)
            var detail = "\(audio) s audio, \(decodeMs) ms"
            if let wer = report["wer"] as? Double { detail += ", WER \(rounded(wer * 100, 1))%" }
            check("clip \(clip.name)", problems, detail)
        }
        out["clips"] = reports
    }

    // MARK: - replay

    @MainActor private static func replay(_ url: URL) async -> [String: Any] {
        guard #available(macOS 15, *) else { return ["error": "voice needs macOS 15"] }
        let engine = VoiceEngine.shared
        var loadS: Double?
        if !(await engine.isReady) {
            guard let dir = testModelDir else { return ["error": "model absent — set SEARCH_VOICE_MODEL_DIR to a ready model folder"] }
            let loading = Date()
            do { try await engine.prepare(modelDir: dir) { _ in } } catch { return ["error": "prepare: \(error.localizedDescription)"] }
            loadS = Date().timeIntervalSince(loading)
        }
        let samples: [Swift.Float]
        do { samples = try await Task.detached(priority: .userInitiated, operation: { try read(url) }).value } catch {
            return ["error": "\(url.path): \(error.localizedDescription)"]
        }
        let decoding = Date()
        do {
            let heard = try await engine.transcribe(samples)
            var out: [String: Any] = [
                "text": heard.text,
                "words": heard.words.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] },
                "audio_s": rounded(Double(samples.count) / 16_000, 3),
                "decode_ms": rounded(Date().timeIntervalSince(decoding) * 1000, 1),
            ]
            if let loadS { out["load_s"] = rounded(loadS, 3) }
            return out
        } catch {
            return ["error": "transcribe: \(error.localizedDescription)"]
        }
    }

    // MARK: - audio

    /// A file AVAudioFile reads (wav, aiff, caf, m4a, mp3, flac; any rate,
    /// any channels), whole, as 16 kHz mono — in memory, no temporary file.
    static func read(_ url: URL) throws -> [Swift.Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceBenchError("too long to read at once")
        }
        try file.read(into: buffer)
        guard let mono = mono16k(buffer) else { throw VoiceBenchError("couldn't convert it to 16 kHz mono") }
        return mono
    }

    /// Any PCM buffer, channels averaged, at 16 kHz.
    static func mono16k(_ buffer: AVAudioPCMBuffer) -> [Swift.Float]? {
        resample(samples(of: buffer), from: buffer.format.sampleRate)
    }

    /// A buffer's frames as Float, channels averaged.
    static func samples(of buffer: AVAudioPCMBuffer) -> [Swift.Float] {
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        var out = [Swift.Float](repeating: 0, count: frames)
        let share = 1 / Swift.Float(channels)
        let interleaved = buffer.format.isInterleaved
        if let data = buffer.floatChannelData {
            for c in 0..<channels {
                for i in 0..<frames { out[i] += (interleaved ? data[0][i * channels + c] : data[c][i]) * share }
            }
        } else if let data = buffer.int16ChannelData {
            for c in 0..<channels {
                for i in 0..<frames { out[i] += Swift.Float(interleaved ? data[0][i * channels + c] : data[c][i]) / 32_768 * share }
            }
        } else if let data = buffer.int32ChannelData {
            for c in 0..<channels {
                for i in 0..<frames { out[i] += Swift.Float(interleaved ? data[0][i * channels + c] : data[c][i]) / 2_147_483_648 * share }
            }
        }
        return out
    }

    /// Mono samples at `rate` → 16 kHz, through AVAudioConverter at its best
    /// quality, trimmed to the exact length the rate change implies.
    static func resample(_ input: [Swift.Float], from rate: Double) -> [Swift.Float]? {
        if input.isEmpty { return [] }
        if rate == 16_000 { return input }
        guard rate > 0,
              let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: from, to: to),
              let source = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(input.count)),
              let channel = source.floatChannelData?[0] else { return nil }
        input.withUnsafeBufferPointer { samples in
            for i in 0..<samples.count { channel[i] = samples[i] }
        }
        source.frameLength = AVAudioFrameCount(input.count)
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let wanted = Int((Double(input.count) * 16_000 / rate).rounded())
        var out: [Swift.Float] = []
        out.reserveCapacity(wanted + 1024)
        let feed = Feed(source)
        while out.count <= wanted + 4096 {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: 8192) else { return nil }
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, state in feed.next(state) }
            if status == .error { return nil }
            if let data = chunk.floatChannelData?[0], chunk.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(chunk.frameLength)))
            }
            if status == .endOfStream || chunk.frameLength == 0 { break }
        }
        if out.count > wanted { out.removeLast(out.count - wanted) }
        return out
    }

    /// Hands the converter the one buffer, then says the stream has ended.
    private final class Feed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let given = buffer else { state.pointee = .endOfStream; return nil }
            buffer = nil
            state.pointee = .haveData
            return given
        }
    }

    /// `seconds` of near-silence: white noise at −66 dBFS RMS, a quiet room
    /// through a good microphone — quiet, but not the digital zero the
    /// engine short-circuits, so the model itself has to hear nothing.
    static func roomQuiet(seconds: Double) -> [Swift.Float] {
        var state: UInt32 = 0x2545_F491
        return (0..<Int(seconds * 16_000)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Swift.Float(state >> 8) / Swift.Float(1 << 24) - 0.5) * 0.0017
        }
    }

    // MARK: - speech for the clips

    /// `text` spoken by the system voice, as 16 kHz mono: AVSpeechSynthesizer
    /// into buffers (nothing plays, nothing is written); `/usr/bin/say` into
    /// a temporary file if that doesn't answer.
    @MainActor static func speak(_ text: String) async -> (samples: [Swift.Float], how: String)? {
        if let spoken = await synthesize(text), !spoken.isEmpty { return (spoken, "AVSpeechSynthesizer") }
        if let said = await say(text), !said.isEmpty { return (said, "say") }
        return nil
    }

    @MainActor private static func synthesize(_ text: String) async -> [Swift.Float]? {
        let collector = SpeechCollector()
        return await withCheckedContinuation { continuation in
            collector.start(text) { continuation.resume(returning: $0) }
        }
    }

    /// Collects the synthesizer's buffers until it says it has finished (or
    /// 15 s), then resamples once. An empty buffer is not the end: one comes
    /// between the chunks a long text is spoken in.
    private final class SpeechCollector: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let synthesizer = AVSpeechSynthesizer()
        private var samples: [Swift.Float] = []
        private var rate = 0.0
        private var done: (([Swift.Float]?) -> Void)?

        func start(_ text: String, done: @escaping ([Swift.Float]?) -> Void) {
            self.done = done
            synthesizer.delegate = self
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
                ?? AVSpeechSynthesisVoice(language: "en-US")
            // Weak here, strong in the timeout: the synthesizer keeps its
            // callback, and the timeout keeps the collector until it fires.
            synthesizer.write(utterance) { [weak self] buffer in
                guard let self, let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
                lock.lock()
                if rate == 0 { rate = pcm.format.sampleRate }
                samples += VoiceBench.samples(of: pcm)
                lock.unlock()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [self] in finish() }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }

        private func finish() {
            lock.lock()
            let callback = done
            done = nil
            let collected = samples, at = rate
            lock.unlock()
            guard let callback else { return }
            callback(collected.isEmpty || at <= 0 ? nil : VoiceBench.resample(collected, from: at))
        }
    }

    /// The `say` command, into a temporary AIFF that is read and removed.
    private static func say(_ text: String) async -> [Swift.Float]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("copper-voice-\(UUID().uuidString).aiff")
                defer { try? FileManager.default.removeItem(at: file) }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["-v", "Samantha", "-o", file.path, text]
                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: try read(file))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - scoring

    /// Lowercase words with punctuation gone (an apostrophe joins its word).
    static func normalized(_ text: String) -> [String] {
        let kept = text.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if scalar == "'" || scalar == "\u{2019}" { return nil }
            return CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").map(String.init)
    }

    /// Word-level edit distance over the reference's length, after normalising both.
    static func wordErrorRate(reference: String, heard: String) -> Double {
        let r = normalized(reference), h = normalized(heard)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var row = Array(0...h.count)
        for i in 1...r.count {
            var next = [i] + [Int](repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            row = next
        }
        return Double(row[h.count]) / Double(r.count)
    }

    static func rounded(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}

/// A bench refusal with its reason.
struct VoiceBenchError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
