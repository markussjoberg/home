import Foundation

/// Web Mercator -projektio (EPSG:3857) offline-karttakuvia varten: puhelin
/// ompelee karttatiilet yhdeksi kuvaksi ja kello piirtää sijainnin ja jäljen
/// kuvan päälle näillä kaavoilla — ei karttakirjastoa, ei verkkoa.
public enum WebMercator {

    /// Tiilikoordinaatit (murtolukuina) annetulla zoomilla.
    public static func tileXY(latitude: Double, longitude: Double, zoom: Int) -> (x: Double, y: Double) {
        let n = pow(2.0, Double(zoom))
        let x = n * (longitude + 180) / 360
        let latRad = latitude * .pi / 180
        let y = n * (1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2
        return (x, y)
    }

    /// Metriä per pikseli (256 px tiilet) — mittakaavajanaa varten.
    public static func metersPerPixel(latitude: Double, zoom: Int) -> Double {
        156_543.03392 * cos(latitude * .pi / 180) / pow(2.0, Double(zoom))
    }
}

/// Ommellun karttakuvan kalibrointi: mistä tiilistä kuva koostuu, jotta
/// koordinaatit voi projisoida pikseleiksi. Kulkee kelloon kuvan mukana.
public struct OfflineMapCalibration: Codable, Sendable, Equatable {
    public var zoom: Int
    /// Vasemman yläkulman tiili.
    public var tileMinX: Int
    public var tileMinY: Int
    /// Tiiliruudukon koko (esim. 3 = 3×3).
    public var tileCount: Int
    /// Tiilen sivun pikselikoko (yleensä 256).
    public var tileSize: Int

    public init(zoom: Int, tileMinX: Int, tileMinY: Int, tileCount: Int, tileSize: Int = 256) {
        self.zoom = zoom
        self.tileMinX = tileMinX
        self.tileMinY = tileMinY
        self.tileCount = tileCount
        self.tileSize = tileSize
    }

    /// Kuvan sivun pituus pikseleinä.
    public var imageSize: Int { tileCount * tileSize }

    /// Koordinaatti → pikselipiste kuvassa (voi olla kuvan ulkopuolella).
    public func point(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        let tile = WebMercator.tileXY(latitude: latitude, longitude: longitude, zoom: zoom)
        return ((tile.x - Double(tileMinX)) * Double(tileSize),
                (tile.y - Double(tileMinY)) * Double(tileSize))
    }

    /// Onko koordinaatti kuvan alueella (pienellä marginaalilla).
    public func contains(latitude: Double, longitude: Double, margin: Double = 0) -> Bool {
        let p = point(latitude: latitude, longitude: longitude)
        let size = Double(imageSize)
        return p.x >= -margin && p.y >= -margin && p.x <= size + margin && p.y <= size + margin
    }

    /// Rakentaa kalibroinnin niin, että ruudukko keskittyy annettuun pisteeseen.
    public static func centered(latitude: Double, longitude: Double, zoom: Int, tileCount: Int, tileSize: Int = 256) -> OfflineMapCalibration {
        let tile = WebMercator.tileXY(latitude: latitude, longitude: longitude, zoom: zoom)
        let half = tileCount / 2
        return OfflineMapCalibration(
            zoom: zoom,
            tileMinX: Int(floor(tile.x)) - half,
            tileMinY: Int(floor(tile.y)) - half,
            tileCount: tileCount,
            tileSize: tileSize
        )
    }
}
