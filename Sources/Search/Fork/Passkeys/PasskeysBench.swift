import Foundation

/// Bench's small, JSON-safe window into the test-world passkey store.
enum PasskeysBench {
    @MainActor static func handle(_ request: [String: Any]) -> [String: Any] {
        let op = request["op"] as? String ?? "list"
        switch op {
        case "list":
            return ["credentials": PasskeyStore.all().map(row)]
        case "count":
            return ["count": PasskeyStore.all().count]
        case "forget":
            guard let text = request["arg"] as? String, let id = Data(base64URL: text) else {
                return ["error": "passkeys forget needs an id"]
            }
            PasskeyStore.forget(id: id)
            return ["forgotten": text, "count": PasskeyStore.all().count]
        case "answer":
            guard Store.testing else { return ["error": "passkeys answer only works in a test world"] }
            switch (request["arg"] as? String ?? "").lowercased() {
            case "yes": Passkeys.autoProve = true
            case "no": Passkeys.autoProve = false
            case "ask", "": Passkeys.autoProve = nil
            default: return ["error": "passkeys answer expects yes, no, or ask"]
            }
            return ["answer": Passkeys.autoProve.map { $0 ? "yes" : "no" } ?? "ask"]
        default:
            return ["error": "unknown passkeys operation \(op)"]
        }
    }

    private static func row(_ credential: PasskeyStore.Credential) -> [String: Any] {
        [
            "id": credential.id.base64URL,
            "rpId": credential.rpId,
            "userName": credential.userName,
            "displayName": credential.displayName,
            "label": credential.label,
            "origin": credential.origin ?? "Copper",
            "created": credential.created.timeIntervalSince1970,
            "lastUsed": credential.lastUsed?.timeIntervalSince1970 ?? NSNull(),
            "counter": credential.counter,
        ]
    }
}
