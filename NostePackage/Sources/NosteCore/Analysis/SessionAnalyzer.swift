import Foundation

/// Kokoaa session yhteenvedon raakadatasta (GPS + kiihtyvyys).
public enum SessionAnalyzer {

    public struct Config: Sendable {
        /// Nopeus, jonka yli ollaan "liikkeessä" (keskinopeuden laskentaan).
        public var movingSpeed: Double = 1.0
        /// Tätä suuremmat GPS-nopeudet hylätään häiriöinä.
        /// nil = käytä lajin omaa kattoa (Sport.maxPlausibleSpeed) — autoilu
        /// unohtuneen trackerin päällä ei saa päätyä maksiminopeudeksi.
        public var maxPlausibleSpeed: Double?
        public var maxAccuracy: Double = 30
        /// Pumppu lasketaan vain tämän nopeuden yli — uinnin käsivedot näyttävät
        /// ranteessa pumppaukselta, mutta uidessa ei liikuta näin lujaa.
        public var pumpingMinSpeed: Double = 1.5
        /// Uintitunnistus: vauhti tällä välillä + voimakas käsiliike.
        public var swimSpeedRange: ClosedRange<Double> = 0.2...1.4
        /// Käsiliikkeen kynnys uinnille (kiihtyvyyden liukuva keskihajonta, m/s²).
        public var swimRoughness: Double = 1.0

        public init() {}
    }

    public static func summarize(
        sport: Sport,
        startDate: Date,
        points: [TrackPoint],
        motion: [MotionSample] = [],
        heartRate: [HeartRateSample] = [],
        config: Config = Config(),
        rideConfig: RideSegmenter.Config? = nil,
        pumpConfig: PumpDetector.Config = PumpDetector.Config()
    ) -> SessionSummary {
        let duration = points.count >= 2 ? points.last!.t - points.first!.t : 0
        let speedCap = config.maxPlausibleSpeed ?? sport.maxPlausibleSpeed

        var distance = 0.0
        var previous: TrackPoint?
        var maxSpeed = 0.0
        var movingTime = 0.0
        var movingDistance = 0.0
        var lastTime: TimeInterval?

        for point in points {
            let accuracyOK = point.horizontalAccuracy < 0 || point.horizontalAccuracy <= config.maxAccuracy
            guard accuracyOK else { continue }
            var stepDistance = 0.0
            var stepSeconds = 0.0
            if let prev = previous {
                stepDistance = GeoMath.distanceMeters(
                    lat1: prev.latitude, lon1: prev.longitude,
                    lat2: point.latitude, lon2: point.longitude
                )
                stepSeconds = max(0, point.t - prev.t)
            }

            // Liiketila: GPS-nopeus jos saatavilla, muuten askeleen keskinopeus.
            // Paikallaan seisoessa GPS-värinä ei saa kerryttää matkaa.
            let moving: Bool
            if point.speed >= 0 {
                // Häiriöpiikki (epäuskottava nopeus) ei kerrytä matkaa.
                moving = point.speed >= config.movingSpeed && point.speed <= speedCap
            } else {
                moving = stepSeconds > 0 && stepDistance / stepSeconds >= config.movingSpeed
            }

            if moving {
                distance += stepDistance
                if let last = lastTime {
                    movingTime += point.t - last
                    movingDistance += stepDistance
                }
            }
            if point.speed >= 0 && point.speed <= speedCap {
                maxSpeed = max(maxSpeed, point.speed)
            }
            previous = point
            lastTime = point.t
        }

        let roughness = motion.isEmpty ? [] : RideSegmenter.roughness(of: motion)
        let rides = RideSegmenter.analyze(
            points: points,
            roughness: roughness,
            config: rideConfig ?? .forSport(sport)
        )
        var pumps: PumpAnalysis?
        if sport.countsPumps {
            // Raakatunnistus koko signaalista, sitten nopeusportti: uinnin
            // käsivedot (hidas vauhti) eivät päädy pumppulaskuriin.
            let raw = PumpDetector.analyze(motion, config: pumpConfig)
            let validStrokes = raw.strokeTimes.filter { t in
                guard let speed = Self.speed(at: t, in: points) else { return true }
                return speed >= config.pumpingMinSpeed
            }
            var filtered = PumpDetector.analysis(fromStrokeTimes: validStrokes, config: pumpConfig)
            filtered.swimTime = Self.swimTime(points: points, roughness: roughness, config: config)
            pumps = filtered
        }
        let flights = rides.segments.isEmpty ? nil : FlightDetail.compute(
            segments: rides.segments,
            points: points,
            strokeTimes: pumps?.strokeTimes ?? [],
            maxPlausibleSpeed: speedCap
        )

        return SessionSummary(
            sport: sport,
            startDate: startDate,
            duration: duration,
            distance: distance,
            maxSpeed: maxSpeed,
            averageMovingSpeed: movingTime > 0 ? movingDistance / movingTime : 0,
            rides: rides,
            pumps: pumps,
            heartRate: HeartRateStats.from(heartRate),
            flights: flights
        )
    }

    /// GPS-nopeus hetkellä t (lähin piste 3 s sisällä); nil jos ei tiedossa.
    static func speed(at t: TimeInterval, in points: [TrackPoint]) -> Double? {
        var best: TrackPoint?
        var bestDelta = Double.infinity
        // Pisteet ovat aikajärjestyksessä — binäärihaku riittäisi, mutta jäljet
        // ovat lyhyitä (~tuhansia pisteitä) ja tätä kutsutaan per pumppu.
        for point in points {
            let delta = abs(point.t - t)
            if delta < bestDelta {
                bestDelta = delta
                best = point
            } else if point.t > t {
                break
            }
        }
        guard let best, bestDelta <= 3, best.speed >= 0 else { return nil }
        return best.speed
    }

    /// Uintiaika: peräkkäiset pisteet uintivauhdilla ja käsiliike voimakasta.
    static func swimTime(points: [TrackPoint], roughness: [MotionSample], config: Config) -> TimeInterval? {
        guard !points.isEmpty, !roughness.isEmpty else { return nil }
        var total: TimeInterval = 0
        var roughnessIndex = 0
        var previous: TrackPoint?
        for point in points {
            defer { previous = point }
            guard let prev = previous else { continue }
            guard point.speed >= 0, config.swimSpeedRange.contains(point.speed),
                  prev.speed >= 0, config.swimSpeedRange.contains(prev.speed) else { continue }
            while roughnessIndex + 1 < roughness.count && roughness[roughnessIndex + 1].t <= point.t {
                roughnessIndex += 1
            }
            if roughness[roughnessIndex].verticalAcceleration >= config.swimRoughness {
                total += point.t - prev.t
            }
        }
        return total > 0 ? total : nil
    }
}
