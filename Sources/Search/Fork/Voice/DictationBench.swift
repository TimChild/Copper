import AppKit
import Foundation
import SwiftUI

// Dictation, checked from the shell without a microphone: the real Voice
// session fed from a sound file instead of the mic, the keys sent through
// the app the way a press arrives, and the pane frozen in each state for
// pictures. Every verb here that changes something runs only in a test world.
//
//   voice dictate PATH [--trigger hold|toggle] [--finish insert|send]
//                      [--draft TEXT] [--caret N | --select A,B | --reopen] [--type TEXT]
//                      [--cancel-at S] [--tap] [--fail-at S] [--speed X]
//                      [--agent busy|unready] [--cap S] [--undo] [--keys CHARS]
//                      [--warm-delay S [--start-cold]]
//                      [--permission denied|ask-grant|ask-deny [--release-during-prompt]]
//   voice source PATH [--speed X] | off     ⌃⇧D and the mic hear this file
//   voice key down|up|press|ctrl-up|escape [CHARS]   ⌃⇧D (or Escape) through NSApp.sendEvent;
//                                           CHARS what the D key types (default d; в is a Russian layout)
//   voice warm cold [DELAY] | now           the model let go (and every load held DELAY s), then loaded as
//                                           the pane opening does; now = loaded and waited for
//   voice seed idle|dictating|finishing|finishing-warming|denied|preparing|warming|downloading|…
//   voice render PATH [WIDTH] [dark]        the pane, drawn off screen at WIDTH
//   voice prefs on|off|hold|toggle|insert|send
//   voice model status|install|cancel|remove
//   voice state                             phase, mic, line, engine, counts, the last timeline
//   voice editor state|type TEXT|event|boundary|undo|redo   the composer's field editor against the draft

@MainActor
enum DictationBench {
    static func handle(_ op: String, _ args: [String], in browser: Browser?, answer: @escaping ([String: Any]) -> Void,
                       job: (String, @escaping @MainActor () async -> [String: Any]) -> Void) -> Bool {
        let voice = Voice.shared
        switch op {
        case "state":
            answer(voice.benchState())
        case "model":
            answer(ModelStore.shared.bench(args.first ?? "status"))
        case "prefs":
            guard Store.testing else { answer(["error": "voice prefs only changes a test world"]); return true }
            for word in args {
                switch word {
                case "on": VoicePrefs.shared.enabled = true
                case "off": VoicePrefs.shared.enabled = false
                case "hold": VoicePrefs.shared.trigger = .hold
                case "toggle": VoicePrefs.shared.trigger = .toggle
                case "insert": VoicePrefs.shared.finish = .insert
                case "send": VoicePrefs.shared.finish = .send
                default: answer(["error": "voice prefs on|off|hold|toggle|insert|send"]); return true
                }
            }
            answer(voice.benchState())
        case "seed":
            guard let browser else { answer(["error": "no browser"]); return true }
            Agent.shared.open = true
            if let error = voice.seed(args.first ?? "dictating", in: browser) { answer(["error": error]); return true }
            answer(voice.benchState())
        case "render":
            guard let browser else { answer(["error": "no browser"]); return true }
            answer(render(args, in: browser))
        case "source":
            guard Store.testing else { answer(["error": "voice source only works in a test world"]); return true }
            if args.first == "off" {
                voice.testSource = nil
                answer(voice.benchState())
                return true
            }
            guard let path = args.first else { answer(["error": "voice source PATH [--speed X] | off"]); return true }
            let speed = number(args, "--speed") ?? 1
            do {
                let samples = try VoiceBench.read(URL(fileURLWithPath: path))
                voice.testSource = { VoiceFileSource(samples: samples, speed: speed) }
                var out = voice.benchState()
                out["source_s"] = VoiceBench.rounded(Double(samples.count) / 16_000, 2)
                answer(out)
            } catch {
                answer(["error": "\(path): \(error.localizedDescription)"])
            }
        case "key":
            guard let browser else { answer(["error": "no browser"]); return true }
            answer(key(args.first ?? "press", characters: args.dropFirst().first ?? "d", in: browser))
        case "warm":
            guard Store.testing else { answer(["error": "voice warm only works in a test world"]); return true }
            switch args.first ?? "now" {
            case "cold":
                let delay = args.dropFirst().first.flatMap(Double.init)
                job("warm") { await voice.benchCold(delay: delay, start: true); return voice.benchState() }
            case "now":
                job("warm") {
                    let started = Date()
                    let ok = await voice.benchWarmed()
                    var out = voice.benchState()
                    out["warmed"] = ok
                    out["warm_ms"] = VoiceBench.rounded(Date().timeIntervalSince(started) * 1000, 1)
                    return out
                }
            default:
                answer(["error": "voice warm cold [DELAY] | now"])
            }
        case "editor":
            // The composer's field editor itself: what it holds against the
            // draft, typing into it, and its undo — to tell a dictation's
            // insert from a person's typing.
            guard Store.testing, let browser else { answer(["error": "voice editor only works in a test world"]); return true }
            let window = Windows.window(of: browser)
            guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor else { answer(["error": "the composer doesn't have the keyboard"]); return true }
            var out: [String: Any] = [:]
            switch args.first ?? "state" {
            case "type": editor.insertText(args.dropFirst().joined(separator: " "), replacementRange: editor.selectedRange())
            case "undo", "redo":
                // ⌘Z / ⇧⌘Z as the Edit menu sends them.
                out["via"] = menuAction(args.first ?? "undo", editor: editor, window: window)
            case "boundary":
                // What happens between two key presses: an event fetched (the
                // last edit's undo group closes).
                postBoundary()
            case "event":
                // One event through the app, as a key press between the
                // insert and ⌘Z would be.
                if let window, let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                           context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56) {
                    NSApp.sendEvent(event)
                }
            default: break
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                out["editor"] = editor.string
                out["field"] = (editor.delegate as? NSTextField)?.stringValue ?? NSNull()
                out["draft"] = Agent.shared.draft
                out["inSync"] = editor.string == Agent.shared.draft
                out["selection"] = [editor.selectedRange().location, editor.selectedRange().length]
                out["undoName"] = editor.undoManager?.undoActionName ?? ""
                out["canUndo"] = editor.undoManager?.canUndo ?? false
                out["canRedo"] = editor.undoManager?.canRedo ?? false
                out["grouping"] = editor.undoManager?.groupingLevel ?? -1
                out["undoFollowed"] = ComposerInsert.followed
                answer(out)
            }
        case "dictate":
            guard let browser else { answer(["error": "no browser"]); return true }
            guard Store.testing else { answer(["error": "voice dictate only runs in a test world"]); return true }
            job("dictate") { await dictate(args, in: browser) }
        default:
            return false
        }
        return true
    }

    // MARK: - a dictation from a file

    static func dictate(_ args: [String], in browser: Browser) async -> [String: Any] {
        guard let path = args.first, !path.hasPrefix("--") else { return ["error": "voice dictate PATH [--trigger hold|toggle] [--finish insert|send] …"] }
        let voice = Voice.shared, agent = Agent.shared, prefs = VoicePrefs.shared
        guard prefs.enabled else { return ["error": "voice is off in this world — `voice prefs on` first"] }
        let trigger = value(args, "--trigger").flatMap(VoiceTrigger.init(rawValue:)) ?? prefs.trigger
        let finish = value(args, "--finish").flatMap(VoiceFinish.init(rawValue:)) ?? prefs.finish
        let speed = number(args, "--speed") ?? 1
        let cancelAt = number(args, "--cancel-at")
        let failAt = number(args, "--fail-at")
        let tap = args.contains("--tap")
        let agentMode = value(args, "--agent") ?? ""
        // ⌃⇧D through the app's key monitor instead of the bench's own hand,
        // with CHARS what the D key types (в: a Russian layout).
        let keys = value(args, "--keys")
        let warmDelay = number(args, "--warm-delay")
        let samples: [Swift.Float]
        do { samples = try await Task.detached(priority: .userInitiated) { try VoiceBench.read(URL(fileURLWithPath: path)) }.value } catch {
            return ["error": "\(path): \(error.localizedDescription)"]
        }

        // Out of any frozen picture state first.
        voice.cancel("bench")
        voice.seededModel = nil
        if voice.active || voice.phase != .idle { _ = voice.seed("off", in: browser) }
        let saved = (prefs.trigger, prefs.finish, voice.testSource)
        defer {
            prefs.trigger = saved.0
            prefs.finish = saved.1
            voice.testSource = saved.2
            voice.benchRange = nil
            voice.benchAgentReady = nil
        }
        prefs.trigger = trigger
        prefs.finish = finish
        if agentMode == "busy" { _ = agent.bench(["op": "seed", "arg": "running"], in: browser) }
        agent.open = true
        if let draft = value(args, "--draft") { agent.draft = draft }
        let reopen = args.contains("--reopen")
        if reopen {
            // Closed and opened again the way ⌘E does: the field takes the
            // keyboard and selects the whole draft, and nothing else is set.
            agent.open = false
            await sleep(0.3)
            agent.toggle()
            await sleep(0.5)
        }
        let before = agent.draft
        let length = (before as NSString).length
        if reopen {
            voice.benchRange = nil
        } else if let select = value(args, "--select") {
            let ends = select.split(separator: ",").compactMap { Int($0) }
            if ends.count == 2 { voice.benchRange = NSRange(location: ends[0], length: max(ends[1] - ends[0], 0)) }
        } else if let caret = number(args, "--caret") {
            voice.benchRange = NSRange(location: Int(caret), length: 0)
        } else {
            voice.benchRange = NSRange(location: length, length: 0)
        }
        voice.benchAgentReady = agentMode == "unready" ? false : nil
        voice.benchCap = number(args, "--cap")
        switch value(args, "--permission") {
        case "denied": voice.benchPermission = (.denied, false, 0)
        case "ask-grant": voice.benchPermission = (.notDetermined, true, 0.6)
        case "ask-deny": voice.benchPermission = (.notDetermined, false, 0.6)
        default: voice.benchPermission = nil
        }
        defer { voice.benchCap = nil; voice.benchPermission = nil }
        // With the composer's editor in place (the pane focuses it on
        // opening), the selection is put there and the dictation reads it
        // back the way it would a person's; otherwise it is handed over.
        await sleep(0.15)
        let window = Windows.window(of: browser)
        let editor = ComposerInsert.composerEditor(in: window, draft: agent.draft)
        if let editor, let range = voice.benchRange {
            editor.setSelectedRange(ComposerInsert.clamp(range, in: agent.draft))
            voice.benchRange = nil
        }
        let selectionBefore = editor?.selectedRange()
        var out: [String: Any] = [:]
        if let typed = value(args, "--type") {
            // Typed at the caret first, as a person would, then a key press's
            // worth of event loop: the dictation must undo apart from it.
            guard let editor else { return ["error": "--type needs the composer's editor (the pane's field with the keyboard)"] }
            editor.insertText(typed, replacementRange: editor.selectedRange())
            out["typed"] = typed
        }
        postBoundary()
        await sleep(0.15)
        let preDictation = agent.draft
        let source = VoiceFileSource(samples: samples, speed: speed, failAt: failAt)
        voice.testSource = { source }
        func press() {
            if let keys { out["keyDown"] = key(trigger == .hold ? "down" : "press", characters: keys, in: browser)["consumedNow"] }
            else { voice.press(.bench, in: browser, window: window) }
        }
        func release() {
            if let keys { out["keyUp"] = key(trigger == .hold ? "up" : "press", characters: keys, in: browser)["consumedNow"] }
            else if trigger == .hold { voice.lift(.bench) } else { voice.press(.bench, in: browser, window: window) }
        }

        if let warmDelay {
            // The model let go and its next load slow (the Neural Engine
            // preparing it again, as after a macOS update), then loaded as
            // the pane opening does.
            // --start-cold: nothing loading when the press comes (let go after
            // idle minutes); the dictation itself starts the load.
            let startCold = args.contains("--start-cold")
            await voice.benchCold(delay: warmDelay, start: !startCold)
            if !startCold {
                // Pressed once the load has run past a second: turned away, nothing captured.
                await sleep(Voice.slowLoad + 0.25)
                var seen: [String: Any] = ["engine": voice.engineState.rawValue, "engineSlow": voice.engineSlow]
                switch voice.mic(agentReady: Agent.shared.ready) {
                case .preparing: seen["mic"] = "preparing"
                case .ready: seen["mic"] = "ready"
                default: seen["mic"] = "other"
                }
                let refused = voice.refusedPreparing
                press()
                await sleep(0.2)
                seen["phase"] = Voice.name(voice.phase)
                seen["note"] = voice.note ?? NSNull()
                seen["captured"] = voice.active
                seen["refused"] = voice.refusedPreparing - refused
                if trigger == .hold, keys != nil { release() }
                out["whilePreparing"] = seen
                // Then, once loaded, a dictation as usual.
                let started = Date()
                let limit = Date().addingTimeInterval(warmDelay + 60)
                while voice.engineState == .warming, Date() < limit { await sleep(0.05) }
                out["preparedAfter_ms"] = Int(Date().timeIntervalSince(started) * 1000)
                out["micAfterPrepared"] = voice.mic(agentReady: Agent.shared.ready) == .ready ? "ready" : "not ready"
                // From here, loads are quick again.
                voice.benchWarmDelay = nil
            }
        } else {
            // Warm, as the pane opening does, so the numbers are a warm dictation's.
            let started = Date()
            out["warmed"] = await voice.benchWarmed()
            out["warm_ms"] = VoiceBench.rounded(Date().timeIntervalSince(started) * 1000, 1)
        }
        defer { voice.benchWarmDelay = nil }

        press()
        // The stand-in permission question: let go while it is up, or wait for its answer.
        if voice.phase == .arming {
            if args.contains("--release-during-prompt") {
                await sleep(0.2)
                voice.lift(.bench)
            }
            let asking = Date().addingTimeInterval(5)
            while voice.phase == .arming, Date() < asking { await sleep(0.02) }
        }
        if voice.phase == .dictating {
            if tap {
                await sleep(0.1)
                release()
            } else if let cancelAt {
                await sleep(cancelAt / max(speed, 0.01))
                // Someone clicked elsewhere in the field meanwhile: the
                // cancel still puts the selection back where it started.
                editor?.setSelectedRange(NSRange(location: 0, length: 0))
                voice.cancel("bench")
            } else {
                let limit = Date().addingTimeInterval(Double(samples.count) / 16_000 / max(speed, 0.01) + 15)
                while !source.drained, voice.phase == .dictating, Date() < limit { await sleep(0.02) }
                // A person lets go a beat after the last word.
                await sleep(0.15)
                if voice.phase == .dictating { release() }
            }
        }
        // What the line says while the last decode waits (on a slow load, too).
        var lines: [String] = []
        let limit = Date().addingTimeInterval(90)
        while voice.active, Date() < limit {
            if voice.phase == .finishing, let line = voice.benchState()["line"] as? String, lines.last != line { lines.append(line) }
            await sleep(0.02)
        }
        if !lines.isEmpty { out["finishingLines"] = lines }
        let draftAfterInsert = agent.draft

        for (name, state) in voice.benchState() where out[name] == nil { out[name] = state }
        out["draftBefore"] = before
        out["draftAfter"] = agent.draft
        out["draftUnchanged"] = before == agent.draft
        out["draftBeforeUTF8"] = Array(before.utf8).count
        out["draftAfterUTF8"] = Array(agent.draft.utf8).count
        out["editor"] = editor != nil
        if let selectionBefore { out["selectionBefore"] = [selectionBefore.location, selectionBefore.length] }
        if let now = ComposerInsert.composerEditor(in: window, draft: agent.draft)?.selectedRange() {
            out["selectionAfter"] = [now.location, now.length]
        }
        out["trigger"] = trigger.rawValue
        out["finish"] = finish.rawValue
        out["clip_s"] = VoiceBench.rounded(Double(samples.count) / 16_000, 2)
        if let inserted = voice.lastInsert {
            // The words went after everything (a whole-draft selection) rather than over it.
            out["appended"] = agent.draft.hasPrefix(preDictation) && agent.draft.hasSuffix(inserted.piece)
        }
        let rows = voice.timeline
        if let stop = rows.first(where: { $0.event.hasPrefix("finishing") })?.ms,
           let landed = rows.first(where: { $0.event == "inserted" || $0.event == "empty" })?.ms {
            out["release_to_insert_ms"] = landed - stop
        }
        // ⌘Z, then ⇧⌘Z, as the Edit menu sends them, a key press's worth of
        // event loop after the words landed: one step back to the text before
        // the dictation, the draft (what Return sends) with it; one forward.
        if args.contains("--undo") {
            postBoundary()
            await sleep(0.2)
            let editor = ComposerInsert.composerEditor(in: window, draft: agent.draft)
            let undo = editor?.undoManager ?? window?.undoManager
            out["canUndo"] = undo?.canUndo ?? false
            out["undoName"] = undo?.undoActionName ?? ""
            out["undoGrouping"] = undo?.groupingLevel ?? -1
            out["undoVia"] = menuAction("undo", editor: editor, window: window)
            await sleep(0.2)
            out["draftAfterUndo"] = agent.draft
            out["editorAfterUndo"] = editor?.string ?? NSNull()
            out["undoOneStep"] = agent.draft == preDictation
            out["inSyncAfterUndo"] = editor.map { $0.string == agent.draft } ?? true
            out["canRedo"] = undo?.canRedo ?? false
            postBoundary()
            await sleep(0.2)
            out["redoVia"] = menuAction("redo", editor: editor, window: window)
            await sleep(0.2)
            out["draftAfterRedo"] = agent.draft
            out["editorAfterRedo"] = editor?.string ?? NSNull()
            out["redoRestores"] = agent.draft == draftAfterInsert
            out["inSyncAfterRedo"] = editor.map { $0.string == agent.draft } ?? true
            if out["typed"] != nil {
                // Twice back: the dictation, then the typing, each its own step.
                postBoundary()
                await sleep(0.2)
                _ = menuAction("undo", editor: editor, window: window)
                await sleep(0.2)
                postBoundary()
                await sleep(0.2)
                _ = menuAction("undo", editor: editor, window: window)
                await sleep(0.2)
                out["draftAfterTwoUndos"] = agent.draft
                out["inSyncAfterTwoUndos"] = editor.map { $0.string == agent.draft } ?? true
            }
            out["undoFollowed"] = ComposerInsert.followed
        }
        if agentMode == "busy" || finish == .send {
            out["agentItems"] = agent.items.suffix(3).map { ["kind": "\($0.kind)", "text": String($0.text.prefix(120))] as [String: Any] }
            if agent.busy { agent.stop() }
        }
        return out
    }

    // MARK: - keys, as the app receives them

    /// ⌃⇧D down or up, or Escape, through NSApp.sendEvent: the local
    /// monitors see it the way they see a real press.
    static func key(_ what: String, characters: String = "d", in browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "voice key only works in a test world — it presses keys in your window"] }
        guard let window = Windows.window(of: browser) else { return ["error": "no window"] }
        let before = (VoiceKeys.consumed, VoiceKeys.passed)
        func post(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ characters: String, _ code: UInt16) {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { return }
            NSApp.sendEvent(event)
        }
        let chord: NSEvent.ModifierFlags = [.control, .shift]
        switch what {
        case "down":
            post(.flagsChanged, chord, "", 56)
            post(.keyDown, chord, characters, 2)
        case "up":
            post(.keyUp, chord, characters, 2)
            post(.flagsChanged, [], "", 56)
        case "press":
            post(.flagsChanged, chord, "", 56)
            post(.keyDown, chord, characters, 2)
            post(.keyUp, chord, characters, 2)
            post(.flagsChanged, [], "", 56)
        case "ctrl-up":
            post(.flagsChanged, [.shift], "", 59)
        case "escape":
            post(.keyDown, [], "\u{1B}", 53)
            post(.keyUp, [], "\u{1B}", 53)
        default:
            return ["error": "voice key down|up|press|ctrl-up|escape"]
        }
        var out = voice.benchState()
        out["consumedNow"] = VoiceKeys.consumed - before.0
        out["passedNow"] = VoiceKeys.passed - before.1
        return out
    }

    private static var voice: Voice { Voice.shared }

    /// ⌘Z or ⇧⌘Z the way the Edit menu sends it: `undo:`/`redo:` to whoever
    /// has the keyboard. The menu's own way needs a key window, which a
    /// background probe never has; then down the composer editor's responder
    /// chain, which is where it would have gone (NSWindow.undo:).
    static func menuAction(_ name: String, editor: NSTextView?, window: NSWindow?) -> String {
        let action = Selector((name + ":"))
        if NSApp.sendAction(action, to: nil, from: nil) { return "menu action" }
        if let editor, editor.tryToPerform(action, with: nil) { return "responder chain" }
        if let window, window.tryToPerform(action, with: nil) { return "window" }
        return "none"
    }

    /// An event for the app's loop to fetch, as a person's next key press
    /// would be: AppKit closes the undo group the last edit opened when it
    /// fetches one. Nothing receives it.
    static func postBoundary() {
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                             subtype: 0, data1: 0, data2: 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    // MARK: - pictures

    /// The pane at WIDTH (340–620), light or dark, drawn through a hosting
    /// view like `render agent` — whole, off screen, no window brought forward.
    static func render(_ args: [String], in browser: Browser) -> [String: Any] {
        guard let path = args.first else { return ["error": "voice render PATH [WIDTH] [dark]"] }
        let width = CGFloat(args.dropFirst().compactMap { Double($0) }.first ?? Double(AgentPane.width))
        let dark = args.contains("dark")
        let height: CGFloat = 520
        let pane = AgentPane(browser: browser, fixedWidth: width)
            .frame(height: height)
            .background(Palette.ground)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: pane)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        // At 2×, whatever screen (if any) the window would be on.
        guard let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return ["error": "no image"] }
        picture.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: picture)
        guard let png = picture.representation(using: .png, properties: [:]) else { return ["error": "no png"] }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
        // The composer's rows must fit: nothing drawn wider than the pane.
        let fitting = host.fittingSize.width
        return ["path": path, "size": [picture.pixelsWide, picture.pixelsHigh], "width": width, "fittingWidth": fitting,
                "phase": Voice.name(Voice.shared.phase)]
    }

    // MARK: - arguments

    static func value(_ args: [String], _ flag: String) -> String? {
        guard let at = args.firstIndex(of: flag), at + 1 < args.count else { return nil }
        return args[at + 1]
    }

    static func number(_ args: [String], _ flag: String) -> Double? { value(args, flag).flatMap(Double.init) }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}

/// What dictation adds to `voice selftest`: the composer arithmetic, the
/// live session on the real decoder, a clip of exactly 15.00 s, the keys,
/// and what the mic shows in each model state.
enum VoiceChecks {
    @MainActor private static var registered = false

    @MainActor static func register() {
        guard !registered else { return }
        registered = true
        VoiceBench.extraChecks.append(("composer insert", { ComposerInsert.checks() }))
        VoiceBench.extraChecks.append(("live", {
            if #available(macOS 15, *), await VoiceEngine.shared.isReady {
                return await LiveSessionChecks.run(decode: { samples in try await VoiceEngine.shared.transcribe(samples).text })
            }
            return await LiveSessionChecks.run(decode: nil)
        }))
        VoiceBench.extraChecks.append(("15.00 s clip", { await fifteenSeconds() }))
        VoiceBench.extraChecks.append(("keys and mic states", { await MainActor.run { keyAndMicChecks() } }))
    }

    /// Exactly 240,000 samples — one more frame than the 15 s encoder takes
    /// as one window — and its neighbours decode without throwing.
    static func fifteenSeconds() async -> [String] {
        guard #available(macOS 15, *) else { return [] }
        guard await VoiceEngine.shared.isReady else { return [] }
        let text = "This morning the release manager opened the agent pane and checked the dashboard. The first card showed a pending "
            + "pull request for a small accessibility fix. She asked the assistant to compare the colors with the design guide."
        guard let spoken = await VoiceBench.speak(text)?.samples, !spoken.isEmpty else { return ["couldn't synthesize the clip"] }
        var failures: [String] = []
        for count in [239_999, 240_000, 240_001] {
            var clip = Array(spoken.prefix(count))
            if clip.count < count { clip += VoiceBench.roomQuiet(seconds: Double(count - clip.count) / 16_000) }
            do {
                let heard = try await VoiceEngine.shared.transcribe(clip)
                if heard.text.isEmpty { failures.append("\(count) samples decoded to nothing") }
                if count == 240_000, spoken.count <= count {
                    let wer = VoiceBench.wordErrorRate(reference: text, heard: heard.text)
                    if wer > 0.2 { failures.append("240000 samples: word error rate \(VoiceBench.rounded(wer * 100, 1))%") }
                }
            } catch {
                failures.append("\(count) samples threw \(error.localizedDescription)")
            }
        }
        return failures
    }

    @MainActor static func keyAndMicChecks() -> [String] {
        var failures: [String] = []
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ characters: String, code: UInt16 = 2, repeating: Bool = false) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: code)
        }
        // keyCode 2 is the key in D's place on a US keyboard; 14 is E's, 4 H's (where Dvorak has D), 0 A's.
        let cases: [(NSEvent.ModifierFlags, String, UInt16, Bool)] = [
            ([.control, .shift], "d", 2, true), ([.control, .shift], "D", 2, true), ([.control], "d", 2, false), ([.command, .shift], "d", 2, false),
            ([.control, .shift, .option], "d", 2, false), ([.control, .shift, .command], "d", 2, false), ([.control, .shift], "e", 14, false),
            // A layout with no Latin letters: D's key types something else, and is still the key.
            ([.control, .shift], "в", 2, true), ([.control, .shift], "В", 2, true), ([.control, .shift], "δ", 2, true),
            ([.control, .shift], "ф", 0, false), ([.control], "в", 2, false), ([.control, .shift, .command], "в", 2, false),
            ([.control, .shift, .option], "в", 2, false), ([.shift], "в", 2, false),
            // D moved (Dvorak): the key that types d, wherever it is.
            ([.control, .shift], "d", 4, true), ([.control, .shift], "", 2, true), ([.control, .shift], "", 14, false),
        ]
        for (flags, characters, code, wanted) in cases {
            guard let e = event(.keyDown, flags, characters, code: code) else { failures.append("couldn't make a key event"); continue }
            if VoiceKeys.chord(e) != wanted { failures.append("chord(\(flags.rawValue), “\(characters)”, key \(code)) = \(!wanted)") }
        }
        // Letting go of D's key on a Russian layout ends a hold.
        if let up = event(.keyUp, [.control, .shift], "в"), !VoiceKeys.isD(up) { failures.append("key up of в (key 2) isn't D") }
        // A key event for no window is never taken (no pane can be open in it).
        if let e = event(.keyDown, [.control, .shift], "d"), VoicePrefs.shared.enabled, VoiceKeys.take(e) {
            failures.append("⌃⇧D for no window was taken")
        }
        // The mic's face in each model state.
        let voice = Voice.shared
        let kept = voice.seededModel
        defer { voice.seededModel = kept }
        if VoicePrefs.shared.enabled, VoicePrefs.supported {
            let wanted: [(ModelStore.State, Voice.Mic)] = [
                (.ready, .ready),
                (.downloading(0.42), .waiting("Speech model downloading · 42%")),
                (.preparing, .waiting("Preparing speech model — one time, about a minute")),
                (.failed("x"), .waiting("Speech model needs attention")),
            ]
            for (state, mic) in wanted {
                voice.seededModel = state
                if voice.mic(agentReady: true) != mic { failures.append("model \(state): mic \(voice.mic(agentReady: true))") }
            }
            if voice.mic(agentReady: false) != .unavailable("Sign in with Claude or add a key to use the agent") {
                failures.append("agent not ready: mic \(voice.mic(agentReady: false))")
            }
            // The model installed and its load past a second: preparing, dimmed.
            voice.seededModel = .ready
            let warming = voice.seededWarming
            voice.seededWarming = true
            if voice.mic(agentReady: true) != .preparing { failures.append("slow load: mic \(voice.mic(agentReady: true))") }
            voice.seededWarming = false
            if !voice.preparing, voice.mic(agentReady: true) != .ready { failures.append("loaded: mic \(voice.mic(agentReady: true))") }
            voice.seededWarming = warming
        }
        // The partial line: short partials whole, long ones cut at the start.
        let short = DictationPreview.fitted("Listening…", "open the logs", width: 300)
        if short != "Listening… open the logs" { failures.append("short partial shown as “\(short)”") }
        let long = DictationPreview.fitted("Listening…", String(repeating: "word ", count: 200) + "last", width: 300)
        if !long.hasPrefix("Listening… word") || !long.hasSuffix("word last") || long.count > 400 {
            failures.append("long partial not cut at the start")
        }
        return failures
    }
}
