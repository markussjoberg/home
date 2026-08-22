import Foundation

/// GPS-piste. Ajat sekunteina session alusta, jotta analytiikka ei riipu kellonajasta.
public struct TrackPoint: Codable, Sendable, Equatable {
    public var t: TimeInterval
    public var latitude: Double
    public var longitude: Double
    /// Nopeus m/s (GPS:n oma nopeusarvio; < 0 = ei tiedossa).
    public var speed: Double
    /// Vaakasuuntainen tarkkuusarvio metreinä (< 0 = ei tiedossa).
    public var horizontalAccuracy: Double

    public init(t: TimeInterval, latitude: Double, longitude: Double, speed: Double, horizontalAccuracy: Double = -1) {
        self.t = t
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.horizontalAccuracy = horizontalAccuracy
    }
}

/// Kiihtyvyysnäyte: käyttäjäkiihtyvyys painovoiman suunnassa (m/s²), aika session alusta.
public struct MotionSample: Codable, Sendable, Equatable {
    public var t: TimeInterval
    public var verticalAcceleration: Double

    public init(t: TimeInterval, verticalAcceleration: Double) {
        self.t = t
        self.verticalAcceleration = verticalAcceleration
    }
}

/// Yhtenäinen jakso foililla / aallossa.
public struct RideSegment: Codable, Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    /// Jakson aikana kuljettu matka metreinä.
    public var distance: Double

    public init(start: TimeInterval, end: TimeInterval, distance: Double) {
        self.start = start
        self.end = end
        self.distance = distance
    }

    public var duration: TimeInterval { end - start }
}

/// Pumppausanalyysin tulos.
public struct PumpAnalysis: Codable, Sendable, Equatable {
    public var strokeCount: Int
    /// Pumppaushetket sekunteina session alusta.
    public var strokeTimes: [TimeInterval]
    /// Keskikadenssi aktiivisten pumppausjaksojen aikana (pumppua/min).
    public var averageCadence: Double
    /// Yhtenäiset pumppausjaksot (peräkkäisiä pumppuja alle katkaisurajan välein).
    public var bouts: [RideSegment]

    public init(strokeCount: Int = 0, strokeTimes: [TimeInterval] = [], averageCadence: Double = 0, bouts: [RideSegment] = []) {
        self.strokeCount = strokeCount
        self.strokeTimes = strokeTimes
        self.averageCadence = averageCadence
        self.bouts = bouts
    }
}

/// Foili-/laskujaksojen analyysin tulos.
public struct RideAnalysis: Codable, Sendable, Equatable {
    public var segments: [RideSegment]
    public var totalDuration: TimeInterval
    public var totalDistance: Double
    public var longestByDuration: RideSegment?
    /// Keskinopeus jaksojen aikana (m/s).
    public var averageSpeed: Double

    public init(segments: [RideSegment] = [], totalDuration: TimeInterval = 0, totalDistance: Double = 0, longestByDuration: RideSegment? = nil, averageSpeed: Double = 0) {
        self.segments = segments
        self.totalDuration = totalDuration
        self.totalDistance = totalDistance
        self.longestByDuration = longestByDuration
        self.averageSpeed = averageSpeed
    }

    public var count: Int { segments.count }

    /// Lennon keskikesto.
    public var averageDuration: TimeInterval {
        segments.isEmpty ? 0 : totalDuration / Double(segments.count)
    }
}

/// Koko session yhteenveto — se mitä kello näyttää lopuksi ja mitä puhelin tallettaa.
public struct SessionSummary: Codable, Sendable, Equatable {
    public var sport: Sport
    public var startDate: Date
    public var duration: TimeInterval
    public var distance: Double
    public var maxSpeed: Double
    public var averageMovingSpeed: Double
    /// Foilijaksot (wing/pumppi) tai lasketut aallot (surffi).
    public var rides: RideAnalysis
    public var pumps: PumpAnalysis?

    public init(sport: Sport, startDate: Date, duration: TimeInterval, distance: Double, maxSpeed: Double, averageMovingSpeed: Double, rides: RideAnalysis, pumps: PumpAnalysis?) {
        self.sport = sport
        self.startDate = startDate
        self.duration = duration
        self.distance = distance
        self.maxSpeed = maxSpeed
        self.averageMovingSpeed = averageMovingSpeed
        self.rides = rides
        self.pumps = pumps
    }

    /// Foiliajan osuus koko sessiosta (0–1).
    public var rideFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, rides.totalDuration / duration)
    }
}
