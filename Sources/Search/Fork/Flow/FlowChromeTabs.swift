import Foundation

// Chromium keeps open tabs as an append-only command stream rather than JSON.
// This reader replays the small part of that stream which describes windows,
// tabs, navigation entries, pins, groups, and last-active times. It is kept in
// the fork so upstream's importer remains untouched.
enum FlowChromeTabs {
    private static let sessionPrefix = "Session_"
    private static let tabsPrefix = "Tabs_"

    /// Profile directories are the children of Chromium's user-data root.
    static func profiles(of source: Chromium.Source) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: source.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let names = entries.compactMap { url -> String? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let preferences = url.appendingPathComponent("Preferences")
            guard FileManager.default.fileExists(atPath: preferences.path) else { return nil }
            return url.lastPathComponent
        }
        return names.sorted {
            if $0 == "Default" { return true }
            if $1 == "Default" { return false }
            return $0 < $1
        }
    }

    /// Reads every profile which has a readable session file.
    static func read(_ source: Chromium.Source) throws -> [FlowModel.Space] {
        let profiles = profiles(of: source)
        guard !profiles.isEmpty else {
            throw FlowModel.Trouble.unreadable("\(source.name)'s session files")
        }

        var spaces: [FlowModel.Space] = []
        var readAny = false
        for profile in profiles {
            let profileRoot = source.root.appendingPathComponent(profile, isDirectory: true)
            let sessions = profileRoot.appendingPathComponent("Sessions", isDirectory: true)
            let folder = containsSessionFiles(in: sessions) ? sessions : profileRoot
            guard let result = try? parse(folder: folder, profile: profile, sourceName: source.name) else {
                continue
            }
            readAny = readAny || result.readAny
            spaces.append(contentsOf: result.spaces)
        }

        guard readAny else {
            throw FlowModel.Trouble.unreadable("\(source.name)'s session files")
        }
        return spaces
    }

    /// Reads a copied Sessions directory (or a profile directory containing
    /// Current Session / Session_* files). The flexible shape keeps fixtures
    /// small and mirrors both Chromium's modern and legacy layouts.
    static func read(sessionsFolder: URL, profile: String?) throws -> [FlowModel.Space] {
        let folders = resolveFolders(sessionsFolder, profile: profile)
        var spaces: [FlowModel.Space] = []
        var readAny = false
        let sourceName = "Chrome"
        for folder in folders {
            guard let result = try? parse(folder: folder, profile: profile, sourceName: sourceName) else {
                continue
            }
            readAny = readAny || result.readAny
            spaces.append(contentsOf: result.spaces)
        }
        guard readAny else {
            throw FlowModel.Trouble.unreadable("session files")
        }
        return spaces
    }

    // MARK: - locating and copying files

    private struct ParseResult {
        var spaces: [FlowModel.Space]
        var readAny: Bool
    }

    private enum CommandFileKind {
        case session
        case tabs
    }

    private struct Command {
        let id: UInt8
        let payload: [UInt8]
        let kind: CommandFileKind
    }

    private static func resolveFolders(_ root: URL, profile: String?) -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let hasSessionFile = names.contains { isSessionFileName($0.lastPathComponent) }
        if hasSessionFile {
            return [root]
        }

        if let profile {
            let profileRoot = root.appendingPathComponent(profile, isDirectory: true)
            let sessions = profileRoot.appendingPathComponent("Sessions", isDirectory: true)
            if containsSessionFiles(in: sessions) { return [sessions] }
            if let children = try? fm.contentsOfDirectory(at: profileRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
               children.contains(where: { isSessionFileName($0.lastPathComponent) }) {
                return [profileRoot]
            }
        }

        let directSessions = root.appendingPathComponent("Sessions", isDirectory: true)
        if containsSessionFiles(in: directSessions) { return [directSessions] }

        return names.compactMap { child in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let sessions = child.appendingPathComponent("Sessions", isDirectory: true)
            if containsSessionFiles(in: sessions) { return sessions }
            let childFiles = (try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return childFiles.contains(where: { isSessionFileName($0.lastPathComponent) }) ? child : nil
        }
    }

    private static func isSessionFileName(_ name: String) -> Bool {
        name == "Current Session" || name == "Current Tabs" ||
            name.hasPrefix(sessionPrefix) || name.hasPrefix(tabsPrefix)
    }

    private static func containsSessionFiles(in folder: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.contains { isSessionFileName($0.lastPathComponent) }
    }

    /// Copy before reading: Chromium may be writing the live file underneath
    /// us, and the import contract never reads another browser's file in place.
    private static func copiedData(_ url: URL) -> Data? {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-session-\(UUID().uuidString)")
        guard (try? FileManager.default.copyItem(at: url, to: temporary)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try? Data(contentsOf: temporary)
    }

    private static func profileName(in folder: URL, profile: String?) -> String? {
        let profileRoot: URL
        if folder.lastPathComponent == "Sessions" {
            profileRoot = folder.deletingLastPathComponent()
        } else if let profile, !profile.isEmpty, folder.lastPathComponent != profile {
            profileRoot = folder.appendingPathComponent(profile, isDirectory: true)
        } else {
            profileRoot = folder
        }
        let preferences = profileRoot.appendingPathComponent("Preferences")
        guard let data = copiedData(preferences),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileObject = object["profile"] as? [String: Any],
              let name = profileObject["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return name
    }

    private static func candidates(in folder: URL, prefix: String, legacy: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let modern = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { timestamp(in: $0.lastPathComponent, prefix: prefix) > timestamp(in: $1.lastPathComponent, prefix: prefix) }
        if !modern.isEmpty { return modern }
        return files.filter { $0.lastPathComponent == legacy }
    }

    private static func timestamp(in name: String, prefix: String) -> Int64 {
        Int64(name.dropFirst(prefix.count)) ?? 0
    }

    // MARK: - command replay

    private struct TabID: Hashable { let value: Int32 }
    private struct WindowID: Hashable { let value: Int32 }
    private struct GroupKey: Hashable {
        let high: UInt64
        let low: UInt64
    }

    private struct Navigation {
        var index: Int32
        var url: String
        var title: String
    }

    private struct TabState {
        let id: TabID
        var window: WindowID?
        var index: Int32?
        var navigations: [Int32: Navigation] = [:]
        var selectedNavigation: Int32?
        var pinned = false
        var group: GroupKey?
        var lastActive: Date?
    }

    private struct WindowState {
        let id: WindowID
        var selectedTabIndex: Int32 = -1
        var type: Int32 = 0
    }

    private struct GroupState {
        var title = ""
        var hue: Double?
    }

    private static func parse(folder: URL, profile: String?, sourceName: String) throws -> ParseResult {
        let sessionFiles = candidates(in: folder, prefix: sessionPrefix, legacy: "Current Session")
        let tabsFiles = candidates(in: folder, prefix: tabsPrefix, legacy: "Current Tabs")
        guard !sessionFiles.isEmpty || !tabsFiles.isEmpty else {
            return ParseResult(spaces: [], readAny: false)
        }

        var commands: [Command] = []
        var readAny = false
        // Session_* owns window/tab state; Tabs_* owns navigation entries. The
        // latest file of each kind is the complete current snapshot.
        for file in sessionFiles {
            guard let data = copiedData(file), let parsed = parseCommands(data, kind: .session) else { continue }
            readAny = true
            commands.append(contentsOf: parsed)
            break
        }
        for file in tabsFiles {
            guard let data = copiedData(file), let parsed = parseCommands(data, kind: .tabs) else { continue }
            readAny = true
            commands.append(contentsOf: parsed)
            break
        }
        guard readAny else { return ParseResult(spaces: [], readAny: false) }

        var tabs: [TabID: TabState] = [:]
        var windows: [WindowID: WindowState] = [:]
        var groups: [GroupKey: GroupState] = [:]
        for command in commands {
            replay(command, tabs: &tabs, windows: &windows, groups: &groups)
        }

        let profileLabel = profileName(in: folder, profile: profile)
        let baseName: String
        if profile == nil || profile == "" || profile == "Default" {
            baseName = sourceName
        } else {
            baseName = "\(sourceName) · \(profileLabel ?? profile ?? sourceName)"
        }

        let orderedWindows = windows.values
            .filter { $0.type == 0 }
            .sorted { $0.id.value < $1.id.value }
        var spaces: [FlowModel.Space] = []
        for (windowNumber, window) in orderedWindows.enumerated() {
            let tabStates = tabs.values
                .filter { $0.window == window.id }
                .sorted {
                    let left = $0.index ?? Int32.max
                    let right = $1.index ?? Int32.max
                    return left == right ? $0.id.value < $1.id.value : left < right
                }
            var outputTabs: [(FlowModel.Tab, GroupKey?)] = []
            for tab in tabStates {
                let chosenIndex = tab.selectedNavigation.flatMap { tab.navigations[$0] }?.index
                    ?? tab.navigations.keys.max()
                guard let navigation = chosenIndex.flatMap({ tab.navigations[$0] }),
                      let url = URL(string: navigation.url),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
                else { continue }
                let active = tab.index.map { $0 == window.selectedTabIndex } ?? false
                let seen = tab.lastActive?.timeIntervalSince1970
                let model = FlowModel.Tab(
                    url: url,
                    title: navigation.title,
                    pinned: tab.pinned,
                    saved: false,
                    group: nil,
                    seen: seen,
                    active: active
                )
                outputTabs.append((model, tab.group))
            }

            var modelGroups: [FlowModel.Group] = []
            var ids: [GroupKey: UUID] = [:]
            for (_, key) in outputTabs {
                guard let key, ids[key] == nil else { continue }
                ids[key] = UUID()
                guard let id = ids[key] else { continue }
                let state = groups[key] ?? GroupState()
                modelGroups.append(FlowModel.Group(id: id, name: state.title.isEmpty ? "Tab Group" : state.title, hue: state.hue))
            }
            let finalTabs = outputTabs.map { item in
                var tab = item.0
                if let key = item.1 { tab.group = ids[key] }
                return tab
            }
            let space = FlowModel.Space(
                name: windowNumber == 0 ? baseName : "\(baseName) \(windowNumber + 1)",
                groups: modelGroups,
                tabs: finalTabs,
                profile: profile
            )
            // Windows are the import unit. A window whose pages are all
            // chrome:// (and therefore filtered) still remains a named space;
            // a browser with no restored windows produces [] naturally.
            spaces.append(space)
        }
        return ParseResult(spaces: spaces, readAny: true)
    }

    private static func parseCommands(_ data: Data, kind: CommandFileKind) -> [Command]? {
        guard data.count >= 8,
              data[0] == 0x53, data[1] == 0x4e, data[2] == 0x53, data[3] == 0x53
        else { return nil }
        let version = Int32(littleUInt32(data, at: 4))
        // Version 3 is cleartext with a marker. Version 1 is the old cleartext
        // stream. Versions 4/5 are OS-crypt encrypted and intentionally skipped.
        guard version == 1 || version == 3 else { return nil }

        var offset = 8
        var commands: [Command] = []
        while offset + 2 <= data.count {
            let size = Int(littleUInt16(data, at: offset))
            guard size >= 1, size <= data.count - offset - 2 else { break }
            let idOffset = offset + 2
            let id = data[idOffset]
            let payloadStart = idOffset + 1
            let payloadEnd = offset + 2 + size
            if id != 255 {
                commands.append(Command(id: id, payload: Array(data[payloadStart..<payloadEnd]), kind: kind))
            }
            var next = payloadEnd
            // Current Chromium writes records back-to-back. A few old writers
            // padded a pickle record to four bytes, so accept that form when
            // the unaligned bytes cannot themselves be a command header.
            if next % 4 != 0 {
                let aligned = (next + 3) & ~3
                let unalignedValid = next + 2 <= data.count && {
                    let candidate = Int(littleUInt16(data, at: next))
                    return candidate >= 1 && candidate <= data.count - next - 2
                }()
                let alignedValid = aligned + 2 <= data.count && {
                    let candidate = Int(littleUInt16(data, at: aligned))
                    return candidate >= 1 && candidate <= data.count - aligned - 2
                }()
                if !unalignedValid && alignedValid { next = aligned }
            }
            offset = next
        }
        return commands
    }

    private static func replay(_ command: Command, tabs: inout [TabID: TabState], windows: inout [WindowID: WindowState], groups: inout [GroupKey: GroupState]) {
        let id = command.id
        let payload = command.payload
        if case .tabs = command.kind {
            switch id {
            case 1:
                if let navigation = readNavigation(payload) {
                    let tabID = TabID(value: navigation.tabID)
                    var state = tabs[tabID] ?? TabState(id: tabID)
                    state.navigations[navigation.entry.index] = navigation.entry
                    tabs[tabID] = state
                }
            case 4:
                if let (tab, index) = readPair(payload) {
                    let tabID = TabID(value: tab)
                    var state = tabs[tabID] ?? TabState(id: tabID)
                    state.selectedNavigation = index
                    tabs[tabID] = state
                }
            case 5:
                if let (tab, pinned) = readPinned(payload) {
                    let tabID = TabID(value: tab)
                    var state = tabs[tabID] ?? TabState(id: tabID)
                    state.pinned = pinned
                    tabs[tabID] = state
                }
            default:
                break
            }
            return
        }
        switch id {
        case 0:
            guard let (window, tab) = readPair(payload) else { return }
            let tabID = TabID(value: tab), windowID = WindowID(value: window)
            var state = tabs[tabID] ?? TabState(id: tabID)
            state.window = windowID; tabs[tabID] = state
            if windows[windowID] == nil { windows[windowID] = WindowState(id: windowID) }
        case 2:
            guard let (tab, index) = readPair(payload) else { return }
            let tabID = TabID(value: tab)
            var state = tabs[tabID] ?? TabState(id: tabID)
            state.index = index; tabs[tabID] = state
        case 5:
            guard let (tab, index) = readPair(payload), index >= 0 else { return }
            prune(&tabs, tab: TabID(value: tab), index: index, count: Int32.max, shifts: false)
        case 11:
            guard let (tab, index) = readPair(payload), index > 0 else { return }
            prune(&tabs, tab: TabID(value: tab), index: 0, count: index, shifts: true)
        case 6:
            guard let navigation = readNavigation(payload) else { return }
            let tabID = TabID(value: navigation.tabID)
            var state = tabs[tabID] ?? TabState(id: tabID)
            state.navigations[navigation.entry.index] = navigation.entry
            tabs[tabID] = state
        case 7:
            guard let (tab, index) = readPair(payload) else { return }
            let tabID = TabID(value: tab)
            var state = tabs[tabID] ?? TabState(id: tabID)
            state.selectedNavigation = index; tabs[tabID] = state
        case 8:
            guard let (window, index) = readPair(payload) else { return }
            let windowID = WindowID(value: window)
            var state = windows[windowID] ?? WindowState(id: windowID)
            state.selectedTabIndex = index; windows[windowID] = state
        case 9:
            guard let (window, type) = readPair(payload) else { return }
            let windowID = WindowID(value: window)
            var state = windows[windowID] ?? WindowState(id: windowID)
            state.type = type; windows[windowID] = state
        case 12:
            guard let (tab, pinned) = readPinned(payload) else { return }
            let tabID = TabID(value: tab)
            var state = tabs[tabID] ?? TabState(id: tabID)
            state.pinned = pinned; tabs[tabID] = state
        case 16:
            guard let tab = readClosedID(payload) else { return }
            tabs.removeValue(forKey: TabID(value: tab))
        case 17:
            guard let window = readClosedID(payload) else { return }
            windows.removeValue(forKey: WindowID(value: window))
        case 21:
            guard let (tab, micros) = readLastActive(payload) else { return }
            let tabID = TabID(value: tab)
            var state = tabs[tabID] ?? TabState(id: tabID)
            state.lastActive = FlowModel.date(chromium: micros); tabs[tabID] = state
        case 24:
            guard let (tab, index, count) = readTriple(payload), index >= 0, count > 0 else { return }
            prune(&tabs, tab: TabID(value: tab), index: index, count: count, shifts: true)
        case 25:
            guard let value = readTabGroup(payload) else { return }
            let tabID = TabID(value: value.tab)
            var state = tabs[tabID] ?? TabState(id: tabID)
            state.group = value.group; tabs[tabID] = state
        case 27:
            guard let value = readGroupMetadata(payload) else { return }
            groups[value.key] = GroupState(title: value.title, hue: value.hue)
        default:
            break
        }
    }

    private static func prune(_ tabs: inout [TabID: TabState], tab tabID: TabID, index: Int32, count: Int32, shifts: Bool) {
        var state = tabs[tabID] ?? TabState(id: tabID)
        let start = Int64(index)
        let amount = Int64(count)
        let end = count == Int32.max ? Int64.max : start + amount
        var kept: [Int32: Navigation] = [:]
        for (oldIndex, navigation) in state.navigations {
            let old = Int64(oldIndex)
            if old >= start && old < end { continue }
            let candidate = shifts && old >= end ? old - amount : old
            guard candidate >= Int64(Int32.min), candidate <= Int64(Int32.max) else { continue }
            let newIndex = Int32(candidate)
            var moved = navigation
            moved.index = newIndex
            kept[newIndex] = moved
        }
        if let selected = state.selectedNavigation {
            let selectedValue = Int64(selected)
            if selectedValue >= start && selectedValue < end {
                state.selectedNavigation = index > 0 ? index - 1 : nil
            } else if shifts && selectedValue >= end {
                let candidate = selectedValue - amount
                state.selectedNavigation = candidate >= Int64(Int32.min) ? Int32(candidate) : nil
            }
        }
        state.navigations = kept
        tabs[tabID] = state
    }

    // MARK: - binary and pickle readers

    private struct PickleReader {
        let bytes: [UInt8]
        var offset: Int = 4
        let end: Int

        init?(_ payload: [UInt8]) {
            guard payload.count >= 4 else { return nil }
            let declared = Int(littleUInt32(payload, at: 0))
            guard declared == payload.count - 4 else { return nil }
            bytes = payload; end = 4 + declared
        }

        mutating func int32() -> Int32? { integer(Int32.self).map { $0 } }
        mutating func uint32() -> UInt32? { integer(UInt32.self).map { $0 } }
        mutating func uint64() -> UInt64? { integer(UInt64.self).map { $0 } }
        mutating func int64() -> Int64? { integer(Int64.self).map { $0 } }
        mutating func bool() -> Bool? {
            guard offset < end else { return nil }
            let value = bytes[offset] != 0
            offset = aligned(offset + 1)
            guard offset <= end else { return nil }
            return value
        }

        mutating func string() -> String? {
            guard let length = uint32(), UInt64(length) <= UInt64(Int.max) else { return nil }
            let count = Int(length)
            guard count <= end - offset else { return nil }
            let data = Data(bytes[offset..<offset + count])
            offset = aligned(offset + count)
            guard offset <= end else { return nil }
            return String(data: data, encoding: .utf8)
        }

        /// Encoded page state is an opaque byte string and is not necessarily
        /// UTF-8. Consume it without making a lossy String conversion.
        mutating func skipString() -> Bool {
            guard let length = uint32(), UInt64(length) <= UInt64(Int.max) else { return false }
            let count = Int(length)
            guard count <= end - offset else { return false }
            offset = aligned(offset + count)
            return offset <= end
        }

        mutating func string16() -> String? {
            guard let length = uint32(), UInt64(length) <= UInt64(Int.max / 2) else { return nil }
            let count = Int(length) * 2
            guard count <= end - offset else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(Int(length))
            var cursor = offset
            for _ in 0..<Int(length) {
                units.append(UInt16(bytes[cursor]) | UInt16(bytes[cursor + 1]) << 8)
                cursor += 2
            }
            offset = aligned(offset + count)
            guard offset <= end else { return nil }
            return String(decoding: units, as: UTF16.self)
        }

        private mutating func integer<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            guard offset + MemoryLayout<T>.size <= end else { return nil }
            let value: T
            if T.self == UInt32.self {
                value = T(littleUInt32(bytes, at: offset))
            } else if T.self == Int32.self {
                value = unsafeBitCast(littleUInt32(bytes, at: offset), to: T.self)
            } else if T.self == UInt64.self {
                value = T(littleUInt64(bytes, at: offset))
            } else {
                value = unsafeBitCast(littleUInt64(bytes, at: offset), to: T.self)
            }
            offset = aligned(offset + MemoryLayout<T>.size)
            guard offset <= end else { return nil }
            return value
        }

        private func aligned(_ value: Int) -> Int { (value + 3) & ~3 }
    }

    private static func readPair(_ payload: [UInt8]) -> (Int32, Int32)? {
        if var pickle = PickleReader(payload), let a = pickle.int32(), let b = pickle.int32() {
            return (a, b)
        }
        guard payload.count >= 8 else { return nil }
        return (Int32(bitPattern: littleUInt32(payload, at: 0)), Int32(bitPattern: littleUInt32(payload, at: 4)))
    }

    private static func readPinned(_ payload: [UInt8]) -> (Int32, Bool)? {
        if payload.count == 8 && zeroPadding(in: payload, from: 5, through: 7) {
            return (Int32(bitPattern: littleUInt32(payload, at: 0)), payload[4] != 0)
        }
        if var pickle = PickleReader(payload), let tab = pickle.int32(), let pinned = pickle.bool() {
            return (tab, pinned)
        }
        guard payload.count >= 5 else { return nil }
        return (Int32(bitPattern: littleUInt32(payload, at: 0)), payload[4] != 0)
    }

    private static func readClosedID(_ payload: [UInt8]) -> Int32? {
        if payload.count >= 16 && zeroPadding(in: payload, from: 4, through: 7) {
            return Int32(bitPattern: littleUInt32(payload, at: 0))
        }
        if var pickle = PickleReader(payload) { return pickle.int32() }
        guard payload.count >= 4 else { return nil }
        return Int32(bitPattern: littleUInt32(payload, at: 0))
    }

    private static func readLastActive(_ payload: [UInt8]) -> (Int32, Int64)? {
        if payload.count == 16 && littleUInt32(payload, at: 0) != 12 && zeroPadding(in: payload, from: 4, through: 7) {
            return (Int32(bitPattern: littleUInt32(payload, at: 0)), Int64(bitPattern: littleUInt64(payload, at: 8)))
        }
        if var pickle = PickleReader(payload), let tab = pickle.int32(), let micros = pickle.int64() {
            return (tab, micros)
        }
        guard payload.count >= 16 else { return nil }
        return (Int32(bitPattern: littleUInt32(payload, at: 0)), Int64(bitPattern: littleUInt64(payload, at: 8)))
    }

    private static func readTriple(_ payload: [UInt8]) -> (Int32, Int32, Int32)? {
        if var pickle = PickleReader(payload), let a = pickle.int32(), let b = pickle.int32(), let c = pickle.int32() {
            return (a, b, c)
        }
        guard payload.count >= 12 else { return nil }
        return (
            Int32(bitPattern: littleUInt32(payload, at: 0)),
            Int32(bitPattern: littleUInt32(payload, at: 4)),
            Int32(bitPattern: littleUInt32(payload, at: 8))
        )
    }

    private static func readNavigation(_ payload: [UInt8]) -> (tabID: Int32, entry: Navigation)? {
        guard var pickle = PickleReader(payload),
              let tabID = pickle.int32(),
              let index = pickle.int32(),
              let url = pickle.string(),
              let title = pickle.string16(),
              pickle.skipString(),
              pickle.int32() != nil
        else { return nil }
        return (tabID, Navigation(index: index, url: url, title: title))
    }

    private static func readTabGroup(_ payload: [UInt8]) -> (tab: Int32, group: GroupKey?)? {
        if payload.count == 32 && zeroPadding(in: payload, from: 4, through: 7) {
            let tab = Int32(bitPattern: littleUInt32(payload, at: 0))
            let high = littleUInt64(payload, at: 8)
            let low = littleUInt64(payload, at: 16)
            let hasGroup = payload.count < 25 || payload[24] != 0
            return (tab, hasGroup && (high != 0 || low != 0) ? GroupKey(high: high, low: low) : nil)
        }
        if var pickle = PickleReader(payload), let tab = pickle.int32(), let high = pickle.uint64(), let low = pickle.uint64() {
            let hasGroup = pickle.bool() ?? true
            return (tab, hasGroup && (high != 0 || low != 0) ? GroupKey(high: high, low: low) : nil)
        }
        guard payload.count >= 24 else { return nil }
        let tab = Int32(bitPattern: littleUInt32(payload, at: 0))
        let high = littleUInt64(payload, at: 8)
        let low = littleUInt64(payload, at: 16)
        let hasGroup = payload.count < 25 || payload[24] != 0
        return (tab, hasGroup && (high != 0 || low != 0) ? GroupKey(high: high, low: low) : nil)
    }

    private static func readGroupMetadata(_ payload: [UInt8]) -> (key: GroupKey, title: String, hue: Double?)? {
        guard var pickle = PickleReader(payload),
              let high = pickle.uint64(), let low = pickle.uint64(),
              let title = pickle.string16(), let color = pickle.uint32()
        else { return nil }
        let hue: Double? = color == 0 ? nil : min(1, Double(color) / 8.0)
        return (GroupKey(high: high, low: low), title, hue)
    }

    private static func zeroPadding(in bytes: [UInt8], from start: Int, through end: Int) -> Bool {
        guard start >= 0, end < bytes.count, start <= end else { return false }
        return bytes[start...end].allSatisfy { $0 == 0 }
    }

    private static func littleUInt16(_ bytes: Data, at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func littleUInt32(_ bytes: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(bytes[offset + i]) << UInt32(8 * i)
        }
        return value
    }

    private static func littleUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(bytes[offset + i]) << UInt32(8 * i)
        }
        return value
    }

    private static func littleUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        // One shift per line: the eight-way expression is what an older
        // compiler (the release runner's) gives up type-checking.
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[offset + i]) << UInt64(8 * i)
        }
        return value
    }
}
