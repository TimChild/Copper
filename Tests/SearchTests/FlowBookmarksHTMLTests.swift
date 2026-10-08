import Foundation
import Testing
@testable import Search

// The shared Netscape bookmark-file parser (Fork/Flow/FlowBookmarksHTML.swift)
// on synthetic exports written here in Chrome's and Safari's shapes. No real
// browsing data is in this repo.

/// A tree without ids, so two reads can be compared.
private indirect enum Shape: Equatable, CustomStringConvertible {
    case site(String, String)
    case folder(String, [Shape])

    init(_ node: Bookmark) {
        if node.isFolder {
            self = .folder(node.title, (node.children ?? []).map(Shape.init))
        } else {
            self = .site(node.title, node.url ?? "")
        }
    }

    var description: String {
        switch self {
        case let .site(title, url): return "\(title) <\(url)>"
        case let .folder(title, kids): return "\(title)[\(kids.map(\.description).joined(separator: ", "))]"
        }
    }
}

private func shapes(_ nodes: [Bookmark]) -> [Shape] { nodes.map(Shape.init) }
private func titles(_ nodes: [Bookmark]) -> [String] { nodes.map(\.title) }

/// A folder of its own per test, gone when the test is.
private final class HTMLScratch {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("copper-bookmarks-html-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ data: Data, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

// MARK: - fixtures

/// Chrome's Bookmark Manager › Export bookmarks: a comment, one outer list,
/// the bar marked as the toolbar, "Other" and "Mobile" contents loose.
private let chromeHTML = """
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<!-- This is an automatically generated file.
     It will be read and overwritten.
     DO NOT EDIT! <DL><DT><A HREF="https://comment.example.com/">not a bookmark</A> -->
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000100" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="https://news.example.com/" ADD_DATE="1700000001" ICON="data:image/png;base64,iVBORw0KGgo=">News</A>
        <DT><H3 ADD_DATE="1700000002" LAST_MODIFIED="1700000003">Work</H3>
        <DL><p>
            <DT><A HREF="https://tracker.example.org/board?team=a&amp;view=2" ADD_DATE="1700000004">Board &amp; backlog</A>
            <DT><H3 ADD_DATE="1700000005" LAST_MODIFIED="1700000006">Deep</H3>
            <DL><p>
                <DT><A HREF="https://deep.example.org/x" ADD_DATE="1700000007">Deep one</A>
            </DL><p>
        </DL><p>
        <DT><A HREF="javascript:void(document.title)" ADD_DATE="1700000008">Bookmarklet</A>
    </DL><p>
    <DT><A HREF="https://other.example.com/" ADD_DATE="1700000009">Other site</A>
    <DT><H3 ADD_DATE="1700000010" LAST_MODIFIED="1700000011">Recipes</H3>
    <DL><p>
        <DT><A HREF="https://food.example.net/soup" ADD_DATE="1700000012">Soup</A>
    </DL><p>
    <DT><A HREF="https://phone.example.com/" ADD_DATE="1700000013">Saved on the phone</A>
</DL><p>
"""

/// The same bookmarks as Chrome keeps them in its own `Bookmarks` file.
private let chromeJSON = """
{"checksum":"0","roots":{
 "bookmark_bar":{"name":"Bookmarks bar","type":"folder","children":[
   {"name":"News","type":"url","url":"https://news.example.com/"},
   {"name":"Work","type":"folder","children":[
     {"name":"Board & backlog","type":"url","url":"https://tracker.example.org/board?team=a&view=2"},
     {"name":"Deep","type":"folder","children":[{"name":"Deep one","type":"url","url":"https://deep.example.org/x"}]}]},
   {"name":"Bookmarklet","type":"url","url":"javascript:void(document.title)"}]},
 "other":{"name":"Other bookmarks","type":"folder","children":[
   {"name":"Other site","type":"url","url":"https://other.example.com/"},
   {"name":"Recipes","type":"folder","children":[{"name":"Soup","type":"url","url":"https://food.example.net/soup"}]},
   {"name":"Saved on the phone","type":"url","url":"https://phone.example.com/"}]},
 "synced":{"name":"Mobile bookmarks","type":"folder","children":[]}},
 "version":1}
"""

/// Safari's `Bookmarks.html` from File › Export Browsing Data to File…: no
/// outer list, Favorites, the menu, the Reading List by its id, a preview line.
private let safariHTML = """
<!DOCTYPE NETSCAPE-Bookmark-file-1>
\t<HTML>
\t<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
\t<Title>Bookmarks</Title>
\t<H1>Bookmarks</H1>
\t<DT><H3 FOLDED>Favorites</H3>
\t<DL><p>
\t\t<DT><A HREF="https://example.com/">Example &amp; Co</A>
\t\t<DT><H3 FOLDED>Work</H3>
\t\t<DL><p>
\t\t\t<DT><A HREF="https://docs.example.org/guide?a=1&amp;b=2">Guide &#8212; part 1</A>
\t\t\t<DT><A HREF="javascript:alert(1)">Bookmarklet</A>
\t\t</DL><p>
\t</DL><p>
\t<DT><H3 FOLDED>Bookmarks Menu</H3>
\t<DL><p>
\t\t<DT><A HREF="https://menu.example.net/">Menu item</A>
\t</DL><p>
\t<DT><H3>Empty</H3>
\t<DL><p>
\t</DL><p>
\t<DT><A HREF="https://loose.example.com/" ADD_DATE="1700000000">Loose</A>
\t<DT><H3 FOLDED id="com.apple.ReadingList">Reading List</H3>
\t<DL><p>
\t\t<DT><A HREF="https://read.example.com/one">Read one</A>
\t\t<DD>A preview line
\t\t<DT><A HREF="https://read.example.com/two">Read two</A>
\t</DL><p>
</HTML>
"""

// MARK: - Chrome's export

@Suite struct FlowBookmarksHTMLChromeTests {
    @Test func barLooseAndTheRestInOther() {
        let tree = FlowBookmarksHTML.sections(chromeHTML, layout: .chromium).tree(.chromium)
        #expect(shapes(tree) == [
            .site("News", "https://news.example.com/"),
            .folder("Work", [
                .site("Board & backlog", "https://tracker.example.org/board?team=a&view=2"),
                .folder("Deep", [.site("Deep one", "https://deep.example.org/x")]),
            ]),
            .folder("Other", [
                .site("Other site", "https://other.example.com/"),
                .folder("Recipes", [.site("Soup", "https://food.example.net/soup")]),
                .site("Saved on the phone", "https://phone.example.com/"),
            ]),
        ])
    }

    @Test func landsTheSameTreeAsChromesOwnFile() throws {
        let scratch = try HTMLScratch()
        let profile = scratch.root.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data(chromeJSON.utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        let direct = FlowBookmarks.bookmarks(in: [profile])
        let file = try scratch.write(Data(chromeHTML.utf8), "bookmarks_10_7_26.html")
        let exported = FlowBookmarksHTML.read(contentsOf: file, layout: .chromium)
        #expect(direct.complete && exported.complete)
        #expect(shapes(exported.nodes) == shapes(direct.nodes))
        #expect(FlowBookmarks.count(exported.nodes) == 6)
    }

    @Test func aCommentIsNotABookmark() {
        let all = FlowBookmarksHTML.parse(chromeHTML)
        func urls(_ nodes: [FlowBookmarksHTML.Node]) -> [String] {
            nodes.flatMap { node in node.isFolder ? urls(node.children) : [node.url ?? ""] }
        }
        #expect(!urls(all).contains("https://comment.example.com/"))
        #expect(all.first?.attributes["personal_toolbar_folder"] == "true")
        #expect(all.first?.attributes["add_date"] == "1700000000")
    }

    @Test func aFolderNamedFavoritesStaysAFolderInChromesLayout() {
        let sections = FlowBookmarksHTML.sections(safariHTML, layout: .chromium)
        #expect(sections.bar.isEmpty && sections.menu.isEmpty)
        #expect(titles(sections.other) == ["Favorites", "Bookmarks Menu", "Empty", "Loose"])
        // The Reading List is still known by its id, and kept as a folder in Other.
        #expect(titles(sections.readingList) == ["Read one", "Read two"])
        #expect(titles(sections.tree(.chromium).last?.children ?? []) == ["Favorites", "Bookmarks Menu", "Empty", "Loose", "Reading List"])
    }
}

// MARK: - Safari's export

@Suite struct FlowBookmarksHTMLSafariTests {
    @Test func readsSafarisSections() {
        let sections = FlowBookmarksHTML.sections(safariHTML, layout: .safari)
        #expect(titles(sections.bar) == ["Example & Co", "Work"])
        #expect(sections.bar[1].children?.map(\.title) == ["Guide — part 1"])
        #expect(sections.bar[1].children?.first?.url == "https://docs.example.org/guide?a=1&b=2")
        #expect(titles(sections.menu) == ["Menu item"])
        #expect(titles(sections.other) == ["Empty", "Loose"])
        #expect(titles(sections.readingList) == ["Read one", "Read two"])
        #expect(sections.bookmarkCount == 4)
        #expect(sections.readingListCount == 2)
        #expect(sections.count == 6)
    }

    @Test func treePutsFavoritesFirstAndDropsEmptyFolders() {
        let tree = FlowBookmarksHTML.sections(safariHTML, layout: .safari).tree(.safari)
        #expect(titles(tree) == ["Example & Co", "Work", "Bookmarks Menu", "Loose", "Reading List"])
        #expect(tree.last?.children?.count == 2)
    }

    @Test func readingListByIdEvenWhenTheTitleIsLocalized() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DT><H3 FOLDED ID="com.apple.ReadingList">Leseliste</H3>
        <DL><p>
            <DT><A HREF="https://read.example.de/">Artikel</A>
        </DL><p>
        <DT><H3 FOLDED>Favoriten</H3>
        <DL><p>
            <DT><A HREF="https://fav.example.de/">Fav</A>
        </DL><p>
        """
        let sections = FlowBookmarksHTML.sections(html, layout: .safari)
        #expect(titles(sections.readingList) == ["Artikel"])
        // A localized Favorites title isn't known: it comes over as a folder.
        #expect(titles(sections.other) == ["Favoriten"])
    }

    @Test func readReturnsSafarisTree() throws {
        let scratch = try HTMLScratch()
        let file = try scratch.write(Data(safariHTML.utf8), "Bookmarks.html")
        let read = FlowBookmarksHTML.read(contentsOf: file, layout: .safari)
        #expect(read.complete)
        #expect(titles(read.nodes) == ["Example & Co", "Work", "Bookmarks Menu", "Loose", "Reading List"])
        #expect(FlowBookmarks.count(read.nodes) == 6)
    }
}

// MARK: - the format itself

@Suite struct FlowBookmarksHTMLFormatTests {
    @Test func onlyWebPagesAreKept() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><H3>Mixed</H3>
            <DL><p>
                <DT><A HREF="https://ok.example.com/">Secure</A>
                <DT><A HREF="http://plain.example.com/">Plain</A>
                <DT><A HREF="HTTPS://UPPER.EXAMPLE.COM/">Upper</A>
                <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
                <DT><A HREF="file:///Users/someone/notes.html">File</A>
                <DT><A HREF="place:sort=8&amp;maxResults=10">Smart folder</A>
                <DT><A HREF="chrome://settings/">Settings page</A>
                <DT><A HREF="about:blank">Blank</A>
                <DT><A HREF="ftp://files.example.com/">FTP</A>
                <DT><A HREF="https:///nohost">No host</A>
                <DT><A HREF="">Empty address</A>
                <DT><A>No address at all</A>
            </DL><p>
            <DT><H3>Only junk</H3>
            <DL><p>
                <DT><A HREF="javascript:void(0)">Nothing</A>
            </DL><p>
        </DL><p>
        """
        let sections = FlowBookmarksHTML.sections(html, layout: .chromium)
        #expect(titles(sections.other.first?.children ?? []) == ["Secure", "Plain", "Upper"])
        // Chrome's layout keeps a folder whose sites all went, as its direct read does.
        #expect(titles(sections.tree(.chromium).first?.children ?? []) == ["Mixed", "Only junk"])
        // Safari's layout leaves it out.
        #expect(titles(FlowBookmarksHTML.sections(html, layout: .safari).tree(.safari)) == ["Mixed"])
    }

    @Test func entitiesInTitlesAndAddresses() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><A HREF="https://e.example.com/?q=a&amp;b=c&#38;d=e">Tom &amp; Jerry &quot;quoted&quot; &#39;single&#39;</A>
            <DT><A HREF="https://e.example.com/2">&lt;b&gt;bold&lt;/b&gt; &#x2014; dash &#8212; dash</A>
            <DT><A HREF="https://e.example.com/3">Caf&#233; &AMP; &nbsp;bar &bogus; fish &amp chips</A>
            <DT><A HREF="https://e.example.com/4">  spaced
              title  </A>
        </DL><p>
        """
        let nodes = FlowBookmarksHTML.parse(html)
        #expect(nodes.map(\.title) == [
            "Tom & Jerry \"quoted\" 'single'",
            "<b>bold</b> — dash — dash",
            "Café & \u{00A0}bar &bogus; fish &amp chips",
            "spaced\n      title",
        ])
        #expect(nodes.first?.url == "https://e.example.com/?q=a&b=c&d=e")
    }

    @Test func duplicatesAtTheTopFoldLikeChromesOwnFiles() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bar</H3>
            <DL><p>
                <DT><A HREF="https://same.example.com/">Same</A>
                <DT><A HREF="https://same.example.com/">Same</A>
                <DT><A HREF="https://same.example.com/">Same, retitled</A>
            </DL><p>
            <DT><H3>Trips</H3>
            <DL><p>
                <DT><A HREF="https://a.example.com/">A</A>
                <DT><A HREF="https://a.example.com/">A</A>
            </DL><p>
            <DT><H3>Trips</H3>
            <DL><p>
                <DT><A HREF="https://a.example.com/">A</A>
                <DT><A HREF="https://b.example.com/">B</A>
            </DL><p>
            <DT><A HREF="https://loose.example.com/">Loose</A>
            <DT><A HREF="https://loose.example.com/">Loose</A>
        </DL><p>
        """
        let tree = FlowBookmarksHTML.sections(html, layout: .chromium).tree(.chromium)
        #expect(shapes(tree) == [
            .site("Same", "https://same.example.com/"),
            .site("Same, retitled", "https://same.example.com/"),
            .folder("Other", [
                // Same-named folders merge; the first one's own duplicate stays, as with Chrome's file.
                .folder("Trips", [
                    .site("A", "https://a.example.com/"),
                    .site("A", "https://a.example.com/"),
                    .site("B", "https://b.example.com/"),
                ]),
                .site("Loose", "https://loose.example.com/"),
            ]),
        ])
        let safari = FlowBookmarksHTML.sections(html.replacingOccurrences(of: " PERSONAL_TOOLBAR_FOLDER=\"true\">Bar", with: ">Favorites"), layout: .safari).tree(.safari)
        #expect(titles(safari) == ["Same", "Same, retitled", "Trips", "Loose"])
    }

    @Test func aLongFlatLevelFoldsInOnePass() {
        // Thousands of loose bookmarks (Chrome's "Other bookmarks" is often
        // like this), every one twice, plus one folder name repeated.
        var html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n"
        for round in 0..<2 {
            for site in 0..<3000 {
                html += "<DT><A HREF=\"https://loose\(site).example.com/\">Loose \(site)</A>\n"
            }
            html += "<DT><H3>Again</H3>\n<DL><p>\n<DT><A HREF=\"https://again\(round).example.com/\">Again \(round)</A>\n</DL><p>\n"
        }
        html += "</DL><p>\n"
        let other = FlowBookmarksHTML.sections(html, layout: .chromium).tree(.chromium).first?.children ?? []
        #expect(other.count == 3001)
        #expect(other.filter(\.isFolder).map(\.title) == ["Again"])
        #expect(other.first { $0.isFolder }?.children?.map(\.title) == ["Again 0", "Again 1"])
        #expect(FlowBookmarks.count(other) == 3002)
    }

    @Test func toleratesLooseMarkup() {
        // Lowercase tags, single and bare attribute values, an unclosed <A>,
        // an unclosed <H3>, a > inside a quoted value, a folder with no list,
        // and a file that ends before its lists close.
        let html = """
        <!doctype netscape-bookmark-file-1>
        <dl><p>
            <dt><h3 add_date=1>Folder one</h3>
            <dl><p>
                <dt><a href='https://one.example.com/' title="a > b">One
                <dt><a href=https://two.example.com/>Two</a>
            </dl><p>
            <dt><h3>No list here</h3>
            <dt><h3>Unclosed title
            <dl><p>
                <dt><a HREF="https://three.example.com/">Three <b>bold</b></a>
        """
        let nodes = FlowBookmarksHTML.parse(html)
        #expect(nodes.map(\.title) == ["Folder one", "No list here", "Unclosed title"])
        #expect(nodes[0].children.map(\.title) == ["One", "Two"])
        #expect(nodes[0].children[0].attributes["title"] == "a > b")
        #expect(nodes[0].children[1].url == "https://two.example.com/")
        #expect(nodes[1].isFolder && nodes[1].children.isEmpty)
        #expect(nodes[2].children.map(\.title) == ["Three bold"])
    }

    @Test func emptyTitleFallsBackToTheAddress() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p><DT><A HREF="https://untitled.example.com/page"></A></DL><p>
        """
        let other = FlowBookmarksHTML.sections(html, layout: .chromium).other
        #expect(other.count == 1)
        #expect(other.first?.title.isEmpty == false)
        #expect(other.first?.url == "https://untitled.example.com/page")
    }

    @Test func recognisesABookmarkFileAndNothingElse() {
        #expect(FlowBookmarksHTML.isBookmarkFile(chromeHTML))
        #expect(FlowBookmarksHTML.isBookmarkFile(safariHTML))
        #expect(FlowBookmarksHTML.isBookmarkFile("<DL><p><DT><A HREF=\"https://x.example.com/\">x</A></DL>"))
        #expect(!FlowBookmarksHTML.isBookmarkFile("<html><body>hello</body></html>"))
        #expect(!FlowBookmarksHTML.isBookmarkFile("Title,URL,Username,Password,Notes,OTPAuth\n"))
        #expect(!FlowBookmarksHTML.isBookmarkFile(""))
    }

    @Test func readsUTF8WithAMarkUTF16AndLatin1() throws {
        let scratch = try HTMLScratch()
        let html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p><DT><A HREF=\"https://cafe.example.com/\">Café</A></DL><p>\n"
        var marked = Data([0xEF, 0xBB, 0xBF])
        marked.append(Data(html.utf8))
        let utf16 = try #require(html.data(using: .utf16))
        let latin1 = try #require(html.data(using: .isoLatin1))
        for (data, name) in [(marked, "bom.html"), (utf16, "utf16.html"), (latin1, "latin1.html")] {
            let read = FlowBookmarksHTML.read(contentsOf: try scratch.write(data, name), layout: .chromium)
            #expect(read.complete, "\(name)")
            #expect(read.nodes.first?.children?.first?.title == "Café", "\(name)")
        }
    }

    @Test func aFileThatIsNotBookmarksIsAFailedRead() throws {
        let scratch = try HTMLScratch()
        let csv = try scratch.write(Data("Title,URL,Username,Password\n".utf8), "Passwords.csv")
        let missing = scratch.root.appendingPathComponent("gone.html")
        for file in [csv, missing] {
            let read = FlowBookmarksHTML.read(contentsOf: file, layout: .safari)
            #expect(!read.complete)
            #expect(read.failedFiles == [file])
            #expect(read.nodes.isEmpty)
        }
    }

    @Test func aRealFileWithNoBookmarksIsACompleteEmptyRead() throws {
        let scratch = try HTMLScratch()
        let html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n</DL><p>\n"
        let read = FlowBookmarksHTML.read(contentsOf: try scratch.write(Data(html.utf8), "empty.html"), layout: .chromium)
        #expect(read.complete)
        #expect(read.nodes.isEmpty)
    }
}
