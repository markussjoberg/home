import Foundation

/// Session tuuliarvosana: 1–5 tähteä, tai 0 = tuuli ei riittänyt.
public enum WindRating: Int, Codable, CaseIterable, Sendable, Identifiable {
    case insufficient = 0
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .insufficient: return "Ei riittänyt"
        default: return "\(rawValue) tähteä"
        }
    }

    /// Arvo tähtiennusteen laskentaan (riittämätön = 0).
    public var score: Double { Double(rawValue) }
}

/// Session aikana vallinnut tuuli (keskiarvo session tunneilta).
public struct RatedWind: Codable, Sendable, Equatable {
    public var speed: Double
    public var gust: Double
    /// Meteorologinen suunta asteina (mistä tuulee).
    public var direction: Double

    public init(speed: Double, gust: Double, direction: Double) {
        self.speed = speed
        self.gust = gust
        self.direction = direction
    }

    /// Keskiarvo tuntisarjasta; suunta lasketaan vektorikeskiarvona
    /// (pohjoisen yli kiertyvät suunnat eivät saa keskiarvoistua etelään).
    public static func average(of hours: [WindHour]) -> RatedWind? {
        guard !hours.isEmpty else { return nil }
        let n = Double(hours.count)
        var sinSum = 0.0
        var cosSum = 0.0
        for hour in hours {
            let radians = hour.direction * .pi / 180
            sinSum += sin(radians)
            cosSum += cos(radians)
        }
        let direction = (atan2(sinSum, cosSum) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return RatedWind(
            speed: hours.reduce(0) { $0 + $1.speed } / n,
            gust: hours.reduce(0) { $0 + $1.gust } / n,
            direction: direction
        )
    }
}
