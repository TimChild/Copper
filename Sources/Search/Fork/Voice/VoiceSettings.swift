import SwiftUI

// Settings › Voice: the switch, the speech model it needs, how a dictation
// starts and ends, and whose model it is. Drawn with Settings' own sections,
// lines and pills, so it reads as part of the same panel. Every row carries
// the anchor `SettingsIndex` lists for it (Fork/SettingsIndex.swift).

struct VoicePage: View {
    /// Not observed: the browser publishes for every tab and hover, and only
    /// its `open` is needed here, for the credits' links.
    let browser: Browser
    @ObservedObject private var prefs = VoicePrefs.shared
    @ObservedObject private var store = ModelStore.shared

    /// Voice is on and can be: the rows below the switch take part.
    private var live: Bool { prefs.enabled && VoicePrefs.supported }

    var body: some View {
        let _ = SettingsPerf.tick("voicePage") // Fork (settings-perf)
        VStack(alignment: .leading, spacing: 26) {
            SettingsSection("Voice on this Mac") {
                Line("Voice", enableDetail) {
                    Switch(on: Binding(
                        get: { prefs.enabled },
                        set: { on in
                            guard VoicePrefs.supported else { return }
                            withAnimation(Motion.settle) { prefs.enabled = on }
                        }
                    ))
                    .opacity(VoicePrefs.supported ? 1 : 0.4)
                    .allowsHitTesting(VoicePrefs.supported)
                    .accessibilityLabel("Voice")
                    .accessibilityValue(prefs.enabled ? "On" : "Off")
                }
                .settingsAnchor("voice.enabled")
                // Shown while voice is on, and while a model (or part of one)
                // is on disk with voice off — so it can still be removed.
                if VoicePrefs.supported, prefs.enabled || store.onDisk || store.partialBytes > 0 {
                    Rule()
                    VoiceModelRow(store: store, voiceOn: live)
                        .settingsAnchor("voice.model")
                }
            }

            SettingsSection("Talking to the agent") {
                Line("Talk", triggerDetail) {
                    Segmented(options: VoiceTrigger.allCases.map { ($0, $0.title) }, selection: $prefs.trigger)
                }
                .modifier(VoiceDimmed(on: live))
                .settingsAnchor("voice.trigger")
                Rule()
                Line("When you stop", finishDetail) {
                    Segmented(options: VoiceFinish.allCases.map { ($0, $0.title) }, selection: $prefs.finish)
                }
                .modifier(VoiceDimmed(on: live))
                .settingsAnchor("voice.finish")
            }

            credits
                .settingsAnchor("voice.credits")
        }
    }

    private var enableDetail: String {
        guard VoicePrefs.supported else { return "Voice needs macOS 15 or later." }
        return "Talk to the agent in the ⌘E pane. Speech is turned into text on this Mac; audio is never saved or sent."
    }

    private var triggerDetail: String {
        switch prefs.trigger {
        case .hold: return "Hold ⌃⇧D, or the mic button, while you speak."
        case .toggle: return "Press ⌃⇧D, or the mic button, to start — and again to stop."
        }
    }

    private var finishDetail: String {
        switch prefs.finish {
        case .insert: return "The words go into the message, for you to read before sending."
        case .send: return "The message goes to the agent as soon as you stop, as in a conversation."
        }
    }

    // MARK: - credits

    /// CC BY 4.0 asks for the name, the source and the licence wherever the
    /// model is offered; the links open in a tab beside yours.
    private var credits: some View {
        Text(creditsLine)
            .font(.system(size: 11.5))
            .foregroundStyle(SettingsInk.detail)
            .tint(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                browser.tuning = false
                browser.open(url, foreground: true)
                return .handled
            })
    }

    private var creditsLine: AttributedString {
        var line = AttributedString("Speech model: ")
        var phonon = AttributedString("Phonon-2")
        phonon.link = URL(string: "https://huggingface.co/FermionResearch/Phonon-2-CoreML")
        phonon.underlineStyle = .single
        var parakeet = AttributedString("NVIDIA Parakeet TDT 0.6B v3")
        parakeet.link = URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")
        parakeet.underlineStyle = .single
        line += phonon
        line += AttributedString(" by Fermion Research, based on ")
        line += parakeet
        line += AttributedString(" · CC BY 4.0")
        return line
    }
}

/// Faded and out of reach while voice is off, the way Labs fades a flight's
/// own settings.
private struct VoiceDimmed: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0.4)
            .allowsHitTesting(on)
            .disabled(!on)
            .animation(Motion.quick, value: on)
    }
}

// MARK: - the model's row

/// Where the speech model is: downloading, preparing, ready, or what went
/// wrong — with the one button that fits. With voice off it only says what
/// is on disk (faded) and keeps Remove, so space can be had back without
/// turning voice on.
private struct VoiceModelRow: View {
    @ObservedObject var store: ModelStore
    let voiceOn: Bool

    private var size: String { ModelStore.megabytes(ModelStore.totalBytes) }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Speech model")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: SettingsMetrics.detailSize(true)))
                    .foregroundStyle(SettingsMetrics.detailInk(true))
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction {
                    VoiceProgress(fraction: fraction)
                        .padding(.top, 5)
                }
            }
            .opacity(voiceOn ? 1 : 0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        // Settings' own `Line` metrics (Fork/SettingsLook.swift).
        .padding(.horizontal, SettingsMetrics.lineInset(true))
        .padding(.vertical, SettingsMetrics.lineHeight(true))
        .animation(Motion.quick, value: store.state)
    }

    private var fraction: Double? {
        guard voiceOn, case .downloading(let fraction) = store.state else { return nil }
        return fraction
    }

    private var paused: String {
        let fraction = Double(store.partialBytes) / Double(ModelStore.totalBytes)
        return "Paused at \(Self.percent(fraction)) of \(size)"
    }

    private var detail: String {
        guard voiceOn else {
            return store.onDisk ? "Ready · \(size)" : paused
        }
        switch store.state {
        case .absent:
            return store.partialBytes > 0 ? paused : "Phonon-2 · \(size), downloaded once and kept on this Mac"
        case .downloading(let fraction): return "Downloading · \(Self.percent(fraction)) of \(size)"
        case .verifying: return "Checking the download"
        case .compiling, .preparing: return "Preparing — one time, about a minute"
        case .ready: return "Ready · \(size)"
        case .failed(let why): return why
        }
    }

    @ViewBuilder
    private var control: some View {
        if !voiceOn {
            Pill("Remove") { store.remove() }
        } else {
            switch store.state {
            case .absent:
                Pill(store.partialBytes > 0 ? "Resume" : "Download") { store.install() }
            case .downloading:
                Pill("Cancel") { store.cancel() }
            case .verifying, .compiling, .preparing:
                Ring(size: 12)
                    .accessibilityLabel("Preparing")
            case .ready:
                Pill("Remove") { store.remove() }
            case .failed:
                Pill("Try again") { store.install() }
            }
        }
    }

    /// Whole percents; "less than 1%" rather than a 0% that is moving.
    static func percent(_ fraction: Double) -> String {
        let whole = Int((fraction * 100).rounded(.down))
        if whole == 0, fraction > 0 { return "less than 1%" }
        return "\(min(100, whole))%"
    }
}

/// A thin track that fills as the model arrives.
private struct VoiceProgress: View {
    let fraction: Double

    var body: some View {
        GeometryReader { space in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.wash)
                Capsule()
                    .fill(Palette.ink.opacity(0.75))
                    .frame(width: max(3, space.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(maxWidth: 220)
        .frame(height: 3)
        .animation(Motion.quick, value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Download")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}
