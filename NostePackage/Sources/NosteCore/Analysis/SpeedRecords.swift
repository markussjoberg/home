import Foundation

/// Speedsurfing-tyyliset huippunopeudet: paras 2 s ja 10 s keskinopeus sekä
/// nopein 100 m. Lasketaan GPS-pisteistä lajikohtaisella nopeuskatolla —
/// häiriöpiikit ja autoilu eivät päädy ennätyksiin.
public struct SpeedRecords: Codable, Sendable, Equatable {
    /// Paras 2 s keskinopeus (m/s).
    public var best2s: Double
    /// Paras 10 s keskinopeus (m/s).
    public var best10s: Double
    /// Nopein 100 m keskinopeus (m/s); 0 jos matkaa ei kertynyt sataa metriä.
    public var best100m: Double

    public init(best2s: Double, best10s: Double, best100m: Double) {
        self.best2s = best2s
        self.best10s = best10s
        self.best100m = best100m
    }

    public static func compute(points: [TrackPoint], maxPlausibleSpeed: Double) -> SpeedRecords? {
        // Kelvolliset näytteet: tunnettu, uskottava nopeus ja riittävä tarkkuus.
        let samples = points.compactMap { point -> (t: TimeInterval, speed: Double)? in
            guard point.speed >= 0, point.speed <= maxPlausibleSpeed,
                  point.horizontalAccuracy < 0 || point.horizontalAccuracy <= 30
            else { return nil }
            return (point.t, point.speed)
        }
        guard samples.count >= 3 else { return nil }

        // Kumulatiivinen matka nopeusintegraalina (trapetsi).
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(samples.count)
        for i in 1..<samples.count {
            let dt = max(0, samples[i].t - samples[i - 1].t)
            cumulative.append(cumulative[i - 1] + (samples[i].speed + samples[i - 1].speed) / 2 * dt)
        }

        func bestWindow(_ window: TimeInterval) -> Double {
            var best = 0.0
            var start = 0
            for end in 1..<samples.count {
                while samples[end].t - samples[start].t > window + 0.001 { start += 1 }
                let duration = samples[end].t - samples[start].t
                if duration >= window - 0.001, duration > 0 {
                    best = max(best, (cumulative[end] - cumulative[start]) / duration)
                }
            }
            return best
        }

        // Nopein 100 m: jokaiselle loppupisteelle tiukin alku jolla matkaa on ≥ 100 m.
        var best100 = 0.0
        var start = 0
        for end in 1..<samples.count {
            while start + 1 < end && cumulative[end] - cumulative[start + 1] >= 100 {
                start += 1
            }
            let distance = cumulative[end] - cumulative[start]
            let duration = samples[end].t - samples[start].t
            if distance >= 100, duration > 0 {
                best100 = max(best100, distance / duration)
            }
        }

        return SpeedRecords(best2s: bestWindow(2), best10s: bestWindow(10), best100m: best100)
    }
}
