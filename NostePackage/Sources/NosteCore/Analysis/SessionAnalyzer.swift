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
        /// Surffin punnerrusvahvistus: aallon irtoamista edeltävä iskupiikki
        /// (m/s²) — pop-up + ponnistus. Erottaa aallon tuuliajelehdinnasta.
        public var surfPopupImpact: Double = 5.0
        /// Ikkuna ennen irtoamista, jolta punnerrus haetaan (s).
        public var surfPopupWindow: TimeInterval = 5.0

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
        pumpConfig: PumpDetector.Config = PumpDetector.Config(),
        segments: [SessionSegment]? = nil
    ) -> SessionSummary {
        // Segmentit: mittarit lasketaan vain vesijaksoista, mutta kesto ja
        // tallennettu jälki kattavat aina koko session. Ilman segmenttejä
        // (vanha data / ei maskia) kaikki on vettä.
        if let segments, segments.contains(where: { $0.kind != .water }) {
            return summarizeSegmented(
                sport: sport, startDate: startDate, points: points, motion: motion,
                heartRate: heartRate, config: config, rideConfig: rideConfig,
                pumpConfig: pumpConfig, segments: segments
            )
        }

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
        var rides = RideSegmenter.analyze(
            points: points,
            roughness: roughness,
            config: rideConfig ?? .forSport(sport)
        )
        // Surffi: aalto vaatii punnerruksen (pop-up-piikki juuri ennen
        // irtoamista) — muuten nopea ajelehdinta/melonta myötätuuleen
        // laskettaisiin aalloksi. Melonta on hidasta, lasku nopeaa: nopeus
        // erottaa jakson, punnerrus vahvistaa sen aalloksi.
        if sport == .surf, !motion.isEmpty {
            rides = Self.confirmSurfWaves(rides, motion: motion, config: config)
        }
        var pumps: PumpAnalysis?
        if sport.countsPumps {
            // Raakatunnistus koko signaalista, sitten nopeusportti: uinnin
            // käsivedot (hidas vauhti) eivät päädy pumppulaskuriin.
            let raw = PumpDetector.analyze(motion, config: pumpConfig)
            let validStrokes = raw.strokeTimes.filter { t in
                // Nopeudeton hetki hylätään — uinnin käsivedot eivät ole pumppuja.
                guard let speed = Self.speed(at: t, in: points) else { return false }
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
            maxPlausibleSpeed: speedCap,
            bouts: pumps?.bouts ?? []
        )

        // Hypyt: vapaapudotus kelpaa vain vauhdissa — kaatumisen mätkähdys
        // paikaltaan ei ole hyppy.
        var jumps: JumpAnalysis?
        if sport.countsJumps, !motion.isEmpty {
            let raw = JumpDetector.analyze(motion)
            let valid = raw.jumps.filter { jump in
                guard let speed = Self.speed(at: jump.t, in: points) else { return false }
                return speed >= 3.0
            }
            jumps = valid.isEmpty ? nil : JumpAnalysis(jumps: valid)
        }

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
            flights: flights,
            speedRecords: SpeedRecords.compute(points: points, maxPlausibleSpeed: speedCap),
            segments: segments,
            jumps: jumps
        )
    }

    /// Segmentoitu analyysi: jokainen vesijakso analysoidaan omana kokonaisuutenaan
    /// (aikaikkunat eivät koskaan ylitä maissa-/siirtymäjaksoa) ja tulokset
    /// yhdistetään. Näin esim. nopein 100 m ei voi syntyä autolla ajaen.
    private static func summarizeSegmented(
        sport: Sport,
        startDate: Date,
        points: [TrackPoint],
        motion: [MotionSample],
        heartRate: [HeartRateSample],
        config: Config,
        rideConfig: RideSegmenter.Config?,
        pumpConfig: PumpDetector.Config,
        segments: [SessionSegment]
    ) -> SessionSummary {
        let duration = points.count >= 2 ? points.last!.t - points.first!.t : 0
        let windows = segments.filter { $0.kind == .water }

        var distance = 0.0
        var maxSpeed = 0.0
        var movingSum = 0.0
        var movingWeight = 0.0
        var rideSegments: [RideSegment] = []
        var attemptTotal = 0
        var hasAttempts = false
        var strokeTimes: [TimeInterval] = []
        var bouts: [RideSegment] = []
        var swimTotal: TimeInterval = 0
        var hasSwim = false
        var records: SpeedRecords?
        var allJumps: [Jump] = []
        var waterPoints: [TrackPoint] = []
        let speedCap = config.maxPlausibleSpeed ?? sport.maxPlausibleSpeed

        for window in windows {
            let windowPoints = points.filter { $0.t >= window.start && $0.t <= window.end }
            let windowMotion = motion.filter { $0.t >= window.start && $0.t <= window.end }
            guard windowPoints.count >= 2 else { continue }
            let part = summarize(
                sport: sport, startDate: startDate, points: windowPoints,
                motion: windowMotion, heartRate: [], config: config,
                rideConfig: rideConfig, pumpConfig: pumpConfig
            )
            distance += part.distance
            maxSpeed = max(maxSpeed, part.maxSpeed)
            if part.averageMovingSpeed > 0 {
                // Painotus jakson kestolla — riittävä approksimaatio liikeajalle.
                movingSum += part.averageMovingSpeed * part.duration
                movingWeight += part.duration
            }
            rideSegments.append(contentsOf: part.rides.segments)
            if let attempts = part.rides.attemptCount {
                attemptTotal += attempts
                hasAttempts = true
            }
            if let pumps = part.pumps {
                strokeTimes.append(contentsOf: pumps.strokeTimes)
                bouts.append(contentsOf: pumps.bouts)
                if let swim = pumps.swimTime {
                    swimTotal += swim
                    hasSwim = true
                }
            }
            if let partJumps = part.jumps {
                allJumps.append(contentsOf: partJumps.jumps)
            }
            if let partRecords = part.speedRecords {
                records = SpeedRecords(
                    best2s: max(records?.best2s ?? 0, partRecords.best2s),
                    best10s: max(records?.best10s ?? 0, partRecords.best10s),
                    best100m: max(records?.best100m ?? 0, partRecords.best100m)
                )
            }
            waterPoints.append(contentsOf: windowPoints)
        }

        let totalRideDuration = rideSegments.reduce(0) { $0 + $1.duration }
        let totalRideDistance = rideSegments.reduce(0) { $0 + $1.distance }
        let rides = RideAnalysis(
            segments: rideSegments,
            totalDuration: totalRideDuration,
            totalDistance: totalRideDistance,
            longestByDuration: rideSegments.max { $0.duration < $1.duration },
            averageSpeed: totalRideDuration > 0 ? totalRideDistance / totalRideDuration : 0,
            attemptCount: hasAttempts ? attemptTotal : nil
        )

        var pumps: PumpAnalysis?
        if sport.countsPumps {
            var merged = PumpDetector.analysis(fromStrokeTimes: strokeTimes.sorted(), config: pumpConfig)
            merged.swimTime = hasSwim ? swimTotal : nil
            pumps = merged
        }

        // Syke: vesi- ja maissajaksot kuuluvat sessioon, siirtymä (autoilu) ei.
        let transitWindows = segments.filter { $0.kind == .transit }
        let sessionHeartRate = heartRate.filter { sample in
            !transitWindows.contains { sample.t >= $0.start && sample.t <= $0.end }
        }

        let flights = rides.segments.isEmpty ? nil : FlightDetail.compute(
            segments: rides.segments,
            points: waterPoints,
            strokeTimes: pumps?.strokeTimes ?? [],
            maxPlausibleSpeed: speedCap,
            bouts: pumps?.bouts ?? []
        )

        return SessionSummary(
            sport: sport,
            startDate: startDate,
            duration: duration,
            distance: distance,
            maxSpeed: maxSpeed,
            averageMovingSpeed: movingWeight > 0 ? movingSum / movingWeight : 0,
            rides: rides,
            pumps: pumps,
            heartRate: HeartRateStats.from(sessionHeartRate),
            flights: flights,
            speedRecords: records,
            segments: segments,
            jumps: allJumps.isEmpty ? nil : JumpAnalysis(jumps: allJumps)
        )
    }

    /// Suodattaa surffijaksot: mukaan vain ne, joita edeltää punnerruspiikki.
    static func confirmSurfWaves(_ rides: RideAnalysis, motion: [MotionSample], config: Config) -> RideAnalysis {
        let confirmed = rides.segments.filter { segment in
            let windowStart = segment.start - config.surfPopupWindow
            let windowEnd = segment.start + 1.0
            return motion.contains { sample in
                sample.t >= windowStart && sample.t <= windowEnd
                    && abs(sample.verticalAcceleration) >= config.surfPopupImpact
            }
        }
        let totalDuration = confirmed.reduce(0) { $0 + $1.duration }
        let totalDistance = confirmed.reduce(0) { $0 + $1.distance }
        return RideAnalysis(
            segments: confirmed,
            totalDuration: totalDuration,
            totalDistance: totalDistance,
            longestByDuration: confirmed.max { $0.duration < $1.duration },
            averageSpeed: totalDuration > 0 ? totalDistance / totalDuration : 0,
            attemptCount: rides.attemptCount
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
