import AppKit
import SwiftUI

// Test seams for Settings › General, Tabs, Spaces, Downloads and Extensions
// (settings-browse): what a person would do in a panel the system puts on
// the screen — a save panel, a folder chooser — done by the bench instead,
// in a test run only, so a probe never puts a window in front of whoever is
// working beside it.

/// The panels Settings and its downloads put up — a folder chooser, a save
/// panel — as sheets on the window they are for. They were app-modal, so
/// every window froze until one was answered. With no window shown (or none
/// to be had) the panel is app-modal as before.
@MainActor
enum SettingsPanels {
    static func present(_ panel: NSSavePanel, on window: NSWindow?, done: @escaping (URL?) -> Void) {
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            done(response == .OK ? panel.url : nil)
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

/// The rail's lower edge, softened: at Settings' smallest the list of pages
/// runs on below it, and a hard cut gave no sign there was more.
struct SettingsRailFade: View {
    /// As tall as the rail's own bottom padding, so the last page, scrolled
    /// to, is never faded.
    static let height: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.height)
        }
    }
}

/// "Ask where to save each file", answered without a save panel in a test
/// run: the name it would have asked about is noted, and the bench says
/// where it goes — a folder, or cancel.
@MainActor
enum DownloadAsk {
    /// The names asked about, oldest first.
    private(set) static var asked: [String] = []
    /// `nil` saves into the downloads folder as the panel would offer; a
    /// path saves there; `cancel` is the panel's Cancel.
    static var reply: String?

    static func answer(_ name: String, in folder: URL) -> URL? {
        asked.append(name)
        if reply == "cancel" { return nil }
        let into = reply.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? folder
        try? FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        var candidate = into.appendingPathComponent(name)
        var n = 2
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = into.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    static func reset() {
        asked = []
        reply = nil
    }
}

/// `bench settings browse …`:
///   folder PATH      the downloads folder, as Change… would set it
///   ask [PATH|cancel|folder|reset]  how the save panel is answered; the names asked about
///   prefs            the Browsing pages' values as Settings shows them
///   glyph letters|icons  Tabs show, as its choice sets it
///   picture spaces|extensions PATH [WIDTH] [light|dark]  the whole page at a column width
@MainActor
enum SettingsBrowseBench {
    static func handle(_ arg: String, in browser: Browser) -> [String: Any] {
        guard Store.testing else { return ["error": "only in a test run"] }
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let prefs = browser.prefs
        switch words.first ?? "prefs" {
        case "folder":
            guard words.count == 2 else { return ["error": "settings browse folder PATH"] }
            prefs.downloads = URL(fileURLWithPath: (words[1] as NSString).expandingTildeInPath, isDirectory: true)
        case "ask":
            let what = words.count == 2 ? words[1] : ""
            switch what {
            case "": break
            case "reset": DownloadAsk.reset()
            case "folder": DownloadAsk.reply = nil
            default: DownloadAsk.reply = what
            }
            return ["asked": DownloadAsk.asked, "reply": DownloadAsk.reply ?? "folder", "asks": prefs.asksWhereToSave]
        case "prefs": break
        case "glyph":
            // glyph letters|icons: Tabs › Tabs show, as the choice would set it.
            guard words.count == 2, let glyph = Glyph(rawValue: words[1]) else { return ["error": "settings browse glyph letters|icons"] }
            prefs.glyph = glyph
        case "picture":
            // picture spaces|extensions PATH [WIDTH] [light|dark]: the whole page,
            // laid out at WIDTH (the page column; 345 is Settings' narrowest), not scrolled.
            var rest = words.count == 2 ? words[1].split(separator: " ").map(String.init) : []
            let look = ["light", "dark"].contains(rest.last ?? "") ? rest.removeLast() : nil
            let width = rest.count >= 3 ? Double(rest.removeLast()) : nil
            guard rest.count == 2 else { return ["error": "settings browse picture spaces|extensions PATH [WIDTH] [light|dark]"] }
            let dark = look.map { $0 == "dark" } ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            let column = CGFloat(width ?? Double(SpacePage.width))
            let png: NSBitmapImageRep?
            switch rest[0] {
            case "spaces": png = picture(SpacesSettingsPage(browser: browser), width: column, dark: dark)
            case "extensions":
                guard #available(macOS 15.4, *) else { return ["error": "extensions need macOS 15.4"] }
                png = picture(ExtensionsSettings(browser: browser, extensions: .shared), width: column, dark: dark)
            default: return ["error": "picture spaces|extensions"]
            }
            guard let data = png?.representation(using: .png, properties: [:]) else { return ["error": "no picture"] }
            let path = (rest[1] as NSString).expandingTildeInPath
            do { try data.write(to: URL(fileURLWithPath: path)) } catch { return ["error": "\(error)"] }
            return ["path": path, "width": column, "height": png?.size.height ?? 0]
        default: return ["error": "settings browse folder PATH|ask [PATH|cancel|folder|reset]|prefs|picture …"]
        }
        return values(browser)
    }

    /// A page drawn off screen at a given column width, the way it lays out
    /// in Settings at that width — to see what the narrowest window does to
    /// it without scrolling a window nobody can see.
    private static func picture<Page: View>(_ page: Page, width: CGFloat, dark: Bool) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: page
            .frame(width: width, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            .background(SettingsInk.content)
            .environment(\.settingsLook, true)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: picture)
        return picture
    }

    static func values(_ browser: Browser) -> [String: Any] {
        let prefs = browser.prefs
        return [
            "look": prefs.look.rawValue,
            "autocorrect": prefs.autocorrect,
            "webkitAutocorrect": UserDefaults.standard.bool(forKey: "WebAutomaticSpellingCorrectionEnabled"),
            "bench": prefs.bench,
            "sidebar": prefs.sidebar,
            "glyph": prefs.glyph.rawValue,
            "tabSwitching": prefs.tabSwitching.rawValue,
            "swipeDirection": prefs.swipeDirection.rawValue,
            "sleepsTabs": prefs.sleepsTabs,
            "archive": Sections.shared.archive.rawValue,
            "downloads": prefs.downloads.path,
            "asksWhereToSave": prefs.asksWhereToSave,
        ]
    }
}

/// A tab's mark in the sidebar, as Settings › Tabs › "Tabs show" says:
/// the site's icon, or its letter. The sidebar drew the icon whatever the
/// choice, so Letters did nothing there (D7). Watching the preferences here
/// redraws only the marks when the choice changes.
struct SideGlyphMark: View {
    @ObservedObject var prefs: Preferences
    let icon: NSImage?
    let letter: String
    let tint: SpaceTint
    var size: CGFloat = 16

    var body: some View {
        RowMark(icon: prefs.glyph == .icons ? icon : nil, letter: letter, tint: tint, size: size)
    }
}
