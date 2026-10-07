import AppKit

/// Send Feedback — Settings › About and Help › Send Feedback…: a new issue on
/// Copper's own repository, opened in a Copper tab with the version, build
/// and macOS already written in. Nothing is sent until the person files it
/// there. (It used to draft a mail to the upstream project's author.)
enum Feedback {
    static let newIssue = "https://github.com/copper-browser/Copper/issues/new"

    /// The prefilled page's address.
    static func url(version: String, build: String, system: OperatingSystemVersion) -> URL {
        var parts = URLComponents(string: newIssue)!
        parts.queryItems = [
            URLQueryItem(name: "title", value: title(version: version)),
            URLQueryItem(name: "body", value: body(version: version, build: build, system: system)),
        ]
        // A literal "+" in a query reads as a space on the other end.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    static func title(version: String) -> String {
        "Feedback on Copper \(version)"
    }

    static func body(version: String, build: String, system: OperatingSystemVersion) -> String {
        "What happened, and what did you expect?\n\n\n\n---\nCopper \(version) · build \(build) · macOS \(macOS(system))"
    }

    /// 27.0, or 27.0.1 when there is a third number.
    static func macOS(_ system: OperatingSystemVersion) -> String {
        let head = "\(system.majorVersion).\(system.minorVersion)"
        return system.patchVersion > 0 ? "\(head).\(system.patchVersion)" : head
    }

    /// The last page opened, for the bench.
    @MainActor private(set) static var lastOpened: URL?

    /// Settings closes so the new tab is what you see.
    @MainActor
    static func open(in window: Browser? = nil) {
        let browser = window ?? Windows.current
        let page = url(version: Updater.version, build: String(Updater.build),
                       system: ProcessInfo.processInfo.operatingSystemVersion)
        lastOpened = page
        browser.tuning = false
        browser.open(page, foreground: true)
    }
}
