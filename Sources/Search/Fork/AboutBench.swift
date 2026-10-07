import AppKit

/// `bench about …` — Settings › About and General's one-off actions in a
/// test world: Send Feedback's page, Make default (which a test run
/// refuses), and where the Settings pages' Copy and Open went.
@MainActor
enum AboutBench {
    private static let probe = URL(string: "https://example.com")!

    static func handle(_ request: [String: Any], in browser: Browser) -> [String: Any] {
        let op = request["op"] as? String ?? "status"
        let arg = request["arg"] as? String ?? ""
        switch op {
        case "status":
            return status(browser)
        case "feedback":
            // The same call as the About pill and Help › Send Feedback….
            Links.writeFeedback()
            guard let url = Feedback.lastOpened else { return ["error": "nothing opened"] }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return [
                "url": url.absoluteString,
                "host": url.host ?? "",
                "path": url.path,
                "title": items.first { $0.name == "title" }?.value ?? "",
                "body": items.first { $0.name == "body" }?.value ?? "",
                "tab": Windows.current.active?.address?.absoluteString ?? "",
                "settingsOpen": Windows.current.tuning,
            ]
        case "default":
            // Make default's own call; the answer arrives a moment later
            // (`about status` → announcement, handler).
            let before = handler()
            Links.becomeDefault { worked in
                browser.announce(worked && Links.isDefault ? "Links now open here"
                                 : Links.refusesDefault ? "Not in a test run" : "macOS didn't change it")
            }
            return ["refuses": Links.refusesDefault, "handlerBefore": before]
        case "copy":
            switch arg {
            case "pairing": CloudPairing.shared.copy()
            default: return ["error": "about copy pairing"]
            }
            return clipboard()
        case "clipboard":
            return clipboard()
        default:
            return ["error": "about status|feedback|default|copy pairing|clipboard"]
        }
    }

    private static func handler() -> String {
        NSWorkspace.shared.urlForApplication(toOpen: probe)?.path ?? ""
    }

    private static func status(_ browser: Browser) -> [String: Any] {
        [
            "refusesDefault": Links.refusesDefault,
            "isDefault": Links.isDefault,
            "handler": handler(),
            "announcement": browser.announcement ?? NSNull(),
            "updateLog": Updates.log.path,
        ]
    }

    /// The world's own pasteboard and what was opened — and the general
    /// pasteboard's change count, which a test run must leave alone.
    private static func clipboard() -> [String: Any] {
        [
            "text": SettingsActions.pasteboard.string(forType: .string) ?? "",
            "opened": SettingsActions.opened,
            "probe": SettingsActions.probe,
            "generalChangeCount": NSPasteboard.general.changeCount,
        ]
    }
}
