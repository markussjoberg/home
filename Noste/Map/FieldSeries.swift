import Foundation
import MapKit

/// Open-Meteon tuntileimat: "yyyy-MM-dd'T'HH:mm" UTC:ssä ilman Z:aa.
enum FieldTime {
    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    static func parse(_ times: [String]) -> [Date] {
        times.compactMap { parser.date(from: $0) }
    }

    /// Lähimmän tunnin indeksi; nil jos sarja on tyhjä.
    static func index(of date: Date, in dates: [Date]) -> Int? {
        guard !dates.isEmpty else { return nil }
        var best = 0
        var bestDiff = Double.infinity
        for (i, d) in dates.enumerated() {
            let diff = abs(d.timeIntervalSince(date))
            if diff < bestDiff { best = i; bestDiff = diff }
        }
        return best
    }

    /// Nykyhetki tasatunniksi pyöristettynä — aikajanan nollakohta.
    static func currentHour(now: Date = Date()) -> Date {
        Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)
    }
}

/// Tuulihila kaikille ennustetunneille (aikajana selaa ilman uusia hakuja).
struct WindFieldSeries: Decodable {
    struct Cell: Decodable {
        var latitude: Double
        var longitude: Double
        var speed: [Double]
        var direction: [Double]
    }

    var times: [String]
    var cells: [Cell]
    var dates: [Date]

    private enum CodingKeys: String, CodingKey { case times, cells }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        times = try c.decode([String].self, forKey: .times)
        cells = try c.decode([Cell].self, forKey: .cells)
        dates = FieldTime.parse(times)
    }

    var isEmpty: Bool { cells.isEmpty || dates.isEmpty }

    func cells(at index: Int) -> [WindCell] {
        cells.compactMap { cell in
            guard index >= 0, index < cell.speed.count, index < cell.direction.count else { return nil }
            return WindCell(latitude: cell.latitude, longitude: cell.longitude,
                            speed: cell.speed[index], direction: cell.direction[index])
        }
    }
}

/// Aaltohila kaikille ennustetunneille + palvelimen todella hakema alue.
struct WaveFieldSeries: Decodable {
    struct Cell: Decodable {
        var latitude: Double
        var longitude: Double
        var height: [Double]
        var direction: [Double]
        var period: [Double]
    }

    var times: [String]
    var cells: [Cell]
    /// [minLon, minLat, maxLon, maxLat]
    var bbox: [Double]
    var dates: [Date]

    private enum CodingKeys: String, CodingKey { case times, cells, bbox }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        times = try c.decode([String].self, forKey: .times)
        cells = try c.decode([Cell].self, forKey: .cells)
        bbox = try c.decode([Double].self, forKey: .bbox)
        dates = FieldTime.parse(times)
        guard bbox.count == 4 else {
            throw DecodingError.dataCorruptedError(forKey: .bbox, in: c, debugDescription: "bbox tarvitsee 4 lukua")
        }
    }

    var isEmpty: Bool { cells.isEmpty || dates.isEmpty }
    var spanLat: Double { bbox[3] - bbox[1] }
    var spanLon: Double { bbox[2] - bbox[0] }
    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (bbox[1] + bbox[3]) / 2, longitude: (bbox[0] + bbox[2]) / 2)
    }

    func cells(at index: Int) -> [WaveCell] {
        cells.compactMap { cell in
            guard index >= 0, index < cell.height.count, index < cell.direction.count else { return nil }
            return WaveCell(latitude: cell.latitude, longitude: cell.longitude, height: cell.height[index],
                            direction: cell.direction[index], period: index < cell.period.count ? cell.period[index] : 0)
        }
    }

    func field(at index: Int, mask: WaterSnapshotMask? = nil, corrections: [WaveCorrection] = []) -> WaveField {
        WaveField(cells: cells(at: index), spanLat: spanLat, spanLon: spanLon, mask: mask, corrections: corrections)
    }
}
