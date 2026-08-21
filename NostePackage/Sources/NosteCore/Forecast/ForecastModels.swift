import Foundation

/// Tunnin tuuliennuste.
public struct WindHour: Codable, Sendable, Equatable, Identifiable {
    public var time: Date
    /// m/s
    public var speed: Double
    /// m/s
    public var gust: Double
    /// asteina, mistä tuulee (meteorologinen)
    public var direction: Double

    public init(time: Date, speed: Double, gust: Double, direction: Double) {
        self.time = time
        self.speed = speed
        self.gust = gust
        self.direction = direction
    }

    public var id: Date { time }
    public var directionName: String { GeoMath.compassName(degrees: direction) }
}

/// Tunnin aaltoennuste.
public struct WaveHour: Codable, Sendable, Equatable, Identifiable {
    public var time: Date
    /// Merkitsevä aallonkorkeus metreinä.
    public var height: Double
    /// Jaksonaika sekunteina.
    public var period: Double
    /// Tulosuunta asteina.
    public var direction: Double

    public init(time: Date, height: Double, period: Double, direction: Double) {
        self.time = time
        self.height = height
        self.period = period
        self.direction = direction
    }

    public var id: Date { time }
}

/// Spotin koottu ennuste. Codable, jotta sama paketti kulkee kelloon snapshotina.
public struct SpotForecast: Codable, Sendable, Equatable {
    public var spotID: UUID
    public var spotName: String
    public var fetchedAt: Date
    public var wind: [WindHour]
    /// nil sisävesispoteille.
    public var waves: [WaveHour]?

    public init(spotID: UUID, spotName: String, fetchedAt: Date, wind: [WindHour], waves: [WaveHour]? = nil) {
        self.spotID = spotID
        self.spotName = spotName
        self.fetchedAt = fetchedAt
        self.wind = wind
        self.waves = waves
    }

    /// Ennusteen tunnit annetusta hetkestä eteenpäin.
    public func upcoming(from date: Date, hours: Int) -> SpotForecast {
        let cutoff = date.addingTimeInterval(-3600)
        var copy = self
        copy.wind = Array(wind.filter { $0.time > cutoff }.prefix(hours))
        copy.waves = waves.map { Array($0.filter { $0.time > cutoff }.prefix(hours)) }
        return copy
    }
}
