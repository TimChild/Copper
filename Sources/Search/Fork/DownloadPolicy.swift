import Foundation
import WebKit

// What a response becomes: a page, a file, or nothing at all.
//
// Upstream answered every response with `canShowMIMEType ? .allow : .download`.
// That one line had three failures in it, all seen on real sites:
//
// - A file the server says is an attachment, in a type WebKit can draw (a
//   PDF, an HTML page, an image), was drawn instead of saved. Gmail's download
//   button loads the attachment into a hidden frame and relies on
//   `Content-Disposition: attachment` to turn it into a file: drawn in a frame
//   nobody can see, the button did nothing at all. A link opened with
//   window.open left a blank tab the same way.
// - Any frame on a page — an ad, a tracker, a widget — whose answer WebKit
//   couldn't draw was saved to Downloads, so a page "downloaded something" as
//   it loaded.
// - An error or an empty answer (a 404 with no body, a 500 with an odd type) was
//   saved as a file named after the address: `phi-hub.apps.exowatt.com`,
//   `healthz`, `overview` — zero bytes each.
//
// The rule now is the one Chrome and Safari keep in practice: the server's
// `attachment` is obeyed wherever it appears; a page's own frames never save
// anything they weren't told to; the main frame saves a successful, non-empty
// answer it cannot show, and never markup; errors and empties are not files.
enum DownloadPolicy {
    enum Verdict: Equatable {
        /// Let WebKit draw it.
        case show
        /// Turn it into a WKDownload.
        case download
        /// Neither: stop the load. `reason` is what to tell the person, when
        /// the main frame was asked for it.
        case drop(reason: String?)
    }

    struct Answer {
        var mainFrame: Bool
        var canShow: Bool
        var status: Int?
        var mime: String?
        var disposition: String?
        var expectedLength: Int64
    }

    static func decide(_ response: WKNavigationResponse) -> Verdict {
        let http = response.response as? HTTPURLResponse
        let answer = Answer(
            mainFrame: response.isForMainFrame,
            canShow: response.canShowMIMEType,
            status: http?.statusCode,
            mime: response.response.mimeType,
            disposition: http?.value(forHTTPHeaderField: "Content-Disposition"),
            expectedLength: response.response.expectedContentLength
        )
        return decide(answer)
    }

    static func decide(_ a: Answer) -> Verdict {
        let ok = a.status.map { (200..<300).contains($0) } ?? true
        let mime = (a.mime ?? "").lowercased()

        // 204/205: "stay where you are" — every browser leaves the page alone.
        if a.status == 204 || a.status == 205 { return .drop(reason: nil) }

        // An error page is a page. Shown if WebKit can draw it; otherwise
        // the main frame says what happened and a frame says nothing — never
        // a file named after the address.
        guard ok else {
            if a.canShow { return .show }
            return .drop(reason: a.mainFrame ? errorReason(a.status) : nil)
        }

        // The server said "save this". Obeyed in any frame: that's how hidden
        // download frames (Gmail, Drive, most webmail) hand files over.
        if isAttachment(a.disposition), a.expectedLength != 0 { return .download }

        if a.canShow { return .show }

        // Nothing came back: nothing to show, nothing to keep.
        if a.expectedLength == 0 {
            return .drop(reason: a.mainFrame ? "This address sent back nothing to show." : nil)
        }

        // A frame inside a page doesn't get to save files on its own — that's
        // the "it downloaded something as the page loaded" case.
        guard a.mainFrame else { return .drop(reason: nil) }

        // Markup is a page even when it arrives somewhere WebKit balks at it.
        if isMarkup(mime) { return .show }

        return .download
    }

    /// RFC 6266: the disposition type is the first token, case-insensitive.
    static func isAttachment(_ disposition: String?) -> Bool {
        guard let disposition else { return false }
        let type = disposition.split(separator: ";", maxSplits: 1).first ?? ""
        return type.trimmingCharacters(in: .whitespaces).lowercased() == "attachment"
    }

    static func isMarkup(_ mime: String) -> Bool {
        ["text/html", "application/xhtml+xml"].contains(mime)
    }

    private static func errorReason(_ status: Int?) -> String {
        guard let status else { return "The page didn't load." }
        switch status {
        case 401, 403: return "This page isn't open to you (\(status))."
        case 404, 410: return "Nothing at this address (\(status))."
        case 500..<600: return "The site had a problem answering (\(status))."
        default: return "The site answered \(status) and sent nothing to show."
        }
    }

    // MARK: - checks

    /// The rule's own cases, run by the bench (`downloads policy-check`), so a
    /// change to it is checked without a server.
    static func selfCheck() -> [String] {
        func A(_ main: Bool, _ show: Bool, _ status: Int?, _ mime: String?, _ disp: String? = nil, _ len: Int64 = -1) -> Answer {
            Answer(mainFrame: main, canShow: show, status: status, mime: mime, disposition: disp, expectedLength: len)
        }
        let cases: [(String, Answer, Verdict)] = [
            ("html page", A(true, true, 200, "text/html"), .show),
            ("pdf inline", A(true, true, 200, "application/pdf"), .show),
            ("pdf attachment main", A(true, true, 200, "application/pdf", "attachment; filename=\"a.pdf\""), .download),
            ("pdf attachment frame (gmail)", A(false, true, 200, "application/pdf", "ATTACHMENT;filename=a.pdf"), .download),
            ("html attachment", A(true, true, 200, "text/html", "attachment"), .download),
            ("inline disposition", A(true, true, 200, "application/pdf", "inline; filename=a.pdf"), .show),
            ("binary main", A(true, false, 200, "application/octet-stream", nil, 10), .download),
            ("binary frame", A(false, false, 200, "application/octet-stream", nil, 10), .drop(reason: nil)),
            ("404 empty main", A(true, false, 404, nil, nil, 0), .drop(reason: "Nothing at this address (404).")),
            ("404 empty frame", A(false, false, 404, nil, nil, 0), .drop(reason: nil)),
            ("500 odd type", A(true, false, 500, "application/x-thing", nil, 9), .drop(reason: "The site had a problem answering (500).")),
            ("404 html", A(true, true, 404, "text/html"), .show),
            ("200 empty", A(true, false, 200, nil, nil, 0), .drop(reason: "This address sent back nothing to show.")),
            ("200 empty attachment", A(true, false, 200, nil, "attachment", 0), .drop(reason: "This address sent back nothing to show.")),
            ("unknown length binary", A(true, false, 200, "application/zip", nil, -1), .download),
            ("markup not showable", A(true, false, 200, "text/html", nil, 100), .show),
            ("file url", A(true, false, nil, "application/zip", nil, 100), .download),
            ("204 stays", A(true, false, 204, nil, nil, 0), .drop(reason: nil)),
        ]
        return cases.compactMap { name, answer, want in
            let got = decide(answer)
            return got == want ? nil : "\(name): wanted \(want), got \(got)"
        }
    }
}
