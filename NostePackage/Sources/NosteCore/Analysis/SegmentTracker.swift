import Foundation

/// Luokittelee session ajan segmenteiksi (vesi / maissa / siirtymä) livenä.
///
/// KESKEINEN PERIAATE: tämä EI koskaan pysäytä eikä pauseta tallennusta.
/// Vesilajeissa paikallaan olo (tuulen odotus, kellunta) on lajin ydintä, joten
/// nopeus tai paikallaanolo ei kelpaa taukoperusteeksi — vain vesialuetieto.
/// Kaikki data tallentuu aina; segmentit vain kertovat analyysille, mikä osa
/// ajasta oli vesillä. Datan tai luokittelun ongelmat eivät siis koskaan
/// aiheuta datan menetystä, ja fail-safe on aina "vettä".
///
/// Säännöt:
/// - Oletustila on vesi. Tuntematon sijainti (ei maskia, maskin ulkopuolella,
///   epätarkka GPS) tulkitaan vedeksi.
/// - Maissa-segmentti alkaa vasta, kun vesialuemaski sanoo yhtäjaksoisesti
///   riittävän kauan "maalla" — GPS-heitot rannassa eivät tee maissa-jaksoja.
/// - Vesihavainto palauttaa vesitilaan nopeasti.
/// - Lajille epäuskottava vauhti riittävän kauan = siirtymä (autoilu). Siirtymä
///   päättyy, kun ollaan taas vesialueella tai vauhti on ollut pitkään maltillinen.
public final class SegmentTracker {

    public struct Config: Sendable {
        /// Yhtäjaksoinen maissaolo (s) ennen kuin maissa-segmentti alkaa.
        public var landConfirmDuration: TimeInterval = 60
        /// Yhtäjaksoinen vesihavainto (s) ennen paluuta vesisegmenttiin.
        public var waterConfirmDuration: TimeInterval = 10
        /// Lajille epäuskottava nopeus (m/s) — siirtymän tunnusmerkki.
        public var transitSpeed: Double
        /// Kuinka kauan epäuskottavaa vauhtia vaaditaan (s).
        public var transitConfirmDuration: TimeInterval = 30
        /// Maltillinen vauhti tämän ajan (s) päättää siirtymän ilman vesihavaintoa.
        public var transitCalmDuration: TimeInterval = 120

        public init(sport: Sport) {
            transitSpeed = sport.maxPlausibleSpeed
        }
    }

    private let config: Config
    private(set) public var currentKind: SessionSegment.Kind = .water

    private var segments: [SessionSegment] = []
    private var currentStart: TimeInterval = 0
    private var started = false

    private var landSince: TimeInterval?
    private var waterSince: TimeInterval?
    private var fastSince: TimeInterval?
    private var calmSince: TimeInterval?

    public init(config: Config) {
        self.config = config
    }

    public convenience init(sport: Sport) {
        self.init(config: Config(sport: sport))
    }

    /// Syötä GPS-havainto. `isWater` = vesialuemaskin vastaus (nil = ei tietoa,
    /// tulkitaan vedeksi). Palauttaa senhetkisen segmenttilajin.
    @discardableResult
    public func add(t: TimeInterval, speed: Double, isWater: Bool?) -> SessionSegment.Kind {
        if !started {
            started = true
            currentStart = t
        }

        // Epäuskottava vauhti → siirtymä, riippumatta maskista (silta veden yli
        // autolla on silti siirtymä).
        if speed > config.transitSpeed {
            calmSince = nil
            if fastSince == nil { fastSince = t }
            if currentKind != .transit, t - fastSince! >= config.transitConfirmDuration {
                closeSegment(at: fastSince!)
                currentKind = .transit
                landSince = nil
                waterSince = nil
            }
        } else {
            fastSince = nil
        }

        switch currentKind {
        case .water:
            if isWater == false {
                waterSince = nil
                if landSince == nil { landSince = t }
                if t - landSince! >= config.landConfirmDuration {
                    closeSegment(at: landSince!)
                    currentKind = .land
                    landSince = nil
                }
            } else {
                landSince = nil
            }
        case .land:
            if isWater != false {
                if waterSince == nil { waterSince = t }
                if t - waterSince! >= config.waterConfirmDuration {
                    closeSegment(at: waterSince!)
                    currentKind = .water
                    waterSince = nil
                }
            } else {
                waterSince = nil
            }
        case .transit:
            // Paluu vesille: vesihavainto (tai tuntematon + maltillinen vauhti
            // riittävän kauan) päättää siirtymän.
            if speed <= config.transitSpeed {
                if isWater == true {
                    if waterSince == nil { waterSince = t }
                    if t - waterSince! >= config.waterConfirmDuration {
                        closeSegment(at: waterSince!)
                        currentKind = .water
                        waterSince = nil
                        calmSince = nil
                    }
                } else {
                    waterSince = nil
                    if calmSince == nil { calmSince = t }
                    if t - calmSince! >= config.transitCalmDuration {
                        closeSegment(at: calmSince!)
                        currentKind = isWater == false ? .land : .water
                        calmSince = nil
                    }
                }
            } else {
                waterSince = nil
            }
        }

        return currentKind
    }

    private func closeSegment(at t: TimeInterval) {
        if t > currentStart {
            segments.append(SessionSegment(start: currentStart, end: t, kind: currentKind))
        }
        currentStart = t
    }

    /// Segmentit tähän hetkeen asti (avoin segmentti suljettuna hetkeen `t`).
    /// Ei muuta tilaa — sopii sekä autosaveen että lopetukseen.
    public func snapshot(at t: TimeInterval) -> [SessionSegment] {
        var result = segments
        if started, t > currentStart {
            result.append(SessionSegment(start: currentStart, end: t, kind: currentKind))
        }
        return result
    }
}
