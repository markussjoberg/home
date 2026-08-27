import Foundation

/// Yksittäisen suorituksen (lennon/laskun) tiedot — pumpissa tämä on se mitä
/// tarkastellaan: kesto, matka, pumput, frekvenssi, huippu- ja keskivauhti.
/// Reitti saadaan raakajäljestä aikaikkunalla [start, end].
public struct FlightDetail: Codable, Sendable, Equatable, Identifiable {
    /// Alku ja loppu sekunteina session alusta.
    public var start: TimeInterval
    public var end: TimeInterval
    /// Matka metreinä.
    public var distance: Double
    /// Huippuvauhti lennon aikana (m/s).
    public var maxSpeed: Double
    /// Pumppujen määrä lennon aikana (0 muille lajeille).
    public var strokeCount: Int

    public init(start: TimeInterval, end: TimeInterval, distance: Double, maxSpeed: Double, strokeCount: Int) {
        self.start = start
        self.end = end
        self.distance = distance
        self.maxSpeed = maxSpeed
        self.strokeCount = strokeCount
    }

    public var id: TimeInterval { start }
    public var duration: TimeInterval { end - start }
    /// Keskivauhti (m/s).
    public var averageSpeed: Double { duration > 0 ? distance / duration : 0 }
    /// Pumppufrekvenssi lennon aikana (pumppua/min).
    public var cadence: Double { duration > 0 ? Double(strokeCount) / duration * 60 : 0 }

    /// Kokoaa suorituskohtaiset tiedot: jaksot + GPS-pisteet + pumppuhetket.
    public static func compute(
        segments: [RideSegment],
        points: [TrackPoint],
        strokeTimes: [TimeInterval],
        maxPlausibleSpeed: Double
    ) -> [FlightDetail] {
        segments.map { segment in
            var maxSpeed = 0.0
            for point in points where point.t >= segment.start && point.t <= segment.end {
                if point.speed >= 0 && point.speed <= maxPlausibleSpeed {
                    maxSpeed = max(maxSpeed, point.speed)
                }
            }
            let strokes = strokeTimes.filter { $0 >= segment.start && $0 <= segment.end }.count
            return FlightDetail(
                start: segment.start,
                end: segment.end,
                distance: segment.distance,
                maxSpeed: maxSpeed,
                strokeCount: strokes
            )
        }
    }
}
