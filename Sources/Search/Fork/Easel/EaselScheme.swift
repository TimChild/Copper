import Foundation
import WebKit

// copper-easel://easel/… — where a board's page, its scripts and its pictures
// come from. One handler per easel tab, made with that tab's configuration
// and bound to its one board (see Easels.configuration(for:)):
//
//   /<id>, /<id>/                 the bundle's index.html, for this board only
//   /assets/<file>                the bundle's assets/ (Vite, base '/')
//   /files/<id>/<fileId>          a picture dropped on this board
//   anything else                 404
//
// Ordinary tabs never get a handler at all, so to every other page the
// scheme does not exist: nothing a website writes — a link, a redirect, an
// <iframe>, an <img>, fetch() — can load a byte of an easel. Binding each
// handler to its board goes one further: a board can read only its own
// document and its own pictures, never a neighbour's.

final class EaselScheme: NSObject, WKURLSchemeHandler {
    nonisolated static let name = "copper-easel"
    nonisolated static let host = "easel"

    /// The board this view was built for.
    let easel: String

    /// Requests in flight. WebKit raises an exception, not an error, when a
    /// task it has already stopped hears anything more, so an answer read
    /// off the disk is given only to a task still listed here.
    private var live: [ObjectIdentifier: WKURLSchemeTask] = [:]

    init(easel: String) {
        self.easel = easel
    }

    /// Where index.html and assets/ live. SwiftPM copies Fork/Easel/web into
    /// Search_Search.bundle beside the binary — what a run from the build
    /// folder sees — and build.sh carries that bundle into Copper.app's
    /// Resources; the same two places BackdropScene.folder looks.
    nonisolated static let bundle: URL? = {
        let name = "Search_Search.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        let folders = roots.flatMap { root -> [URL] in
            var found: [URL] = []
            if let inner = Bundle(url: root.appendingPathComponent(name))?.resourceURL { found.append(inner.appendingPathComponent("web")) }
            found.append(root.appendingPathComponent(name).appendingPathComponent("web"))
            return found
        }
        return folders.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return answer(task, status: 404) }
        guard let found = route(url) else {
            NSLog("easel: 404 %@", url.absoluteString)
            return answer(task, status: 404)
        }
        let key = ObjectIdentifier(task)
        live[key] = task
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: found.file, options: .mappedIfSafe)
            DispatchQueue.main.async {
                guard let self, let task = self.live.removeValue(forKey: key) else { return }
                guard let data else {
                    // The board's own page missing from this build is worth a
                    // sentence; a missing picture is just a missing picture.
                    if found.page { return self.answer(task, status: 200, type: "text/html", body: Data(EaselScheme.missing.utf8), page: true) }
                    return self.answer(task, status: 404)
                }
                self.answer(task, status: 200, type: found.type, body: data, page: found.page, immutable: found.immutable)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live[ObjectIdentifier(task)] = nil
    }

    // MARK: - routes

    private struct Found {
        let file: URL
        let type: String
        var page = false
        var immutable = false
    }

    private func route(_ url: URL) -> Found? {
        guard url.scheme?.lowercased() == EaselScheme.name, url.host()?.lowercased() == EaselScheme.host,
              let parts = EaselScheme.parts(of: url)
        else { return nil }
        switch parts.first {
        case "assets":
            guard parts.count >= 2, let bundle = EaselScheme.bundle,
                  let type = EaselScheme.types[(parts.last! as NSString).pathExtension.lowercased()]
            else { return nil }
            let file = parts.reduce(bundle) { $0.appendingPathComponent($1) }
            guard EaselScheme.inside(file, bundle) else { return nil }
            return Found(file: file, type: type, immutable: true)
        case "files":
            guard parts.count == 3, parts[1] == easel, EaselScheme.isPicture(parts[2]),
                  let type = EaselScheme.types[(parts[2] as NSString).pathExtension.lowercased()]
            else { return nil }
            let base = EaselStore.files(of: easel)
            let file = base.appendingPathComponent(parts[2])
            guard EaselScheme.inside(file, base) else { return nil }
            return Found(file: file, type: type, immutable: true)
        case easel where parts.count == 1:
            let file = (EaselScheme.bundle ?? URL(fileURLWithPath: "/nonexistent")).appendingPathComponent("index.html")
            return Found(file: file, type: "text/html", page: true)
        default:
            return nil
        }
    }

    /// The path's parts, each one decoded and checked: nothing empty, no `.`
    /// or `..`, nothing hidden, no separator smuggled in as %2F. Nil for a
    /// path that tries any of it. A trailing slash is allowed and dropped.
    nonisolated static func parts(of url: URL) -> [String]? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              raw.hasPrefix("/")
        else { return nil }
        var pieces = raw.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if pieces.count > 1, pieces.last == "" { pieces.removeLast() }
        var out: [String] = []
        for piece in pieces {
            guard let part = piece.removingPercentEncoding, !part.isEmpty, !part.hasPrefix("."),
                  !part.contains("/"), !part.contains("\\"), !part.contains("\0")
            else { return nil }
            out.append(part)
        }
        return out.isEmpty ? nil : out
    }

    /// Still inside `base` once every link and dot is resolved.
    nonisolated private static func inside(_ file: URL, _ base: URL) -> Bool {
        let root = base.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// `<uuid>.<ext>`, lowercase, a picture type the board takes.
    nonisolated static func isPicture(_ fileId: String) -> Bool {
        let bits = fileId.split(separator: ".", omittingEmptySubsequences: false)
        guard bits.count == 2, Easels.isID(String(bits[0])) else { return false }
        return ["png", "jpg", "jpeg", "gif", "webp"].contains(String(bits[1]))
    }

    /// By extension, and only these. A file the bundle has that is not in
    /// this list is not served, rather than served as something it is not.
    nonisolated static let types: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "woff2": "font/woff2", "woff": "font/woff",
        "ttf": "font/ttf", "json": "application/json", "wasm": "application/wasm", "map": "application/json",
    ]

    // MARK: - answers

    private func answer(_ task: WKURLSchemeTask, status: Int, type: String = "text/plain", body: Data = Data(),
                        page: Bool = false, immutable: Bool = false) {
        guard let url = task.request.url else { return }
        let text = type.hasPrefix("text/") || type.hasSuffix("json") || type.hasSuffix("+xml")
        var headers: [String: String] = [
            "Content-Type": text ? type + "; charset=utf-8" : type,
            "Content-Length": String(body.count),
            "X-Content-Type-Options": "nosniff",
            // A page from somewhere else — a site framed on a board, later
            // on — may not so much as draw one of these as an <img>.
            "Cross-Origin-Resource-Policy": "same-origin",
            "Cache-Control": immutable ? "max-age=31536000, immutable" : "no-cache",
        ]
        if page {
            // The board is never inside somebody else's frame. The navigation
            // policy already refuses; the page says so as well.
            headers["Content-Security-Policy"] = "frame-ancestors 'none'"
            headers["X-Frame-Options"] = "DENY"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: type, expectedContentLength: body.count, textEncodingName: nil)
        task.didReceive(response)
        if !body.isEmpty { task.didReceive(body) }
        task.didFinish()
    }

    private static let missing = """
    <!doctype html><meta charset="utf-8"><title>Easel</title>
    <body style="font: 15px -apple-system; color: #888; display: grid; place-items: center; height: 90vh">
    This build of Copper has no easel app in it (Fork/Easel/web).
    """
}
