import AppKit

/// Copy and Open on Settings pages. In a test world with the bench on they
/// stay inside the world: a copy goes to a pasteboard of the world's own and
/// a file or address is noted rather than handed to another app, so a test
/// run never overwrites the clipboard of the person at the Mac (a copied
/// token included) or brings an editor forward. Everywhere else they are the
/// ordinary pasteboard and Finder.
@MainActor
enum SettingsActions {
    /// Whether this run keeps copies and opens to itself: a named test world
    /// with the bench on. False in the browser somebody is using.
    static var probe: Bool { seams(world: Store.world, bench: Store.settings.bool(forKey: "bench")) }

    /// The rule on its own, so a test can show it is off outside a probe.
    nonisolated static func seams(world: String?, bench: Bool) -> Bool {
        guard let world, !world.isEmpty else { return false }
        return bench
    }

    /// The pasteboard Settings reads and writes: the world's own in a probe.
    static var pasteboard: NSPasteboard {
        guard probe, let world = Store.world else { return .general }
        return NSPasteboard(name: NSPasteboard.Name("copper.probe.\(world)"))
    }

    /// What the pages asked to open, in a test world (`bench ai clipboard`).
    private(set) static var opened: [String] = []

    static func copy(_ text: String) {
        let board = pasteboard
        board.clearContents()
        board.setString(text, forType: .string)
    }

    static func open(_ url: URL) {
        if probe {
            opened.append(url.isFileURL ? url.path : url.absoluteString)
            return
        }
        NSWorkspace.shared.open(url)
    }
}
