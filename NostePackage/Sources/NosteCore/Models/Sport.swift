import Foundation

/// Tuetut lajit. Kynnysarvot ovat lähtöoletuksia — kalibroidaan kenttädatalla (ks. KONSEPTI.md).
public enum Sport: String, Codable, CaseIterable, Sendable, Identifiable {
    case wingFoil
    case pumpFoil
    case parawing
    case kite
    case surf
    case sup

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wingFoil: return "Wingfoil"
        case .pumpFoil: return "Pumpfoil"
        case .parawing: return "Parawing"
        case .kite: return "Kite"
        case .surf: return "Lainelautailu"
        case .sup: return "SUP"
        }
    }

    public var symbolName: String {
        switch self {
        case .wingFoil: return "wind"
        case .pumpFoil: return "figure.surfing"
        case .parawing: return "wind.circle"
        case .kite: return "paperplane"
        case .surf: return "water.waves"
        case .sup: return "oar.2.crossed"
        }
    }

    /// Käyttääkö laji foilia (foiliajan tunnistus päällä).
    public var usesFoil: Bool {
        switch self {
        case .wingFoil, .pumpFoil, .parawing, .kite: return true
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
        case .parawing: return 3.3   // kuten wing — kalibroidaan kenttädatalla
        case .kite: return 3.5
        case .surf: return 2.8       // ~10 km/h: laskunopeus selvästi yli melonnan
        case .sup: return 2.8
        }
    }

    /// Nopeus (m/s), jonka alitus päättää lennon/laskun (hystereesi).
    public var touchdownSpeed: Double {
        switch self {
        case .wingFoil: return 2.5
        case .pumpFoil: return 1.7
        case .parawing: return 2.5
        case .kite: return 2.5
        case .surf: return 2.0
        case .sup: return 2.0
        }
    }

    /// Suurin lajissa uskottava nopeus (m/s). Kovemmat lukemat ovat GPS-häiriötä
    /// tai autoilua — ne suodatetaan analyysistä ja merkitsevät siirtymäjakson.
    /// Kalibroidaan kenttädatalla.
    public var maxPlausibleSpeed: Double {
        switch self {
        case .wingFoil: return 20   // 72 km/h
        case .pumpFoil: return 9    // 32 km/h
        case .parawing: return 18
        case .kite: return 25       // 90 km/h — kitefoil kulkee wingiä lujempaa
        case .surf: return 15
        case .sup: return 8
        }
    }
}
