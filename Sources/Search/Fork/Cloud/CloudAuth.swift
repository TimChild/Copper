import Foundation

// Signing up, in and out of the linked instance (spec §2, /v1/auth/*). The
// device goes with every sign-in — its id minted once per data folder, its
// name the Mac's — so the server can list sessions per device and the sync
// engine can tell this Copper's changes from another's. Nothing here runs
// unless a person presses a button on the Cloud page (or ./bench says so).

extension Cloud {
    /// The server's floor, said before asking it.
    nonisolated static let minimumPassword = 10

    /// The account a sign-up or sign-in answers with.
    private struct Signed: Decodable {
        struct User: Decodable {
            var id: UUID
            var email: String
            var displayName: String?
            enum CodingKeys: String, CodingKey { case id, email, displayName = "display_name" }
        }
        struct Device: Decodable {
            var id: UUID
            var name: String?
        }
        var token: String
        var user: User
        var device: Device?
    }

    /// `GET /v1/auth/me`.
    struct Me: Decodable {
        struct User: Decodable {
            var id: UUID
            var email: String
            var displayName: String?
            var isAdmin: Bool?
            enum CodingKeys: String, CodingKey { case id, email, displayName = "display_name", isAdmin = "is_admin" }
        }
        struct Device: Decodable {
            var id: UUID
            var name: String?
        }
        var user: User
        var device: Device?
    }

    func signUp(email: String, password: String, displayName: String) async throws {
        let email = try Cloud.checkedEmail(email)
        try Cloud.checkPassword(password)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure(status: 0, code: "display_name", message: "Add a name to show on shared canvases") }
        try await signedIn(path: "/v1/auth/signup", body: [
            "email": email, "password": password, "display_name": name, "device": device,
        ], verb: "Created")
    }

    func signIn(email: String, password: String) async throws {
        let email = try Cloud.checkedEmail(email)
        guard !password.isEmpty else { throw Failure(status: 0, code: "password", message: "Enter your password") }
        try await signedIn(path: "/v1/auth/login", body: [
            "email": email, "password": password, "device": device,
        ], verb: "Signed in as")
    }

    /// Ends the session on the server too, when it can be reached. Signed out
    /// here either way.
    func signOut() async {
        guard isSignedIn else { return }
        _ = try? await request("POST", "/v1/auth/logout")
        forgetAccount()
        CloudLog.note("Signed out")
    }

    /// Ask who this session is, and keep the answer. A 401 `session` signs
    /// out (in `request`).
    @discardableResult
    func me() async throws -> Me {
        let me: Me = try await requestJSON("GET", "/v1/auth/me")
        if var account {
            account.email = me.user.email
            account.displayName = me.user.displayName ?? account.displayName
            refresh(account: account)
        }
        return me
    }

    /// Tell the server this device's new name (Settings › Cloud).
    func renameDevice(_ name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        deviceName = name
        guard let account else { return }
        _ = try await request("PATCH", "/v1/devices/\(account.deviceId.uuidString.lowercased())", json: ["name": name])
        CloudLog.note("Device renamed to \(name)")
    }

    /// The device as the server is told about it.
    private var device: [String: String] {
        ["id": deviceId.uuidString.lowercased(), "name": deviceName]
    }

    private func signedIn(path: String, body: [String: Any], verb: String) async throws {
        guard isLinked else { throw Failure(status: 0, code: "not_linked", message: "Connect to a cloud first") }
        // Signed in already: that session stays until this one works, then
        // `adopt` ends it on the server.
        let answer: Signed
        do {
            answer = try await requestJSON("POST", path, json: body)
        } catch let failure as Failure {
            throw Cloud.authFailure(failure)
        }
        // The server keeps the id this Copper sent; its answer is the one
        // the `tabs:<device>` document is written under either way.
        let account = Account(userId: answer.user.id, email: answer.user.email,
                              displayName: answer.user.displayName ?? answer.user.email, deviceId: answer.device?.id ?? deviceId)
        adopt(token: answer.token, account: account)
        CloudLog.note("\(verb) \(account.email)")
        _ = try? await me()
    }

    /// The server's refusals, in words for under the form.
    nonisolated static func authFailure(_ failure: Failure) -> Failure {
        var failure = failure
        switch (failure.status, failure.code) {
        case (401, "credentials"), (401, "unauthorized"):
            failure.message = "Wrong email or password"
        case (409, _), (_, "email_taken"):
            failure.message = "There's already an account with that email — sign in instead"
        case (403, _), (_, "signup_disabled"):
            failure.message = failure.message.lowercased().contains("invite")
                ? failure.message
                : "This instance isn't taking new accounts — ask its admin for an invite"
        case (429, _):
            failure.message = "Too many tries — wait a minute and try again"
        case (401, "instance_key"):
            failure.message = "The instance refused this Copper's key — connect again with a fresh link code"
        default:
            break
        }
        return failure
    }

    nonisolated static func checkedEmail(_ email: String) throws -> String {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !email.contains(" ") else {
            throw Failure(status: 0, code: "email", message: "That doesn't look like an email address")
        }
        return email
    }

    nonisolated static func checkPassword(_ password: String) throws {
        guard password.count >= minimumPassword else {
            throw Failure(status: 0, code: "password", message: "Use at least \(minimumPassword) characters for the password")
        }
    }
}
