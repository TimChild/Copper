import Foundation
import SQLite3
import Testing
@testable import Search

// The Safari Move-in source (Fork/Flow/FlowSafari.swift) on the synthetic
// files of FlowSafariTests.swift: what a look finds, what a move may bring,
// what stays behind, and how Safari sits in the sheet's source list.

// MARK: - the whole look, and what stays behind

@Suite struct SafariLookTests {
    @Test func readsADirectCopyAndAnExportTogether() throws {
        let scratch = try SafariScratch()
        let library = try scratch.folder("Safari")
        let container = try scratch.folder("Container")
        try SafariFixture.bookmarksPlist().write(to: library.appendingPathComponent("Bookmarks.plist"))
        let db = try SafariFixture.historyDB(at: library.appendingPathComponent("History.db"))
        sqlite3_close(db)
        try SafariFixture.tabsDB(at: container.appendingPathComponent("SafariTabs.db"))
        let export = try SafariFixture.exportFolder(in: scratch)

        let roots = FlowSafari.Roots.copy(at: scratch.root)
        #expect(roots.library == library)
        #expect(roots.container == container)
        #expect(FlowSafari.probeAccess(roots) == .readable)

        let found = FlowSafari.look(direct: roots, export: export)
        #expect(found.direct && found.fromExport)
        #expect(found.spaces == 4)
        #expect(found.tabs == 8)
        #expect(found.pins == 2)
        #expect(found.bookmarks == 4) // from the plist, which wins over the export's HTML
        #expect(found.readingList == 2)
        #expect(found.hasBookmarks)
        #expect(found.places == 7) // 3 from History.db + 4 from the two History JSON files
        #expect(found.hasPasswords)
        #expect(found.passwords == 1)
        #expect(found.cards == 2)
        #expect(found.extensions == ["Example Blocker"])

        // With its own files and the export, only cards and extensions stay.
        let stays = FlowSafari.stayed(found)
        #expect(stays.count == 2)
        #expect(stays.contains { $0.contains("2 payment cards") })
        #expect(stays.contains { $0.contains("Example Blocker") })
        #expect(FlowSafari.staysLine(found) == "Stays in Safari: 2 payment cards and 1 Safari extension.")
    }

    @Test func anExportAloneSaysTheTabsStayed() throws {
        let scratch = try SafariScratch()
        let export = try SafariFixture.exportFolder(in: scratch)
        let got = FlowSafari.collect(direct: nil, export: export)
        #expect(got.spaces.isEmpty)
        #expect(got.bookmarks.bookmarkCount == 4)
        #expect(got.bookmarkRead != nil)
        let stays = FlowSafari.stayed(FlowSafari.look(got))
        #expect(stays.first?.hasPrefix("Open tabs and tab groups aren't in Safari's export") == true)
    }

    @Test func itsOwnFilesAloneSayWherePasswordsAre() throws {
        let scratch = try SafariScratch()
        let library = try scratch.folder("Safari")
        try SafariFixture.bookmarksPlist().write(to: library.appendingPathComponent("Bookmarks.plist"))
        let found = FlowSafari.look(direct: .copy(at: scratch.root), export: nil)
        #expect(found.direct && !found.fromExport)
        #expect(!found.hasPasswords)
        #expect(FlowSafari.stayed(found).contains { $0.hasPrefix("Passwords are only in Safari's export") })
    }

    /// FS-02: an export with only passwords has no bookmark file, so the
    /// move must not take an empty read (it would remove the last move's).
    @Test func aPasswordsOnlyExportHasNoBookmarkRead() throws {
        let scratch = try SafariScratch()
        let csv = try scratch.write(SafariFixture.passwordsCSV, "Passwords.csv")
        let got = FlowSafari.collect(direct: nil, export: csv)
        #expect(got.fromExport)
        #expect(got.bookmarkRead == nil)
        #expect(got.passwordsCSV != nil)
        let found = FlowSafari.look(got)
        #expect(!found.hasBookmarks)
        #expect(found.passwords == 1)
    }

    @Test func aMissingFolderIsMissingNotRefused() throws {
        let scratch = try SafariScratch()
        let roots = FlowSafari.Roots(library: scratch.root.appendingPathComponent("nope"), container: scratch.root)
        #expect(FlowSafari.probeAccess(roots) == .missing)
    }
}

// MARK: - what a Safari move may bring

@Suite struct SafariChoiceTests {
    @Test func tabsNeedItsOwnFilesAndPasswordsNeedTheExport() {
        var look = FlowSafari.Look()
        let all = FlowModel.Choice()
        let exportOnly = FlowSafari.usable(all, direct: false, look: look)
        #expect(!exportOnly.tabs)
        #expect(exportOnly.bookmarks && exportOnly.history)
        #expect(!exportOnly.passwords)
        // Never what Safari doesn't have.
        #expect(!exportOnly.cookies && !exportOnly.localStorage && !exportOnly.passkeys && !exportOnly.extensions)

        look.hasPasswords = true
        let both = FlowSafari.usable(all, direct: true, look: look)
        #expect(both.tabs && both.passwords)
    }

    @Test func nothingChosenIsNothingToMove() {
        var off = FlowModel.Choice()
        off.tabs = false; off.bookmarks = false; off.history = false; off.passwords = false
        #expect(!FlowSafari.anything(FlowSafari.usable(off, direct: true, look: nil)))
    }
}

// MARK: - Safari in the source list

@Suite struct SafariSourceTests {
    @Test func aProbeNeverLooksAtThisMacsSafari() {
        // Not named, no copy, no state: not listed at all.
        #expect(Flow.safari(roots: [:], only: nil, forced: [:], export: nil, probe: true) == nil)
        // Named: listed, and locked without a copy — nothing is touched.
        let named = Flow.safari(roots: [:], only: ["Safari"], forced: [:], export: nil, probe: true)
        #expect(named?.locked == true)
        #expect(named?.readable == false)
        #expect(named?.showsLocked == true)
        // Left out of a list that doesn't name it.
        #expect(Flow.safari(roots: [:], only: ["Chrome"], forced: [:], export: nil, probe: true) == nil)
    }

    @Test func aCopyIsReadAndAnExportMakesALockedSafariReadable() throws {
        let scratch = try SafariScratch()
        let library = try scratch.folder("Safari")
        try SafariFixture.bookmarksPlist().write(to: library.appendingPathComponent("Bookmarks.plist"))
        let copy = Flow.safari(roots: ["Safari": scratch.root], only: nil, forced: [:], export: nil, probe: true)
        #expect(copy?.readable == true)
        #expect(copy?.safariDirect?.library == library)

        let export = try SafariFixture.exportFolder(in: scratch)
        let locked = Flow.safari(roots: [:], only: ["Safari"], forced: [:], export: export, probe: true)
        #expect(locked?.locked == true)
        #expect(locked?.readable == true) // the export is something to read
        #expect(locked?.showsLocked == false) // so no locked card
        #expect(locked?.safariDirect == nil) // but not its own files
        // Still locked underneath: coming back to Copper looks again.
        #expect(FlowMachine.recheckOnActivation(sources: [locked!.candidate], open: true))
    }

    @Test func aForcedStateWins() {
        let forced = Flow.safari(roots: [:], only: nil, forced: ["Safari": .locked], export: nil, probe: true)
        #expect(forced?.locked == true)
        #expect(forced?.glyph == "safari")
        #expect(forced?.isSafari == true)
    }
}
