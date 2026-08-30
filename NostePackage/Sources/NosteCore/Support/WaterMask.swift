import Foundation

/// Vesialuemaski: bittikartta siitä, mikä osa offline-karttakuvan alueesta on
/// vettä. Puhelin luokittelee maastokarttatiilien pikselit ompeluvaiheessa ja
/// kello vastaa sillä kysymykseen "olenko vesialueella" täysin offline.
/// Ruudukko on karttakuvaa harvempi (factor), koska rantaviivan metritarkkuutta
/// ei tarvita — SegmentTracker vaatii joka tapauksessa pitkän yhtäjaksoisen
/// maissaolon ennen maissa-merkintää.
public struct WaterMask: Codable, Sendable, Equatable {
    public var calibration: OfflineMapCalibration
    /// Montako karttapikseliä yksi maskiruutu kattaa sivullaan (esim. 4).
    public var factor: Int
    /// Ruudukon leveys/korkeus (imageSize / factor).
    public var gridSize: Int
    /// Bitit rivi kerrallaan, 8 ruutua/tavu, MSB ensin. 1 = vettä.
    public var bits: Data

    public init(calibration: OfflineMapCalibration, factor: Int, gridSize: Int, bits: Data) {
        self.calibration = calibration
        self.factor = factor
        self.gridSize = gridSize
        self.bits = bits
    }

    /// Rakentaa maskin valmiista vesiruudukosta (rivi kerrallaan, true = vettä).
    public init(calibration: OfflineMapCalibration, factor: Int, waterCells: [Bool]) {
        let grid = calibration.imageSize / factor
        var data = Data(count: (grid * grid + 7) / 8)
        for (index, isWater) in waterCells.prefix(grid * grid).enumerated() where isWater {
            data[index / 8] |= 1 << (7 - UInt8(index % 8))
        }
        self.init(calibration: calibration, factor: factor, gridSize: grid, bits: data)
    }

    /// Onko koordinaatti vettä. nil = maskin alueen ulkopuolella (ei tietoa).
    public func isWater(latitude: Double, longitude: Double) -> Bool? {
        let point = calibration.point(latitude: latitude, longitude: longitude)
        let size = Double(calibration.imageSize)
        guard point.x >= 0, point.y >= 0, point.x < size, point.y < size else { return nil }
        let column = min(gridSize - 1, Int(point.x) / factor)
        let row = min(gridSize - 1, Int(point.y) / factor)
        let index = row * gridSize + column
        guard index / 8 < bits.count else { return nil }
        return bits[index / 8] & (1 << (7 - UInt8(index % 8))) != 0
    }
}

/// Kokoelma maskeja (eri spotit ja zoomit): vastaa tarkimmasta kattavasta maskista.
public struct WaterMaskIndex: Sendable {
    private let masks: [WaterMask]

    public init(masks: [WaterMask]) {
        // Tarkin zoomi ensin — se vastaa ensimmäisenä, jos kattaa pisteen.
        self.masks = masks.sorted { $0.calibration.zoom > $1.calibration.zoom }
    }

    public var isEmpty: Bool { masks.isEmpty }

    /// nil = mikään maski ei kata pistettä (tuntematon → tulkitaan vedeksi).
    public func isWater(latitude: Double, longitude: Double) -> Bool? {
        for mask in masks {
            if let answer = mask.isWater(latitude: latitude, longitude: longitude) {
                return answer
            }
        }
        return nil
    }
}
