import AppKit
import Foundation
import Testing
@testable import Search

// The plain rules under Settings' shell and its Browsing pages
// (Fork/SettingsControls.swift, Fork/SettingsBrowse.swift, the matcher in
// Fork/SettingsSearch.swift, the Spaces page's symbol names and a tab's
// letter): what a control is called, how the arrows move a row of choices,
// which key closes Settings, how a held question is answered, where a test
// run may keep its downloads, which slips the search forgives.

@Suite("Settings controls")
struct SettingsControlRulesTests {
    @Test func nameComesFromWhereItWasMadeThenTheRow() {
        #expect(SettingsControlRules.name(given: "Every website", row: "Site access") == "Every website")
        #expect(SettingsControlRules.name(given: nil, row: "Correct spelling as you type") == "Correct spelling as you type")
        #expect(SettingsControlRules.name(given: "", row: "Appearance") == "Appearance")
        #expect(SettingsControlRules.name(given: nil, row: nil) == "")
    }

    @Test func arrowsStepAlongAndStopAtTheEnds() {
        #expect(SettingsControlRules.step(from: 0, by: 1, count: 3) == 1)
        #expect(SettingsControlRules.step(from: 2, by: -1, count: 3) == 1)
        #expect(SettingsControlRules.step(from: 2, by: 1, count: 3) == nil)
        #expect(SettingsControlRules.step(from: 0, by: -1, count: 3) == nil)
        #expect(SettingsControlRules.step(from: nil, by: 1, count: 3) == nil)
        #expect(SettingsControlRules.step(from: 0, by: 1, count: 0) == nil)
    }

    @Test func onlyPlainCommandWClosesSettings() {
        #expect(SettingsControlRules.closes(key: "w", flags: [.command]))
        #expect(SettingsControlRules.closes(key: "W", flags: [.command]))
        #expect(!SettingsControlRules.closes(key: "w", flags: [.command, .shift]))
        #expect(!SettingsControlRules.closes(key: "w", flags: [.command, .option]))
        #expect(!SettingsControlRules.closes(key: "w", flags: []))
        #expect(!SettingsControlRules.closes(key: "q", flags: [.command]))
    }
}

@Suite("Held questions")
struct TestConfirmTests {
    let buttons = ["Close Tabs & Delete", "Move Tabs to “Work” & Delete", "Cancel"]

    @Test func aButtonIsNamedByNumberTitleOrItsStart() {
        #expect(TestConfirm.button("1", in: buttons) == 0)
        #expect(TestConfirm.button("3", in: buttons) == 2)
        #expect(TestConfirm.button("cancel", in: buttons) == 2)
        #expect(TestConfirm.button("Move Tabs", in: buttons) == 1)
        #expect(TestConfirm.button("close", in: buttons) == 0)
        #expect(TestConfirm.button("4", in: buttons) == nil)
        #expect(TestConfirm.button("remove", in: buttons) == nil)
        #expect(TestConfirm.button("  ", in: buttons) == nil)
    }

    @Test func answersAreTheAlertsOwnResponses() {
        #expect(TestConfirm.response(for: 0) == .alertFirstButtonReturn)
        #expect(TestConfirm.response(for: 1) == .alertSecondButtonReturn)
        #expect(TestConfirm.response(for: 2) == .alertThirdButtonReturn)
    }
}

@MainActor
@Suite("Browsing pages")
struct SettingsBrowseTests {
    @Test func aTestRunKeepsOnlyFoldersItCouldHaveMadeItself() {
        let world = "/Users/someone/Library/Application Support/Copper (probe)"
        #expect(Preferences.testFolder(world + "/Picked", world: world)?.path == world + "/Picked")
        #expect(Preferences.testFolder("/tmp/probe-downloads", world: world)?.path == "/tmp/probe-downloads")
        #expect(Preferences.testFolder("/private/tmp/x", world: world) != nil)
        #expect(Preferences.testFolder("/Users/someone/Downloads", world: world) == nil)
        #expect(Preferences.testFolder(world, world: world) == nil)
        #expect(Preferences.testFolder("/tmp/../Users/someone/Downloads", world: world) == nil)
        #expect(Preferences.testFolder(nil, world: world) == nil)
    }

    @Test func theBenchsSavePanelNeverWritesOverAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("copper-ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        DownloadAsk.reset()
        defer { DownloadAsk.reset() }

        let first = try #require(DownloadAsk.answer("report.csv", in: folder))
        #expect(first.lastPathComponent == "report.csv")
        try Data("a".utf8).write(to: first)
        let second = try #require(DownloadAsk.answer("report.csv", in: folder))
        #expect(second.lastPathComponent == "report 2.csv")

        DownloadAsk.reply = "cancel"
        #expect(DownloadAsk.answer("file.txt", in: folder) == nil)
        #expect(DownloadAsk.asked == ["report.csv", "report.csv", "file.txt"])
    }

    @Test func aNumberedHostTakesTheTitlesLetter() {
        #expect(Tab.monogram(host: "127.0.0.1", title: "Local report") == "L")
        #expect(Tab.monogram(host: "::1", title: "dashboard") == "D")
        #expect(Tab.monogram(host: "[::1]", title: "") == "1")
        #expect(Tab.monogram(host: "127.0.0.1", title: "") == "1")
        #expect(Tab.monogram(host: "www.example.com", title: "Anything") == "E")
        #expect(Tab.monogram(host: "9lives.example", title: "Sign in") == "9")
        #expect(Tab.monogram(host: nil, title: "New Tab") == "•")
    }

    @Test func symbolsAreCalledWhatTheyLookLike() {
        #expect(SpacePage.symbolName("cup.and.saucer") == "Cup")
        #expect(SpacePage.symbolName("gamecontroller") == "Game controller")
        #expect(SpacePage.symbolName("sun.max") == "Sun")
        #expect(SpacePage.symbolName("some.new.symbol") == "Some new symbol")
        for symbol in SpacePage.symbols {
            let name = SpacePage.symbolName(symbol)
            #expect(!name.contains("."), "\(symbol) → \(name)")
            #expect(name.first?.isUppercase == true, "\(symbol) → \(name)")
        }
    }
}

@MainActor
@Suite("Settings search slips")
struct SettingsMatcherSlipTests {
    private func lands(_ query: String, _ word: String) -> Bool {
        SettingsMatcher.match(Array(query), Array(word)) != nil
    }

    @Test func shortWordsNeedTheirOwnLetters() {
        #expect(!lands("font", "front"))
        #expect(!lands("font", "from"))
    }

    @Test func eightLettersForgiveOneSlipNotTwo() {
        #expect(!lands("unpacked", "unlocked"))
        #expect(lands("dowloads", "downloads"))
        #expect(lands("extensons", "extensions"))
        #expect(lands("privcy", "privacy"))
    }

    @Test func wordsRunTogetherLandWholeNotPickedApart() throws {
        let joined = SettingsMatcher.field("Page in front of every question")
        #expect(SettingsMatcher.best(Array("font"), in: joined) == nil)
        let dark = try #require(SettingsMatcher.best(Array("darkmode"), in: SettingsMatcher.field("Dark mode")))
        #expect(dark.score >= 0.9)
    }

    @Test func prefixesAndShorthandStillLand() {
        #expect(lands("down", "downloads"))
        #expect(lands("pswd", "password"))
        #expect(lands("dark", "dark"))
        #expect(lands("shortcut", "shortcuts"))
    }
}
