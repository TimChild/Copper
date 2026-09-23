import Foundation
import AppKit

// Site marks for rows that have no page behind them.
//
// Upstream's Favicons asks the *page* which icon it wants to be known by: it
// runs a script in a live WKWebView, reads the <link rel=icon> tags, and
// fetches the best one. That is the right answer for a tab you are looking
// at, and no answer at all for the command bar, whose rows are mostly things
// with no web view — tabs asleep since yesterday's session, pages open in
// another space, bookmarks, places in history. Those rows fell through to a
// coloured letter tile, and a card of eight letter tiles looks like a
// placeholder for the card it means to be.
//
// So the same question is asked over the network instead. Three doors every
// site has had since about 1999, then the page's own <link rel=icon> tags,
// read out of the HTML rather than out of a rendered document — which is
// most of what the WKWebView probe was for, and needs no web view and no
// dependency. Whatever comes back goes to `Favicons.adopt`, already the way
// an icon from somewhere else (another browser's cache, at import) gets
// decoded, squared, written next to the history and announced. So a mark
// fetched here is a mark the tabs and the sidebar wear too, and it is on
// disk before the next launch asks for it.
//
// A site with no icon anywhere is asked once and then left alone.

@MainActor
final class HostIcons: ObservableObject {
    static let shared = HostIcons()

    /// Bumped when an icon lands, so the rows holding one redraw. The count
    /// itself means nothing; that it changed is the whole message.
    @Published private(set) var landed = 0

    private var busy: Set<String> = []
    /// Asked, and the site had nothing. Going back on every keystroke is
    /// exactly the kind of thing a quiet browser doesn't do.
    private var missing: Set<String> = []

    /// The host a row's icon is filed under — the same spelling upstream uses
    /// for a tab, so a mark fetched for a row is found again by the tab on
    /// the same site, and `cached` here and `cached` there agree.
    static func key(for url: URL) -> String? {
        guard let host = url.host()?.lowercased(), host.contains(".") else { return nil }
        return host
    }

    /// Everything on screen wants its mark. Cheap to call again: a host that
    /// is known, in flight, or already known to have nothing falls out before
    /// it costs anything.
    func want(_ urls: [URL]) {
        for url in urls {
            guard let host = HostIcons.key(for: url) else { continue }
            fetch(host)
        }
    }

    func fetch(_ host: String) {
        guard Favicons.shared.cached(host) == nil,
              !busy.contains(host), !missing.contains(host)
        else { return }
        busy.insert(host)
        Task { await pull(host) }
    }

    // MARK: - asking

    private func pull(_ host: String) async {
        let session = HostIcons.session()

        // The three blind doors at once. They are independent, and knocking
        // on them one after another spends three round trips to learn what
        // one round trip would — which is the difference between a mark that
        // is there when you look at the row and one that arrives after you
        // have read past it.
        if let data = await HostIcons.race(HostIcons.doors(host), on: session),
           await adopt(data, as: host) { return }

        // Nothing at the usual addresses. Plenty of sites — anything built as
        // one big script, and anything behind a sign-in — answer /favicon.ico
        // with their homepage, so ask the homepage what it actually declares.
        for candidate in await HostIcons.declared(by: host, on: session) {
            guard let data = await HostIcons.grab(candidate, on: session) else { continue }
            if await adopt(data, as: host) { return }
        }

        // Still nothing, and this is a room inside a larger site: wear the
        // house mark. A Google glyph on a calendar row is not the calendar's
        // own icon, but it is the truth about where the row leads, which a
        // letter in a coloured square is not.
        if let parent = HostIcons.parent(of: host),
           let data = await HostIcons.grab(URL(string: "https://\(parent)/favicon.ico"), on: session),
           await adopt(data, as: host) { return }

        busy.remove(host)
        missing.insert(host)
    }

    /// Keep these bytes as the host's mark, if they decode to a picture at
    /// all. True when the host now has one.
    private func adopt(_ data: Data, as host: String) async -> Bool {
        await Favicons.shared.adopt(data, for: host)
        guard Favicons.shared.cached(host) != nil else { return false }
        busy.remove(host)
        landed += 1
        return true
    }

    /// All of them at once, and the best one that answered — best meaning
    /// earliest in the list, not first back.
    private nonisolated static func race(_ urls: [URL?], on session: URLSession) async -> Data? {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (rank, url) in urls.enumerated() {
                group.addTask { (rank, await grab(url, on: session)) }
            }
            var best: (rank: Int, data: Data)?
            for await (rank, data) in group {
                guard let data else { continue }
                if best == nil || rank < best!.rank { best = (rank, data) }
            }
            return best?.data
        }
    }

    /// One candidate, fetched, and handed back only if it could be a picture.
    private nonisolated static func grab(_ url: URL?, on session: URLSession) async -> Data? {
        guard let url, let (data, response) = try? await session.data(from: url) else { return nil }
        let http = response as? HTTPURLResponse
        guard http.map({ (200..<300).contains($0.statusCode) }) ?? true,
              // A sign-in page dressed as an icon. The size tests below would
              // mostly catch it, but the type says so outright and costs
              // nothing to read.
              !(http?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/") ?? false),
              data.count > 60, data.count < 2_000_000
        else { return nil }
        return data
    }

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Short: this is decoration arriving beside a list someone is already
        // reading. A site that needs eight seconds to hand over a 4 KB icon
        // has missed the moment.
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["User-Agent": Self.agent]
        return URLSession(configuration: config)
    }

    /// Sites hand a plain fetcher a bot page and a browser the real thing.
    /// This is the browser saying so.
    private static let agent = """
        Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
        (KHTML, like Gecko) Version/17.0 Safari/605.1.15
        """

    /// The addresses worth trying blind, best first. `favicon.ico` is the one
    /// every site has; the touch icon is the one that is actually square and
    /// actually large, which matters at 16pt on a Retina screen, and plenty
    /// of sites don't have it.
    private static func doors(_ host: String) -> [URL?] {
        [
            URL(string: "https://\(host)/favicon.ico"),
            URL(string: "https://\(host)/apple-touch-icon.png"),
            URL(string: "https://\(host)/favicon.png"),
        ]
    }

    /// `news.example.co.uk` → `example.co.uk`. Rough on purpose: two labels,
    /// or three when the second-to-last is one of the handful of registry
    /// suffixes that would otherwise leave nothing behind.
    private static func parent(of host: String) -> String? {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return nil }
        let registry: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let take = labels.count > 3 && registry.contains(labels[labels.count - 2]) ? 3 : 2
        let parent = labels.suffix(take).joined(separator: ".")
        return parent == host ? nil : parent
    }

    // MARK: - what the page declares

    /// The icons the homepage names in its own head, best first. Read out of
    /// the HTML: no web view, no parser, no dependency — a link tag is a link
    /// tag whether or not anything has rendered it.
    private static func declared(by host: String, on session: URLSession) async -> [URL?] {
        guard let page = URL(string: "https://\(host)/"),
              let (data, response) = try? await session.data(from: page),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              // A homepage that is megabytes of inlined script has its head
              // in the first slice of it either way.
              let html = String(data: data.prefix(400_000), encoding: .utf8)
                  ?? String(data: data.prefix(400_000), encoding: .isoLatin1)
        else { return [] }

        let at = (response as? HTTPURLResponse)?.url ?? page
        let text = html as NSString
        guard let tags = try? NSRegularExpression(pattern: "<link\\s[^>]*>", options: .caseInsensitive)
        else { return [] }

        var found: [(URL, Int)] = []
        for match in tags.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let tag = text.substring(with: match.range)
            guard let rel = attribute("rel", of: tag)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", of: tag),
                  let url = URL(string: href, relativeTo: at)?.absoluteURL
            else { continue }
            // An SVG is the crispest thing a site can offer and the one thing
            // AppKit will not draw from raw bytes, so it goes last rather
            // than nowhere — something else usually wins first.
            if url.pathExtension.lowercased() == "svg" { found.append((url, 1)); continue }
            let declared = attribute("sizes", of: tag)
                .flatMap { Int($0.lowercased().split(separator: "x").first ?? "") }
            found.append((url, declared ?? (rel.contains("apple") ? 180 : 32)))
        }

        // Around 128 is the sweet spot: big enough that 16pt on a Retina
        // screen is not mush, small enough that it is not a 512px launcher
        // tile with a page of padding around the mark.
        return found
            .sorted { abs($0.1 - 128) < abs($1.1 - 128) }
            .prefix(3)
            .map { Optional($0.0) }
    }

    /// One attribute out of one tag. Quoted either way, or bare.
    private static func attribute(_ name: String, of tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let text = tag as NSString
        guard let match = re.firstMatch(in: tag, range: NSRange(location: 0, length: text.length)) else { return nil }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return text.substring(with: match.range(at: group))
        }
        return nil
    }
}
