import Foundation

/// 1Password's item JSON (op 2.x `item list` / `item get --format json`)
/// turned into Copper's vocabulary: login metadata for the picker, secrets
/// for the in-memory fill cache, and the identities, cards and custom fields
/// the autofill picker already speaks. Nothing here starts a process.
extension OnePassword {
    struct Vault: Hashable, Identifiable {
        let id: String
        let name: String
    }

    struct Field: Hashable {
        let name: String
        /// Empty for a hidden field: its value lives in `Secret.hidden`.
        let value: String
        let hidden: Bool
    }

    /// A stripped item. Secret values never live here.
    struct Item: Hashable, Identifiable {
        let id: String
        let vaultID: String
        let vaultName: String
        /// op's category constant: LOGIN, PASSWORD, CREDIT_CARD, IDENTITY, …
        let category: String
        let title: String
        let username: String
        let urls: [String]
        let tags: [String]
        let version: Int
        var hasTOTP: Bool
        var fields: [Field]
        /// The full item (fields, secrets) has been read, not only the list row.
        var detailed: Bool

        /// What the sign-in picker lists: logins, and password items that
        /// carry a website.
        var isLogin: Bool { category == "LOGIN" || (category == "PASSWORD" && !urls.isEmpty) }
    }

    struct Secret {
        var password: String?
        var totp: String?
        var hidden: [String: String] = [:]
    }

    struct Detail {
        let item: Item
        let secret: Secret
        let identity: AutofillIdentity?
        let card: AutofillCard?
    }

    /// The categories Copper reads; everything else stays in 1Password.
    static let categories = "Login,Password,Credit Card,Identity"

    // MARK: - From `op item list`

    static func summary(_ object: [String: Any]) -> Item? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        let vault = object["vault"] as? [String: Any]
        let category = (object["category"] as? String ?? "").uppercased()
        let username = category == "LOGIN" ? (object["additional_information"] as? String ?? "") : ""
        return Item(id: id,
                    vaultID: vault?["id"] as? String ?? "",
                    vaultName: vault?["name"] as? String ?? "",
                    category: category,
                    title: object["title"] as? String ?? "",
                    username: username,
                    urls: urls(object),
                    tags: (object["tags"] as? [String]) ?? [],
                    version: (object["version"] as? Int) ?? 0,
                    hasTOTP: false,
                    fields: [],
                    detailed: false)
    }

    private static func urls(_ object: [String: Any]) -> [String] {
        let raw = object["urls"] as? [[String: Any]] ?? []
        // The primary website first, the way 1Password itself fills.
        let sorted = raw.sorted { ($0["primary"] as? Bool ?? false) && !($1["primary"] as? Bool ?? false) }
        return sorted.compactMap { ($0["href"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    // MARK: - From `op item get --reveal`

    private static let loginBuiltIns: Set<String> = ["username", "password", "notesplain"]
    private static let cardBuiltIns: Set<String> = [
        "cardholder", "type", "ccnum", "cvv", "expiry", "validfrom", "bank", "phonelocal",
        "phonetollfree", "phoneintl", "website", "pin", "creditlimit", "cashlimit", "interest",
        "issuenumber", "notesplain",
    ]
    private static let identityBuiltIns: Set<String> = [
        "firstname", "initial", "lastname", "gender", "birthdate", "occupation", "company",
        "department", "jobtitle", "address", "defphone", "homephone", "cellphone", "busphone",
        "username", "reminderq", "remindera", "email", "website", "icq", "skype", "jabber",
        "aim", "yahoo", "msn", "notesplain",
    ]

    static func detail(_ object: [String: Any]) -> Detail? {
        guard var item = summary(object) else { return nil }
        let rawFields = object["fields"] as? [[String: Any]] ?? []
        var secret = Secret()
        var fields: [Field] = []
        var username = item.username
        var hasTOTP = false

        let builtIns: Set<String>
        switch item.category {
        case "CREDIT_CARD": builtIns = cardBuiltIns
        case "IDENTITY": builtIns = identityBuiltIns
        default: builtIns = loginBuiltIns
        }

        for raw in rawFields {
            let id = (raw["id"] as? String ?? "")
            let lowerID = id.lowercased()
            let type = (raw["type"] as? String ?? "").uppercased()
            let purpose = (raw["purpose"] as? String ?? "").uppercased()
            let label = (raw["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let value = string(raw["value"])

            if type == "OTP" {
                hasTOTP = true
                if secret.totp == nil, !value.isEmpty { secret.totp = value }
                continue
            }
            if purpose == "USERNAME" {
                if !value.isEmpty { username = value }
                continue
            }
            if purpose == "PASSWORD" || (item.category == "PASSWORD" && lowerID == "password") {
                if !value.isEmpty { secret.password = value }
                continue
            }
            if purpose == "NOTES" || builtIns.contains(lowerID) { continue }
            guard !label.isEmpty else { continue }
            if type == "CONCEALED" {
                secret.hidden[label] = value
                fields.append(Field(name: label, value: "", hidden: true))
            } else if ["STRING", "EMAIL", "URL", "PHONE", "MENU", "DATE", "MONTH_YEAR", ""].contains(type) {
                fields.append(Field(name: label, value: value, hidden: false))
            }
        }

        item = Item(id: item.id, vaultID: item.vaultID, vaultName: item.vaultName, category: item.category,
                    title: item.title, username: username, urls: item.urls, tags: item.tags,
                    version: item.version, hasTOTP: hasTOTP, fields: fields, detailed: true)

        var identity: AutofillIdentity?
        var card: AutofillCard?
        if item.category == "IDENTITY" { identity = makeIdentity(item, rawFields) }
        if item.category == "CREDIT_CARD" { card = makeCard(item, rawFields) }
        return Detail(item: item, secret: secret, identity: identity, card: card)
    }

    // MARK: - Identities and cards

    /// The stable id an identity, card or field is shared under:
    /// `op:<item id>` (Bitwarden's are bare ids, shared as `bw:<id>`).
    static func stableID(_ itemID: String) -> String { "op:\(itemID)" }

    /// A field's value by its op id or its label, first key that has one.
    private struct Lookup {
        var byKey: [String: String] = [:]

        init(_ fields: [[String: Any]]) {
            for raw in fields {
                let value = OnePassword.string(raw["value"])
                guard !value.isEmpty else { continue }
                if let id = raw["id"] as? String, byKey[id.lowercased()] == nil { byKey[id.lowercased()] = value }
                if let label = raw["label"] as? String, byKey[label.lowercased()] == nil { byKey[label.lowercased()] = value }
            }
        }

        func callAsFunction(_ keys: String...) -> String {
            for key in keys { if let value = byKey[key] { return value } }
            return ""
        }
    }

    private static func makeIdentity(_ item: Item, _ fields: [[String: Any]]) -> AutofillIdentity {
        let get = Lookup(fields)
        var street = "", city = "", region = "", zip = "", country = ""
        if let raw = fields.first(where: { ($0["type"] as? String ?? "").uppercased() == "ADDRESS" || ($0["id"] as? String) == "address" }) {
            if let parts = raw["address"] as? [String: Any] ?? raw["value"] as? [String: Any] {
                street = string(parts["street"])
                city = string(parts["city"])
                region = string(parts["state"])
                zip = string(parts["zip"])
                country = string(parts["country"])
            } else {
                // "1 Infinite Loop, Cupertino, CA, 95014, us"
                let pieces = string(raw["value"]).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if pieces.count >= 5 {
                    country = pieces[pieces.count - 1]
                    zip = pieces[pieces.count - 2]
                    region = pieces[pieces.count - 3]
                    city = pieces[pieces.count - 4]
                    street = pieces[0..<(pieces.count - 4)].joined(separator: ", ")
                } else if !pieces.isEmpty {
                    street = pieces.joined(separator: ", ")
                }
            }
        }
        let phone = [get("defphone", "phone"), get("cellphone", "mobile"), get("homephone"), get("busphone")]
            .first(where: { !$0.isEmpty }) ?? ""
        return AutofillIdentity(
            id: stableID(item.id),
            name: item.title,
            title: "",
            firstName: get("firstname", "first name"),
            middleName: get("initial", "middle name"),
            lastName: get("lastname", "last name"),
            username: get("username"),
            company: get("company"),
            email: get("email"),
            phone: phone,
            address1: street,
            address2: "",
            address3: "",
            city: city,
            state: region.count == 2 ? region.uppercased() : region,
            postalCode: zip,
            country: country.count == 2 ? country.uppercased() : country,
            ssn: "",
            passportNumber: "",
            licenseNumber: ""
        )
    }

    private static func makeCard(_ item: Item, _ fields: [[String: Any]]) -> AutofillCard {
        let get = Lookup(fields)
        let (month, year) = expiry(get("expiry", "expiry date"))
        return AutofillCard(
            id: stableID(item.id),
            name: item.title,
            cardholderName: get("cardholder", "cardholder name"),
            brand: brand(get("type")),
            expMonth: month,
            expYear: year,
            number: get("ccnum", "number"),
            code: get("cvv", "verification number")
        )
    }

    /// op writes a card's expiry as `YYYYMM`; people type `MM/YYYY`. Both.
    static func expiry(_ raw: String) -> (String, String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let digits = value.filter(\.isNumber)
        if !value.contains("/"), digits.count == 6 {
            return (String(Int(digits.suffix(2)) ?? 0), String(digits.prefix(4)))
        }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return ("", "") }
        if parts[0].count == 4 { return (String(Int(parts[1]) ?? 0), parts[0]) }
        let year = parts[1].count == 2 ? "20\(parts[1])" : parts[1]
        return (String(Int(parts[0]) ?? 0), year)
    }

    static func brand(_ raw: String) -> String {
        switch raw.lowercased() {
        case "visa": return "Visa"
        case "mc", "mastercard": return "Mastercard"
        case "amex", "american express": return "American Express"
        case "discover": return "Discover"
        case "jcb": return "JCB"
        case "diners", "dinersclub", "diners club": return "Diners Club"
        case "unionpay": return "UnionPay"
        default: return raw.isEmpty ? "" : raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    fileprivate nonisolated static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }
}
