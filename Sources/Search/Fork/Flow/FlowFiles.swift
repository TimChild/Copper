import AppKit
import Foundation
import UniformTypeIdentifiers

/// The way in that needs no permission: a file the browser exported.
///
/// When macOS keeps Chrome's folder private, Chrome can still hand over two
/// things on its own — its bookmarks as an HTML file, its passwords as a
/// CSV. The locked card's "Use an export instead…" takes either, dropped on
/// the sheet or picked. A file brings only what is in it: no open tabs,
/// history or sign-ins, and the pane says so.
///
/// Bookmarks go through the same merge as a direct read
/// (`FlowBookmarks.take(_, from:)`), so taking the same file twice — or the
/// file after a direct read — replaces rather than doubles. Passwords go
/// where a move's passwords go (`FlowSecrets.sink`): the keychain, or in a
/// test run the in-memory stand-in.
enum FlowFiles {
    enum Kind: Equatable { case bookmarks, passwords, neither }

    /// What a file is, by what is in it rather than its name.
    static func kind(of text: String) -> Kind {
        if FlowBookmarksHTML.isBookmarkFile(text) { return .bookmarks }
        if passwordColumns(text) != nil { return .passwords }
        return .neither
    }

    /// Text the way exports come: UTF-8 (with or without a byte-order mark),
    /// UTF-16 with one, or a single-byte file as Latin-1.
    static func text(_ data: Data) -> String? { FlowBookmarksHTML.text(data) }

    /// The header of a passwords CSV: the columns `Vault.take(csv:)` reads
    /// (a site, a username, a password), or nil when the first line isn't one.
    // TODO(integrator): use PasswordCSV.problem(with:) (ux/settings-data) here, one CSV module (X-15).
    static func passwordColumns(_ text: String) -> [String]? {
        guard let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        let names = line.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{FEFF} ")).lowercased()
        }
        let site = names.contains { ["url", "login_uri", "website", "site"].contains($0) }
        let user = names.contains { ["username", "login_username", "user", "email"].contains($0) }
        let password = names.contains { ["password", "login_password"].contains($0) }
        return site && user && password ? names : nil
    }

    /// The sentence a passwords file comes to.
    static func passwordSentence(kept: Int, skipped: Int, new: Int?) -> String {
        if kept == 0, skipped == 0 { return "That file has no passwords in it" }
        if kept == 0 {
            return skipped == 1
                ? "Nothing imported — its one row has no site or no password"
                : "Nothing imported — none of its \(skipped) rows has both a site and a password"
        }
        var head = kept == 1 ? "1 password imported" : "\(kept) passwords imported"
        if let new, new < kept { head += new == 0 ? " — all were already here" : " — \(new) new" }
        return skipped == 0 ? head : "\(head), \(skipped) skipped (no site or no password)"
    }

    /// The sentence a bookmarks file comes to.
    static func bookmarkSentence(read: Int, new: Int, source: String) -> String {
        if read == 0 { return "That file has no bookmarks in it" }
        if new == 0 {
            return read == 1
                ? "Nothing new — the bookmark in that file was already here"
                : "Nothing new — the \(read) bookmarks in that file were already here"
        }
        let head = read == 1 ? "1 bookmark from \(source)'s file" : "\(read) bookmarks from \(source)'s file"
        return new < read ? "\(head), \(new) new" : head
    }
}

extension Flow {
    /// The locked card's secondary button: the export pane for this source.
    func showExport(for source: FlowSource) {
        guard !moving else { return }
        exporting = source
        log("export", source.name)
    }

    /// Takes one exported file, as dropped or picked. The file is read and
    /// parsed off the main actor, and its bookmarks merged there too (a
    /// large export takes a moment, never the window); one file at a time.
    func takeFile(_ url: URL, from source: String, into browser: Browser) {
        guard !fileBusy else { return }
        fileBusy = true
        fileResult = nil
        log("file", "reading")
        Task {
            let result = await bring(url, from: source, into: browser)
            fileResult = result
            fileBusy = false
            log("file", "\(result.ok ? "ok" : "no") \(result.text)")
        }
    }

    /// What a file is, read off the main actor.
    private enum Opened {
        case unreadable
        case bookmarks(FlowBookmarks.Read, count: Int, new: Int)
        case passwords(String)
        case neither
    }

    private func bring(_ url: URL, from source: String, into browser: Browser) async -> FileResult {
        let before = browser.bookmarks.roots
        let opened = await Task.detached(priority: .userInitiated) { () -> Opened in
            guard let data = try? Data(contentsOf: url), let text = FlowFiles.text(data) else { return .unreadable }
            switch FlowFiles.kind(of: text) {
            case .bookmarks:
                let read = FlowBookmarksHTML.read(data, layout: .chromium, file: url)
                let new = FlowBookmarks.addresses(read.nodes).subtracting(FlowBookmarks.addresses(before)).count
                return .bookmarks(read, count: read.complete ? FlowBookmarks.count(read.nodes) : 0, new: new)
            case .passwords: return .passwords(text)
            case .neither: return .neither
            }
        }.value
        switch opened {
        case .unreadable:
            return FileResult(ok: false, text: "Couldn't read that file — choose the file the export made")
        case .bookmarks(let read, let count, let new):
            guard count > 0 else {
                return FileResult(ok: false, text: FlowFiles.bookmarkSentence(read: 0, new: 0, source: source))
            }
            await FlowBookmarks.takeInBackground(read, from: source, into: browser.bookmarks)
            return FileResult(ok: new > 0, text: FlowFiles.bookmarkSentence(read: count, new: new, source: source))
        case .passwords(let text):
            let seams = FlowSecrets.seams
            let sink = FlowSecrets.sink
            // Each row is a keychain write in a real run: off the main actor.
            let result = await Task.detached(priority: .userInitiated) { () -> (kept: Int, skipped: Int, new: Int?) in
                guard seams else {
                    // Copper's own CSV import, as Passwords › CSV file… runs it.
                    let taken = Vault.take(csv: text)
                    return (taken.kept, taken.skipped, nil)
                }
                var new = 0
                var known = true
                let taken = Vault.take(csv: text) { host, user, password in
                    let saved = sink.savePassword(host: host, user: user, password: password, used: nil)
                    if let isNew = saved.new { if isNew && saved.kept { new += 1 } } else { known = false }
                    return saved.kept
                }
                return (taken.kept, taken.skipped, known ? new : nil)
            }.value
            if !seams { browser.relist() }
            return FileResult(ok: result.kept > 0,
                              text: FlowFiles.passwordSentence(kept: result.kept, skipped: result.skipped, new: result.new))
        case .neither:
            return FileResult(ok: false, text: "That isn't a bookmarks or passwords file — export one from \(source) as described above")
        }
    }

    /// "Choose a file…": a panel on the sheet itself, starting in Downloads.
    func chooseFile(from source: String, into browser: Browser) {
        guard let sheet = FlowPresenter.shared.sheetWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html, .commaSeparatedText, .plainText]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose the bookmarks (.html) or passwords (.csv) file \(source) exported."
        panel.prompt = "Bring In"
        log("file-panel", source)
        panel.beginSheetModal(for: sheet) { [weak self, weak browser] response in
            guard response == .OK, let url = panel.url, let self, let browser else { return }
            self.takeFile(url, from: source, into: browser)
        }
    }
}
