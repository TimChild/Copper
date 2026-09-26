import Foundation

/// Fill a shared Bitwarden card, identity, or custom field without returning its value.
enum AgentAutofill {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func run(_ args: [String: Any], in browser: Browser, source: Source) async throws -> [String: Any] {
        guard let tab = browser.active else { throw Failure(message: "no active tab") }
        guard !tab.shy else { throw Failure(message: "autofill is unavailable in private tabs") }
        guard let address = tab.address, let rawHost = address.host(), !rawHost.isEmpty else {
            throw Failure(message: "current tab has no host")
        }
        var host = rawHost.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard case .unlocked = Bitwarden.shared.state else {
            throw Failure(message: "bitwarden is locked — unlock it in Settings › Passwords")
        }

        guard let rawKind = args["kind"] as? String else {
            throw Failure(message: "kind is required (card, identity, or field)")
        }
        let kind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["card", "identity", "field"].contains(kind) else {
            throw Failure(message: "kind must be card, identity, or field")
        }
        let shouldSubmit = (args["submit"] as? Bool) ?? false
        let first = (args["first"] as? Bool) ?? false
        let requestedName = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = requestedName.flatMap { $0.isEmpty ? nil : $0 }

        switch kind {
        case "card":
            let all = Autofill.cards
            let permitted = all.filter { Autofill.isAllowed($0.id) }
            guard !permitted.isEmpty else {
                if !all.isEmpty {
                    throw Failure(message: "card exists but is not shared with agents — enable it in Settings › Passwords › Agent access")
                }
                throw Failure(message: "no saved card")
            }
            let matches: [AutofillCard]
            if let name {
                matches = permitted.filter { card in
                    [card.name, card.label, card.last4, card.cardholderName].contains {
                        $0.caseInsensitiveCompare(name) == .orderedSame
                    }
                }
                guard !matches.isEmpty else {
                    throw Failure(message: "no shared card named \(name); saved: \(permitted.map(\.name).joined(separator: ", "))")
                }
            } else {
                matches = permitted
            }
            guard first || matches.count == 1 else {
                return ["candidates": matches.map(\.name), "kind": kind]
            }
            guard let card = matches.first else { throw Failure(message: "no saved card") }
            guard await tab.hasFields(.card) else { throw Failure(message: "no card fields on the page") }
            let filled = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                tab.fillValues(card.values()) { count in continuation.resume(returning: count) }
            }
            guard filled > 0 else { throw Failure(message: "no card fields on the page") }
            let submitted = shouldSubmit ? await submit(tab) : false
            return ["filled": filled, "kind": kind, "name": card.name, "submitted": submitted]

        case "identity":
            let all = Autofill.identities
            let permitted = all.filter { Autofill.isAllowed($0.id) }
            guard !permitted.isEmpty else {
                if !all.isEmpty {
                    throw Failure(message: "identity exists but is not shared with agents — enable it in Settings › Passwords › Agent access")
                }
                throw Failure(message: "no saved identity")
            }
            let matches: [AutofillIdentity]
            if let name {
                matches = permitted.filter { identity in
                    [identity.name, identity.fullName, identity.email].contains {
                        $0.caseInsensitiveCompare(name) == .orderedSame
                    }
                }
                guard !matches.isEmpty else {
                    throw Failure(message: "no shared identity named \(name); saved: \(permitted.map(\.name).joined(separator: ", "))")
                }
            } else {
                matches = permitted
            }
            guard first || matches.count == 1 else {
                return ["candidates": matches.map(\.name), "kind": kind]
            }
            guard let identity = matches.first else { throw Failure(message: "no saved identity") }
            guard await tab.hasFields(.identity) else { throw Failure(message: "no identity fields on the page") }
            let filled = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                tab.fillValues(identity.values()) { count in continuation.resume(returning: count) }
            }
            guard filled > 0 else { throw Failure(message: "no identity fields on the page") }
            let submitted = shouldSubmit ? await submit(tab) : false
            return ["filled": filled, "kind": kind, "name": identity.name, "submitted": submitted]

        case "field":
            guard let name else { throw Failure(message: "name is required for field") }
            let all = Autofill.fields(for: host, matching: name)
            guard let field = all.first(where: { Autofill.isAllowed($0.itemID) }) else {
                if !all.isEmpty {
                    throw Failure(message: "field exists but is not shared with agents — enable it in Settings › Passwords › Agent access")
                }
                throw Failure(message: "no saved field named \(name)")
            }
            let filled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                tab.fillField(label: name, value: field.value) { ok in continuation.resume(returning: ok) }
            }
            if !filled {
                let focused = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    tab.fillFocused(field.value) { ok in continuation.resume(returning: ok) }
                }
                guard focused else { throw Failure(message: "no field named \(name) on the page") }
            }
            return ["filled": 1, "kind": kind, "name": field.name, "item": field.itemName]

        default:
            throw Failure(message: "kind must be card, identity, or field")
        }
    }

    @MainActor
    private static func submit(_ tab: Tab) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            tab.submitSignIn { ok in continuation.resume(returning: ok) }
        }
    }
}
