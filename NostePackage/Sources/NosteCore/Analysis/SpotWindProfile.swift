import Foundation

/// Spotin oppiva tuuliprofiili: rakentuu reittatuista sessioista (tuuli + tähdet).
///
/// - **Sopivat suunnat**: ilmansuunnittain keskiarvosana ja määrä; "sopiva" kun
///   keskiarvo ≥ 3,5 vähintään kahdesta sessiosta.
/// - **Tähtiennuste**: ennustetunnille arvio lähimpien aiempien sessioiden
///   painotettuna keskiarvona (gaussinen paino nopeus- ja suuntaerolle).
///   "Riittämätön tuuli" (0) osallistuu laskentaan ja vetää heikkojen tuulten
///   ennustetta alas — juuri niin kuin pitää. Ennustetta ei anneta, ellei
///   lähellä ole tarpeeksi todistusaineistoa (kaukana kaikesta koetusta → nil,
///   ei huono arvaus).
public struct SpotWindProfile: Sendable {

    public struct RatedSession: Sendable {
        public var rating: WindRating
        public var wind: RatedWind

        public init(rating: WindRating, wind: RatedWind) {
            self.rating = rating
            self.wind = wind
        }
    }

    public struct DirectionSummary: Sendable, Identifiable {
        public var octant: Int
        public var averageRating: Double
        public var count: Int

        public var id: Int { octant }
    }

    public struct Config: Sendable {
        /// Montako reittausta ennen kuin tähtiennuste annetaan.
        public var minSessionsForPrediction = 5
        /// Nopeuseron hajonta painotuksessa (m/s).
        public var speedSigma = 2.5
        /// Suuntaeron hajonta painotuksessa (astetta).
        public var directionSigma = 40.0
        /// Vaadittu yhteispaino, jotta ennuste annetaan (≈ "tarpeeksi lähellä koettua").
        public var minTotalWeight = 0.8
        /// Sopivan suunnan raja.
        public var goodDirectionRating = 3.5
        public var minPerDirection = 2

        public init() {}
    }

    public let sessions: [RatedSession]
    public let config: Config

    public init(sessions: [RatedSession], config: Config = Config()) {
        self.sessions = sessions
        self.config = config
    }

    public var sessionCount: Int { sessions.count }

    /// Onko dataa tarpeeksi tähtiennusteeseen.
    public var isReady: Bool { sessions.count >= config.minSessionsForPrediction }

    /// Yhteenveto ilmansuunnittain (vain suunnat joista on dataa).
    /// "Riittämätön tuuli" jätetään pois — se kertoo voimakkuudesta, ei suunnasta.
    public func directionSummaries() -> [DirectionSummary] {
        var byOctant: [Int: [Double]] = [:]
        for session in sessions where session.rating != .insufficient {
            byOctant[SpotData.compassOctant(degrees: session.wind.direction), default: []].append(session.rating.score)
        }
        return byOctant.keys.sorted().map { octant in
            let scores = byOctant[octant]!
            return DirectionSummary(
                octant: octant,
                averageRating: scores.reduce(0, +) / Double(scores.count),
                count: scores.count
            )
        }
    }

    /// Suunnat, jotka ovat osoittautuneet toimiviksi.
    public var goodOctants: [Int] {
        directionSummaries()
            .filter { $0.averageRating >= config.goodDirectionRating && $0.count >= config.minPerDirection }
            .map(\.octant)
    }

    /// Tähtiennuste ennustetunnille (0–5), tai nil jos dataa ei ole tarpeeksi
    /// tai tunti on liian kaukana kaikesta koetusta.
    public func predictedRating(speed: Double, direction: Double) -> Double? {
        guard isReady else { return nil }
        var weightSum = 0.0
        var weightedScore = 0.0
        for session in sessions {
            let speedDiff = (speed - session.wind.speed) / config.speedSigma
            let angleDiff = Self.angularDifference(direction, session.wind.direction) / config.directionSigma
            let weight = exp(-0.5 * (speedDiff * speedDiff + angleDiff * angleDiff))
            weightSum += weight
            weightedScore += weight * session.rating.score
        }
        guard weightSum >= config.minTotalWeight else { return nil }
        return weightedScore / weightSum
    }

    public func predictedRating(for hour: WindHour) -> Double? {
        predictedRating(speed: hour.speed, direction: hour.direction)
    }

    /// Kulmien pienin ero asteina (0–180).
    static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        return diff > 180 ? 360 - diff : diff
    }
}
