import Foundation

/// Reconstructs the extensions Chrome had installed, without loading them.
enum FlowExtensions {
    private static let builtInIDs: Set<String> = [
        // Chrome's own offline viewer and Web Store are not user extensions.
        "ghbmnnjooekpmoecnnnilnnbdlolhkhi", // Google Docs Offline
        "ahfgeienlihckogmohjhadlkjgocpleb", // Chrome Web Store
        "mhjfbmdgcfjbbpaeojofohoefgiehjai", // Chrome PDF Viewer
    ]

    /// Reads the two preference files Chrome uses for extension settings.
    static func read(_ source: Chromium.Source, profiles: [String]? = nil) -> [FlowModel.Extension] {
        let selected = profiles ?? profileNames(of: source)
        var found: [String: FlowModel.Extension] = [:]

        for profile in selected {
            let folder = source.root.appendingPathComponent(profile, isDirectory: true)
            // Secure Preferences is the authoritative copy; Preferences fills
            // in profiles written by older Chrome versions.
            for filename in ["Secure Preferences", "Preferences"] {
                guard let root = json(at: folder.appendingPathComponent(filename)),
                      let extensions = root["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: Any]
                else { continue }

                for (rawID, value) in settings where found[rawID.lowercased()] == nil {
                    guard let entry = value as? [String: Any],
                          let item = makeExtension(
                            id: rawID,
                            entry: entry,
                            profileFolder: folder
                          )
                    else { continue }
                    found[item.id] = item
                }
            }
        }

        return found.values.sorted {
            let names = $0.name.localizedStandardCompare($1.name)
            return names == .orderedSame ? $0.id < $1.id : names == .orderedAscending
        }
    }

    /// Starts a Web Store install for each extension that is not present.
    @available(macOS 15.4, *)
    @MainActor
    static func install(_ list: [FlowModel.Extension]) -> Int {
        var count = 0
        for item in list {
            guard !Extensions.shared.installed.contains(where: { $0.id == item.id }) else { continue }
            Extensions.shared.install(from: item.id)
            count += 1
        }
        return count
    }

    private static func makeExtension(
        id rawID: String,
        entry: [String: Any],
        profileFolder: URL
    ) -> FlowModel.Extension? {
        let id = rawID.lowercased()
        guard Crx.id(in: id) == id, !builtInIDs.contains(id) else { return nil }

        let fromWebStore = (entry["from_webstore"] as? Bool) == true
        let location = number(entry["location"])
        if location == 5 || location == 10 { return nil }
        let updateURL = entry["update_url"] as? String ?? ""
        let hasStoreUpdate = updateURL.localizedCaseInsensitiveContains("clients2.google.com")
        let fromStore = fromWebStore || hasStoreUpdate
        guard fromWebStore || (location == 1 && hasStoreUpdate) else { return nil }

        let manifest = entry["manifest"] as? [String: Any] ?? [:]
        let path = entry["path"] as? String
        if manifest["key"] == nil && !isUnderExtensions(path, profileFolder: profileFolder) {
            return nil
        }

        let version = manifest["version"] as? String ?? "?"
        let name = displayName(
            manifest: manifest,
            id: id,
            version: version,
            profileFolder: profileFolder,
            path: path
        )
        return FlowModel.Extension(
            id: id,
            name: name,
            version: version,
            enabled: number(entry["state"]) == 1,
            fromStore: fromStore
        )
    }

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func displayName(
        manifest: [String: Any],
        id: String,
        version: String,
        profileFolder: URL,
        path: String?
    ) -> String {
        guard let raw = manifest["name"] as? String, !raw.isEmpty else { return id }
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
        let keyStart = raw.index(raw.startIndex, offsetBy: 6)
        let keyEnd = raw.index(raw.endIndex, offsetBy: -2)
        let key = String(raw[keyStart..<keyEnd])
        guard let locale = manifest["default_locale"] as? String, !locale.isEmpty else { return id }

        let base: URL
        if let path, let candidate = extensionPath(path, profileFolder: profileFolder),
           isUnderExtensions(path, profileFolder: profileFolder)
        {
            base = candidate
        } else {
            base = profileFolder
                .appendingPathComponent("Extensions", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
        }
        let messages = base
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
            .appendingPathComponent("messages.json")
        guard let json = json(at: messages),
              let item = json[key] as? [String: Any],
              let message = item["message"] as? String,
              !message.isEmpty
        else { return id }
        return message
    }

    private static func isUnderExtensions(_ rawPath: String?, profileFolder: URL) -> Bool {
        guard let rawPath, !rawPath.isEmpty else { return false }
        let root = profileFolder
            .appendingPathComponent("Extensions", isDirectory: true)
            .standardizedFileURL.path
        guard let candidate = extensionPath(rawPath, profileFolder: profileFolder) else { return false }
        let path = candidate.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private static func extensionPath(_ rawPath: String, profileFolder: URL) -> URL? {
        guard !rawPath.isEmpty else { return nil }
        let supplied = URL(fileURLWithPath: rawPath, isDirectory: true)
        return supplied.path.hasPrefix("/")
            ? supplied
            : profileFolder.appendingPathComponent(rawPath, isDirectory: true)
    }

    /// Keeps this reader independent of the tab reader's profile discovery.
    private static func profileNames(of source: Chromium.Source) -> [String] {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(
            at: source.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var names = entries.compactMap { folder -> String? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  files.fileExists(atPath: folder.appendingPathComponent("Preferences").path)
            else { return nil }
            return folder.lastPathComponent
        }
        names.sort { left, right in
            if left == "Default" { return right != "Default" }
            if right == "Default" { return false }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return names
    }

    /// Copies preferences before parsing, so a browser write cannot tear JSON.
    private static func json(at file: URL) -> [String: Any]? {
        let files = FileManager.default
        guard files.fileExists(atPath: file.path) else { return nil }
        let temp = files.temporaryDirectory
            .appendingPathComponent("office-import-\(UUID().uuidString).json")
        guard (try? files.copyItem(at: file, to: temp)) != nil else { return nil }
        defer { try? files.removeItem(at: temp) }
        guard let data = try? Data(contentsOf: temp),
              let object = try? JSONSerialization.jsonObject(with: data),
              let value = object as? [String: Any]
        else { return nil }
        return value
    }
}
