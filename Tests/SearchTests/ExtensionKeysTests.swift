import AppKit
import Testing
@testable import Search

// Which keystrokes stay Copper's when an extension registered the same one
// (Extensions.ownKey). Claude's extension suggests ⌘E for its side panel, and
// extensions hear keys before the app does, so ⌘E never reached the agent pane.

private func press(_ key: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                  windowNumber: 0, context: nil, characters: key,
                                  charactersIgnoringModifiers: key, isARepeat: false, keyCode: 14))
}

/// A View menu shaped like Copper's: the agent on ⌘E, Ask on ⇧⌘E (SwiftUI
/// writes the shift into the mask), and one item written AppKit's way, as a capital.
@MainActor private func menu() -> NSMenu {
    let view = NSMenu(title: "View")
    view.addItem(withTitle: "Agent", action: nil, keyEquivalent: "e")
    let ask = view.addItem(withTitle: "Ask About This Page", action: nil, keyEquivalent: "e")
    ask.keyEquivalentModifierMask = [.command, .shift]
    view.addItem(withTitle: "Canvas", action: nil, keyEquivalent: "O")
    let bar = NSMenu()
    bar.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view
    return bar
}

@available(macOS 15.4, *)
@MainActor @Test func copperKeepsItsOwnKeys() throws {
    let bar = menu()
    #expect(Extensions.ownKey(try press("e", .command), in: bar))
    #expect(Extensions.ownKey(try press("E", [.command, .shift]), in: bar))
    #expect(Extensions.ownKey(try press("O", [.command, .shift]), in: bar))
}

@available(macOS 15.4, *)
@MainActor @Test func extensionsKeepKeysCopperDoesNotUse() throws {
    let bar = menu()
    #expect(!Extensions.ownKey(try press(".", [.command, .shift]), in: bar))
    #expect(!Extensions.ownKey(try press("e", [.command, .option]), in: bar))
    #expect(!Extensions.ownKey(try press("e", [.control, .shift]), in: bar))
    #expect(!Extensions.ownKey(try press("o", .command), in: bar))
    #expect(!Extensions.ownKey(try press("e", .command), in: nil))
}
