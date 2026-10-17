import Foundation
import Testing
@testable import Search

// ⌘T's and ⌘K's card in sections (Fork/CardSections.swift, Fork/Launcher.swift,
// Fork/CommandBar.swift): one fixed order — Open Tabs → History → Bookmarks →
// Canvases → Commands → Search — the first row of the first section
// highlighted, and Tab / ⇧Tab jumping a section at a time, round the end.

private func row(_ key: String, _ kind: Suggestion.Kind, _ url: String = "https://example.com/") -> Suggestion {
    Suggestion(key: key, title: "", url: URL(string: url)!, kind: kind)
}

private func titles(_ headings: [Int: String]) -> [String] {
    headings.sorted { $0.key < $1.key }.map(\.value)
}

// MARK: - order

@Test func sectionsAreLaidOutInTheFixedOrderWhateverOrderTheyWereFound() {
    let found: [CardSection: [String]] = [
        .search: ["search-a", "search-b"],
        .commands: ["command"],
        .history: ["history-a", "history-b"],
        .canvases: ["canvas"],
        .tabs: ["tab-a", "tab-b"],
        .bookmarks: ["bookmark"],
    ]
    let laid = CardSections.lay(sections: found)
    #expect(laid.rows == ["tab-a", "tab-b", "history-a", "history-b", "bookmark", "canvas", "command", "search-a", "search-b"])
    #expect(laid.headings == [0: "Open Tabs", 2: "History", 4: "Bookmarks", 5: "Canvases", 6: "Commands", 7: "Search"])
}

@Test func anEmptySectionDrawsNothingNotEvenItsHeading() {
    let laid = CardSections.lay(sections: [.search: ["search"], .tabs: [], .history: ["history"], .bookmarks: []] as [CardSection: [String]])
    #expect(laid.rows == ["history", "search"])
    #expect(laid.headings == [0: "History", 1: "Search"])
    #expect(CardSections.lay(sections: [:] as [CardSection: [String]]).rows.isEmpty)
    #expect(CardSections.lay(sections: [:] as [CardSection: [String]]).headings.isEmpty)
}

@Test func theShelvesNeverSitAboveOpenTabsOrHistory() {
    for shelf in [CardSection.bookmarks, .canvases, .commands] {
        #expect(shelf > .tabs)
        #expect(shelf > .history)
        #expect(shelf < .search)
    }
    #expect(CardSection.allCases.map(\.title) == ["Open Tabs", "History", "Bookmarks", "Canvases", "Commands", "Search"])
}

@Test func aRankedListKeepsItsRankingWithinEachSection() {
    // ⌘K ranks everything together; the sections cut it without reordering
    // the rows inside one.
    let ranked = ["h1", "t1", "s1", "h2", "b1", "t2", "c1", "h3"]
    func section(_ name: String) -> CardSection {
        switch name.first {
        case "t": return .tabs
        case "h": return .history
        case "b": return .bookmarks
        case "c": return .commands
        default: return .search
        }
    }
    let laid = CardSections.group(ranked, by: section)
    #expect(laid.rows == ["t1", "t2", "h1", "h2", "h3", "b1", "c1", "s1"])
    #expect(titles(laid.headings) == ["Open Tabs", "History", "Bookmarks", "Commands", "Search"])
}

@Test func eachKindOfRowHasItsSection() {
    #expect(CardSection.of(row("Tab", .open)) == .tabs)
    #expect(CardSection.of(row("Visited", .visited)) == .history)
    #expect(CardSection.of(row("Known", .known)) == .history)
    #expect(CardSection.of(row("Bookmark", .bookmark)) == .bookmarks)
    #expect(CardSection.of(row("Split View", .command, "copper://command/split")) == .commands)
    #expect(CardSection.of(row("Open Canvas · Plan", .command, "copper://canvas/abc")) == .canvases)
    // An open canvas is an open tab like any other.
    #expect(CardSection.of(row("Plan", .open, "copper://canvas/abc")) == .tabs)
    #expect(CardSection.of(row("weather", .search, "https://www.google.com/search?q=weather")) == .search)
}

// MARK: - ⌘T: where the words themselves go

@Test func aSearchGoesLastAndOpenTabsComeFirst() {
    let search = row("Search Google for “git”", .search, "https://www.google.com/search?q=git")
    let laid = Launcher.layout(top: search, [
        .tabs: [row("GitHub", .open, "https://github.com/")],
        .history: [row("Gitea", .visited, "https://gitea.io/")],
        .search: [row("github copilot", .search, "https://www.google.com/search?q=github+copilot")],
    ])
    #expect(laid.rows.map(\.key) == ["GitHub", "Gitea", "Search Google for “git”", "github copilot"])
    #expect(laid.headings == [0: "Open Tabs", 1: "History", 2: "Search"])
    // Return takes the best open tab, not the search.
    #expect(CardSections.first(count: laid.rows.count).map { laid.rows[$0].kind } == .open)
}

@Test func withNothingButTheSearchReturnSearches() {
    let search = row("Search Google for “zzqx”", .search, "https://www.google.com/search?q=zzqx")
    let laid = Launcher.layout(top: search, [:])
    #expect(laid.rows.map(\.key) == ["Search Google for “zzqx”"])
    #expect(laid.headings == [0: "Search"])
    #expect(CardSections.first(count: laid.rows.count) == 0)
}

@Test func withNoTabsHistoryIsWhatReturnTakes() {
    let search = row("Search Google for “wiki”", .search, "https://www.google.com/search?q=wiki")
    let laid = Launcher.layout(top: search, [.history: [row("Wikipedia", .visited, "https://wikipedia.org/")]])
    #expect(laid.rows.first?.key == "Wikipedia")
    #expect(laid.headings[0] == "History")
}

@Test func anAddressTypedInFullLeadsTheCardSoReturnGoesThere() throws {
    for typed in ["github.com", "localhost:3000", "https://example.com/path", "192.168.1.10:8080"] {
        let url = try #require(Address.url(from: typed), "\(typed) should read as an address")
        let lead = row("Open \(typed)", .known, url.absoluteString)
        let laid = Launcher.layout(top: lead, [
            .tabs: [row("GitHub", .open, "https://github.com/exowatt")],
            .search: [row("Search Google for “\(typed)”", .search, "https://www.google.com/search?q=x")],
        ])
        #expect(laid.rows.first?.url == url)
        // The lead row wears no heading; the sections follow in order.
        #expect(laid.headings[0] == nil)
        #expect(laid.headings == [1: "Open Tabs", 2: "Search"])
        #expect(CardSections.first(count: laid.rows.count) == 0)
    }
    // The row says where Return goes, port and all.
    #expect(Launcher.spoken(URL(string: "http://localhost:3000")!) == "localhost:3000")
    #expect(Launcher.spoken(URL(string: "http://localhost:3000/api/x")!) == "localhost:3000/api/x")
    #expect(Launcher.spoken(URL(string: "https://www.github.com/exowatt")!) == "github.com/exowatt")
    // Words are not an address: they are searched.
    #expect(Address.url(from: "weather tomorrow") == nil)
    #expect(Address.url(from: "todo") == nil)
}

// MARK: - the highlight

@Test func theFirstRowOfTheFirstNonEmptySectionIsHighlighted() {
    #expect(CardSections.first(count: 0) == nil)
    #expect(CardSections.first(count: 1) == 0)
    #expect(CardSections.first(count: 9) == 0)
}

// MARK: - Tab and ⇧Tab

/// Open Tabs 0–2, History 3–4, Search 5–7.
private let three: [Int: String] = [0: "Open Tabs", 3: "History", 5: "Search"]

@Test func tabMovesToTheFirstRowOfTheNextSection() {
    #expect(CardSections.jump(from: 0, by: 1, count: 8, headings: three) == 3)
    #expect(CardSections.jump(from: 1, by: 1, count: 8, headings: three) == 3)
    #expect(CardSections.jump(from: 3, by: 1, count: 8, headings: three) == 5)
    #expect(CardSections.jump(from: 4, by: 1, count: 8, headings: three) == 5)
}

@Test func tabWrapsFromTheLastSectionToTheFirst() {
    #expect(CardSections.jump(from: 5, by: 1, count: 8, headings: three) == 0)
    #expect(CardSections.jump(from: 7, by: 1, count: 8, headings: three) == 0)
}

@Test func shiftTabMovesToThePreviousSectionAndWraps() {
    #expect(CardSections.jump(from: 5, by: -1, count: 8, headings: three) == 3)
    // From inside a section, to the one before it — not the top of its own.
    #expect(CardSections.jump(from: 4, by: -1, count: 8, headings: three) == 0)
    #expect(CardSections.jump(from: 7, by: -1, count: 8, headings: three) == 3)
    #expect(CardSections.jump(from: 0, by: -1, count: 8, headings: three) == 5)
    #expect(CardSections.jump(from: 2, by: -1, count: 8, headings: three) == 5)
}

@Test func tabAndShiftTabWithNothingHighlighted() {
    #expect(CardSections.jump(from: nil, by: 1, count: 8, headings: three) == 0)
    #expect(CardSections.jump(from: nil, by: -1, count: 8, headings: three) == 5)
}

@Test func tabSkipsSectionsWithNoRows() {
    // Bookmarks, Canvases and Commands found nothing: Tab goes straight from
    // History to Search, and back.
    let laid = CardSections.lay(sections: [
        .tabs: ["t1"], .history: ["h1", "h2"], .bookmarks: [], .canvases: [], .commands: [], .search: ["s1"],
    ] as [CardSection: [String]])
    #expect(CardSections.starts(count: laid.rows.count, headings: laid.headings) == [0, 1, 3])
    #expect(CardSections.jump(from: 1, by: 1, count: laid.rows.count, headings: laid.headings) == 3)
    #expect(CardSections.jump(from: 3, by: -1, count: laid.rows.count, headings: laid.headings) == 1)
    // No open tabs at all: the card starts at History, and Tab round the end
    // comes back to it.
    let noTabs = CardSections.lay(sections: [.history: ["h1"], .search: ["s1", "s2"]] as [CardSection: [String]])
    #expect(CardSections.jump(from: 1, by: 1, count: noTabs.rows.count, headings: noTabs.headings) == 0)
}

@Test func theLeadRowIsASectionOfItsOwn() {
    // ⌘T with an address: "Open github.com", then Open Tabs at 1, Search at 3.
    let headings = [1: "Open Tabs", 3: "Search"]
    #expect(CardSections.starts(count: 5, headings: headings) == [0, 1, 3])
    #expect(CardSections.jump(from: 0, by: 1, count: 5, headings: headings) == 1)
    #expect(CardSections.jump(from: 4, by: 1, count: 5, headings: headings) == 0)
    #expect(CardSections.jump(from: 1, by: -1, count: 5, headings: headings) == 0)
}

@Test func oneSectionOrNoneKeepsTheHighlightPut() {
    #expect(CardSections.jump(from: 2, by: 1, count: 4, headings: [0: "Open Tabs"]) == 0)
    #expect(CardSections.jump(from: 0, by: -1, count: 4, headings: [0: "Open Tabs"]) == 0)
    #expect(CardSections.jump(from: nil, by: 1, count: 0, headings: [:]) == nil)
    #expect(CardSections.jump(from: 0, by: -1, count: 0, headings: [0: "Open Tabs"]) == nil)
    // A heading past the end of the rows (a stale one) is not a stop.
    #expect(CardSections.starts(count: 2, headings: [0: "Open Tabs", 5: "Search"]) == [0])
}

@Test func theEmptyCardTabsBetweenRecentAndClosed() {
    let laid = CardSections.lay([(title: "Recent Tabs", rows: ["r1", "r2", "r3"]), (title: "Recently Closed", rows: ["c1"])])
    #expect(laid.headings == [0: "Recent Tabs", 3: "Recently Closed"])
    #expect(CardSections.first(count: laid.rows.count) == 0)
    #expect(CardSections.jump(from: 0, by: 1, count: 4, headings: laid.headings) == 3)
    #expect(CardSections.jump(from: 3, by: 1, count: 4, headings: laid.headings) == 0)
}
