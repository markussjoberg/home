import Foundation

/// Autopaussi: tunnistaa maissa olon ilman karttadataa kolmella säännöllä.
///
/// 1. Paikallaan riittävän kauan → paussi. Lähtöpaikan lähellä nopeammin,
///    koska lähtöpaikka on yleensä myös lopetuspaikka.
/// 2. Paussi lähtöpaikan lähellä → EI automaattista jatkoa (sessio on
///    todennäköisesti ohi — juuri tässä tilanteessa autolla lähtö sotkisi
///    datan). Muualla (lepo vesillä) liikkeelle lähtö jatkaa session
///    automaattisesti.
/// 3. Lajille epäuskottava nopeus paussin aikana (= autoilua) tai ylipitkä
///    paussi → suositellaan session päättämistä.
public final class AutoPauseController {

    public struct Config: Sendable {
        /// Nopeus (m/s), jonka alle ollaan "paikallaan".
        public var stationarySpeed: Double = 0.7
        /// Paikallaanolo ennen paussia (s).
        public var stationaryDuration: TimeInterval = 90
        /// Paikallaanolo ennen paussia lähtöpaikan lähellä (s).
        public var nearStartDuration: TimeInterval = 45
        /// Etäisyys (m), jonka sisällä ollaan "lähtöpaikan lähellä".
        public var nearStartRadius: Double = 120
        /// Nopeus (m/s), joka jatkaa session automaattisesti (vesillä).
        public var resumeSpeed: Double
        /// Kuinka kauan jatkonopeutta vaaditaan yhtäjaksoisesti (s).
        public var resumeDuration: TimeInterval = 5
        /// Lajille epäuskottava nopeus (m/s) — tulkitaan autoiluksi.
        public var implausibleSpeed: Double
        /// Kuinka kauan epäuskottavaa nopeutta vaaditaan (s).
        public var implausibleDuration: TimeInterval = 30
        /// Paussin maksimikesto ennen päättämissuositusta (s).
        public var maxPauseDuration: TimeInterval = 20 * 60

        public init(sport: Sport) {
            resumeSpeed = max(1.5, sport.touchdownSpeed)
            implausibleSpeed = sport.maxPlausibleSpeed
        }
    }

    public enum Event: Equatable, Sendable {
        case none
        /// Paussi päälle. `nearStart` kertoo, tuliko paussi lähtöpaikan lähellä
        /// (silloin automaattinen jatko on pois päältä).
        case pause(nearStart: Bool)
        case resume
        /// Sessio kannattaa päättää: ajoa havaittu tai paussi kesti liian pitkään.
        case endSession(reason: EndReason)
    }

    public enum EndReason: Equatable, Sendable {
        case drivingDetected
        case pauseTimeout
    }

    public enum Mode: Equatable, Sendable {
        case running
        /// autoResume: saako liike jatkaa session automaattisesti.
        case paused(autoResume: Bool)
    }

    private let config: Config
    public private(set) var mode: Mode = .running

    private var stationarySince: TimeInterval?
    private var movingSince: TimeInterval?
    private var implausibleSince: TimeInterval?
    private var pausedAt: TimeInterval?

    public init(config: Config) {
        self.config = config
    }

    public convenience init(sport: Sport) {
        self.init(config: Config(sport: sport))
    }

    /// Syötä GPS-päivitys. `distanceFromStart` = etäisyys session lähtöpisteestä (m);
    /// negatiivinen jos ei tiedossa. Palauttaa tapahtuman, johon isännän tulee reagoida.
    public func add(t: TimeInterval, speed: Double, distanceFromStart: Double) -> Event {
        switch mode {
        case .running:
            return handleRunning(t: t, speed: speed, distanceFromStart: distanceFromStart)
        case .paused(let autoResume):
            return handlePaused(t: t, speed: speed, autoResume: autoResume)
        }
    }

    /// Käyttäjä pausetti/jatkoi itse — nollaa automaattitilan.
    public func manualPause(t: TimeInterval) {
        mode = .paused(autoResume: false)
        pausedAt = t
        implausibleSince = nil
        movingSince = nil
    }

    public func manualResume() {
        mode = .running
        stationarySince = nil
        pausedAt = nil
    }

    private func handleRunning(t: TimeInterval, speed: Double, distanceFromStart: Double) -> Event {
        guard speed >= 0 else { return .none }
        if speed < config.stationarySpeed {
            if stationarySince == nil { stationarySince = t }
            let nearStart = distanceFromStart >= 0 && distanceFromStart <= config.nearStartRadius
            let required = nearStart ? config.nearStartDuration : config.stationaryDuration
            if t - stationarySince! >= required {
                mode = .paused(autoResume: !nearStart)
                pausedAt = t
                stationarySince = nil
                movingSince = nil
                implausibleSince = nil
                return .pause(nearStart: nearStart)
            }
        } else {
            stationarySince = nil
        }
        return .none
    }

    private func handlePaused(t: TimeInterval, speed: Double, autoResume: Bool) -> Event {
        if let pausedAt, t - pausedAt >= config.maxPauseDuration {
            return .endSession(reason: .pauseTimeout)
        }

        guard speed >= 0 else { return .none }

        if speed > config.implausibleSpeed {
            if implausibleSince == nil { implausibleSince = t }
            if t - implausibleSince! >= config.implausibleDuration {
                return .endSession(reason: .drivingDetected)
            }
            movingSince = nil
            return .none
        }
        implausibleSince = nil

        if autoResume && speed >= config.resumeSpeed {
            if movingSince == nil { movingSince = t }
            if t - movingSince! >= config.resumeDuration {
                mode = .running
                stationarySince = nil
                movingSince = nil
                pausedAt = nil
                return .resume
            }
        } else {
            movingSince = nil
        }
        return .none
    }
}
