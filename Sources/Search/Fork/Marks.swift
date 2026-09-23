import AppKit
import CryptoKit
import Foundation

// Icons for rows that have no page.
//
// Upstream asks a site for its favicon through the tab's own web view, which
// means a row restored from yesterday — asleep, holding an address and
// nothing else — shows a letter until you click it. A sidebar of forty
// letters is the single loudest difference between Copper and Arc, which has
// every mark on screen the moment the window opens.
//
// So each host in the column with nothing in the cache is asked, without a
// page and without JavaScript, in the order that costs least:
//
//   0. Arc's own icon cache, if there is one on this Mac. A world imported
//      from Arc has Arc's pages and none of Arc's pictures, and a good third
//      of those pages sit behind a VPN or a login where no amount of asking
//      politely will produce an icon — but the browser next door already
//      has it. Costs no network at all.
//   1. /favicon.ico — the address every site has answered since 1999, and
//      the only request most sites need.
//   2. the front page's own <link rel="icon">, read out of the first 64 KB
//      of HTML. Half the modern web 404s on the root icon and declares a
//      hashed one on a CDN instead; this is the half.
//   3. /apple-touch-icon.png, for the sites that have only ever thought
//      about the home screen.
//
// Whatever comes back goes to `Favicons.adopt`, which squares it, keeps it
// next to the history and tells every tab on that host. A host that answers
// nothing is never asked twice in a launch.

@MainActor
enum Marks {
    /// Hosts already tried this launch, answered or not.
    private static var asked: Set<String> = []

    /// How many hosts are in flight at once. Enough to fill a column of 150
    /// rows in a few seconds, few enough that a space switch doesn't look
    /// like a crawl.
    private static let lane = 10

    /// Safari's, near enough. A plain URLSession is served a bot page by a
    /// good deal of the web, and a bot page has no icon in it.
    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// Every host in these rows that has no mark yet.
    ///
    /// Also puts on the marks that arrived while this row was parked in
    /// another space: upstream hands an icon to the tabs on screen when it
    /// lands, and a tab restored into a parked row read the cache once, at
    /// launch, when it was empty. Without this, every space but the first
    /// one you open is a column of letters for the rest of the session.
    static func warm(_ tabs: [Tab]) {
        var hosts: [String] = []
        for tab in tabs {
            // A sleeping tab keeps its address in `pending`; either will do.
            guard let url = tab.pending ?? tab.address,
                  url.scheme?.hasPrefix("http") == true,
                  let host = url.host()?.lowercased(), !host.isEmpty,
                  tab.icon == nil
            else { continue }
            if let known = Favicons.shared.cached(host) {
                tab.icon = known
                continue
            }
            guard !asked.contains(host) else { continue }
            asked.insert(host)
            hosts.append((url.scheme ?? "https") + "://" + host + (url.port.map { ":\($0)" } ?? ""))
        }
        guard !hosts.isEmpty else { return }
        Task { await fetch(borrow(hosts)) }
    }

    // MARK: - what the browser next door already has

    /// Host → the file Arc keeps its mark in. Read once a launch, or left
    /// empty for a Mac that has never had Arc on it.
    private static var lent: [String: URL]?

    /// Hands Arc's picture to `Favicons` for every origin it has one for,
    /// and gives back the origins still wanting.
    private static func borrow(_ origins: [String]) async -> [String] {
        // A megabyte and a half of JSON, off the main thread, once.
        if lent == nil { lent = await Task.detached(priority: .utility) { Marks.read() }.value }
        guard let lent, !lent.isEmpty else { return origins }
        var left: [String] = []
        for origin in origins {
            guard let host = URL(string: origin)?.host()?.lowercased(),
                  let file = lent[host],
                  let data = try? Data(contentsOf: file),
                  data.count > 60
            else { left.append(origin); continue }
            await Favicons.shared.adopt(data, for: host)
        }
        return left
    }

    /// Arc's sidebar file lists every tab it holds; its icon cache keeps one
    /// PNG per tab, named for the MD5 of that tab's id. Between the two,
    /// a host and the picture Arc drew for it.
    private nonisolated static func read() -> [String: URL] {
        let arc = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
        let cache = arc.appendingPathComponent("SidebarItemsFaviconCache", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cache.path),
              let data = try? Data(contentsOf: arc.appendingPathComponent("StorableSidebar.json")),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (top["sidebar"] as? [String: Any])?["containers"] as? [Any]
        else { return [:] }

        var out: [String: URL] = [:]
        for container in containers {
            guard let container = container as? [String: Any],
                  let items = container["items"] as? [Any] else { continue }
            for item in items {
                guard let item = item as? [String: Any],
                      let id = item["id"] as? String,
                      let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
                      let address = tab["savedURL"] as? String,
                      let host = URL(string: address)?.host()?.lowercased(),
                      out[host] == nil
                else { continue }
                let digest = Insecure.MD5.hash(data: Data(id.uppercased().utf8))
                let file = cache.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
                if FileManager.default.fileExists(atPath: file.path) { out[host] = file }
            }
        }
        return out
    }

    private static func fetch(_ origins: [String]) async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 2
        config.httpAdditionalHeaders = ["User-Agent": agent]
        let session = URLSession(configuration: config)
        var next = 0
        while next < origins.count {
            let slice = Array(origins[next..<min(next + lane, origins.count)])
            next += slice.count
            await withTaskGroup(of: (String, Data?).self) { group in
                for origin in slice {
                    group.addTask { (origin, await Marks.ask(origin, session)) }
                }
                for await (origin, data) in group {
                    guard let data, let host = URL(string: origin)?.host()?.lowercased() else { continue }
                    await Favicons.shared.adopt(data, for: host)
                }
            }
        }
        session.invalidateAndCancel()
    }

    private nonisolated static func ask(_ origin: String, _ session: URLSession) async -> Data? {
        if let hit = await image(origin + "/favicon.ico", session) { return hit }
        for href in await declared(origin, session) {
            if let hit = await image(href, session) { return hit }
        }
        return await image(origin + "/apple-touch-icon.png", session)
    }

    /// One candidate, fetched and checked. "Checked" means it decodes as a
    /// picture: a site that answers its own 404 page with a 200 is common
    /// enough that a status code alone proves nothing.
    private nonisolated static func image(_ address: String, _ session: URLSession) async -> Data? {
        guard let url = URL(string: address),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              data.count > 60, data.count < 2_000_000,
              let image = NSImage(data: data), image.isValid, image.size.width > 0
        else { return nil }
        return data
    }

    /// What the front page says its icon is, best guess first. The HTML is
    /// read with a regular expression rather than a parser on purpose —
    /// a `<link rel=icon href=…>` is a shape a regex gets right, and the
    /// alternative is a web view, which is the thing this exists to avoid.
    private nonisolated static func declared(_ origin: String, _ session: URLSession) async -> [String] {
        guard let url = URL(string: origin + "/"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let text = String(data: data.prefix(64_000), encoding: .utf8)
                  ?? String(data: data.prefix(64_000), encoding: .isoLatin1)
        else { return [] }

        let pattern = try? NSRegularExpression(pattern: "<link[^>]+>", options: .caseInsensitive)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var scored: [(String, Int)] = []
        pattern?.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let tag = Range(match.range, in: text).map({ String(text[$0]) }) else { return }
            let low = tag.lowercased()
            guard low.contains("rel="), low.contains("icon"), !low.contains("mask-icon") else { return }
            guard let href = attribute("href", in: tag),
                  let resolved = URL(string: href, relativeTo: URL(string: origin + "/"))?.absoluteString,
                  resolved.hasPrefix("http")
            else { return }
            // A 32–192px raster is what a 16pt mark wants. SVG decodes on
            // some Macs and not others, so it goes last rather than first.
            var score = 30
            if let sizes = attribute("sizes", in: tag),
               let px = sizes.lowercased().split(separator: " ").compactMap({ Int($0.split(separator: "x").first ?? "") }).max() {
                switch px {
                case ..<24: score = 12
                case 24..<64: score = 50
                case 64..<200: score = 45
                default: score = 25
                }
            }
            if low.contains("apple-touch") { score = min(score, 35) }
            if resolved.lowercased().contains(".svg") { score = 8 }
            scored.append((resolved, score))
        }
        var seen = Set<String>()
        return scored.sorted { $0.1 > $1.1 }.map(\.0).filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    /// `name="value"`, `name='value'` or `name=value`, out of one tag.
    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag))
        else { return nil }
        for group in 2...4 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }
}
