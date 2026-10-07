import AppKit
import Foundation

// Listen, checked from the shell without a microphone (DictationBench's
// sibling): the real Listen session, fed from a sound file.
//
//   voice listen start [--source PATH] [--fast | --speed X] [--wait] [--grant|--ask-grant|--ask-deny]
//                                   a file standing in for the mic (from the last
//                                   `listen start --source`, or `voice source`);
//                                   --fast feeds it as fast as the queue goes;
//                                   --wait answers once the file is heard out
//   voice listen pause|resume|stop|forget
//   voice listen state [--settle] [--last N]   phase, reason, segments, the last N, live, partial
//   voice listen close-pane|open-pane|sleep|lock|device-lost   what pauses it, as it arrives
//
// Every verb but `state` runs only in a test world (DictationBench.refusal).

@MainActor
enum ListenBench {
    /// The file source of the capture now running, to know when it's heard out.
    private static var current: VoiceFileSource?
    private static var speed: Double = 1

    static func handle(_ args: [String], in browser: Browser?, answer: @escaping ([String: Any]) -> Void,
                       job: (String, @escaping @MainActor () async -> [String: Any]) -> Void) {
        let listen = Listen.shared
        let verb = args.first ?? "state"
        let rest = Array(args.dropFirst())
        let last = Int(DictationBench.value(rest, "--last") ?? "") ?? 5
        switch verb {
        case "state":
            if rest.contains("--settle") {
                job("listen") { await settle(); return listen.benchState(last: last) }
            } else {
                answer(listen.benchState(last: last))
            }
        case "start", "resume":
            guard let browser else { answer(["error": "no browser"]); return }
            guard VoicePrefs.shared.enabled else { answer(["error": "voice is off in this world — `voice prefs on` first"]); return }
            if let path = DictationBench.value(rest, "--source") {
                do {
                    let samples = try VoiceBench.read(URL(fileURLWithPath: path))
                    speed = rest.contains("--fast") ? 0 : (DictationBench.number(rest, "--speed") ?? 1)
                    let pace = speed
                    listen.testSource = {
                        let source = VoiceFileSource(samples: samples, speed: pace)
                        ListenBench.current = source
                        return source
                    }
                } catch {
                    answer(["error": "\(path): \(error.localizedDescription)"])
                    return
                }
            } else if listen.testSource == nil, let dictation = Voice.shared.testSource {
                listen.testSource = dictation
            }
            if rest.contains("--ask-grant") { listen.benchPermission = (.notDetermined, true, 0.5) }
            else if rest.contains("--ask-deny") { listen.benchPermission = (.notDetermined, false, 0.5) }
            else { listen.benchPermission = nil }
            Agent.shared.open = true
            listen.start(in: browser)
            if rest.contains("--wait") {
                job("listen") { await settle(); return listen.benchState(last: last) }
            } else {
                answer(listen.benchState(last: last))
            }
        case "pause":
            listen.pause()
            answer(listen.benchState(last: last))
        case "stop":
            listen.stop()
            answer(listen.benchState(last: last))
        case "forget":
            listen.forget()
            answer(listen.benchState(last: last))
        case "close-pane", "open-pane":
            Agent.shared.open = verb == "open-pane"
            answer(listen.benchState(last: last))
        case "sleep":
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
            answer(listen.benchState(last: last))
        case "lock":
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: NSWorkspace.shared)
            answer(listen.benchState(last: last))
        case "device-lost":
            listen.benchDeviceLost()
            answer(listen.benchState(last: last))
        default:
            answer(["error": "voice listen start [--source PATH] [--fast] [--wait] | pause | resume | stop | forget | state [--settle]"])
        }
    }

    /// The file heard out, its last phrase finalized, every decode done.
    private static func settle() async {
        let limit = Date().addingTimeInterval(300)
        while let source = current, !source.drained, Listen.shared.capturing, Date() < limit {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // The pause that closes the last phrase: 0.7 s of room tone, at the file's pace.
        let close = speed > 0 ? 1.0 / speed : 0.05
        try? await Task.sleep(nanoseconds: UInt64((close + 0.1) * 1_000_000_000))
        await Listen.shared.benchSettle()
    }
}
