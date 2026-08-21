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
public struct SpotData: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var waterType: WaterType
    public var sports: [Sport]
    public var isFavorite: Bool
    public var notes: String

    public init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double,
                waterType: WaterType = .sea, sports: [Sport] = [], isFavorite: Bool = false, notes: String = "") {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.waterType = waterType
        self.sports = sports
        self.isFavorite = isFavorite
        self.notes = notes
    }
}
