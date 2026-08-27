import Foundation

/// Tunnistaa GPS-jäljestä yhtenäiset jaksot foililla (wing/pumppi) tai aallossa (surffi).
///
/// Perusta on nopeushystereesi: jakso alkaa kun nopeus ylittää lajin irtoamiskynnyksen
/// ja päättyy vasta kun nopeus alittaa selvästi matalamman kosketuskynnyksen — näin
/// kynnyksen ympärillä värähtely ei pilko lentoa osiin. Lyhyet katkot yhdistetään ja
/// alle minimikeston jaksot hylätään. Jos kiihtyvyysdataa on, jakson alkuun vaaditaan
/// lisäksi sileä signaali: foililla ajo on tasaista, runkokosketus näkyy tärinänä.
public enum RideSegmenter {

    public struct Config: Sendable {
        public var takeoffSpeed: Double
        public var touchdownSpeed: Double
        /// Lyhin hyväksytty jakso sekunteina.
        public var minDuration: TimeInterval
        /// Enintään näin pitkä katko yhdistetään yhdeksi jaksoksi.
        public var mergeGap: TimeInterval
        /// Suurin sallittu tärinätaso (liukuva keskihajonta, m/s²) jakson alussa.
        /// nil = pelkkä nopeus riittää (esim. jos kiihtyvyysdataa ei ole).
        public var maxTakeoffRoughness: Double?
        /// GPS-pisteet, joiden tarkkuusarvio on tätä huonompi, ohitetaan matkasta.
        public var maxAccuracy: Double

        public init(takeoffSpeed: Double, touchdownSpeed: Double, minDuration: TimeInterval = 3,
                    mergeGap: TimeInterval = 1.5, maxTakeoffRoughness: Double? = nil, maxAccuracy: Double = 30) {
            self.takeoffSpeed = takeoffSpeed
            self.touchdownSpeed = touchdownSpeed
            self.minDuration = minDuration
            self.mergeGap = mergeGap
            self.maxTakeoffRoughness = maxTakeoffRoughness
            self.maxAccuracy = maxAccuracy
        }

        public static func forSport(_ sport: Sport) -> Config {
            Config(
                takeoffSpeed: sport.takeoffSpeed,
                touchdownSpeed: sport.touchdownSpeed,
                minDuration: sport == .pumpFoil ? 2 : 3
            )
        }
    }

    /// Tärinätaso: pystykiihtyvyyden liukuva keskihajonta annetulla ikkunalla.
    public static func roughness(of samples: [MotionSample], window: TimeInterval = 1.0) -> [MotionSample] {
        var result: [MotionSample] = []
        result.reserveCapacity(samples.count)
        var startIndex = 0
        var sum = 0.0
        var sumSquares = 0.0
        for (i, sample) in samples.enumerated() {
            sum += sample.verticalAcceleration
            sumSquares += sample.verticalAcceleration * sample.verticalAcceleration
            while sample.t - samples[startIndex].t > window {
                let old = samples[startIndex].verticalAcceleration
                sum -= old
                sumSquares -= old * old
                startIndex += 1
            }
            let n = Double(i - startIndex + 1)
            let variance = max(0, sumSquares / n - (sum / n) * (sum / n))
            result.append(MotionSample(t: sample.t, verticalAcceleration: variance.squareRoot()))
        }
        return result
    }

    public static func analyze(points: [TrackPoint], roughness: [MotionSample] = [], config: Config) -> RideAnalysis {
        guard !points.isEmpty else { return RideAnalysis() }

        var raw: [RideSegment] = []
        var rideStart: TimeInterval?
        var rideDistance = 0.0
        var lastGoodPoint: TrackPoint?
        var roughnessIndex = 0

        func roughnessAt(_ t: TimeInterval) -> Double? {
            guard !roughness.isEmpty else { return nil }
            while roughnessIndex + 1 < roughness.count && roughness[roughnessIndex + 1].t <= t {
                roughnessIndex += 1
            }
            return roughness[roughnessIndex].verticalAcceleration
        }

        for point in points {
            let accuracyOK = point.horizontalAccuracy < 0 || point.horizontalAccuracy <= config.maxAccuracy
            if rideStart != nil, accuracyOK, let previous = lastGoodPoint {
                rideDistance += GeoMath.distanceMeters(
                    lat1: previous.latitude, lon1: previous.longitude,
                    lat2: point.latitude, lon2: point.longitude
                )
            }
            if accuracyOK { lastGoodPoint = point }

            if rideStart == nil {
                var takeoff = point.speed >= config.takeoffSpeed
                if takeoff, let limit = config.maxTakeoffRoughness, let rough = roughnessAt(point.t) {
                    takeoff = rough <= limit
                }
                if takeoff {
                    rideStart = point.t
                    rideDistance = 0
                }
            } else if point.speed >= 0 && point.speed < config.touchdownSpeed {
                raw.append(RideSegment(start: rideStart!, end: point.t, distance: rideDistance))
                rideStart = nil
            }
        }
        if let start = rideStart, let last = points.last {
            raw.append(RideSegment(start: start, end: last.t, distance: rideDistance))
        }

        // Yhdistä lyhyen katkon erottamat jaksot.
        var merged: [RideSegment] = []
        for segment in raw {
            if var previous = merged.last, segment.start - previous.end <= config.mergeGap {
                previous.end = segment.end
                previous.distance += segment.distance
                merged[merged.count - 1] = previous
            } else {
                merged.append(segment)
            }
        }

        let segments = merged.filter { $0.duration >= config.minDuration }
        let totalDuration = segments.reduce(0) { $0 + $1.duration }
        let totalDistance = segments.reduce(0) { $0 + $1.distance }
        return RideAnalysis(
            segments: segments,
            totalDuration: totalDuration,
            totalDistance: totalDistance,
            longestByDuration: segments.max { $0.duration < $1.duration },
            averageSpeed: totalDuration > 0 ? totalDistance / totalDuration : 0,
            // Kaikki irtoamiset (myös heti lässähtäneet) = startti-/lentoyritykset.
            attemptCount: merged.count
        )
    }
}
