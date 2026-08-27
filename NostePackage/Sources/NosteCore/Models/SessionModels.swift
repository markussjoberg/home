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

    // Käsin kirjoitettu dekoodaus, jotta myöhemmin lisättävät kentät eivät koskaan
    // riko vanhojen jälkien lukua (init-oletusarvo ei päde synteettiseen Decodableen).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        t = try container.decode(TimeInterval.self, forKey: .t)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        speed = try container.decode(Double.self, forKey: .speed)
        horizontalAccuracy = try container.decodeIfPresent(Double.self, forKey: .horizontalAccuracy) ?? -1
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

/// Sykenäyte (lyönnit/min), aika session alusta.
public struct HeartRateSample: Codable, Sendable, Equatable {
    public var t: TimeInterval
    public var bpm: Double

    public init(t: TimeInterval, bpm: Double) {
        self.t = t
        self.bpm = bpm
    }
}

/// Sykeyhteenveto.
public struct HeartRateStats: Codable, Sendable, Equatable {
    public var average: Double
    public var max: Double

    public init(average: Double, max: Double) {
        self.average = average
        self.max = max
    }

    /// Laskee tilastot näytteistä; nil jos näytteitä ei ole.
    public static func from(_ samples: [HeartRateSample]) -> HeartRateStats? {
        guard !samples.isEmpty else { return nil }
        let sum = samples.reduce(0) { $0 + $1.bpm }
        let peak = samples.map(\.bpm).max() ?? 0
        return HeartRateStats(average: sum / Double(samples.count), max: peak)
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
    /// Uintiaika (s): hidas vauhti + voimakas käsiliike — esim. laituripaluu.
    /// Uinnin käsivedot EIVÄT ole mukana pumppulaskurissa.
    public var swimTime: TimeInterval?

    public init(strokeCount: Int = 0, strokeTimes: [TimeInterval] = [], averageCadence: Double = 0, bouts: [RideSegment] = [], swimTime: TimeInterval? = nil) {
        self.strokeCount = strokeCount
        self.strokeTimes = strokeTimes
        self.averageCadence = averageCadence
        self.bouts = bouts
        self.swimTime = swimTime
    }

    /// Aktiivisen pumppauksen kokonaiskesto (jaksojen summa).
    public var totalBoutTime: TimeInterval {
        bouts.reduce(0) { $0 + $1.duration }
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
    /// Yritysten määrä: kaikki irtoamiset, myös alle minimikeston jääneet
    /// (dock start -onnistumisprosentti = count / attemptCount).
    public var attemptCount: Int?

    public init(segments: [RideSegment] = [], totalDuration: TimeInterval = 0, totalDistance: Double = 0, longestByDuration: RideSegment? = nil, averageSpeed: Double = 0, attemptCount: Int? = nil) {
        self.segments = segments
        self.totalDuration = totalDuration
        self.totalDistance = totalDistance
        self.longestByDuration = longestByDuration
        self.averageSpeed = averageSpeed
        self.attemptCount = attemptCount
    }

    /// Onnistumisprosentti (0–1), jos yrityksiä on kirjattu.
    public var successRate: Double? {
        guard let attemptCount, attemptCount > 0 else { return nil }
        return Double(segments.count) / Double(attemptCount)
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
    /// Sykeyhteenveto (nil jos sykedataa ei ollut — esim. puhelimella tallennettu sessio).
    public var heartRate: HeartRateStats?
    /// Suorituskohtaiset tiedot per lento/lasku: kesto, matka, pumput, frekvenssi,
    /// huippu- ja keskivauhti. Reitti = raakajälki lennon aikaikkunalla.
    public var flights: [FlightDetail]?
    /// Huippunopeudet: paras 2 s / 10 s / 100 m.
    public var speedRecords: SpeedRecords?

    public init(sport: Sport, startDate: Date, duration: TimeInterval, distance: Double, maxSpeed: Double, averageMovingSpeed: Double, rides: RideAnalysis, pumps: PumpAnalysis?, heartRate: HeartRateStats? = nil, flights: [FlightDetail]? = nil, speedRecords: SpeedRecords? = nil) {
        self.sport = sport
        self.startDate = startDate
        self.duration = duration
        self.distance = distance
        self.maxSpeed = maxSpeed
        self.averageMovingSpeed = averageMovingSpeed
        self.rides = rides
        self.pumps = pumps
        self.heartRate = heartRate
        self.flights = flights
        self.speedRecords = speedRecords
    }

    /// Foiliajan osuus koko sessiosta (0–1).
    public var rideFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, rides.totalDuration / duration)
    }
}
