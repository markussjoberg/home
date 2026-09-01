import Foundation

/// Käännös vauhdissa (jiipi tai tacki). Laji selviää vasta tuulensuunnasta,
/// joten talteen menee raakadata ja luokittelu tehdään näyttöhetkellä —
/// tuulitieto voi tarkentua session jälkeen (reittaus, FMI-havainto).
public struct Turn: Codable, Sendable, Equatable {
    /// Käännöksen keskihetki (s session alusta).
    public var t: TimeInterval
    public var duration: TimeInterval
    /// Suunnanmuutos asteina, etumerkillä (+ = myötäpäivään).
    public var headingChange: Double
    /// Kulkusuunta käännöksen puolivälissä (°) — luokitteluun tuulta vasten.
    public var midHeading: Double
    /// Pienin nopeus käännöksen aikana (m/s).
    public var minSpeed: Double
    /// Pysyikö foililla läpi käännöksen (minSpeed ≥ lajin kosketuskynnys).
    public var onFoil: Bool

    public init(t: TimeInterval, duration: TimeInterval, headingChange: Double,
                midHeading: Double, minSpeed: Double, onFoil: Bool) {
        self.t = t
        self.duration = duration
        self.headingChange = headingChange
        self.midHeading = midHeading
        self.minSpeed = minSpeed
        self.onFoil = onFoil
    }
}

public enum TurnKind: String, Codable, Sendable {
    case jibe
    case tack
}

/// Session käännökset. Jiipi/tacki-jako lasketaan tuulensuunnalla:
/// käännöksen keskellä keula osoittaa joko myötä- (jiipi) tai vastatuuleen (tacki).
public struct TurnAnalysis: Codable, Sendable, Equatable {
    public var turns: [Turn]

    public init(turns: [Turn] = []) {
        self.turns = turns
    }

    public var count: Int { turns.count }
    public var foiledCount: Int { turns.filter(\.onFoil).count }

    /// Käännöksen laji: keskisuunta lähempänä myötätuulta = jiipi, vastatuulta = tacki.
    public static func kind(of turn: Turn, windDirection: Double) -> TurnKind {
        let downwind = (windDirection + 180).truncatingRemainder(dividingBy: 360)
        let toDownwind = GeoMath.angularDistance(turn.midHeading, downwind)
        let toUpwind = GeoMath.angularDistance(turn.midHeading, windDirection)
        return toDownwind <= toUpwind ? .jibe : .tack
    }

    public func jibes(windDirection: Double) -> [Turn] {
        turns.filter { Self.kind(of: $0, windDirection: windDirection) == .jibe }
    }

    public func tacks(windDirection: Double) -> [Turn] {
        turns.filter { Self.kind(of: $0, windDirection: windDirection) == .tack }
    }
}

/// Tunnistaa käännökset GPS-jäljestä: kulkusuunnan yhtäjaksoinen kääntyminen
/// ≥ minTurnAngle riittävän lyhyessä ajassa, vauhdissa (irtoamiskynnyksen
/// yli käännökseen tultaessa). Suunta lasketaan sijainneista vasta ≥ minStep
/// metrin askelin, jottei GPS-värinä sotke.
public enum TurnDetector {

    public struct Config: Sendable {
        /// Pienin suunnanmuutos, joka lasketaan käännökseksi (°).
        public var minTurnAngle: Double = 100
        /// Pisin käännöksen kesto (s) — hitaampi kaartelu ei ole jiippi/tacki.
        public var maxTurnDuration: TimeInterval = 15
        /// Nopeus käännökseen tultaessa vähintään (m/s) — vauhdissa käännytään.
        public var minEntrySpeed: Double
        /// Foilirajana kosketuskynnys: tämän yli koko käännös = pysyi foililla.
        public var onFoilSpeed: Double
        /// Suunnan laskennan minimiaskel metreinä.
        public var minStep: Double = 4
        /// Vastakkaissuuntainen heitto (°), joka siedetään kesken käännöksen.
        public var jitterTolerance: Double = 20

        public init(sport: Sport) {
            minEntrySpeed = sport.takeoffSpeed
            onFoilSpeed = sport.touchdownSpeed
        }
    }

    public static func analyze(points: [TrackPoint], config: Config) -> TurnAnalysis {
        // Suuntanäytteet ≥ minStep-askelin.
        var headings: [(t: TimeInterval, heading: Double, speed: Double)] = []
        var anchor: TrackPoint?
        for point in points {
            let accuracyOK = point.horizontalAccuracy < 0 || point.horizontalAccuracy <= 30
            guard accuracyOK else { continue }
            guard let previous = anchor else { anchor = point; continue }
            let distance = GeoMath.distanceMeters(
                lat1: previous.latitude, lon1: previous.longitude,
                lat2: point.latitude, lon2: point.longitude
            )
            guard distance >= config.minStep else { continue }
            let bearing = GeoMath.bearingDegrees(
                lat1: previous.latitude, lon1: previous.longitude,
                lat2: point.latitude, lon2: point.longitude
            )
            headings.append((point.t, bearing, max(0, point.speed)))
            anchor = point
        }
        guard headings.count > 3 else { return TurnAnalysis() }

        var turns: [Turn] = []

        // Käännösputket: peräkkäiset merkittävät samansuuntaiset kulmamuutokset.
        // Pieni delta = suoraa ajoa; ~parin sekunnin suora katkaisee putken.
        let noiseFloor = 8.0
        var runStart = -1
        var runEnd = -1
        var accumulated = 0.0
        var minSpeed = Double.infinity
        var entrySpeed = 0.0

        func closeRun() {
            defer { runStart = -1; accumulated = 0 }
            guard runStart >= 0, runEnd > runStart else { return }
            let start = headings[runStart]
            let end = headings[runEnd]
            let duration = end.t - start.t
            guard abs(accumulated) >= config.minTurnAngle,
                  duration <= config.maxTurnDuration,
                  entrySpeed >= config.minEntrySpeed else { return }
            let mid = (start.heading + accumulated / 2 + 720).truncatingRemainder(dividingBy: 360)
            turns.append(Turn(
                t: (start.t + end.t) / 2,
                duration: duration,
                headingChange: accumulated,
                midHeading: mid,
                minSpeed: minSpeed,
                onFoil: minSpeed >= config.onFoilSpeed
            ))
        }

        for i in 1..<headings.count {
            let delta = GeoMath.signedAngleDelta(from: headings[i - 1].heading, to: headings[i].heading)

            if abs(delta) < noiseFloor {
                // Suoraa: jos putki on auki ja suoraa on jatkunut, sulje se.
                if runStart >= 0, runEnd >= 0, headings[i].t - headings[runEnd].t > 2.5 {
                    closeRun()
                }
                continue
            }

            let sameDirection = accumulated == 0 || (accumulated > 0) == (delta > 0)
            if runStart < 0 || !sameDirection
                || headings[i].t - headings[runStart].t > config.maxTurnDuration {
                closeRun()
                runStart = i - 1
                entrySpeed = headings[i - 1].speed
                minSpeed = min(headings[i - 1].speed, headings[i].speed)
                accumulated = delta
            } else {
                accumulated += delta
                minSpeed = min(minSpeed, headings[i].speed)
            }
            runEnd = i
        }
        closeRun()

        return TurnAnalysis(turns: turns)
    }
}
