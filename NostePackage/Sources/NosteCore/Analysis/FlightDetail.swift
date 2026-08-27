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
    /// Aktiivinen pumppausaika lennon sisällä (s) — loppu on liitoa.
    public var pumpingTime: TimeInterval?

    public init(start: TimeInterval, end: TimeInterval, distance: Double, maxSpeed: Double, strokeCount: Int, pumpingTime: TimeInterval? = nil) {
        self.start = start
        self.end = end
        self.distance = distance
        self.maxSpeed = maxSpeed
        self.strokeCount = strokeCount
        self.pumpingTime = pumpingTime
    }

    public var id: TimeInterval { start }
    public var duration: TimeInterval { end - start }
    /// Keskivauhti (m/s).
    public var averageSpeed: Double { duration > 0 ? distance / duration : 0 }
    /// Pumppufrekvenssi lennon aikana (pumppua/min).
    public var cadence: Double { duration > 0 ? Double(strokeCount) / duration * 60 : 0 }
    /// Liidon osuus lennosta (0–1): aika jolloin ei pumpata — pumppauksen
    /// tehokkuuden ydinmittari. nil jos pumppudataa ei ole.
    public var glideRatio: Double? {
        guard let pumpingTime, duration > 0 else { return nil }
        return max(0, min(1, 1 - pumpingTime / duration))
    }

    /// Kokoaa suorituskohtaiset tiedot: jaksot + GPS-pisteet + pumppuhetket ja
    /// pumppausjaksot (liito-osuutta varten).
    public static func compute(
        segments: [RideSegment],
        points: [TrackPoint],
        strokeTimes: [TimeInterval],
        maxPlausibleSpeed: Double,
        bouts: [RideSegment] = []
    ) -> [FlightDetail] {
        segments.map { segment in
            var maxSpeed = 0.0
            for point in points where point.t >= segment.start && point.t <= segment.end {
                if point.speed >= 0 && point.speed <= maxPlausibleSpeed {
                    maxSpeed = max(maxSpeed, point.speed)
                }
            }
            let strokes = strokeTimes.filter { $0 >= segment.start && $0 <= segment.end }.count
            var pumping: TimeInterval? = nil
            if !bouts.isEmpty {
                pumping = bouts.reduce(0.0) { total, bout in
                    let overlap = min(bout.end, segment.end) - max(bout.start, segment.start)
                    return total + max(0, overlap)
                }
            }
            return FlightDetail(
                start: segment.start,
                end: segment.end,
                distance: segment.distance,
                maxSpeed: maxSpeed,
                strokeCount: strokes,
                pumpingTime: pumping
            )
        }
    }
}
