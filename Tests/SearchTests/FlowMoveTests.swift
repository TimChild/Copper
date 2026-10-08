import CommonCrypto
import Foundation
import Testing
@testable import Search

// Moving in from Chrome (and Arc): the adopt planner and its registry
// (Fork/Flow/FlowState.swift FlowAdopt), the per-category summary
// (FlowSummary), what counts as "locked" (FlowAccess), what a dropped file is
// (FlowFiles) and the test passphrase's key (FlowSecrets).

private func tab(_ url: String, pinned: Bool = false, seen: Double? = nil) -> FlowModel.Tab {
    FlowModel.Tab(url: URL(string: url)!, title: url, pinned: pinned, seen: seen)
}

private func space(_ name: String, _ tabs: [FlowModel.Tab]) -> FlowModel.Space {
    FlowModel.Space(name: name, tabs: tabs)
}

@Suite("Flow move: adopt plan")
struct FlowAdoptTests {
    @Test("First move: one space per window with tabs; a window of only new-tab pages makes none")
    func firstMove() {
        let home = FlowAdopt.Existing(id: UUID(), name: "Home", addresses: [])
        let steps = FlowAdopt.plan(
            [space("Chrome", [tab("https://a.invalid/"), tab("https://b.invalid/x")]), space("Chrome 2", [])],
            source: "Chrome", registry: [:], existing: [home], pinned: []
        )
        #expect(steps.count == 2)
        #expect(steps[0].target == .make("Chrome"))
        #expect(steps[0].loose == [0, 1])
        #expect(steps[1].target == .none)
        #expect(steps[1].loose.isEmpty)
    }

    @Test("Second move fills the space the first one made, skipping tabs it has")
    func secondMoveFills() {
        let made = UUID()
        let existing = [
            FlowAdopt.Existing(id: UUID(), name: "Home", addresses: []),
            FlowAdopt.Existing(id: made, name: "Chrome", addresses: [FlowAdopt.address(URL(string: "https://a.invalid/")!)]),
        ]
        let steps = FlowAdopt.plan(
            [space("Chrome", [tab("https://a.invalid"), tab("https://c.invalid/")])],
            source: "Chrome", registry: ["chrome": made], existing: existing, pinned: []
        )
        #expect(steps == [FlowAdopt.Step(index: 0, key: "chrome", target: .fill(made), loose: [1], pins: [], skipped: 1)])
    }

    @Test("A space the person deleted is made again")
    func deletedIsRemade() {
        let steps = FlowAdopt.plan(
            [space("Work", [tab("https://a.invalid/")])], source: "Arc",
            registry: ["work": UUID()], existing: [FlowAdopt.Existing(id: UUID(), name: "Home", addresses: [])], pinned: []
        )
        #expect(steps.first?.target == .make("Work"))
    }

    @Test("Nothing new: every tab skipped, nothing to add")
    func nothingNew() {
        let made = UUID()
        let a = FlowAdopt.address(URL(string: "https://a.invalid/")!)
        let steps = FlowAdopt.plan(
            [space("Work", [tab("https://a.invalid/"), tab("https://a.invalid/#top")])], source: "Arc",
            registry: ["work": made], existing: [FlowAdopt.Existing(id: made, name: "Work", addresses: [a])], pinned: []
        )
        #expect(steps.first?.loose == [])
        #expect(steps.first?.skipped == 2)
    }

    @Test("Pins already pinned are skipped; a space of only pins makes no space")
    func pins() {
        let pinned: Set<String> = [FlowAdopt.address(URL(string: "https://mail.invalid/")!)]
        let steps = FlowAdopt.plan(
            [space("Favourites", [tab("https://mail.invalid/", pinned: true), tab("https://cal.invalid/", pinned: true)])],
            source: "Arc", registry: [:], existing: [], pinned: pinned
        )
        #expect(steps.first?.target == FlowAdopt.Target.none)
        #expect(steps.first?.pins == [1])
        #expect(steps.first?.skipped == 1)
    }

    @Test("Favourites every Arc space carries are pinned once, and never counted as 'already here' on a first move")
    func sharedFavourites() {
        let favourites = [tab("https://mail.invalid/", pinned: true), tab("https://cal.invalid/", pinned: true)]
        let spaces = (1...4).map { space("Space \($0)", favourites + [tab("https://s\($0).invalid/")]) }
        let first = FlowAdopt.plan(spaces, source: "Arc", registry: [:], existing: [], pinned: [])
        #expect(first.map(\.pins) == [[0, 1], [], [], []])
        #expect(first.map(\.skipped) == [0, 0, 0, 0])
        // Moving in again: each pin is already here once, not once per space.
        let pinned = Set(favourites.map { FlowAdopt.address($0.url) })
        let again = FlowAdopt.plan(spaces, source: "Arc", registry: [:], existing: [], pinned: pinned)
        #expect(again.map(\.pins) == [[], [], [], []])
        #expect(again.map(\.skipped).reduce(0, +) == 2)
    }

    @Test("A clashing name takes the source's name (X-12), numbered after that")
    func naming() {
        #expect(FlowAdopt.name("Work", source: "Safari", taken: ["work"]) == "Work (Safari)")
        #expect(FlowAdopt.name("Work", source: "Chrome", taken: ["work", "work (chrome)"]) == "Work (Chrome) 2")
        #expect(FlowAdopt.name("  ", source: "Chrome", taken: []) == "Chrome")
        let steps = FlowAdopt.plan(
            [space("Home", [tab("https://a.invalid/")]), space("Home", [tab("https://b.invalid/")])],
            source: "Arc", registry: [:], existing: [FlowAdopt.Existing(id: UUID(), name: "Home", addresses: [])], pinned: []
        )
        #expect(steps.map(\.target) == [.make("Home (Arc)"), .make("Home (Arc) 2")])
        #expect(steps.map(\.key) == ["home", "home#2"])
    }

    @Test("Imported tabs count as seen at the move, never earlier (X-11)")
    func seen() {
        let moved = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(FlowAdopt.seen(1_000_000_000, movedAt: moved) == 2_000_000_000)
        #expect(FlowAdopt.seen(nil, movedAt: moved) == 2_000_000_000)
    }

    @Test("Addresses match without fragment, trailing slash or host case")
    func addresses() {
        #expect(FlowAdopt.address(URL(string: "https://A.invalid/path/#x")!) == FlowAdopt.address(URL(string: "https://a.invalid/path")!))
        #expect(FlowAdopt.address(URL(string: "https://a.invalid/?q=1")!) != FlowAdopt.address(URL(string: "https://a.invalid/?q=2")!))
    }
}

@Suite("Flow move: summary")
struct FlowSummaryTests {
    @Test("Empty spaces and new-tab-only windows that made no space are said, not dropped in silence")
    func emptiesLeftOut() {
        var arc = FlowSummary.Facts(source: "Arc")
        arc.tabsChosen = true
        arc.windowsAreSpaces = true
        arc.windowsRead = 7
        arc.windowsEmpty = 3
        arc.tabsAdded = 228
        arc.pinsAdded = 5
        arc.spacesMade = 4
        #expect(FlowSummary.lines(arc).map(\.plain) == ["✓ Tabs: 228 tabs (5 pinned) in 4 spaces — 3 empty spaces left out"])
        var chrome = FlowSummary.Facts(source: "Chrome")
        chrome.tabsChosen = true
        chrome.windowsRead = 2
        chrome.windowsEmpty = 1
        chrome.tabsAdded = 3
        chrome.tabsSkipped = 2
        chrome.spacesFilled = 1
        #expect(FlowSummary.lines(chrome).map(\.plain) == ["✓ Tabs: 3 tabs in 1 space — 2 already here, 1 window of only new-tab pages left out"])
    }
    @Test("The real Chrome copy: only new-tab pages, no bookmarks, 44 places")
    func realChromeCopy() {
        var f = FlowSummary.Facts(source: "Chrome")
        f.tabsChosen = true
        f.windowsRead = 1
        f.windowsEmpty = 1
        f.bookmarksChosen = true
        f.historyChosen = true
        f.placesRead = 44
        f.placesNew = 44
        let lines = FlowSummary.lines(f).map(\.plain)
        #expect(lines == [
            "— Tabs: Chrome's last window had only new-tab pages",
            "— Bookmarks: Chrome has none",
            "✓ History: 44 places",
        ])
        #expect(FlowSummary.title(FlowSummary.lines(f), source: "Chrome") == "Moved in from Chrome")
    }

    @Test("Second run: nothing new, said per category")
    func secondRun() {
        var f = FlowSummary.Facts(source: "Arc")
        f.tabsChosen = true
        f.tabsSkipped = 12
        f.bookmarksChosen = true
        f.bookmarksRead = 40
        f.historyChosen = true
        f.placesRead = 1
        let lines = FlowSummary.lines(f)
        #expect(lines.map(\.plain) == [
            "— Tabs: nothing new — all 12 were already here",
            "— Bookmarks: nothing new — all 40 from Arc were already here",
            "— History: nothing new — 1 place already here",
        ])
        #expect(FlowSummary.title(lines, source: "Arc") == "Nothing new from Arc")
    }

    @Test("Grammar: one space, one tab; skipped tabs are named")
    func grammar() {
        var f = FlowSummary.Facts(source: "Chrome")
        f.tabsChosen = true
        f.tabsAdded = 1
        f.spacesMade = 1
        #expect(FlowSummary.lines(f).first?.plain == "✓ Tabs: 1 tab in 1 space")
        f.tabsAdded = 3
        f.tabsSkipped = 2
        f.spacesMade = 0
        f.spacesFilled = 2
        #expect(FlowSummary.lines(f).first?.plain == "✓ Tabs: 3 tabs in 2 spaces — 2 already here")
    }

    @Test("A refused key is said against each thing it would have unlocked")
    func refusedKey() {
        var f = FlowSummary.Facts(source: "Chrome")
        f.passwordsChosen = true
        f.cookiesChosen = true
        f.passkeysChosen = true
        let why = "macOS didn't hand over Chrome's key"
        f.passwordsWhy = why
        f.cookiesWhy = why
        f.passkeysWhy = why
        #expect(FlowSummary.lines(f).map(\.plain) == [
            "— Passwords: macOS didn't hand over Chrome's key",
            "— Passkeys: macOS didn't hand over Chrome's key",
            "— Sign-ins: macOS didn't hand over Chrome's key",
        ])
        #expect(FlowSummary.title(FlowSummary.lines(f), source: "Chrome") == "Nothing came over from Chrome")
    }

    @Test("One leg failing leaves the others standing")
    func legs() {
        var f = FlowSummary.Facts(source: "Chrome")
        f.passwordsChosen = true
        f.passwordsFound = 2
        f.passwordsKept = 2
        f.passwordsNew = 2
        f.cookiesChosen = true
        f.cookiesWhy = "couldn't read Chrome's cookies"
        #expect(FlowSummary.lines(f).map(\.plain) == [
            "✓ Passwords: 2 passwords",
            "— Sign-ins: couldn't read Chrome's cookies",
        ])
    }

    @Test("Sign-ins count sites and what WebKit took; extensions say where from")
    func cookiesAndExtensions() {
        var f = FlowSummary.Facts(source: "Chrome")
        f.cookiesChosen = true
        f.cookiesFound = 3
        f.cookiesSet = 3
        f.cookiesNew = 3
        f.cookieSites = 2
        f.extensionsChosen = true
        #expect(FlowSummary.lines(f).map(\.plain) == [
            "✓ Sign-ins: 2 sites (3 cookies)",
            "— Extensions: none from the Chrome Web Store",
        ])
    }

    @Test("Unchosen categories say nothing")
    func unchosen() {
        #expect(FlowSummary.lines(FlowSummary.Facts(source: "Chrome")).isEmpty)
    }
}

@Suite("Flow move: access, files, key")
struct FlowAccessFilesTests {
    @Test("EPERM, EACCES and Cocoa's no-permission are locked; no such file is not")
    func denied() {
        #expect(FlowAccess.denied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        #expect(FlowAccess.denied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(FlowAccess.denied(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 256,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(FlowAccess.denied(wrapped))
        #expect(!FlowAccess.denied(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
    }

    @Test("A folder that isn't there is missing; one that is, readable")
    func state() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flow-access-\(UUID().uuidString)")
        #expect(FlowAccess.state(of: folder) == .missing)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(FlowAccess.state(of: folder) == .readable)
    }

    @Test("The Allow button goes to Files & Folders first")
    func privacyPage() {
        #expect(FlowAccess.privacyPages.first?.hasSuffix("Privacy_FilesAndFolders") == true)
        #expect(FlowAccess.privacyPages.last?.hasSuffix("Privacy_AllFiles") == true)
    }

    @Test("A dropped file is told by what is in it")
    func kinds() {
        let html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p><DT><A HREF=\"https://a.invalid/\">A</A></DL>"
        #expect(FlowFiles.kind(of: html) == .bookmarks)
        #expect(FlowFiles.kind(of: "name,url,username,password,note\nA,https://a.invalid,me,pw,\n") == .passwords)
        #expect(FlowFiles.kind(of: "\u{FEFF}\"url\",\"username\",\"password\"\n") == .passwords)
        #expect(FlowFiles.kind(of: "title,url\nA,https://a.invalid\n") == .neither)
        #expect(FlowFiles.kind(of: "") == .neither)
    }

    @Test("File sentences")
    func sentences() {
        #expect(FlowFiles.bookmarkSentence(read: 40, new: 40, source: "Chrome") == "40 bookmarks from Chrome's file")
        #expect(FlowFiles.bookmarkSentence(read: 40, new: 0, source: "Chrome") == "Nothing new — the 40 bookmarks in that file were already here")
        #expect(FlowFiles.bookmarkSentence(read: 20_000, new: 20_000, source: "Chrome") == "20,000 bookmarks from Chrome's file")
        #expect(FlowFiles.passwordSentence(kept: 3, skipped: 0, new: 0) == "3 passwords imported — all were already here")
        #expect(FlowFiles.passwordSentence(kept: 0, skipped: 2, new: nil) == "Nothing imported — none of its 2 rows has both a site and a password")
    }

    @Test("A test run's key comes only from a test passphrase, and opens what Chromium sealed")
    func testKey() throws {
        let source = Chromium.known.first { $0.name == "Chrome" }!
        #expect(throws: FlowSecrets.KeyTrouble.self) {
            try FlowSecrets.key(for: source, testPassphrase: nil, seams: true)
        }
        let key = try FlowSecrets.key(for: source, testPassphrase: "copper-fixture-passphrase", seams: true)
        #expect(key == Chromium.stretch("copper-fixture-passphrase"))
        // Seal "alpha-secret-1" the way Chromium does and read it back.
        let plain = Array("alpha-secret-1".utf8)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var sealed = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, plain, plain.count, &sealed, sealed.count, &moved)
        #expect(status == kCCSuccess)
        let blob = Data("v10".utf8) + Data(sealed.prefix(moved))
        #expect(Chromium.unwrap(blob, key: key) == "alpha-secret-1")
    }

    @Test("The stand-in keeps each login once and says what was new")
    func probeSink() {
        let sink = FlowProbeSink()
        #expect(sink.savePassword(host: "a.invalid", user: "me", password: "pw", used: nil) == (true, true))
        #expect(sink.savePassword(host: "a.invalid", user: "me", password: "pw2", used: nil) == (true, false))
        #expect(sink.savePassword(host: "", user: "me", password: "pw", used: nil).kept == false)
        let passkey = FlowModel.Passkey(credentialId: Data([1, 2]), rpId: "a.invalid", userHandle: Data(), userName: "me",
                                        displayName: "Me", privateKey: Data(count: 32))
        #expect(sink.savePasskeys([passkey, passkey], from: "Chrome") == 1)
        #expect(sink.savePasskeys([passkey], from: "Chrome") == 0)
    }
}

@Suite("Flow move: what a source brought")
struct FlowBroughtTests {
    @Test("A tab that redirected after the first move is not brought again")
    func redirected() {
        let made = UUID()
        let steps = FlowAdopt.plan(
            [space("Work", [tab("https://youtube.com/"), tab("https://new.invalid/")])], source: "Arc",
            registry: ["work": made],
            existing: [FlowAdopt.Existing(id: made, name: "Work", addresses: [FlowAdopt.address(URL(string: "https://www.youtube.com/")!)])],
            pinned: [], brought: ["work": [FlowAdopt.address(URL(string: "https://youtube.com/")!)]]
        )
        #expect(steps.first?.loose == [1])
        #expect(steps.first?.skipped == 1)
    }

    @Test("A pin brought before is not pinned again, even unpinned since")
    func pinsBrought() {
        let mail = FlowAdopt.address(URL(string: "https://mail.invalid/")!)
        let steps = FlowAdopt.plan([space("Fav", [tab("https://mail.invalid/", pinned: true)])], source: "Arc",
                                   registry: [:], existing: [], pinned: [], brought: [FlowAdopt.pinsKey: [mail]])
        #expect(steps.first?.pins == [])
        #expect(steps.first?.skipped == 1)
    }

    @Test("Merging keeps earlier moves' records, restarts a re-made space's, and Undo takes a move's out")
    func record() {
        var run = FlowAdoption()
        run.brought = ["work": ["c"], "home": ["x"]]
        run.fresh = ["home"]
        let merged = FlowAdopt.merged(["work": ["a", "b"], "home": ["old"]], run)
        #expect(merged == ["work": ["a", "b", "c"], "home": ["x"]])
        #expect(FlowAdopt.without(merged, run) == ["work": ["a", "b"]])
    }
}

@Suite("Flow move: the moving view")
struct FlowStepTests {
    @Test("A row per chosen category, in the summary's order, all waiting")
    func rows() {
        var choice = FlowModel.Choice()
        choice.history = false
        choice.extensions = false
        let steps = FlowStep.steps(for: choice)
        #expect(steps.map(\.category) == [.tabs, .bookmarks, .passwords, .passkeys, .cookies, .localStorage])
        #expect(steps.allSatisfy { $0.state == .waiting && $0.text.isEmpty })
        #expect(FlowSummary.Category.cookies.title == "Sign-ins")
        #expect(FlowSummary.Category.localStorage.title == "Site data")
    }

    @Test("Rows change in place and end on the summary's own words; nothing is added")
    func inPlace() {
        var choice = FlowModel.Choice()
        choice.passwords = false
        choice.passkeys = false
        choice.cookies = false
        choice.localStorage = false
        choice.extensions = false
        var steps = FlowStep.steps(for: choice)
        steps = FlowStep.set(.bookmarks, .working, "reading…", in: steps)
        #expect(steps.map(\.state) == [.waiting, .working, .waiting])
        steps = FlowStep.set(.passwords, .working, "not chosen", in: steps)
        #expect(steps.count == 3)

        var f = FlowSummary.Facts(source: "Chrome")
        f.tabsChosen = true
        f.windowsRead = 1
        f.windowsEmpty = 1
        steps = FlowStep.finished(.tabs, f, in: steps)
        #expect(steps[0].state == .missed)
        #expect(steps[0].text == "Chrome's last window had only new-tab pages")
        #expect(steps[0].line == "Tabs: Chrome's last window had only new-tab pages")

        f.bookmarksChosen = true
        f.bookmarksRead = 3
        f.bookmarksNew = 3
        steps = FlowStep.finished(.bookmarks, f, in: steps)
        #expect(steps[1].state == .arrived)
        #expect("Bookmarks: " + steps[1].text == FlowSummary.lines(f).first { $0.category == .bookmarks }?.text)
        // The summary's rows show the same words as the moving view's.
        #expect(FlowSummary.lines(f).map(\.detail) == [steps[0].text, steps[1].text])
        #expect(steps.map(\.category) == [.tabs, .bookmarks, .history])
    }
}
