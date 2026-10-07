import Foundation
import os

// Live words over an offline speech model: a port of Fermion Research's own
// `phonon listen` loop (fermion-research 0.2.10, fermion/_speech/live.py,
// Apache-2.0).
//
// Phonon-2 keeps no streaming state. Every partial re-decodes the whole phrase
// in flight and a pause re-decodes it once more as the final — the vendor's
// live behaviour, kept as it is: 50 ms blocks; a block is voice when its RMS is
// above max(0.004, 0.18 × the phrase's loudest block); a first partial once
// 0.35 s of the phrase is in, another after each further 0.5 s; a final once
// 0.7 s has stayed under the gate. Partials are the whole hypothesis for the
// phrase in flight and replace each other; nothing is ever appended.
//
// What differs from live.py, and why:
// - Decoding runs off the feeding thread, one decode at a time, latest-only.
//   live.py decodes inline and lets the microphone queue back up behind it;
//   here a partial that comes due while a decode runs is remembered once and
//   taken from the newest audio when the decoder frees up, so a slow decode
//   never builds a backlog. A partial that comes back after its phrase was
//   finalized is dropped (a generation number per phrase).
// - Cadence counts audio, not wall time, as live.py's own self-clocking does
//   (next partial = the phrase's length when a partial returns + 0.5 s). A
//   file replayed faster than real time therefore gives the same events.
// - The first partial counts its 0.35 s from where voice began, not from the
//   phrase's first sample. live.py's phrase starts with whatever room tone
//   came before the voice, so its first partial of every later phrase lands
//   on the first voiced block with almost no voice in it; the two agree when
//   the speaker starts at once.
// - Listen caps a phrase at 15 s, not 30, so every final is a single window
//   of the encoder (longer audio is windowed with seams that add stray
//   punctuation and words). The cut lands after the quietest 50 ms block of
//   the last 3 s, and what comes after it starts the next phrase. "15 s" is
//   299 blocks (14.95 s): the runner sizes a window as its mel frames + 0.02 s,
//   so exactly 240,000 samples asks for 15.02 s and is refused.
// - A final decoded in one window can lose a whole sentence (Phonon-2 on
//   ~14 s of unbroken speech: 2 of 8 bench paragraphs; the same audio in
//   halves hears every word). Fermion's runner rescues its long-audio windows
//   with this same rule: under 2.4 words per second of speech, decode the two
//   halves (split at the quietest block, at most twice deep) and keep them if
//   they hear more words. Its other trigger — 1.5 s of speech under no word —
//   needs word timings, which `decode` doesn't return.
// - Room tone before a phrase keeps only its last second (live.py keeps that
//   second when it throws idle audio away at its 30 s cap), so silence never
//   eats into the 15 s cap or into a partial's decode.
// - Hold mode — push-to-talk — never finalizes by itself. Its partials decode
//   at most the last 15 s, starting no earlier than a second before the voice
//   did (a long quiet lead-in made the model hear "Yeah." in room tone);
//   finish() decodes the whole hold in one call (the engine windows anything
//   longer than one encoder window).

/// One finalized stretch of speech. `t0ms`/`t1ms` count from the session's
/// first sample; segments are ordered and never overlap.
struct VoiceSegment: Sendable, Equatable {
    let seq: Int
    let t0ms: Int
    let t1ms: Int
    let text: String
}

enum LiveEvent: Sendable, Equatable {
    /// The whole current hypothesis for the phrase in flight; replaces the last one.
    case partial(String)
    case final(VoiceSegment)
}

/// One dictation or listen session. Thread-safe: `feed` from the capture
/// queue, `finish`/`cancel` from anywhere. `emit` is called serially, never
/// with a lock of this session held, and never after `cancel()` returns —
/// so `emit` must not block waiting on a thread that might be calling
/// `cancel()` (hop to the main actor asynchronously instead).
final class LiveSession: @unchecked Sendable {
    enum Mode: Sendable { case hold, listen }

    // live.py's constants, in samples at 16 kHz.
    static let sampleRate = 16_000
    static let firstPartial = 5_600          // FIRST_PARTIAL_S = 0.35
    static let partialEvery = 8_000          // PARTIAL_EVERY_S = 0.50
    static let silenceClose = 11_200         // SILENCE_CLOSE_S = 0.70
    static let noiseFloor: Swift.Float = 0.004     // NOISE_FLOOR_RMS
    static let gateRatio: Swift.Float = 0.18       // GATE_RATIO
    // Copper's (see the notes above).
    static let maxPhrase = 239_200           // 15 s (see above); live.py's MAX_SEGMENT_S is 30
    static let cutSearch = 48_000            // the cut is looked for in the last 3 s
    static let preRoll = 16_000              // room tone kept ahead of a phrase
    static let partialWindow = 239_200       // hold partials decode the last 15 s
    static let rescueDensity = 2.4           // the runner's rescueMinDensity, words per speech-second

    private let mode: Mode
    private let decode: @Sendable ([Swift.Float]) async throws -> String
    private let emit: @Sendable (LiveEvent) -> Void

    /// Guards every field below. Never held across `decode` or `emit`.
    private let lock = NSLock()
    /// Held across `emit`, so `cancel()` cannot return while an event is
    /// being delivered. Recursive: `emit` may call `cancel()` itself.
    private let emitLock = NSRecursiveLock()

    private var phrase = Phrase(start: 0)
    private var heard = 0                    // samples fed this session
    private var generation = 0               // bumped whenever a phrase ends
    private var finals: [Job] = []           // finals waiting for the decoder, in order
    private var partialWanted = false        // one partial due; taken from the newest audio
    private var busy = false                 // a decode is running (at most one)
    private var inFlightWaiter: CheckedContinuation<String, Never>?
    private var idleWaiters: [() -> Void] = []
    private var finishing = false
    private var cancelled = false
    private var seq = 0
    private var failure: String?

    private static let log = Logger(subsystem: "com.collinrijock.copper", category: "voice")

    init(mode: Mode,
         decode: @escaping @Sendable ([Swift.Float]) async throws -> String,
         emit: @escaping @Sendable (LiveEvent) -> Void) {
        self.mode = mode
        self.decode = decode
        self.emit = emit
    }

    /// The last decode error, if any decode failed (its text counts as empty).
    var lastDecodeError: String? { lock.withLock { failure } }

    /// 16 kHz mono samples, nominally 50 ms (800) at a time.
    func feed(_ block: [Swift.Float]) {
        guard !block.isEmpty else { return }
        let level = Self.rms(block)
        lock.withLock {
            guard !finishing, !cancelled else { return }
            heard += block.count
            phrase.add(block, rms: level)
            switch mode {
            case .listen:
                // live.py's order: a pause ends the phrase, else the cap, else a partial.
                if phrase.voiced, phrase.count - phrase.lastVoice >= Self.silenceClose {
                    endPhrase(keeping: phrase.blocks.count)
                } else if phrase.count >= Self.maxPhrase, phrase.voiced {
                    endPhrase(keeping: phrase.quietestCut(within: Self.cutSearch))
                } else if !phrase.voiced {
                    phrase.trimIdle(to: Self.preRoll)
                } else if phrase.count >= phrase.nextPartial {
                    wantPartial()
                }
            case .hold:
                if phrase.voiced, phrase.count >= phrase.nextPartial { wantPartial() }
            }
        }
        pump()
    }

    /// Stops taking audio, final-decodes what is pending (listen: the phrase in
    /// flight; hold: the whole hold) and returns that final's text — "" when
    /// nothing was pending or it decoded to nothing. Emits `.final` for it if
    /// it is non-empty. Returns once every earlier event has been emitted.
    func finish() async -> String {
        await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            let accepted = lock.withLock { () -> Bool in
                guard !finishing, !cancelled else { return false }
                finishing = true
                partialWanted = false
                generation += 1
                if phrase.voiced, phrase.count > 0 {
                    finals.append(Job(kind: .final(t0ms: Self.ms(phrase.start), t1ms: Self.ms(phrase.start + phrase.count)),
                                      samples: phrase.samples(), generation: generation, waiter: done))
                } else {
                    idleWaiters.append { done.resume(returning: "") }
                }
                phrase = Phrase(start: heard)
                return true
            }
            if !accepted { done.resume(returning: "") }
            pump()
        }
    }

    /// Drops everything. No event is emitted after this returns; a pending
    /// `finish()` returns "".
    func cancel() {
        var wake: [() -> Void] = []
        emitLock.lock()
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            for job in finals { if let waiter = job.waiter { wake.append { waiter.resume(returning: "") } } }
            finals = []
            partialWanted = false
            if let waiter = inFlightWaiter {
                inFlightWaiter = nil
                wake.append { waiter.resume(returning: "") }
            }
            wake += idleWaiters
            idleWaiters = []
            phrase = Phrase(start: heard)
        }
        emitLock.unlock()
        wake.forEach { $0() }
    }

    /// Returns when no decode is running or due. A replay that waits for this
    /// after every block behaves as if decoding took no time, so its events
    /// are the same on every run (the checks use it).
    func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if cancelled || idleLocked { return true }
                idleWaiters.append { done.resume() }
                return false
            }
            if now { done.resume() }
        }
    }

    // MARK: - Scheduling (lock held unless noted)

    private var idleLocked: Bool { !busy && finals.isEmpty && !(partialWanted && !finishing) }

    private func wantPartial() {
        partialWanted = true
        // Re-armed when this partial comes back: the self-clocking of live.py.
        phrase.nextPartial = .max
    }

    /// Ends the phrase after its first `keeping` blocks and queues its final;
    /// any blocks after the cut start the next phrase.
    private func endPhrase(keeping n: Int) {
        let cut = min(max(n, 1), phrase.blocks.count)
        let spoken = Phrase.join(phrase.blocks[0..<cut])
        let t0 = phrase.start, t1 = phrase.start + spoken.count
        let rest = Array(zip(phrase.blocks[cut...], phrase.levels[cut...]))
        generation += 1
        partialWanted = false
        finals.append(Job(kind: .final(t0ms: Self.ms(t0), t1ms: Self.ms(t1)), samples: spoken, generation: generation, waiter: nil))
        phrase = Phrase(start: t1)
        for (block, level) in rest { phrase.add(block, rms: level) }
    }

    /// Starts the next decode if the decoder is free. Called without the lock.
    private func pump() {
        var job: Job?
        var wake: [() -> Void] = []
        lock.withLock {
            guard !busy, !cancelled else { return }
            if !finals.isEmpty {
                job = finals.removeFirst()
            } else if partialWanted, !finishing {
                partialWanted = false
                let audio = mode == .listen ? phrase.samples()
                    : phrase.tail(min(Self.partialWindow, phrase.count - max(0, phrase.onset - Self.preRoll)))
                job = Job(kind: .partial, samples: audio, generation: generation, waiter: nil)
            }
            if var next = job {
                busy = true
                inFlightWaiter = next.waiter
                next.waiter = nil
                job = next
            } else {
                wake = idleWaiters
                idleWaiters = []
            }
        }
        wake.forEach { $0() }
        guard let job else { return }
        Task.detached(priority: .userInitiated) { [self] in
            let began = DispatchTime.now().uptimeNanoseconds
            var text = ""
            var error: String?
            do {
                if job.isFinal { text = try await finalText(job.samples) } else { text = try await decode(job.samples) }
            } catch let thrown {
                error = thrown.localizedDescription
            }
            let took = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
            // Debug only, and never the words.
            Self.log.debug("decode \(job.isFinal ? "final" : "partial", privacy: .public) \(Double(job.samples.count) / 16_000, privacy: .public) s in \(took, privacy: .public) ms")
            complete(job, text.trimmingCharacters(in: .whitespacesAndNewlines), error: error)
        }
    }

    /// A decode came back: emit what it means, then free the decoder. The
    /// decoder stays busy until the event is out, so a later job's event can
    /// never overtake this one.
    private func complete(_ job: Job, _ text: String, error: String?) {
        var event: LiveEvent?
        var result = ""
        emitLock.lock()
        lock.withLock {
            if let error { failure = error }
            guard !cancelled else { return }
            switch job.kind {
            case .partial:
                guard job.generation == generation, !finishing else { return }   // stale: its phrase has ended
                phrase.nextPartial = phrase.count + Self.partialEvery
                if !text.isEmpty { event = .partial(text) }
            case .final(let t0, let t1):
                guard !text.isEmpty else { return }
                seq += 1
                event = .final(VoiceSegment(seq: seq, t0ms: t0, t1ms: t1, text: text))
                result = text
            }
        }
        if let event { emit(event) }
        let waiter = lock.withLock { () -> CheckedContinuation<String, Never>? in
            busy = false
            defer { inFlightWaiter = nil }
            return inFlightWaiter
        }
        emitLock.unlock()
        waiter?.resume(returning: result)
        pump()
    }

    /// A final's text, rescued when it heard too few words (see the notes at
    /// the top). Holds longer than one window are left to the engine, which
    /// windows them and rescues each window with word timings. A final that
    /// heard nothing at all is left alone: room tone decodes to nothing, and
    /// halves of it are only a chance for the model to invent a word.
    private func finalText(_ samples: [Swift.Float], depth: Int = 0) async throws -> String {
        let text = try await decode(samples).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.wordCount(text)
        guard words > 0, depth < 2, samples.count >= 3 * Self.sampleRate, samples.count <= Self.maxPhrase,
              let speech = Self.speechSeconds(samples), speech >= 2, Double(words) / speech < Self.rescueDensity else { return text }
        let cut = Self.quietestSplit(samples)
        guard let first = try? await finalText(Array(samples[..<cut]), depth: depth + 1),
              let second = try? await finalText(Array(samples[cut...]), depth: depth + 1) else { return text }
        let halves = [first, second].filter { !$0.isEmpty }.joined(separator: " ")
        let better = Self.wordCount(halves) > words
        Self.log.debug("rescue: \(words, privacy: .public) words in \(speech, privacy: .public) s of speech, halves \(Self.wordCount(halves), privacy: .public)")
        return better ? halves : text
    }

    private static func wordCount(_ text: String) -> Int { text.split(whereSeparator: { $0.isWhitespace }).count }

    /// Seconds of 50 ms blocks above the runner's gate for the whole window.
    private static func speechSeconds(_ x: [Swift.Float]) -> Double? {
        let blocks = x.count / 800
        guard blocks > 0 else { return nil }
        let levels = (0..<blocks).map { rms(Array(x[$0 * 800 ..< ($0 + 1) * 800])) }
        let gate = max(noiseFloor, gateRatio * (levels.max() ?? 0))
        return Double(levels.filter { $0 > gate }.count) * 0.05
    }

    /// The middle of the quietest 50 ms block in the middle third, at least 1 s from either end.
    private static func quietestSplit(_ x: [Swift.Float]) -> Int {
        let blocks = x.count / 800
        let low = max(sampleRate / 800, blocks / 3), high = min(blocks - sampleRate / 800, 2 * blocks / 3)
        guard low < high else { return x.count / 2 }
        var best = low, quietest = Swift.Float.greatestFiniteMagnitude
        for b in low..<high {
            let level = rms(Array(x[b * 800 ..< (b + 1) * 800]))
            if level < quietest { quietest = level; best = b }
        }
        return best * 800 + 400
    }

    // MARK: - Pieces

    private struct Job {
        enum Kind { case partial, final(t0ms: Int, t1ms: Int) }
        let kind: Kind
        let samples: [Swift.Float]
        let generation: Int
        var waiter: CheckedContinuation<String, Never>?
        var isFinal: Bool { if case .final = kind { return true } else { return false } }
    }

    /// The phrase in flight: its blocks, each block's RMS, and live.py's gate state.
    private struct Phrase {
        var blocks: [[Swift.Float]] = []
        var levels: [Swift.Float] = []
        var start: Int                    // session sample of blocks[0]
        var count = 0                     // samples in blocks
        var voiced = false                // anything above the gate yet
        var lastVoice = 0                 // `count` when voice was last heard
        var peak: Swift.Float = 0               // loudest block so far (the adaptive gate)
        var onset = 0                     // where voice began, in samples of the phrase
        var nextPartial = Int.max         // `count` at which the next partial is due

        init(start: Int) { self.start = start }

        mutating func add(_ block: [Swift.Float], rms level: Swift.Float) {
            blocks.append(block)
            levels.append(level)
            count += block.count
            peak = max(peak, level)
            if level > max(LiveSession.noiseFloor, LiveSession.gateRatio * peak) {
                if !voiced {
                    voiced = true
                    onset = count - block.count
                    nextPartial = onset + LiveSession.firstPartial
                }
                lastVoice = count
            }
        }

        /// Room tone ahead of any voice keeps only its last `keep` samples.
        /// Unvoiced, every block is at or under the absolute floor, so the
        /// gate is the floor either way and dropping blocks cannot move it.
        mutating func trimIdle(to keep: Int) {
            var drop = 0, dropped = 0
            while drop < blocks.count - 1, count - dropped - blocks[drop].count >= keep {
                dropped += blocks[drop].count
                drop += 1
            }
            guard drop > 0 else { return }
            blocks.removeFirst(drop)
            levels.removeFirst(drop)
            count -= dropped
            start += dropped
        }

        /// How many blocks to keep so the phrase ends with its quietest block
        /// among those covering the last `window` samples (the earliest, on a tie).
        func quietestCut(within window: Int) -> Int {
            guard var index = blocks.indices.last else { return 0 }
            var best = index, covered = 0
            while index >= 0, covered < window {
                if levels[index] <= levels[best] { best = index }
                covered += blocks[index].count
                index -= 1
            }
            return best + 1
        }

        func samples() -> [Swift.Float] { Phrase.join(blocks[...]) }

        /// The last `limit` samples (whole phrase when shorter).
        func tail(_ limit: Int) -> [Swift.Float] {
            guard count > limit else { return samples() }
            var first = blocks.count, taken = 0
            while first > 0, taken + blocks[first - 1].count <= limit {
                taken += blocks[first - 1].count
                first -= 1
            }
            var out = Phrase.join(blocks[first...])
            if taken < limit, first > 0 {
                // A block straddles the limit: take its end.
                let partial = blocks[first - 1].suffix(limit - taken)
                out.insert(contentsOf: partial, at: 0)
            }
            return out
        }

        static func join(_ slice: ArraySlice<[Swift.Float]>) -> [Swift.Float] {
            var out: [Swift.Float] = []
            out.reserveCapacity(slice.reduce(0) { $0 + $1.count })
            for block in slice { out.append(contentsOf: block) }
            return out
        }
    }

    static func rms(_ block: [Swift.Float]) -> Swift.Float {
        guard !block.isEmpty else { return 0 }
        var sum: Swift.Float = 0
        for x in block { sum += x * x }
        return (sum / Swift.Float(block.count)).squareRoot()
    }

    private static func ms(_ samples: Int) -> Int { samples * 1000 / sampleRate }
}
