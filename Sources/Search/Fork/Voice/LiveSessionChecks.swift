import AVFoundation
import Foundation

// LiveSession's and VoiceBlockMaker's checks, for `voice selftest`.
//
// Without a decoder they run on synthetic audio and a fake decoder that hears
// "words": every 50 ms frame louder than 0.05 belongs to a word, and a word's
// tone says which one it is (word k is a 0.3 s sine at 300 + 40k Hz). That
// makes cut positions, duplicated or lost words and event order exact, with
// no model. With the real decoder they also replay synthesized speech (`say`)
// through both modes and compare the finals with one batch decode of the same
// audio. Nothing here touches a microphone; the speech files live in a
// temporary folder that is removed afterwards.

enum LiveSessionChecks {
    typealias Decode = @Sendable ([Swift.Float]) async throws -> String

    /// Failures, as sentences; empty when everything passed.
    static func run(decode: (@Sendable ([Swift.Float]) async throws -> String)?) async -> [String] {
        await run(decode: decode, report: nil)
    }

    /// The same, with `report` given the event streams, seams and comparisons
    /// of the speech checks as readable lines.
    static func run(decode: Decode?, report: (@Sendable (String) -> Void)?) async -> [String] {
        var failures = await sessionChecks()
        failures += blockMakerChecks()
        if let decode { failures += await speechChecks(decode, report: report) }
        return failures
    }

    // MARK: - Replay

    struct Replay {
        /// Each event with the audio position (ms) it was emitted at.
        var events: [(atMs: Int, event: LiveEvent)]
        /// Events emitted before finish() was called.
        var beforeFinish: Int
        var finished: String

        var finals: [VoiceSegment] { events.compactMap { if case .final(let s) = $0.event { return s } else { return nil } } }
        var partials: [String] { events.compactMap { if case .partial(let t) = $0.event { return t } else { return nil } } }
        var text: String { finals.map(\.text).joined(separator: " ") }

        func lines() -> [String] {
            events.map { item in
                let at = String(format: "%7.2fs", Double(item.atMs) / 1000)
                switch item.event {
                case .partial(let text): return "  \(at)  partial  \(text)"
                case .final(let s):
                    return "  \(at)  FINAL #\(s.seq) [\(String(format: "%.2f", Double(s.t0ms) / 1000))–\(String(format: "%.2f", Double(s.t1ms) / 1000)) s]  \(s.text)"
                }
            }
        }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(atMs: Int, event: LiveEvent)] = []
        private var position = 0
        func at(_ samples: Int) { lock.withLock { position = samples } }
        func record(_ event: LiveEvent) { lock.withLock { items.append((position * 1000 / LiveSession.sampleRate, event)) } }
        var events: [(atMs: Int, event: LiveEvent)] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
    }

    /// Feeds `samples` in 50 ms blocks. `settle` waits for the session after
    /// every block — decoding then costs no audio time, so the events are the
    /// same on every run; otherwise blocks go in as fast as they come, or
    /// `pace` apart.
    static func replay(_ samples: [Swift.Float], mode: LiveSession.Mode, decode: @escaping Decode,
                       settle: Bool = true, paceNanoseconds: UInt64 = 0) async -> Replay {
        let recorder = Recorder()
        let session = LiveSession(mode: mode, decode: decode, emit: { recorder.record($0) })
        var index = 0
        while index < samples.count {
            let end = min(index + VoiceBlockMaker.blockSize, samples.count)
            recorder.at(end)
            session.feed(Array(samples[index..<end]))
            index = end
            if settle { await session.drain() } else if paceNanoseconds > 0 { try? await Task.sleep(nanoseconds: paceNanoseconds) }
        }
        let before = recorder.count
        let finished = await session.finish()
        return Replay(events: recorder.events, beforeFinish: before, finished: finished)
    }

    /// Order problems in an event stream: seq from 1 without gaps, segments in
    /// order and not overlapping, no partial once finish() was called, and
    /// finish()'s text (when it had any) being the last final's.
    static func orderProblems(_ r: Replay, _ name: String) -> [String] {
        var problems: [String] = []
        var lastEnd = 0
        for (i, s) in r.finals.enumerated() {
            if s.seq != i + 1 { problems.append("\(name): final #\(i + 1) has seq \(s.seq)") }
            if s.t0ms < lastEnd || s.t1ms <= s.t0ms { problems.append("\(name): final \(s.seq) spans \(s.t0ms)–\(s.t1ms) ms after one ending at \(lastEnd) ms") }
            lastEnd = s.t1ms
        }
        for item in r.events[r.beforeFinish...] {
            if case .partial(let text) = item.event { problems.append("\(name): partial \"\(text)\" after finish()") }
        }
        let emittedLast = r.beforeFinish < r.events.count ? r.finals.last?.text : nil
        if !r.finished.isEmpty, emittedLast != r.finished {
            problems.append("\(name): finish() returned \"\(r.finished)\" but its final wasn't the last event")
        }
        return problems
    }

    // MARK: - Synthetic audio and the fake decoder

    enum Tone {
        static let rate = LiveSession.sampleRate
        static func seconds(_ s: Double) -> Int { Int((s * Double(rate)).rounded()) }

        /// Word k: 0.3 s of a 300 + 40k Hz sine (RMS 0.21).
        static func word(_ k: Int) -> [Swift.Float] {
            let f = 300.0 + 40.0 * Double(k)
            return (0..<seconds(0.3)).map { Swift.Float(0.3 * sin(2 * Double.pi * f * Double($0) / Double(rate))) }
        }

        static func zeros(_ s: Double) -> [Swift.Float] { [Swift.Float](repeating: 0, count: seconds(s)) }

        /// Deterministic uniform noise at the given RMS.
        static func noise(_ s: Double, rms: Swift.Float, seed: UInt64 = 7) -> [Swift.Float] {
            var state = seed &* 6_364_136_223_846_793_005 &+ 1
            let amplitude = rms * Swift.Float(3).squareRoot()
            return (0..<seconds(s)).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return amplitude * (Swift.Float(state >> 40) / Swift.Float(1 << 24) * 2 - 1)
            }
        }

        /// Words with a 0.2 s gap of faint room tone after each: 0.5 s per word.
        /// `silentGapAfter` makes that word's gap digital silence instead.
        static func speech(_ words: [Int], silentGapAfter: Int? = nil) -> [Swift.Float] {
            var out: [Swift.Float] = []
            for k in words {
                out += word(k)
                out += k == silentGapAfter ? zeros(0.2) : noise(0.2, rms: 0.0009, seed: UInt64(k + 11))
            }
            return out
        }
    }

    /// The fake model: runs of 50 ms frames louder than 0.05 are words, named
    /// by their pitch ("w3"). Silence and room tone decode to "".
    static func fakeDecode(_ x: [Swift.Float]) -> String {
        var words: [String] = []
        var run: Int?
        var frame = 0
        func close(_ end: Int) {
            guard let start = run else { return }
            run = nil
            // Pitch from the tone itself: frames that straddle a word's edge
            // (audio cut mid-block) carry room tone, whose crossings don't count.
            guard let first = (start..<end).first(where: { abs(x[$0]) > 0.02 }),
                  let last = (start..<end).last(where: { abs(x[$0]) > 0.02 }), last > first else { return }
            var crossings = 0
            for i in (first + 1)...last where (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
            let hertz = Double(crossings) * Double(LiveSession.sampleRate) / (2 * Double(last + 1 - first))
            words.append("w\(Int(((hertz - 300) / 40).rounded()))")
        }
        while frame < x.count {
            let end = min(frame + VoiceBlockMaker.blockSize, x.count)
            if LiveSession.rms(Array(x[frame..<end])) > 0.05 {
                if run == nil { run = frame }
            } else {
                close(frame)
            }
            frame = end
        }
        close(x.count)
        return words.joined(separator: " ")
    }

    static let fake: Decode = { fakeDecode($0) }

    static func words(_ ks: [Int]) -> String { ks.map { "w\($0)" }.joined(separator: " ") }

    /// A fake decoder that takes its time and counts how it was called.
    final class SlowDecoder: @unchecked Sendable {
        private let lock = NSLock()
        private let nanoseconds: UInt64
        private(set) var calls = 0, inFlight = 0, mostInFlight = 0
        private var marks: [Int] = []          // call index at each mark
        init(milliseconds: UInt64) { nanoseconds = milliseconds * 1_000_000 }
        var decode: Decode {
            { [self] samples in
                lock.withLock { calls += 1; inFlight += 1; mostInFlight = max(mostInFlight, inFlight) }
                try? await Task.sleep(nanoseconds: nanoseconds)
                lock.withLock { inFlight -= 1 }
                return LiveSessionChecks.fakeDecode(samples)
            }
        }
        var snapshot: (calls: Int, most: Int) { lock.withLock { (calls, mostInFlight) } }
    }

    /// Counts calls and remembers each decode's length.
    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var lengths: [Int] = []
        var decode: Decode { { [self] samples in lock.withLock { lengths.append(samples.count) }; return LiveSessionChecks.fakeDecode(samples) } }
        var all: [Int] { lock.withLock { lengths } }
    }

    // MARK: - Session checks (no model)

    static func sessionChecks() async -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }

        // One phrase, then a pause: partials, then exactly one final.
        let one = Tone.speech(Array(0..<6)) + Tone.zeros(1.5)
        let single = await replay(one, mode: .listen, decode: fake)
        failures += orderProblems(single, "one phrase")
        expect(single.finals.map(\.text) == [words(Array(0..<6))], "one phrase: finals \(single.finals.map(\.text)), expected [\(words(Array(0..<6)))]")
        expect(single.events.first.map { if case .partial = $0.event { return true } else { return false } } == true,
               "one phrase: the first event was not a partial")
        if case .partial(let first)? = single.events.first?.event {
            expect(first == "w0" && single.events[0].atMs == 350, "one phrase: first partial \"\(first)\" at \(single.events[0].atMs) ms, expected \"w0\" at 350 ms")
        }
        expect(single.partials.count >= 5, "one phrase: \(single.partials.count) partials for 3 s of speech, expected one per 0.5 s")
        expect(single.finals.first?.t1ms == 3_500, "one phrase: final ends at \(single.finals.first?.t1ms ?? -1) ms, expected 3500 (0.7 s after the last word)")

        // Two phrases 1.2 s apart → two finals in listen; one at finish() in hold.
        let a = [0, 1, 2, 3], b = [10, 11, 12, 13]
        let two = Tone.speech(a) + Tone.zeros(1.2) + Tone.speech(b) + Tone.zeros(1.0)
        let listen = await replay(two, mode: .listen, decode: fake)
        failures += orderProblems(listen, "two phrases")
        expect(listen.finals.map(\.text) == [words(a), words(b)], "two phrases: finals \(listen.finals.map(\.text))")
        expect(listen.finals.map(\.t0ms) == [0, 2_500] && listen.finals.map(\.t1ms) == [2_500, 5_700],
               "two phrases: spans \(listen.finals.map { "\($0.t0ms)–\($0.t1ms)" }), expected 0–2500, 2500–5700")
        expect(staleProblems(listen, first: Set(a.map { "w\($0)" })).isEmpty, "two phrases: \(staleProblems(listen, first: Set(a.map { "w\($0)" })))")

        let hold = await replay(two, mode: .hold, decode: fake)
        failures += orderProblems(hold, "hold")
        expect(hold.beforeFinish == hold.partials.count, "hold: a final came before finish()")
        expect(hold.finals.map(\.text) == [words(a + b)], "hold: finals \(hold.finals.map(\.text)), expected one with every word")
        expect(hold.finals.first.map { $0.t0ms == 0 && $0.t1ms == two.count * 1000 / LiveSession.sampleRate } == true, "hold: final spans \(hold.finals.first.map { "\($0.t0ms)–\($0.t1ms)" } ?? "nothing")")
        expect(hold.finished == words(a + b), "hold: finish() returned \"\(hold.finished)\"")

        // Silence and room tone: no events; under the floor, not even a decode.
        let quiet = Tally()
        for mode in [LiveSession.Mode.listen, .hold] {
            let still = await replay(Tone.zeros(10) + Tone.noise(5, rms: 0.0028), mode: mode, decode: quiet.decode)
            expect(still.events.isEmpty && still.finished.isEmpty, "silence (\(mode)): \(still.events.count) events")
            let hiss = await replay(Tone.zeros(10) + Tone.noise(5, rms: 0.0056), mode: mode, decode: fake)
            expect(hiss.events.isEmpty && hiss.finished.isEmpty, "room tone over the floor (\(mode)): \(hiss.events.count) events")
        }
        expect(quiet.all.isEmpty, "silence: \(quiet.all.count) decodes of audio under the noise floor")

        // Room tone ahead of speech keeps its last second (hold: in partials; its final hears it all).
        let lateAudio = Tone.zeros(10) + Tone.speech([5, 6]) + Tone.zeros(1)
        let late = await replay(lateAudio, mode: .listen, decode: fake)
        expect(late.finals.map(\.t0ms) == [9_000] && late.finals.map(\.text) == ["w5 w6"], "pre-roll: finals \(late.finals.map { "\($0.t0ms) \($0.text)" }), expected one from 9000 ms")
        let leadIn = Tally()
        let lateHold = await replay(lateAudio, mode: .hold, decode: leadIn.decode)
        expect(lateHold.finals.map(\.text) == ["w5 w6"] && (leadIn.all.dropLast().max() ?? 0) <= Tone.seconds(3) && leadIn.all.last == lateAudio.count,
               "pre-roll (hold): partial decodes up to \(leadIn.all.dropLast().max() ?? 0) samples (expected ≤ 3 s), final \(leadIn.all.last ?? 0) of \(lateAudio.count)")

        // The 15 s cap: cut after the quietest block of the last 3 s (word 26's
        // silent gap, 13.30–13.35 s), the rest carried into the next phrase.
        let long = Tone.speech(Array(0..<40), silentGapAfter: 26) + Tone.zeros(1)
        let lengths = Tally()
        let capped = await replay(long, mode: .listen, decode: lengths.decode)
        failures += orderProblems(capped, "15 s cap")
        expect(capped.finals.map(\.text) == [words(Array(0...26)), words(Array(27..<40))], "15 s cap: finals \(capped.finals.map(\.text))")
        expect(capped.finals.map(\.t1ms) == [13_350, 20_500], "15 s cap: finals end at \(capped.finals.map(\.t1ms)), expected 13350 (the silent block) and 20500")
        expect((lengths.all.max() ?? 0) <= LiveSession.maxPhrase, "15 s cap: a listen decode of \(lengths.all.max() ?? 0) samples")

        // A final that loses words in one long window is decoded again in halves.
        let lossy: Decode = { samples in
            let all = fakeDecode(samples).split(separator: " ")
            return samples.count > Tone.seconds(10) ? all.prefix(all.count * 3 / 10).joined(separator: " ") : all.joined(separator: " ")
        }
        let rescued = await replay(Tone.speech(Array(0..<24)) + Tone.zeros(1), mode: .listen, decode: lossy)
        expect(rescued.finals.map(\.text) == [words(Array(0..<24))], "rescue: finals \(rescued.finals.map(\.text)), expected all 24 words")

        // Hold past 15 s: partials see the last 15 s, the final the whole hold.
        let held = Tally()
        let longHold = await replay(long, mode: .hold, decode: held.decode)
        expect(longHold.finals.map(\.text) == [words(Array(0..<40))], "long hold: finals \(longHold.finals.map(\.text))")
        expect(held.all.dropLast().allSatisfy { $0 <= LiveSession.partialWindow } && held.all.last == long.count,
               "long hold: partial decodes up to \(held.all.dropLast().max() ?? 0) samples, final \(held.all.last ?? 0) of \(long.count)")

        // Latest-only: a decoder slower than the audio never builds a backlog.
        let slow = SlowDecoder(milliseconds: 200)
        let burst = await replay(Tone.speech(Array(0..<20)), mode: .listen, decode: slow.decode, settle: false)
        expect(slow.snapshot.most == 1, "latest-only: \(slow.snapshot.most) decodes at once")
        expect(slow.snapshot.calls <= 3, "latest-only: \(slow.snapshot.calls) decodes for 10 s fed at once (a backlog)")
        expect(burst.finals.map(\.text) == [words(Array(0..<20))], "latest-only: finals \(burst.finals.map(\.text))")

        let paced = SlowDecoder(milliseconds: 100)
        let steady = await replay(two + Tone.speech(Array(20..<30)) + Tone.zeros(1), mode: .listen, decode: paced.decode,
                                  settle: false, paceNanoseconds: 5_000_000)
        failures += orderProblems(steady, "paced")
        expect(paced.snapshot.most == 1, "paced: \(paced.snapshot.most) decodes at once")
        expect(paced.snapshot.calls <= 30, "paced: \(paced.snapshot.calls) decodes for 12 s at 10× real time with 1 s of audio per decode")
        expect(steady.finals.map(\.text) == [words(a), words(b), words(Array(20..<30))], "paced: finals \(steady.finals.map(\.text))")
        expect(staleProblems(steady, first: Set(a.map { "w\($0)" })).isEmpty, "paced: \(staleProblems(steady, first: Set(a.map { "w\($0)" })))")

        // cancel(): nothing after it, ever; finish() then returns "".
        let gate = SlowDecoder(milliseconds: 80)
        let recorder = Recorder()
        let session = LiveSession(mode: .listen, decode: gate.decode, emit: { recorder.record($0) })
        let speech = Tone.speech(Array(0..<8))
        for start in stride(from: 0, to: speech.count / 2, by: VoiceBlockMaker.blockSize) {
            session.feed(Array(speech[start..<min(start + VoiceBlockMaker.blockSize, speech.count)]))
        }
        try? await Task.sleep(nanoseconds: 30_000_000)        // a decode is in flight
        session.cancel()
        let atCancel = recorder.count
        for start in stride(from: speech.count / 2, to: speech.count, by: VoiceBlockMaker.blockSize) {
            session.feed(Array(speech[start..<min(start + VoiceBlockMaker.blockSize, speech.count)]))
        }
        let after = await session.finish()
        try? await Task.sleep(nanoseconds: 250_000_000)
        expect(recorder.count == atCancel && after.isEmpty, "cancel: \(recorder.count - atCancel) events after cancel(), finish() returned \"\(after)\"")

        // finish() twice, feed after finish(): ignored.
        let again = LiveSession(mode: .hold, decode: fake, emit: { recorder.record($0) })
        again.feed(Array(Tone.word(3).prefix(VoiceBlockMaker.blockSize)))
        let once = await again.finish()
        again.feed(Tone.word(4))
        let twice = await again.finish()
        expect(once == "w3" && twice.isEmpty, "finish twice: \"\(once)\" then \"\(twice)\"")

        return failures
    }

    /// Partials after the first final that still carry the first phrase's words.
    static func staleProblems(_ r: Replay, first: Set<String>) -> [String] {
        guard let cut = r.events.firstIndex(where: { if case .final = $0.event { return true } else { return false } }) else { return [] }
        return r.events[(cut + 1)...].compactMap { item in
            guard case .partial(let text) = item.event else { return nil }
            return text.split(separator: " ").contains { first.contains(String($0)) } ? "stale partial \"\(text)\" at \(item.atMs) ms" : nil
        }
    }

    // MARK: - VoiceBlockMaker (no model)

    static func blockMakerChecks() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }

        // 16 kHz mono passes through untouched, whatever the buffer sizes.
        let source = Tone.speech([1, 2, 3])
        var through: [Swift.Float] = []
        var sizes = true
        let maker = VoiceBlockMaker()
        var offset = 0
        for size in [333, 1_000, 4_096, 17, 2_400] + Array(repeating: 1_600, count: 20) where offset < source.count {
            let chunk = Array(source[offset..<min(offset + size, source.count)])
            offset += chunk.count
            guard let buffer = pcm(chunk.map { [$0] }, rate: 16_000, format: .pcmFormatFloat32, interleaved: false) else { return ["block maker: couldn't make a test buffer"] }
            do {
                for block in try maker.append(buffer) { sizes = sizes && block.count == VoiceBlockMaker.blockSize; through += block }
            } catch { return ["block maker: \(error)"] }
        }
        for block in maker.finish() { sizes = sizes && block.count == VoiceBlockMaker.blockSize; through += block }
        expect(sizes, "block maker: a block that wasn't 800 samples")
        expect(Array(through.prefix(source.count)) == source && through.count == source.count, "block maker: 16 kHz mono changed on the way through (\(through.count) of \(source.count) samples)")

        // 48 kHz stereo float and 44.1 kHz interleaved Int16 → 16 kHz mono at the same pitch and level.
        for (rate, format, interleaved) in [(48_000.0, AVAudioCommonFormat.pcmFormatFloat32, false), (44_100.0, .pcmFormatInt16, true)] {
            let name = "block maker \(Int(rate)) Hz \(format == .pcmFormatInt16 ? "int16" : "float") stereo"
            let seconds = 2.0, hertz = 440.0
            let frames = Int(rate * seconds)
            let stereo = (0..<frames).map { i -> [Swift.Float] in
                let x = Swift.Float(0.5 * sin(2 * Double.pi * hertz * Double(i) / rate))
                return [x, x]
            }
            let made = VoiceBlockMaker()
            var out: [Swift.Float] = []
            var whole = true
            var index = 0
            for size in [4_800, 1_024, 777, 9_600, 512] + Array(repeating: 4_410, count: 40) where index < frames {
                let end = min(index + size, frames)
                guard let buffer = pcm(Array(stereo[index..<end]), rate: rate, format: format, interleaved: interleaved) else { return ["\(name): couldn't make a test buffer"] }
                index = end
                do { for block in try made.append(buffer) { whole = whole && block.count == VoiceBlockMaker.blockSize; out += block } } catch { return ["\(name): \(error)"] }
            }
            for block in made.finish() { whole = whole && block.count == VoiceBlockMaker.blockSize; out += block }
            expect(whole, "\(name): a block that wasn't 800 samples")
            expect(abs(out.count - Int(seconds * 16_000)) <= VoiceBlockMaker.blockSize, "\(name): \(out.count) samples for \(seconds) s")
            let middle = Array(out[8_000..<24_000])
            var crossings = 0
            for i in 1..<middle.count where (middle[i - 1] < 0) != (middle[i] < 0) { crossings += 1 }
            let pitch = Double(crossings) / 2
            expect(abs(pitch - hertz) <= 2, "\(name): pitch \(pitch) Hz, expected 440")
            let level = LiveSession.rms(middle)
            expect(abs(level - 0.3536) <= 0.02, "\(name): level \(level), expected 0.354")
        }

        // The rate changes mid-stream (a new device): blocks stay whole and contiguous.
        let switching = VoiceBlockMaker()
        var total = 0
        var ok = true
        for rate in [48_000.0, 16_000, 44_100, 48_000] {
            let frames = Int(rate / 2)
            guard let buffer = pcm((0..<frames).map { [Swift.Float(0.2 * sin(Double($0) / 7))] }, rate: rate, format: .pcmFormatFloat32, interleaved: false) else { return failures + ["block maker: couldn't make a test buffer"] }
            do { for block in try switching.append(buffer) { ok = ok && block.count == VoiceBlockMaker.blockSize; total += block.count } } catch { return failures + ["block maker, rate change: \(error)"] }
        }
        for block in switching.finish() { ok = ok && block.count == VoiceBlockMaker.blockSize; total += block.count }
        expect(ok && abs(total - 32_000) <= 2 * VoiceBlockMaker.blockSize, "block maker, rate change: \(total) samples for 2 s")
        return failures
    }

    /// A PCM buffer of `frames` (one array of channel values per frame).
    static func pcm(_ frames: [[Swift.Float]], rate: Double, format: AVAudioCommonFormat, interleaved: Bool) -> AVAudioPCMBuffer? {
        let channels = frames.first?.count ?? 1
        guard let f = AVAudioFormat(commonFormat: format, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: interleaved),
              let buffer = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(max(frames.count, 1))) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames.count)
        let stride = interleaved ? channels : 1
        for (i, frame) in frames.enumerated() {
            for (c, x) in frame.enumerated() {
                switch format {
                case .pcmFormatFloat32:
                    guard let data = buffer.floatChannelData else { return nil }
                    (interleaved ? data[0] + c : data[c])[i * stride] = x
                case .pcmFormatInt16:
                    guard let data = buffer.int16ChannelData else { return nil }
                    (interleaved ? data[0] + c : data[c])[i * stride] = Int16(max(-1, min(1, x)) * 32_767)
                default:
                    return nil
                }
            }
        }
        return buffer
    }

    // MARK: - Speech (the real decoder)

    enum Script {
        static let first = "Please open the settings page and turn on the dark theme, then move the downloads folder to the desktop and check whether the new version has finished installing on this computer."
        static let second = "After lunch we should compare the two reports side by side, write a short summary of the differences, and send the draft to the team so everyone can review it before the meeting on Thursday."
        static let long = "The planning review covered several topics, starting with the budget for new laptops and the schedule for moving the office to the third floor, then a long discussion about hiring two more engineers for the mobile team, how to share the support rotation fairly across time zones, and whether the dashboard needs a new filter for urgent tickets, and finally the group agreed to meet again next Tuesday afternoon to finish the remaining items on the list."
    }

    static let maxWER = 0.15

    static func speechChecks(_ decode: @escaping Decode, report: (@Sendable (String) -> Void)?) async -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("copper-voice-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first: [Swift.Float], second: [Swift.Float], long: [Swift.Float]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            first = try load(try speak(Script.first, as: "first", in: folder))
            second = try load(try speak(Script.second, as: "second", in: folder))
            long = try load(try speak(Script.long, as: "long", in: folder))
        } catch {
            return ["speech: couldn't make the test speech (\(error.localizedDescription))"]
        }
        let pair = first + Tone.zeros(1.2) + second
        let silence = Tone.zeros(10) + Tone.noise(5, rms: 0.0056)

        let cases: [(name: String, audio: [Swift.Float], finals: ClosedRange<Int>, seams: Bool)] = [
            ("paragraph", first, 1...Int.max, false),
            ("two paragraphs 1.2 s apart", pair, 2...2, false),
            ("25 s paragraph", long, 2...Int.max, true),
        ]
        for (name, audio, finals, seams) in cases {
            let batch: String
            do { batch = try await decode(audio) } catch { failures.append("\(name): batch decode failed (\(error.localizedDescription))"); continue }
            let listen = await replay(audio, mode: .listen, decode: decode)
            report?("\(name), listen (\(String(format: "%.1f", Double(audio.count) / 16_000)) s):")
            listen.lines().forEach { report?($0) }
            failures += orderProblems(listen, "\(name), listen")
            expect(finals.contains(listen.finals.count), "\(name), listen: \(listen.finals.count) finals")
            let firstFinal = listen.events.firstIndex { if case .final = $0.event { return true } else { return false } } ?? 0
            expect(firstFinal >= 1, "\(name), listen: no partial before the first final")
            let wer = errorRate(reference: batch, hypothesis: listen.text)
            report?(String(format: "  WER of the finals against one batch decode: %.1f%%", wer * 100))
            expect(wer <= maxWER, "\(name), listen: finals differ from the batch decode by \(String(format: "%.1f", wer * 100))% WER")
            if seams {
                for (seam, diff) in seamDifferences(reference: batch, finals: listen.finals.map(\.text)) {
                    report?("  seam after word \(seam): \(diff) word(s) differ from the batch decode within 2 words")
                    expect(diff <= 1, "\(name): \(diff) words differ at the cut after word \(seam)")
                }
            }

            let hold = await replay(audio, mode: .hold, decode: decode)
            failures += orderProblems(hold, "\(name), hold")
            expect(hold.beforeFinish == hold.partials.count && hold.finals.count == 1,
                   "\(name), hold: \(hold.finals.count) finals (\(hold.events.count - hold.beforeFinish) after finish)")
            let holdWER = errorRate(reference: batch, hypothesis: hold.text)
            report?(String(format: "  hold: %ld partials, %ld final(s), WER against the batch decode %.1f%%", hold.partials.count, hold.finals.count, holdWER * 100))
            expect(holdWER <= maxWER, "\(name), hold: final differs from the batch decode by \(String(format: "%.1f", holdWER * 100))% WER")
            report?("  batch: \(batch)")
        }

        // Any length means any: a hold of exactly 300 blocks is one full 15.00 s
        // window, which Fermion's runner sizes at 15.02 s and refuses.
        do {
            let edge = try await decode(Array(long.prefix(240_000)))
            expect(!edge.isEmpty, "decoder: exactly 15.00 s of speech decoded to nothing")
        } catch {
            failures.append("decoder: exactly 15.00 s of speech (240,000 samples) failed (\(error.localizedDescription)); a hold that long loses its final")
        }

        for mode in [LiveSession.Mode.listen, .hold] {
            let still = await replay(silence, mode: mode, decode: decode)
            expect(still.events.isEmpty, "silence (\(mode)): \(still.events.count) events: \(still.lines().joined(separator: " / "))")
        }

        // A 48 kHz stereo file through VoiceBlockMaker hears what the 16 kHz mono one does.
        do {
            let spoken = folder.appendingPathComponent("first.aiff")
            let mono = folder.appendingPathComponent("first-16k.wav"), stereo = folder.appendingPathComponent("first-48k-stereo.wav")
            try shell("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", spoken.path, mono.path])
            try shell("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@48000", "-c", "2", spoken.path, stereo.path])
            let a = try load(mono), b = try load(stereo)
            let ta = try await decode(a), tb = try await decode(b)
            let wer = errorRate(reference: ta, hypothesis: tb)
            let likeness = similarity(a, b)
            report?(String(format: "48 kHz stereo vs 16 kHz mono: %ld vs %ld samples, correlation %.4f, WER %.1f%%", b.count, a.count, likeness, wer * 100))
            expect(abs(a.count - b.count) <= 2 * VoiceBlockMaker.blockSize, "48 kHz stereo: \(b.count) samples, the 16 kHz file \(a.count)")
            expect(likeness >= 0.95, "48 kHz stereo: correlation \(likeness) with the 16 kHz file")
            expect(wer <= 0.05, "48 kHz stereo: decodes \(String(format: "%.1f", wer * 100))% WER away from the 16 kHz file")
        } catch {
            failures.append("48 kHz stereo: \(error.localizedDescription)")
        }
        return failures
    }

    /// Speech from `say` (Samantha when the Mac has her) as an AIFF in `folder`.
    static func speak(_ text: String, as name: String, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("\(name).aiff")
        do { try shell("/usr/bin/say", ["-v", "Samantha", "-o", file.path, text]) } catch { try shell("/usr/bin/say", ["-o", file.path, text]) }
        return file
    }

    struct ToolFailed: LocalizedError {
        let tool: String, status: Int32
        var errorDescription: String? { "\(tool) exited with \(status)" }
    }

    static func shell(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolFailed(tool: (tool as NSString).lastPathComponent, status: process.terminationStatus) }
    }

    /// Any audio file AVAudioFile reads, through VoiceBlockMaker: 16 kHz mono,
    /// padded to whole 50 ms blocks.
    static func load(_ url: URL) throws -> [Swift.Float] {
        let file = try AVAudioFile(forReading: url)
        let maker = VoiceBlockMaker()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else { throw VoiceCaptureError.unsupportedFormat }
        var out: [Swift.Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 8_192)
            if buffer.frameLength == 0 { break }
            for block in try maker.append(buffer) { out += block }
        }
        for block in maker.finish() { out += block }
        return out
    }

    // MARK: - Comparing texts

    /// Lowercase words without punctuation, for comparing transcripts.
    static func normalized(_ text: String) -> [String] {
        var kept = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) { kept.append(scalar) }
            else if scalar != "'", scalar != "\u{2019}" { kept.append(" ") }   // "don't" → "dont"
        }
        return String(kept).split(separator: " ").map(String.init)
    }

    /// Word error rate of `hypothesis` against `reference`, normalized.
    static func errorRate(reference: String, hypothesis: String) -> Double {
        let r = normalized(reference), h = normalized(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(edits(r, h).count) / Double(r.count)
    }

    /// For each seam between consecutive finals: how many word edits against
    /// the reference fall within two words of it.
    static func seamDifferences(reference: String, finals: [String]) -> [(seam: Int, diff: Int)] {
        let h = finals.map(normalized)
        let positions = edits(normalized(reference), h.flatMap { $0 })
        var seams: [(Int, Int)] = []
        var seam = 0
        for words in h.dropLast() {
            seam += words.count
            seams.append((seam, positions.filter { $0 >= seam - 2 && $0 < seam + 2 }.count))
        }
        return seams
    }

    /// The hypothesis position of every edit in a minimal alignment.
    static func edits(_ r: [String], _ h: [String]) -> [Int] {
        let n = r.count, m = h.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
                }
            }
        }
        var out: [Int] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
                if r[i - 1] != h[j - 1] { out.append(j - 1) }
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                out.append(j)                       // a reference word missing before hypothesis word j
                i -= 1
            } else {
                out.append(j - 1)                   // an extra hypothesis word
                j -= 1
            }
        }
        return out
    }

    /// Best normalized correlation of two signals within ±16 samples of lag.
    static func similarity(_ a: [Swift.Float], _ b: [Swift.Float]) -> Double {
        let n = min(a.count, b.count) - 32
        guard n > 0 else { return 0 }
        var best = -1.0
        for lag in -16...16 {
            var ab = 0.0, aa = 0.0, bb = 0.0
            for i in 16..<n {
                let x = Double(a[i]), y = Double(b[i + lag])
                ab += x * y; aa += x * x; bb += y * y
            }
            if aa > 0, bb > 0 { best = max(best, ab / (aa * bb).squareRoot()) }
        }
        return best
    }
}
