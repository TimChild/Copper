import Foundation

/// A stable identifier for a saved sign-in, independent of the backend that
/// stores its secret. The string form is intentionally small enough to use in
/// settings and in the agent allow-list.
enum CredentialID: Hashable, Codable {
    case keychain(host: String, user: String)
    case bitwarden(String)

    var string: String {
        switch self {
        case .keychain(let host, let user):
            return "kc:\(host)\u{1}\(user)"
        case .bitwarden(let id):
            return "bw:\(id)"
        }
    }

    init?(string: String) {
        if string.hasPrefix("kc:") {
            let body = String(string.dropFirst(3))
            guard let separator = body.firstIndex(of: "\u{1}") else { return nil }
            let host = String(body[..<separator])
            let user = String(body[body.index(after: separator)...])
            guard !host.isEmpty, !user.isEmpty else { return nil }
            self = .keychain(host: host, user: user)
        } else if string.hasPrefix("bw:") {
            let id = String(string.dropFirst(3))
            guard !id.isEmpty else { return nil }
            self = .bitwarden(id)
        } else {
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let id = Self(string: value) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                   debugDescription: "Invalid credential id")
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

struct Credential: Identifiable, Hashable {
    enum Source: Hashable {
        case keychain
        case bitwarden
    }

    enum AgentHint: Hashable {
        case none
        case allow
        case deny
    }

    let id: CredentialID
    let source: Source
    let host: String
    let user: String
    let sites: [String]
    let name: String
    let hasTOTP: Bool
    let used: Date?
    let folder: String?
    let agentHint: AgentHint

    var stableID: String { id.string }
}
