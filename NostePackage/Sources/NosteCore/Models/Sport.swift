import Foundation

/// Tuetut lajit. Kynnysarvot ovat lähtöoletuksia — kalibroidaan kenttädatalla (ks. KONSEPTI.md).
public enum Sport: String, Codable, CaseIterable, Sendable, Identifiable {
    case wingFoil
    case pumpFoil
    case surf
    case sup

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wingFoil: return "Wing"
        case .pumpFoil: return "Pumppi"
        case .surf: return "Surffi"
        case .sup: return "SUP"
        }
    }

    public var symbolName: String {
        switch self {
        case .wingFoil: return "wind"
        case .pumpFoil: return "figure.surfing"
        case .surf: return "water.waves"
        case .sup: return "oar.2.crossed"
        }
    }

    /// Käyttääkö laji foilia (foiliajan tunnistus päällä).
    public var usesFoil: Bool {
        switch self {
        case .wingFoil, .pumpFoil: return true
        case .surf, .sup: return false
        }
    }

    /// Lasketaanko pumppauksia.
    public var countsPumps: Bool { self == .pumpFoil }

    /// Nopeus (m/s), jonka ylitys tulkitaan lennoksi / laskuksi.
    public var takeoffSpeed: Double {
        switch self {
        case .wingFoil: return 3.3   // ~12 km/h
        case .pumpFoil: return 2.2   // ~8 km/h
        case .surf: return 2.8       // ~10 km/h: laskunopeus selvästi yli melonnan
        case .sup: return 2.8
        }
    }

    /// Nopeus (m/s), jonka alitus päättää lennon/laskun (hystereesi).
    public var touchdownSpeed: Double {
        switch self {
        case .wingFoil: return 2.5
        case .pumpFoil: return 1.7
        case .surf: return 2.0
        case .sup: return 2.0
        }
    }
}
