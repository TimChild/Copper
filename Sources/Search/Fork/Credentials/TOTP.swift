import Foundation
import CryptoKit

/// Time-based one-time codes from a stored seed, as Bitwarden keeps them:
/// an `otpauth://totp/...?secret=...&digits=6&period=30&algorithm=SHA1` URI,
/// or the bare base32 secret. Nil for anything this does not understand, so
/// the caller can ask `bw` instead.
enum TOTP {
    static func code(from seed: String, at date: Date = Date()) -> String? {
        var secret = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        var digits = 6
        var period: TimeInterval = 30
        var algorithm = "SHA1"
        if secret.lowercased().hasPrefix("otpauth://") {
            guard let url = URL(string: secret), url.host()?.lowercased() == "totp",
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            else { return nil }
            var found: String?
            for item in items {
                switch item.name.lowercased() {
                case "secret": found = item.value
                case "digits": digits = Int(item.value ?? "") ?? digits
                case "period": period = TimeInterval(item.value ?? "") ?? period
                case "algorithm": algorithm = (item.value ?? algorithm).uppercased()
                default: break
                }
            }
            guard let found else { return nil }
            secret = found
        } else if secret.lowercased().hasPrefix("steam://") {
            return nil
        }
        guard let key = base32(secret), !key.isEmpty, (6...8).contains(digits), period > 0 else { return nil }
        var counter = UInt64(date.timeIntervalSince1970 / period).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let mac: [UInt8]
        switch algorithm {
        case "SHA256": mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case "SHA512": mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case "SHA1": mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        default: return nil
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let binary = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        let value = binary % UInt32(pow(10, Double(digits)))
        return String(format: "%0\(digits)d", value)
    }

    private static func base32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }
        let cleaned = text.uppercased().filter { $0 != "=" && $0 != " " && $0 != "-" }
        var bits = 0, buffer: UInt32 = 0
        var out = Data()
        for c in cleaned {
            guard let v = lookup[c] else { return nil }
            buffer = (buffer << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> UInt32(bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out
    }
}
