// The shared vocabulary between the page classifier and the vault.
enum FieldKind: String, Hashable, Codable, CaseIterable {
    case username, password, otp
    case fullName, firstName, middleName, lastName, email, phone, company
    case address1, address2, address3, city, state, postalCode, country
    case ssn, passportNumber, licenseNumber
    case cardNumber, cardName, cardExpMonth, cardExpYear, cardExp, cardCode, cardBrand
    case other

    enum Group: String {
        case login, identity, card, other
    }

    var group: Group {
        switch self {
        case .username, .password, .otp: return .login
        case .cardNumber, .cardName, .cardExpMonth, .cardExpYear, .cardExp, .cardCode, .cardBrand: return .card
        case .other: return .other
        default: return .identity
        }
    }
}
