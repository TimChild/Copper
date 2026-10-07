import Foundation

/// Where the secrets a move brings — passwords, passkeys — are kept, and
/// where the key that unlocks them comes from.
///
/// A real run keeps them where Copper always does (the keychain, through
/// `Vault` and `PasskeyStore`) and asks macOS for the browser's key once. A
/// test run never touches the keychain at all, either way: the key comes
/// from a test passphrase a script hands over (`bench flow passphrase`), and
/// what it unlocks goes to an in-memory stand-in a script can read back
/// (`bench flow secrets`). Without a test passphrase a test run reads no
/// secrets and says so.
protocol FlowSecretSink: AnyObject {
    /// "keychain" or "probe", for the bench.
    var name: String { get }
    /// Keeps one login. `new` is nil when the sink can't tell without
    /// reading the keychain back.
    func savePassword(host: String, user: String, password: String, used: Date?) -> (kept: Bool, new: Bool?)
    /// Sites the browser was told never to save for.
    func never(_ hosts: [String])
    /// Keeps the passkeys not already kept, returns how many were new.
    func savePasskeys(_ passkeys: [FlowModel.Passkey], from source: String) -> Int
}

enum FlowSecrets {
    /// The one switch between the two. A test run (`Store.testing`) always
    /// gets the stand-in.
    // TODO(integrator): point FlowProbeSink at Data's ProbeKeychain and gate on Store.probeSeams (D9) once ux/settings-data lands.
    static var seams: Bool { Store.testing }

    @MainActor static var sink: FlowSecretSink { seams ? FlowProbeSink.shared : FlowKeychainSink.shared }

    /// Test passphrases by source name, test runs only, this run only.
    @MainActor static var passphrases: [String: String] = [:]

    enum KeyTrouble: Error {
        /// A test run with no test passphrase: it reads no keychain.
        case testRun
    }

    /// The browser's stretched key. In a test run: only from a test
    /// passphrase, never from the keychain.
    static func key(for source: Chromium.Source, testPassphrase: String?, seams: Bool) throws -> [UInt8] {
        if seams {
            guard let testPassphrase, !testPassphrase.isEmpty else { throw KeyTrouble.testRun }
            return Chromium.stretch(testPassphrase)
        }
        return try Chromium.key(for: source)
    }
}

/// The keychain, as Copper always keeps passwords and passkeys.
final class FlowKeychainSink: FlowSecretSink {
    static let shared = FlowKeychainSink()
    var name: String { "keychain" }

    func savePassword(host: String, user: String, password: String, used: Date?) -> (kept: Bool, new: Bool?) {
        (Vault.save(host: host, user: user, password: password, used: used), nil)
    }

    func never(_ hosts: [String]) {
        guard !hosts.isEmpty else { return }
        var never = Vault.never
        hosts.forEach { never.insert($0) }
        Vault.never = never
    }

    func savePasskeys(_ passkeys: [FlowModel.Passkey], from source: String) -> Int {
        FlowPasskeys.install(passkeys, from: source)
    }
}

/// A test run's stand-in: kept in memory for the life of the process, read
/// back by `bench flow secrets`. Never the keychain.
final class FlowProbeSink: FlowSecretSink {
    static let shared = FlowProbeSink()
    var name: String { "probe" }

    struct Login: Equatable {
        var host: String
        var user: String
        var password: String
        var used: Date?
    }

    private(set) var logins: [String: Login] = [:]
    private(set) var neverHosts: Set<String> = []
    private(set) var passkeys: [Data: FlowModel.Passkey] = [:]
    private let lock = NSLock()

    func savePassword(host: String, user: String, password: String, used: Date?) -> (kept: Bool, new: Bool?) {
        guard !host.isEmpty, !password.isEmpty else { return (false, false) }
        lock.lock(); defer { lock.unlock() }
        let id = "\(host)\t\(user)"
        let isNew = logins[id] == nil
        logins[id] = Login(host: host, user: user, password: password, used: used)
        return (true, isNew)
    }

    func never(_ hosts: [String]) {
        lock.lock(); defer { lock.unlock() }
        hosts.forEach { neverHosts.insert($0) }
    }

    func savePasskeys(_ list: [FlowModel.Passkey], from source: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        var added = 0
        for passkey in list where passkeys[passkey.credentialId] == nil {
            passkeys[passkey.credentialId] = passkey
            added += 1
        }
        return added
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        logins.removeAll()
        neverHosts.removeAll()
        passkeys.removeAll()
    }

    /// What it holds, for the bench. Passwords as a short digest, so a
    /// script can check they were decrypted right without printing them.
    func describe() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "sink": name,
            "passwords": logins.values.sorted { ($0.host, $0.user) < ($1.host, $1.user) }.map {
                ["host": $0.host, "user": $0.user, "digest": FlowProbeSink.digest($0.password)] as [String: Any]
            },
            "never": neverHosts.sorted(),
            "passkeys": passkeys.values.sorted { $0.rpId < $1.rpId }.map {
                ["rpId": $0.rpId, "user": $0.userName, "keyBytes": $0.privateKey.count] as [String: Any]
            },
        ]
    }

    static func digest(_ text: String) -> String {
        // FNV-1a, 64 bits: enough to tell a right decryption from a wrong one.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(format: "%016llx", hash)
    }
}
