import Foundation

/// Kalustotyyppi (quiver-kirjanpito ja suositukset).
public enum GearType: String, Codable, CaseIterable, Sendable, Identifiable {
    case wing
    case board
    case foil

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wing: return "Siipi"
        case .board: return "Lauta"
        case .foil: return "Foili"
        }
    }

    /// Koon yksikkö (siivet m², laudat litraa, foilit cm²).
    public var sizeUnit: String {
        switch self {
        case .wing: return "m²"
        case .board: return "l"
        case .foil: return "cm²"
        }
    }

    public var symbolName: String {
        switch self {
        case .wing: return "wind"
        case .board: return "surfboard"
        case .foil: return "airplane"
        }
    }
}

/// Yksi kalustoyksilö suosittelijan syötteenä (appi mappaa omasta varastostaan).
public struct GearInfo: Sendable, Equatable {
    public var type: GearType
    public var name: String
    /// Koko tyypin yksikössä (siivet m²); nil jos ei tiedossa.
    public var size: Double?
    /// Vuosimalli; nil jos ei tiedossa.
    public var year: Int?

    public init(type: GearType, name: String, size: Double? = nil, year: Int? = nil) {
        self.type = type
        self.name = name
        self.size = size
        self.year = year
    }
}

/// Myytävä tuote (demo-katalogi appissa; myöhemmin kaupan syöte).
public struct GearCatalogItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var type: GearType
    public var name: String
    public var size: Double?
    public var year: Int
    /// Hinta euroina (näyttöä varten).
    public var price: Int
    public var url: String

    public init(id: String, type: GearType, name: String, size: Double? = nil, year: Int, price: Int, url: String) {
        self.id = id
        self.type = type
        self.name = name
        self.size = size
        self.year = year
        self.price = price
        self.url = url
    }
}

/// Ehdotus: miksi + mikä tuote.
public struct GearSuggestion: Sendable, Equatable, Identifiable {
    public var reason: String
    public var item: GearCatalogItem

    public var id: String { item.id }

    public init(reason: String, item: GearCatalogItem) {
        self.reason = reason
        self.item = item
    }
}

/// Deterministinen kalustosuosittelija: ei mallia, ei satunnaisuutta — samat
/// säännöt tuottavat aina saman ehdotuksen samasta quiveristä.
///
/// Säännöt (tässä järjestyksessä, enintään `maxCount` ehdotusta):
/// 1. Siipivalikoiman aukot: pienin siipi > 3,6 m² → kovan tuulen siipi puuttuu;
///    suurin < 4,9 m² → kevyen tuulen siipi puuttuu; vierekkäisten kokojen väli
///    > 1,6 m² → väliin jäävä koko. Ehdotetaan katalogista kokoa lähinnä
///    tavoitetta. Jos siipiä ei ole lainkaan, ei ehdoteta (ei spämmiä lajista,
///    jota käyttäjä ei ehkä harrasta).
/// 2. Vanha kalusto: vuosimalli ≥ 3 vuotta vanha → saman tyypin uusin malli,
///    kooltaan lähinnä vanhaa.
public enum GearAdvisor {

    public static func suggestions(
        quiver: [GearInfo],
        catalog: [GearCatalogItem],
        currentYear: Int,
        maxCount: Int = 2
    ) -> [GearSuggestion] {
        var result: [GearSuggestion] = []

        let wingSizes = quiver.filter { $0.type == .wing }.compactMap(\.size).sorted()
        if let smallest = wingSizes.first, let largest = wingSizes.last {
            if smallest > 3.6, let item = closestWing(to: smallest - 1.5, in: catalog) {
                result.append(GearSuggestion(
                    reason: "Kovaan tuuleen: pienin siipesi on \(Self.formatSize(smallest)) m²",
                    item: item
                ))
            }
            if largest < 4.9, let item = closestWing(to: largest + 1.5, in: catalog) {
                result.append(GearSuggestion(
                    reason: "Kevyeen tuuleen: suurin siipesi on \(Self.formatSize(largest)) m²",
                    item: item
                ))
            }
            for (small, large) in zip(wingSizes, wingSizes.dropFirst()) where large - small > 1.6 {
                if let item = closestWing(to: (small + large) / 2, in: catalog) {
                    result.append(GearSuggestion(
                        reason: "Aukko siipivalikoimassa: \(Self.formatSize(small))–\(Self.formatSize(large)) m²",
                        item: item
                    ))
                }
            }
        }

        // Vanhin ensin, jotta rajallinen ehdotusmäärä osuu suurimpaan tarpeeseen.
        let dated = quiver.compactMap { gear -> (GearInfo, Int)? in
            guard let year = gear.year, currentYear - year >= 3 else { return nil }
            return (gear, year)
        }.sorted { $0.1 < $1.1 }
        for (gear, year) in dated {
            let candidates = catalog.filter { $0.type == gear.type }
            let newestYear = candidates.map(\.year).max()
            guard let newestYear, newestYear > year else { continue }
            let newest = candidates.filter { $0.year == newestYear }
            let item = gear.size.flatMap { size in
                newest.min { distance($0.size, to: size) < distance($1.size, to: size) }
            } ?? newest.first
            if let item {
                result.append(GearSuggestion(
                    reason: "\(gear.name) on vuosimallia \(year) — uudempi kehittynyt reilusti",
                    item: item
                ))
            }
        }

        // Sama tuote vain kerran.
        var seen = Set<String>()
        return result.filter { seen.insert($0.item.id).inserted }.prefix(maxCount).map { $0 }
    }

    private static func closestWing(to target: Double, in catalog: [GearCatalogItem]) -> GearCatalogItem? {
        catalog
            .filter { $0.type == .wing && $0.size != nil }
            .min { distance($0.size, to: target) < distance($1.size, to: target) }
    }

    private static func distance(_ size: Double?, to target: Double) -> Double {
        guard let size else { return .infinity }
        return abs(size - target)
    }

    private static func formatSize(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}
