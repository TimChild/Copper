import SwiftUI

/// Everything there is to set. Pages down the left in four groups under a
/// search field, one page at a time on the right: its title and what it is
/// for, then titled sections of lines — what it is, a plain sentence, the
/// control at the right. The panel takes the room the window gives it.
///
/// Fork (settings-revamp): sized to the window, grouped rail, page headers,
/// sections, and search over every setting (`Fork/SettingsSearch.swift`,
/// `Fork/SettingsIndex.swift`, `Fork/SettingsSearchUI.swift`,
/// `Fork/SettingsLook.swift`). Every setting, storage key and behaviour is
/// the same as before; only where it is drawn changed.
struct SettingsPanel: View {
    /// Fork (settings-perf): not observed. The browser publishes for every
    /// tab, find, hover and announcement; watching it redrew the whole panel
    /// each time. Only the page matters here, kept below via `onReceive`.
    let browser: Browser
    @ObservedObject var prefs: Preferences

    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var shield = Shield.shared
    @State private var isDefault = SettingsDefaultBrowser.isDefault // Fork (settings-perf): one LaunchServices ask per opening, not per redraw
    /// Fork (settings-revamp): the panel's own width, for the rail's.
    @State private var width: CGFloat = 900
    /// Fork (settings-revamp): the page has scrolled under its header.
    /// Fork (settings-perf): an object only the header's hairline watches,
    /// so crossing the edge redraws the hairline rather than the panel.
    /// (Held in `@State`, not `@StateObject`, which would redraw the panel
    /// on every change of it all the same.)
    @State private var edge = SettingsScrollEdge()
    @Environment(\.accessibilityReduceMotion) private var still

    /// Fork (settings-revamp): this window's search, observed so the rail,
    /// the header and the results follow the query.
    @ObservedObject private var finder: SettingsFinder

    init(browser: Browser, prefs: Preferences) {
        self.browser = browser
        self.prefs = prefs
        self._finder = ObservedObject(wrappedValue: SettingsFinder.of(browser))
        self._page = State(initialValue: browser.settingsPage) // Fork (settings-perf)
    }

    enum Page: String, CaseIterable, Identifiable {
        case general, tabs, spaces, intelligence, agents, cloud, updates, extensions, passwords, downloads, privacy, labs, about // Fork: spaces, intelligence, agents, cloud, updates, labs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .tabs: return "Tabs"
            case .spaces: return "Spaces" // Fork
            case .intelligence: return "Intelligence" // Fork
            case .agents: return "Agents" // Fork
            case .cloud: return "Cloud" // Fork
            case .updates: return "Updates" // Fork
            case .extensions: return "Extensions"
            case .passwords: return "Passwords"
            case .downloads: return "Downloads"
            case .privacy: return "Privacy"
            case .labs: return "Labs" // Fork (trails): flights
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .general: return "macwindow"
            case .tabs: return "rectangle.split.3x1"
            case .spaces: return "square.stack" // Fork
            case .intelligence: return "sparkles" // Fork
            case .agents: return "cpu" // Fork
            case .cloud: return "icloud" // Fork
            case .updates: return "arrow.triangle.2.circlepath" // Fork
            case .extensions: return "puzzlepiece.extension"
            case .passwords: return "key"
            case .downloads: return "arrow.down.circle"
            case .privacy: return "hand.raised"
            case .labs: return "flask" // Fork (trails)
            case .about: return "info.circle"
            }
        }
    }

    /// Fork (settings-revamp): as big as reads well, never past the window.
    static func span(_ length: CGFloat, most: CGFloat, least: CGFloat) -> CGFloat {
        min(most, max(min(least, length - 24), length - 80))
    }

    private var rail: CGFloat { width < 760 ? 190 : 220 }

    @State private var page: Page = .general // Fork (settings-perf): mirrors browser.settingsPage

    var body: some View {
        let _ = SettingsPerf.tick("panel") // Fork (settings-perf)
        HStack(spacing: 0) {
            pages(finder)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content(finder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerRelativeFrame(.horizontal) { length, _ in SettingsPanel.span(length, most: 920, least: 600) }
        .containerRelativeFrame(.vertical) { length, _ in SettingsPanel.span(length, most: 700, least: 440) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(SettingsInk.content, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Fork (settings-perf): the shadow is cast by a plain shape behind the
        // panel. A `.shadow` on the panel itself is drawn from its content, so
        // every scrolled frame, hover and keystroke re-blurred all 920 × 700 pt
        // of it offscreen — the lag. The shape never changes, so its shadow is
        // drawn once.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SettingsInk.content)
                .shadow(color: .black.opacity(0.18), radius: 40, y: 14)
        )
        .environment(\.settingsLook, true)
        .onAppear {
            finder.opened()
            Task { await Bitwarden.shared.refreshStatus() }
            CloudIntelligence.shared.settingsOpened() // Fork (cloud-intelligence)
        }
        .onReceive(browser.$settingsPage.removeDuplicates()) { now in // Fork (settings-perf)
            guard now != page else { return }
            page = now
            Store.settings.set(now.rawValue, forKey: "settings.page")
            edge.scrolled = false
        }
        .onDisappear { SettingsDefaultBrowser.forget() } // Fork (settings-perf)
    }

    // MARK: - the rail

    private func pages(_ finder: SettingsFinder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 6)
                .padding(.top, 20)
                .padding(.bottom, 12)
            SettingsSearchField(finder: finder)
                .padding(.bottom, 12)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Page.Group.allCases, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.rawValue)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(SettingsInk.detail)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                            ForEach(Page.railOrder.filter { $0.group == group }) { item in
                                SettingsRailRow(
                                    page: item,
                                    on: page == item && !finder.showingResults,
                                    count: finder.searching ? (finder.counts[item] ?? 0) : nil
                                ) {
                                    finder.leaveResults()
                                    browser.settingsPage = item
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsInk.rail)
    }

    // MARK: - the page

    private func content(_ finder: SettingsFinder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if finder.showingResults {
                    SettingsHeader(title: "Search", blurb: resultsLine(finder)) { close }
                } else {
                    SettingsHeader(title: page.title, blurb: page.blurb) { close }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 16)
            SettingsHeaderRule(edge: edge, hidden: finder.showingResults) // Fork (settings-perf): Fork/SettingsLook.swift
            if finder.showingResults {
                SettingsResults(finder: finder, browser: browser)
            } else {
                scroll(finder)
                    .id(page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.settingsFlash, finder.flashing)
    }

    private var close: some View {
        Door(icon: "xmark", help: "Done   esc") { browser.tuning = false }
    }

    private func resultsLine(_ finder: SettingsFinder) -> String {
        let shown = finder.query.trimmingCharacters(in: .whitespaces)
        let n = finder.results.count
        if n == 0 { return "Every page searched" }
        let pages = finder.groups.count
        return "\(n) result\(n == 1 ? "" : "s") for “\(shown)”" + (pages > 1 ? " on \(pages) pages" : "") + "  ·  ↑↓ to choose, ↩ to go"
    }

    private func scroll(_ finder: SettingsFinder) -> some View {
        let page = page
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 1).settingsAnchor(page.topAnchor)
                    VStack(alignment: .leading, spacing: 26) {
                        switch page {
                        case .general: general
                        case .tabs: tabs
                        case .spaces: SpacesSettingsPage(browser: browser) // Fork
                        case .intelligence: IntelligencePage(browser: browser) // Fork
                        case .agents: AgentsPage(browser: browser) // Fork
                        case .cloud: CloudPage(browser: browser) // Fork
                        case .updates: UpdatesPage(browser: browser) // Fork
                        case .extensions: ExtensionsPage(browser: browser)
                        case .passwords: passwords
                        case .downloads: downloads
                        case .privacy: privacy
                        case .labs: LabsPage(browser: browser) // Fork (trails): Fork/Trails/Flights.swift
                        case .about: about
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 4)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY < -2 } action: { now in
                    if edge.scrolled != now { edge.scrolled = now }
                }
            }
            .onPreferenceChange(SettingsAnchorsKey.self) { finder.drawn[page] = $0 }
            .task(id: finder.pending?.token) {
                guard let target = finder.pending else { return }
                // The page draws first, and says which anchors it has.
                try? await Task.sleep(nanoseconds: 140_000_000)
                let anchor = finder.resolve(target, on: page)
                let spot = target.flash ? UnitPoint(x: 0.5, y: 0.22) : UnitPoint.top
                withAnimation(still ? nil : Motion.glide) {
                    if let anchor { proxy.scrollTo(anchor, anchor: spot) }
                    // A card another build marks with a plain `.id` still
                    // scrolls into view, even though the index check can't see it.
                    if anchor != target.anchor { proxy.scrollTo(target.anchor, anchor: spot) }
                }
                finder.landed(target, on: anchor)
            }
        }
    }

    // MARK: - general

    private var general: some View {
        Group {
            SettingsSection("Copper on this Mac") {
                Line(
                    "Open links from other apps",
                    isDefault ? "Copper is the default browser on this Mac" : "Mail, Slack and the rest still send links elsewhere"
                ) {
                    if isDefault {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 24)
                    } else {
                        Pill("Make default", filled: true) {
                            Links.becomeDefault { worked in
                                isDefault = Links.isDefault
                                browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                            }
                        }
                    }
                }
                .settingsAnchor("general.default")
                Rule()
                Line("Appearance", "Light, dark, or whatever the Mac is doing — pages follow it too") {
                    Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
                }
                .settingsAnchor("general.appearance")
                Rule()
                Line("Correct spelling as you type", "macOS's autocorrect inside pages — the one that capitalises for you") {
                    Switch(on: $prefs.autocorrect)
                }
                .settingsAnchor("general.autocorrect")
            }
            SettingsSection("Moving in") {
                FlowSettingsLine(browser: browser)
                    .settingsAnchor("general.flow")
                Rule()
                HistorySettingsLine(browser: browser)
                    .settingsAnchor("general.history")
            }
            SettingsSection("Developer") {
                Line("Let a script drive Copper", "A local socket for testing. Its tabs open beside yours with a flask on them and never take over — see ./bench") {
                    Switch(on: $prefs.bench)
                }
                .settingsAnchor("general.bench")
            }
        }
    }

    // MARK: - tabs

    private var tabs: some View {
        Group {
            SettingsSection("Layout") {
                Line("Tabs in a sidebar", "Down the left instead of across the top. Pull its edge to make it wider; double-click the edge to reset.") {
                    Switch(on: Binding(
                        get: { prefs.sidebar },
                        set: { on in withAnimation(Motion.glide) { prefs.sidebar = on } }
                    ))
                }
                .settingsAnchor("tabs.sidebar")
                Rule()
                Line("Tabs show", "Beside the title, and on a pinned square") {
                    Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
                }
                .settingsAnchor("tabs.glyph")
            }
            SettingsSection("Switching") {
                Line("⌃Tab switches to", "Choose whether Control-Tab follows the row or your most recent tabs") {
                    Segmented(options: TabSwitching.allCases.map { ($0, $0.title) }, selection: $prefs.tabSwitching)
                }
                .settingsAnchor("tabs.switching")
                Rule()
                // Fork (swipe-direction): here rather than on the Spaces page,
                // which is the editor for one space at a time; this is how the
                // column itself answers the trackpad, like ⌃Tab above it.
                Line("Swipe between spaces", "Two fingers across the tabs. Natural moves them with your fingers, Inverted the other way; Like scrolling follows the Mac's Natural scrolling") {
                    Segmented(options: SwipeDirection.allCases.map { ($0, $0.title) }, selection: $prefs.swipeDirection)
                }
                .settingsAnchor("tabs.swipe")
            }
            SettingsSection("Tabs you leave") {
                Line("Sleep tabs you aren't using",  "After half an hour away they come back where you left them. Pinned tabs, sound, calls and anything typed stay awake.") {
                    Switch(on: $prefs.sleepsTabs)
                }
                .settingsAnchor("tabs.sleep")
                Rule()
                ArchiveLine() // Fork: sections
                    .settingsAnchor("tabs.archive")
            }
        }
    }

    // MARK: - passwords

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving — it asked Copper not to offer"
        }
        return "Asked once per site, never again for a site you refuse"
    }

    private var passwords: some View {
        Group {
            SettingsSection("Saved passwords") {
                Line("Your passwords", "In the macOS keychain, shown with Touch ID") {
                    Pill("Open…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                .settingsAnchor("passwords.list")
                Rule()
                Line("Offer to save passwords", savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                .settingsAnchor("passwords.save")
                Rule()
                Line("Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it") {
                    Switch(on: $prefs.fillsPasswords)
                }
                .settingsAnchor("passwords.fill")
                Rule()
                Line("Fill addresses and cards", "Click into a checkout or address form and your Bitwarden and 1Password identities and cards hang from it") { // Fork: 1Password
                    Switch(on: $prefs.fillsEverything)
                }
                .settingsAnchor("passwords.everything")
                Rule()
                Line(
                    "Offer passkeys",
                    prefs.passkeysPossible
                        ? "Touch ID or an iCloud passkey, on sites that offer one"
                        : "Copper keeps its own passkeys — Touch ID to sign in; new passkeys are saved here and in your Passwords list"
                ) {
                    Switch(on: $prefs.passkeys)
                }
                .settingsAnchor("passwords.passkeys")
                if !Vault.never.isEmpty {
                    Rule()
                    Line("Sites never asked", "\(Vault.never.count) sites told to stop offering") {
                        Pill("Forget") {
                            Vault.never = []
                            browser.announce("Every site can ask again")
                        }
                    }
                    .settingsAnchor("passwords.never")
                }
            }
            // Fork (settings-revamp): one card per password manager, one
            // under the other — Bitwarden's here, 1Password's beside it.
            SettingsSection("Password managers", carded: false) {
                VStack(alignment: .leading, spacing: 12) {
                    SaveTargetCard(browser: browser) // Fork: Keychain / Bitwarden / 1Password (Fork/OnePasswordSettings.swift)
                    BitwardenCard(browser: browser)
                        .settingsAnchor("bitwarden", card: true)
                    OnePasswordCard(browser: browser) // Fork: 1Password (Fork/OnePasswordSettings.swift)
                        .settingsAnchor("onepassword", card: true)
                }
                .settingsAnchor("passwords.managers", card: true)
            }
            SettingsSection("Agent access", carded: false) {
                AgentAccessCard(browser: browser)
                    .settingsAnchor("passwords.agents", card: true)
            }
            SettingsSection("Import") {
                Line("Bring yours in", "From Dia, Chrome, Arc, Brave or Edge on this Mac — nothing leaves it") {
                    Pill("Import…") {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                .settingsAnchor("passwords.import")
            }
            SettingsSection("Passkeys", carded: false) {
                PasskeysSettings()
                    .settingsAnchor("passwords.passkeylist", card: true)
            }
        }
    }

    // MARK: - downloads

    private var downloads: some View {
        SettingsSection("Downloads") {
            Line("Save to", prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Pill("Change…") { chooseFolder() }
            }
            .settingsAnchor("downloads.folder")
            Rule()
            Line("Ask where to save each file") {
                Switch(on: $prefs.asksWhereToSave)
            }
            .settingsAnchor("downloads.ask")
        }
    }

    // MARK: - privacy

    private var privacy: some View {
        Group {
            SettingsSection("Blocking") {
                Line("Block ads and trackers", shield.trouble ?? "Third parties whose only job is to watch") {
                    Switch(on: $prefs.shielded)
                }
                .settingsAnchor("privacy.shield")
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, "Nothing is being blocked until this clears — try again, or restart Copper") {
                        Pill("Try again") { shield.compile() }
                    }
                }
                if let host = browser.hereHost, prefs.shielded, shield.trouble == nil {
                    Rule()
                    Line("Block on \(host)", "Turn off here if the site breaks — the page reloads") {
                        Switch(on: Binding(
                            get: { !Shield.shared.isPaused(on: host) },
                            set: { on in
                                Shield.shared.pause(host, !on)
                                browser.reload()
                            }
                        ))
                    }
                    .settingsAnchor("privacy.site")
                }
            }
            SettingsSection("Permissions") {
                Line("Camera and microphone", "What each site was allowed or refused") {
                    Pill("Forget choices") { browser.forgetCaptureChoices() }
                }
                .settingsAnchor("privacy.capture")
            }
            SettingsSection("Clear browsing data") {
                Line("History", "Every address you have been to") {
                    Pill("Clear") { browser.clearHistory() }
                }
                .settingsAnchor("privacy.history")
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                .settingsAnchor("privacy.cookies")
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
                .settingsAnchor("privacy.cache")
            }
        }
    }

    // MARK: - about

    private var about: some View {
        Group {
            HStack(spacing: 16) {
                CopperIcon(size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fork.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(verbatim: "by Collin and Felipe · version \(Updater.version) · build \(Updater.build)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsInk.detail)
                        .textSelection(.enabled)
                    Text("Built on Search by Office Commun")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsInk.detail.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(SettingsInk.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(SettingsInk.cardEdge, lineWidth: 1))
            .settingsAnchor("about.identity", card: true)

            SettingsSection("Version") {
                Line(versionTitle, versionDetail) { versionControl }
                    .settingsAnchor("about.version")
                Rule()
                Line("Found something wrong?", "Opens a draft with the version already in it") {
                    Pill("Send Feedback") { Links.writeFeedback() }
                }
                .settingsAnchor("about.feedback")
            }

            CrashesSection() // Fork: the last crash, only when there is one (Fork/CrashesUI.swift)

            SettingsSection("Keyboard shortcuts", carded: false) {
                Card {
                    ForEach(Array(SettingsShortcuts.all.enumerated()), id: \.offset) { index, shortcut in
                        if index > 0 { Rule() }
                        Shortcut(shortcut.keys, shortcut.does)
                    }
                }
                .settingsAnchor("about.shortcuts", card: true)
            }
        }
    }

    /// The version line follows the newer build from found to fetched to
    /// in place; with none, it is simply this one.
    private var versionTitle: String {
        switch updater.stage {
        case .none: return "Updates"
        case .fetching(let next): return "Copper \(next.version) is downloading…"
        case .ready(let next): return "Copper \(next.version) is ready"
        case .offered(let next): return "Copper \(next.version) is out"
        }
    }

    private var versionDetail: String {
        switch updater.stage {
        case .none:
            return updater.lastChecked.map { "Checked \($0.formatted(.relative(presentation: .named))) — once a day on its own" }
                ?? "Checked once a day on its own"
        case .fetching(let next):
            return next.notes ?? "Quietly, in the background — nothing you have set is touched"
        case .ready(let next):
            return next.notes ?? "It's there the next time you open Copper"
        case .offered(let next):
            return next.notes ?? "Open the disk image, the same as the first time"
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? "Checking…" : "Check now") {
                updater.check { found in
                    if found == nil { browser.announce("This is the latest one") }
                }
            }
            .disabled(updater.checking)
        case .fetching:
            Ring(size: 12)
        case .ready:
            Pill("Relaunch now", filled: true) { updater.relaunch() }
        case .offered(let next):
            Pill("Download", filled: true) {
                browser.tuning = false
                browser.open(next.dmg, foreground: true)
            }
        }
    }

    // MARK: - doing

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.downloads = url
    }

    // MARK: - pieces

    /// A keystroke and what it does.
    private struct Shortcut: View {
        let keys: String
        let does: String
        init(_ keys: String, _ does: String) { self.keys = keys; self.does = does }

        var body: some View {
            HStack {
                Text(does)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(keys)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(SettingsInk.detail) // Fork (settings-revamp)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// A row of choices in a grey track, one of them lifted out in white. The
/// white slides to the one you pick rather than appearing there.
struct Segmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    /// True when the control has the whole width to itself, so the choices
    /// share it evenly instead of each taking only what its word needs.
    var wide = false

    @Namespace private var slide

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                Text(title)
                    .font(.system(size: 11.5, weight: option == selection ? .medium : .regular))
                    .foregroundStyle(option == selection ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: !wide, vertical: false)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .padding(.horizontal, wide ? 4 : 10)
                    .padding(.vertical, 5)
                    .background {
                        if option == selection {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.ground)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onTapGesture {
                        withAnimation(Motion.settle) { selection = option }
                    }
            }
        }
        .padding(2)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(Motion.settle, value: selection)
    }
}

/// On or off, in ink rather than in blue.
struct Switch: View {
    @Binding var on: Bool

    var body: some View {
        let _ = SettingsPerf.tick("switch") // Fork (settings-perf)
        Capsule()
            .fill(on ? Palette.ink : Palette.faint)
            .frame(width: 30, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Palette.ground)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Motion.settle) { on.toggle() } }
            .animation(Motion.settle, value: on)
    }
}

/// A small capsule that does one thing. Outlined by default; filled in ink
/// when it is the thing you came here to press.
struct Pill: View {
    let title: String
    var filled = false
    var tint: Color = Palette.ink
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, filled: Bool = false, tint: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        let _ = SettingsPerf.tick("pill") // Fork (settings-perf)
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                // A pill is as wide as its word, never a tall wrapped column.
                .fixedSize()
                .foregroundStyle(filled ? Palette.ground : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.ground), in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

