import Foundation

/// Small helpers for `bench flow …` answers (Flow.bench).
enum FlowBench {
    /// The switches as a script reads them.
    static func choice(_ choice: FlowModel.Choice) -> [String: Bool] {
        ["tabs": choice.tabs, "bookmarks": choice.bookmarks, "history": choice.history,
         "passwords": choice.passwords, "cookies": choice.cookies, "localStorage": choice.localStorage,
         "passkeys": choice.passkeys, "extensions": choice.extensions]
    }

    /// `--only tabs,history`: those switches on, the rest off.
    static func choice(only: String) -> FlowModel.Choice {
        var choice = FlowModel.Choice()
        choice.tabs = false; choice.bookmarks = false; choice.history = false; choice.passwords = false
        choice.cookies = false; choice.localStorage = false; choice.passkeys = false; choice.extensions = false
        for item in only.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch item {
            case "tabs", "spaces": choice.tabs = true
            case "bookmarks": choice.bookmarks = true
            case "history", "places": choice.history = true
            case "passwords": choice.passwords = true
            case "cookies": choice.cookies = true
            case "localstorage", "storage": choice.localStorage = true
            case "passkeys": choice.passkeys = true
            case "extensions": choice.extensions = true
            default: break
            }
        }
        return choice
    }
}
