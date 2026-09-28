import Foundation

/// Owns every configured agent app. Each AgentLink keeps its own stream,
/// grants, calls and generation counter; this object only selects and saves.
@MainActor
final class AgentLinks: ObservableObject {
    static let shared = AgentLinks()

    @Published private(set) var all: [AgentLink] = []
    private var started = false

    private init() {
        let saved = MCP.shared.config.links
        all = saved.compactMap { entry in
            guard !entry.id.isEmpty else { return nil }
            return AgentLink(config: entry)
        }
        for link in all { bind(link) }
        if all.map(\.config) != saved { persist() }
    }

    private func bind(_ link: AgentLink) {
        link.bind { [weak self] in
            guard let self else { return }
            self.persist()
        }
    }

    private func persist() {
        MCP.shared.config.links = all.map(\.config)
        MCP.shared.config.legacyLink = all.first(where: { $0.id == "legacy" })?.config
    }

    func start() {
        guard !started else { return }
        started = true
        for link in all { link.start() }
    }

    @discardableResult
    func add(api: String, token: String = "", label: String = "") -> AgentLink {
        var config = AgentLink.Config(id: UUID().uuidString)
        config.api = api.trimmingCharacters(in: .whitespacesAndNewlines)
        config.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        config.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        config.enabled = !config.api.isEmpty && !config.token.isEmpty
        let link = AgentLink(config: config)
        all.append(link)
        bind(link)
        persist()
        if started { link.start() }
        return link
    }

    /// Adds the empty disabled row shown by Settings.
    @discardableResult
    func addEmpty() -> AgentLink { add(api: "", token: "") }

    /// Best-effort server revoke, then forget locally even when the app is
    /// unreachable. The UI and CLI must never strand a stale entry.
    func remove(_ link: AgentLink) async {
        link.config.enabled = false
        if link.config.linkId != nil { _ = try? await link.revokeLink() }
        all.removeAll { $0.id == link.id }
        persist()
    }

    func find(_ selector: String) -> AgentLink? {
        let wanted = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        return all.first { link in
            let host = URL(string: link.config.api)?.host?.lowercased() ?? ""
            return link.id.lowercased() == wanted || link.config.api.lowercased() == wanted ||
                host == wanted || link.config.label.lowercased() == wanted
        }
    }

    var summary: [String: Any] { ["apps": all.map(\.summary)] }

    private func choices() -> String {
        let labels = all.map { link in
            let label = link.config.label.isEmpty ? (URL(string: link.config.api)?.host ?? link.id) : link.config.label
            return "\(label) [\(link.id)]"
        }
        return labels.isEmpty ? "no agent apps configured" : labels.joined(separator: ", ")
    }

    private func target(_ selector: String) -> AgentLink? {
        if !selector.isEmpty { return find(selector) }
        return all.count == 1 ? all[0] : nil
    }

    /// Loopback control surface. `status` without `app` returns all apps;
    /// every other operation needs a unique target when there is more than one.
    func control(_ params: [String: Any]) async -> [String: Any] {
        let op = params["op"] as? String ?? "status"
        let selector = (params["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if op == "status" && selector.isEmpty {
            var out = summary
            let compat = all.first(where: { $0.id == "legacy" }) ?? all.first
            if let compat { for (key, value) in compat.summary { out[key] = value } }
            return out
        }
        if op == "add" {
            let api = (params["api"] as? String ?? params["arg"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let token = (params["token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (params["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard LinkWire.base(api) != nil else { return ["error": "link add needs an https URL"] }
            let link = add(api: api, token: token, label: label)
            if link.config.enabled {
                link.config.enabled = true
                return await link.settled()
            }
            return link.summary
        }
        guard let link = target(selector) else {
            return ["error": selector.isEmpty ? "choose an app with --app (choices: \(choices()))" : "no agent app \(selector) (choices: \(choices()))"]
        }
        if op == "remove" {
            await remove(link)
            return ["removed": true, "id": link.id]
        }
        return await link.control(params)
    }

    func bench(_ arg: String) -> [String: Any] {
        guard let link = all.first else { return ["error": "no agent apps configured"] }
        return link.bench(arg)
    }
}

