import Foundation

/// Käyttäjän oma kelivahtihälytys. Raja ja sijainti ovat hälytyksen omia:
/// spotin tuuli-ikkuna kuvaa spottia, hälytys sitä milloin käyttäjä haluaa
/// ilmoituksen. Sama muoto kuin palvelimen /api/alerts.
public struct WindAlert: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var spotId: UUID
    public var spotName: String
    public var latitude: Double
    public var longitude: Double
    public var waterType: WaterType
    /// Hälytysraja (m/s): ilmoitus kun ennuste ylittää tämän vähintään minHours tuntia.
    public var minWind: Double
    /// Suunnat spotista (nil = mikä tahansa suunta).
    public var goodDirections: [Int]?
    public var minHours: Int
    public var enabled: Bool

    public init(id: UUID = UUID(), spotId: UUID, spotName: String, latitude: Double, longitude: Double,
                waterType: WaterType, minWind: Double, goodDirections: [Int]? = nil, minHours: Int = 2, enabled: Bool = true) {
        self.id = id
        self.spotId = spotId
        self.spotName = spotName
        self.latitude = latitude
        self.longitude = longitude
        self.waterType = waterType
        self.minWind = minWind
        self.goodDirections = goodDirections
        self.minHours = minHours
        self.enabled = enabled
    }
}
