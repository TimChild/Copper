import SwiftUI

/// Settings › Passwords › Sites never asked: every site someone answered
/// "Never here" for, each with its own Forget, so one site can be let back
/// in without the rest. Forget all appears once the list is long enough to
/// want it. (It used to be one line, "2 sites told to stop offering", whose
/// Forget let every one of them back at once.)
enum NeverAsked {
    /// The rows a "Forget all" is offered beside.
    static let forgetAllFrom = 4

    static func summary(_ count: Int) -> String {
        count == 1 ? "1 site told to stop offering" : "\(count) sites told to stop offering"
    }

    /// The list's order: alphabetical, whatever the case a host was kept in.
    static func ordered(_ hosts: Set<String>) -> [String] {
        hosts.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func forgotten(_ hosts: [String]) -> String {
        hosts.count == 1 ? "\(hosts[0]) can offer to save again" : "Every site can offer to save again"
    }
}

struct NeverAskedLines: View {
    let browser: Browser
    @State private var hosts = NeverAsked.ordered(Vault.never)

    var body: some View {
        // A stack even when empty (no height in the card), so it is there to
        // hear a site added while Settings is open.
        VStack(spacing: 0) {
            if !hosts.isEmpty {
                Rule()
                Line("Sites never asked", NeverAsked.summary(hosts.count)) {
                    if hosts.count >= NeverAsked.forgetAllFrom {
                        Pill("Forget all") { forget(hosts) }
                    }
                }
                .settingsAnchor("passwords.never")
                ForEach(hosts, id: \.self) { host in
                    Rule()
                    Line(host) {
                        Pill("Forget") { forget([host]) }
                            .accessibilityLabel("Forget \(host)")
                    }
                }
            }
        }
        // "Never here" on a save offer, or the bench, while Settings is open.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = NeverAsked.ordered(Vault.never)
            if now != hosts { hosts = now }
        }
    }

    private func forget(_ some: [String]) {
        var never = Vault.never
        for host in some { never.remove(host) }
        Vault.never = never
        hosts = NeverAsked.ordered(never)
        browser.announce(NeverAsked.forgotten(some))
    }
}
