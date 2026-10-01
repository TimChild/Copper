import AppKit
import WebKit

// webkit.messageHandlers.easel — the board's one way to Copper, and Copper's
// answers back through window.__easelHost.receive(<json>). Every message is
// `{ v: 1, type, …payload }`; the shapes are the contract's
// (docs/plans/2026-10-01-easels-p1-local.md, "The bridge").
//
// Like the scheme handler, one per easel tab, bound to its board, and only
// in that tab's configuration: no other page has `easel` among its message
// handlers at all. And even there, a message is heard only from the main
// frame, whose origin is copper-easel://easel, of a view built for this very
// board and showing it — a site framed on the board one day can post all it
// likes and be ignored.
//
// A content controller holds its handlers strongly; this holds nothing but
// the board's id, so a closed tab is not kept alive by its own page.

final class EaselBridge: NSObject, WKScriptMessageHandler {
    static let name = "easel"

    let easel: String

    init(easel: String) {
        self.easel = easel
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { EaselBridge.hear(message, for: easel) }
    }

    // MARK: - page → Copper

    @MainActor
    private static func hear(_ message: WKScriptMessage, for easel: String) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == EaselScheme.name, origin.host == EaselScheme.host,
              let web = message.webView, Easels.board(of: web) == easel, Easels.id(of: web.url) == easel
        else {
            NSLog("easel: refused a message from %@://%@ (main frame: %@)", origin.protocol, origin.host,
                  message.frameInfo.isMainFrame ? "yes" : "no")
            return
        }
        guard let body = message.body as? [String: Any], number(body["v"]) == 1, let type = body["type"] as? String else {
            NSLog("easel: %@ sent something that is not a v1 message", easel)
            return
        }
        switch type {
        case "ready": ready(web, easel)
        case "save": save(body, web, easel)
        case "file": file(body, web, easel)
        case "open": open(body, web)
        case "log":
            let level = (body["level"] as? String).flatMap { ["info", "warn", "error"].contains($0) ? $0 : nil } ?? "info"
            let text = (body["message"] as? String).map { String($0.prefix(4000)) } ?? ""
            NSLog("easel: [%@] %@ %@", level, String(easel.prefix(8)), text)
        default:
            NSLog("easel: %@ sent an unknown message type %@", easel, type)
        }
    }

    /// The page is up and listening: what the board is, who is looking, and
    /// the document as last saved.
    ///
    /// A board renamed in the sidebar while its page was not loaded has a
    /// document whose `meta.title` is the old name. Its `config` says
    /// `renamed: true` beside Copper's title, and a `rename` follows it at
    /// once — either one is enough for the page to take Copper's name, and
    /// until it does, a `save` of the old name does not undo the rename
    /// (EaselStore.save).
    @MainActor
    private static func ready(_ web: WKWebView, _ easel: String) {
        let store = EaselStore.shared
        let known = store.easel(easel)
        var info: [String: Any] = [
            "id": easel,
            "title": known?.title ?? EaselStore.untitled,
            "createdAt": known?.createdAt ?? Date().timeIntervalSince1970,
        ]
        let renamed = known?.renamedFrom != nil
        if renamed { info["renamed"] = true }
        store.state(easel) { [weak web] data in
            guard let web else { return }
            tell(web, [
                "type": "config",
                "easel": info,
                "viewer": store.viewer.json,
                "state": data.map { $0.base64EncodedString() as Any } ?? NSNull(),
                "mode": "local",
            ])
            if renamed, let title = store.easel(easel)?.title { tell(web, ["type": "rename", "title": title]) }
        }
    }

    @MainActor
    private static func save(_ body: [String: Any], _ web: WKWebView, _ easel: String) {
        guard let text = body["state"] as? String, let state = Data(base64Encoded: text) else {
            NSLog("easel: %@ sent a save with no readable state", easel)
            return
        }
        guard state.count <= EaselStore.documentLimit else {
            NSLog("easel: %@ sent a %d-byte document, over the limit; not saved", easel, state.count)
            return
        }
        let title = body["title"] as? String ?? EaselStore.untitled
        EaselStore.shared.save(easel, state: state, title: title)
        Easels.saved(web)
    }

    /// A picture dropped on the board. Checked by its own bytes as well as
    /// by what the page says it is: png, jpeg, gif or webp, 15 MB at most.
    @MainActor
    private static func file(_ body: [String: Any], _ web: WKWebView, _ easel: String) {
        guard let reqId = body["reqId"] as? String, !reqId.isEmpty, reqId.count <= 200 else {
            NSLog("easel: %@ sent a file with no reqId", easel)
            return
        }
        func refuse(_ why: String) {
            tell(web, ["type": "file:error", "reqId": reqId, "message": why])
        }
        guard let text = body["data"] as? String else { return refuse("No picture came with the message.") }
        // A base64 string a third longer than the bytes it carries: refused
        // before it is decoded, so 200 MB of text is never turned into 150.
        guard text.utf8.count <= (EaselStore.pictureLimit / 3 + 1) * 4 else { return refuse("That picture is over 15 MB.") }
        guard let data = Data(base64Encoded: text), !data.isEmpty else { return refuse("The picture didn't come through.") }
        guard data.count <= EaselStore.pictureLimit else { return refuse("That picture is over 15 MB.") }
        guard let ext = EaselStore.sniff(data) else { return refuse("Only PNG, JPEG, GIF and WebP pictures can go on a board.") }
        // A page that does not know the type says so with nothing; one that
        // names a type has to name the right one.
        let mime = (body["mime"] as? String ?? "").lowercased()
        if !mime.isEmpty, mime != "application/octet-stream", EaselStore.pictures[mime] != ext {
            return refuse("That file is not the picture it says it is.")
        }
        EaselStore.shared.keep(picture: data, ext: ext, for: easel) { [weak web] result in
            guard let web else { return }
            switch result {
            case .success(let fileId):
                tell(web, ["type": "file:done", "reqId": reqId, "fileId": fileId,
                           "url": "\(EaselScheme.name)://\(EaselScheme.host)/files/\(easel)/\(fileId)"])
            case .failure(let error):
                tell(web, ["type": "file:error", "reqId": reqId, "message": error.localizedDescription])
            }
        }
    }

    /// A link on the board: an ordinary tab, through the same path a link
    /// opened from any page takes. http and https only — never another
    /// easel, a file, or somebody's app.
    @MainActor
    private static func open(_ body: [String: Any], _ web: WKWebView) {
        guard let text = body["url"] as? String, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil
        else {
            NSLog("easel: refused to open %@", (body["url"] as? String) ?? "nothing")
            return
        }
        let background = body["background"] as? Bool ?? false
        Easels.browser(showing: web).open(url, foreground: !background)
    }

    // MARK: - Copper → page

    /// Into the page's own world, where window.__easelHost lives. The JSON is
    /// the message itself, so the page can take it as an object.
    @MainActor
    static func tell(_ web: WKWebView, _ message: [String: Any]) {
        var message = message
        message["v"] = 1
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8)
        else { return }
        web.evaluateJavaScript("window.__easelHost && window.__easelHost.receive(\(json)); void 0") { _, error in
            guard let error else { return }
            NSLog("easel: the page did not take a %@: %@", message["type"] as? String ?? "message", error.localizedDescription)
        }
    }

    /// A JavaScript number as a number, and a boolean as nothing: NSNumber
    /// carries both, and `true` is not version 1.
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }
}
