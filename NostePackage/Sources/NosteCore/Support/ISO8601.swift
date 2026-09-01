import Foundation

/// ISO 8601 -aikaleimojen jäsennys. Palvelin (JS `toISOString()`) kirjoittaa
/// sekunnin desimaalit, joita pelkkä `ISO8601DateFormatter()` ei hyväksy —
/// kokeillaan ensin desimaalien kanssa, sitten ilman.
public enum ISO8601 {

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()

    public static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }
}
