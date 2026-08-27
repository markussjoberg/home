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
        let pumps = sport.countsPumps ? PumpDetector.analyze(motion, config: pumpConfig) : nil
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
}
