import Foundation

public enum WaterType: String, Codable, CaseIterable, Sendable, Identifiable {
    case sea
    case lake

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sea: return "Meri"
        case .lake: return "Järvi"
        }
    }

    /// Näytetäänkö spotille aaltoennuste (Open-Meteo Marine kattaa vain meret).
    public var hasWaveForecast: Bool { self == .sea }
}

/// Spotti siirto- ja synkkausmuodossa (SwiftData-mallit iOS-apissa kääritään tähän).
/// Tuuli-ikkuna (suunnat + voimakkuus) ohjaa ennusteiden korostusta, kellon
/// glancea ja kelivahtia. Uudet kentät ovat optionaaleja, jotta vanha talletettu
/// data dekoodautuu ongelmitta.
public struct SpotData: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var waterType: WaterType
    public var sports: [Sport]
    public var isFavorite: Bool
    public var notes: String
    /// Toimivat tuulensuunnat kahdeksana ilmansuuntana (0 = N, 1 = NE … 7 = NW).
    /// nil/tyhjä = kaikki suunnat käyvät.
    public var goodDirections: [Int]?
    /// Kelin alaraja m/s (nil = ei rajaa).
    public var minWind: Double?
    /// Kelin yläraja m/s (nil = ei rajaa).
    public var maxWind: Double?
    /// Vanha lippu (ennen omia hälytystietueita) — ei enää käytössä, säilyy dekoodausta varten.
    public var alertEnabled: Bool?
    /// Julkinen spotti: saa näkyä muille, kun spottien jako toteutuu.
    /// nil/false = yksityinen (oletus).
    public var isPublic: Bool?
    /// Maastoanalyysi ilmansuunnittain (0 = N … 7 = NW): pyyhkäisymatka (km)
    /// järviaaltojen laskentaan ja avoimuus 0–1. Haetaan palvelimelta.
    public var fetchKmByOctant: [Double]?
    public var exposureByOctant: [Double]?

    public init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double,
                waterType: WaterType = .sea, sports: [Sport] = [], isFavorite: Bool = false, notes: String = "",
                goodDirections: [Int]? = nil, minWind: Double? = nil, maxWind: Double? = nil,
                alertEnabled: Bool? = nil, isPublic: Bool? = nil,
                fetchKmByOctant: [Double]? = nil, exposureByOctant: [Double]? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.waterType = waterType
        self.sports = sports
        self.isFavorite = isFavorite
        self.notes = notes
        self.goodDirections = goodDirections
        self.minWind = minWind
        self.maxWind = maxWind
        self.alertEnabled = alertEnabled
        self.isPublic = isPublic
        self.fetchKmByOctant = fetchKmByOctant
        self.exposureByOctant = exposureByOctant
    }

    /// Onko spotille määritetty tuuli-ikkuna (jotain, mitä vasten korostaa/vahtia).
    public var hasWindWindow: Bool {
        (goodDirections?.isEmpty == false) || minWind != nil || maxWind != nil
    }

    /// Osuuko ennustetunti spotin tuuli-ikkunaan. Ilman ikkunaa ei osumia
    /// (korostus tarkoittaisi muuten "aina").
    public func matches(_ hour: WindHour) -> Bool {
        guard hasWindWindow else { return false }
        if let min = minWind, hour.speed < min { return false }
        if let max = maxWind, hour.speed > max { return false }
        if let directions = goodDirections, !directions.isEmpty {
            return directions.contains(Self.compassOctant(degrees: hour.direction))
        }
        return true
    }

    /// Suunta-asteet → ilmansuuntaindeksi 0–7 (0 = N, myötäpäivään 45° välein).
    public static func compassOctant(degrees: Double) -> Int {
        let index = Int((degrees / 45).rounded()) % 8
        return (index + 8) % 8
    }
}

public extension SpotData {
    /// Avoimuuskynnys (0–1): tästä ylöspäin suunta on "avoin" — sama raja
    /// surffi-ikkunan osumille ja Avoin-suuntien listalle.
    static let openExposure = 0.7
}
