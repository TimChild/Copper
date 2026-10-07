import Foundation

/// How long the pill at the bottom of the window stays: long enough to read
/// it. A short "Address copied" goes in 1.7 s as it always did; a sentence
/// that says what went wrong and what to do next stays about a second per
/// fifteen characters, up to six.
enum Announcements {
    static func seconds(_ text: String) -> Double {
        min(6, max(1.7, Double(text.count) / 15))
    }
}
