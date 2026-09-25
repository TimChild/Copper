import Foundation

/// Per-credential sharing policy for in-process agent sign-in. The default is
/// deny-by-allow-list: agents receive no credential unless the user explicitly
/// shares its stable id, enables share-all, or places the Bitwarden item in the
/// `Agents` folder.
enum AgentAccess {
    private static let shareAllKey = "agent.credentials.shareAll"
    private static let allowedKey = "agent.credentials.allowed"

    static var shareAll: Bool {
        get { (Store.settings.object(forKey: shareAllKey) as? NSNumber)?.boolValue ?? false }
        set { Store.settings.set(newValue, forKey: shareAllKey) }
    }

    static var allowed: Set<String> {
        get { Set(Store.settings.stringArray(forKey: allowedKey) ?? []) }
        set { Store.settings.set(Array(newValue).sorted(), forKey: allowedKey) }
    }

    static func isAllowed(_ credential: Credential) -> Bool {
        credential.agentHint != .deny
            && (shareAll || allowed.contains(credential.id.string) || credential.agentHint == .allow)
    }

    static func set(_ credential: Credential, allowed value: Bool) {
        var ids = allowed
        if value {
            ids.insert(credential.id.string)
        } else {
            ids.remove(credential.id.string)
        }
        allowed = ids
    }

    @MainActor
    static func permitted(for host: String) -> [Credential] {
        Credentials.candidates(for: host).filter(isAllowed)
    }
}
