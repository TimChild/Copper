import CommonCrypto
import CryptoKit
import Foundation
import SQLite3

/// Imports passkeys Chromium keeps beside passwords in Google Password Manager.
/// The database is copied first because Chrome and Arc keep Login Data open.
enum FlowPasskeys {
    /// Reads visible, decryptable Google Password Manager passkeys in each profile.
    static func read(_ source: Chromium.Source, key: [UInt8], profiles: [String]? = nil) throws -> [FlowModel.Passkey] {
        var result: [FlowModel.Passkey] = []
        var seen = Set<Data>()
        for (file, profile) in loginDataFiles(source, profiles: profiles) {
            try withDatabase(file) { database in
                let columns = try tableColumns(in: database)
                let required = ["credential_id", "rp_id", "user_id", "private_key"]
                guard required.allSatisfy(columns.contains) else { return }

                let optional = ["user_name", "user_display_name", "creation_time", "last_used_time", "hidden"]
                let selected = required + optional.filter(columns.contains)
                let positions = Dictionary(uniqueKeysWithValues: selected.enumerated().map { ($1, $0) })
                let query = "SELECT " + selected.map(quotedColumn).joined(separator: ", ") + " FROM webauthn_credentials"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                      let statement
                else { throw FlowModel.Trouble.unreadable(file.path) }
                defer { sqlite3_finalize(statement) }

                while sqlite3_step(statement) == SQLITE_ROW {
                    guard value(statement, at: positions["hidden"]) == 0,
                          let credentialId = blob(statement, at: positions["credential_id"]), !credentialId.isEmpty,
                          let rpId = text(statement, at: positions["rp_id"]), !rpId.isEmpty,
                          let privateBlob = blob(statement, at: positions["private_key"]), !privateBlob.isEmpty,
                          let decrypted = Chromium.unwrapBytes(privateBlob, key: key),
                          let privateKey = rawPrivateKey(from: decrypted),
                          !seen.contains(credentialId)
                    else { continue }

                    let passkey = FlowModel.Passkey(
                        credentialId: credentialId,
                        rpId: rpId,
                        userHandle: blob(statement, at: positions["user_id"]) ?? Data(),
                        userName: text(statement, at: positions["user_name"]) ?? "",
                        displayName: text(statement, at: positions["user_display_name"]) ?? "",
                        privateKey: privateKey,
                        created: date(statement, at: positions["creation_time"]),
                        lastUsed: date(statement, at: positions["last_used_time"]),
                        profile: profile
                    )
                    seen.insert(credentialId)
                    result.append(passkey)
                }
            }
        }
        return result
    }

    /// Counts database rows without asking for the browser's Safe Storage key.
    /// This is intentionally a row count: decryption happens only when moving.
    static func count(_ source: Chromium.Source, profiles: [String]? = nil) -> Int {
        var total = 0
        for (file, _) in loginDataFiles(source, profiles: profiles) {
            total += (try? withDatabase(file) { database in
                guard try tableExists(in: database) else { return 0 }
                let query = "SELECT COUNT(*) FROM webauthn_credentials"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                      let statement
                else { return 0 }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
                return Int(sqlite3_column_int64(statement, 0))
            }) ?? 0
        }
        return total
    }

    /// Installs only new credential ids; re-running Flow is therefore harmless.
    @discardableResult
    static func install(_ list: [FlowModel.Passkey], from sourceName: String) -> Int {
        var existing = Set(PasskeyStore.all().map(\.id))
        var added = 0
        for passkey in list where !existing.contains(passkey.credentialId) {
            let credential = PasskeyStore.Credential(
                id: passkey.credentialId,
                rpId: passkey.rpId,
                userHandle: passkey.userHandle,
                userName: passkey.userName,
                displayName: passkey.displayName,
                privateKey: passkey.privateKey,
                counter: 0,
                created: passkey.created ?? Date(),
                lastUsed: passkey.lastUsed,
                origin: sourceName
            )
            guard PasskeyStore.save(credential) else { continue }
            existing.insert(passkey.credentialId)
            added += 1
        }
        return added
    }

    /// Converts Chromium's PKCS#8 (or SEC1/X9.63) bytes to Copper's raw scalar.
    /// Kept internal so the fixture harness can test the binary path without a keychain.
    static func rawPrivateKey(from data: Data) -> Data? {
        if let key = try? P256.Signing.PrivateKey(derRepresentation: data) {
            return key.rawRepresentation
        }
        if let key = try? P256.Signing.PrivateKey(x963Representation: data) {
            return key.rawRepresentation
        }
        guard let scalar = derOctetString(in: data),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: scalar)
        else { return nil }
        return key.rawRepresentation
    }

    private static func loginDataFiles(_ source: Chromium.Source, profiles: [String]?) -> [(URL, String?)] {
        let files = FileManager.default
        var candidates: [(URL, String?)] = []
        var seen = Set<String>()

        func append(_ file: URL, profile: String?) {
            guard files.fileExists(atPath: file.path), seen.insert(file.standardizedFileURL.path).inserted else { return }
            candidates.append((file, profile))
        }

        if let profiles {
            for profile in profiles {
                let folder = profile.isEmpty ? source.root : source.root.appendingPathComponent(profile, isDirectory: true)
                append(folder.appendingPathComponent("Login Data"), profile: profile.isEmpty ? nil : profile)
                // Source.files also covers a few Chromium layouts where a profile
                // is linked or nested more deeply than the normal root/profile path.
                for file in source.files where file.deletingLastPathComponent().lastPathComponent == profile {
                    append(file, profile: profile.isEmpty ? nil : profile)
                }
            }
        } else {
            for file in source.files {
                let parent = file.deletingLastPathComponent()
                let profile = parent.path == source.root.path ? nil : parent.lastPathComponent
                append(file, profile: profile)
            }
            append(source.root.appendingPathComponent("Login Data"), profile: nil)
        }
        return candidates
    }

    private static func withDatabase<T>(_ file: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-passkeys-\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: file, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var database: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { throw FlowModel.Trouble.unreadable(file.path) }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private static func tableExists(in database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        let query = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'webauthn_credentials' LIMIT 1"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw FlowModel.Trouble.unreadable("webauthn_credentials") }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func tableColumns(in database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(webauthn_credentials)", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw FlowModel.Trouble.unreadable("webauthn_credentials") }
        defer { sqlite3_finalize(statement) }

        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                result.insert(String(cString: name))
            }
        }
        return result
    }

    private static func quotedColumn(_ name: String) -> String {
        // Names come from this allow-list after PRAGMA introspection.
        name
    }

    private static func blob(_ statement: OpaquePointer, at index: Int?) -> Data? {
        guard let index, sqlite3_column_type(statement, Int32(index)) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, Int32(index))
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, Int32(index))))
    }

    private static func text(_ statement: OpaquePointer, at index: Int?) -> String? {
        guard let index, let value = sqlite3_column_text(statement, Int32(index)) else { return nil }
        return String(cString: value)
    }

    private static func value(_ statement: OpaquePointer, at index: Int?) -> Int {
        guard let index else { return 0 }
        return Int(sqlite3_column_int64(statement, Int32(index)))
    }

    private static func date(_ statement: OpaquePointer, at index: Int?) -> Date? {
        guard let index else { return nil }
        return FlowModel.date(chromium: sqlite3_column_int64(statement, Int32(index)))
    }

    /// Finds a 32-byte OCTET STRING nested in a PKCS#8/SEC1 DER structure.
    private static func derOctetString(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        func walk(_ start: Int, _ end: Int, _ depth: Int) -> Data? {
            guard depth < 8, start < end else { return nil }
            var offset = start
            while offset < end {
                guard offset + 2 <= end else { return nil }
                let tag = bytes[offset]
                offset += 1
                let lengthByte = bytes[offset]
                offset += 1
                let length: Int
                if lengthByte & 0x80 == 0 {
                    length = Int(lengthByte)
                } else {
                    let count = Int(lengthByte & 0x7f)
                    guard count > 0, count <= 4, offset + count <= end else { return nil }
                    var decoded = 0
                    for _ in 0..<count { decoded = (decoded << 8) | Int(bytes[offset]); offset += 1 }
                    length = decoded
                }
                let contentEnd = offset + length
                guard contentEnd <= end else { return nil }
                if tag == 0x04, length == 32 {
                    return Data(bytes[offset..<contentEnd])
                }
                if tag & 0x20 != 0 || tag == 0x30 || tag == 0x31 {
                    if let nested = walk(offset, contentEnd, depth + 1) { return nested }
                }
                offset = contentEnd
            }
            return nil
        }
        return walk(0, bytes.count, 0)
    }
}

extension Chromium {
    /// Decrypts a Chromium v10 blob without interpreting its plaintext as UTF-8.
    static func unwrapBytes(_ blob: Data, key: [UInt8]) -> Data? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return blob }
        guard key.count == kCCKeySizeAES128 else { return nil }
        let body = [UInt8](blob.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, body, body.count, &output, output.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(moved))
    }
}
