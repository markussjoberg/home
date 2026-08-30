import Foundation

/// Kellon ja puhelimen väliset siirtomuodot (WatchConnectivity kuljettaa nämä JSONina).
public enum WatchSync {

    /// Puhelin → kello: spotit ja tuoreet ennusteet offline-käyttöön.
    public struct Snapshot: Codable, Sendable, Equatable {
        public var updatedAt: Date
        public var spots: [SpotData]
        public var forecasts: [SpotForecast]

        public init(updatedAt: Date = Date(), spots: [SpotData], forecasts: [SpotForecast]) {
            self.updatedAt = updatedAt
            self.spots = spots
            self.forecasts = forecasts
        }
    }

    /// Kello → puhelin: valmis sessio raakajälkineen.
    public struct SessionPayload: Codable, Sendable, Equatable {
        public var summary: SessionSummary
        public var track: [TrackPoint]

        public init(summary: SessionSummary, track: [TrackPoint]) {
            self.summary = summary
            self.track = track
        }
    }

    /// applicationContext-avain snapshotille (arvo = JSON Data).
    public static let snapshotKey = "noste.snapshot"

    /// Puhelin → kello: offline-karttakuva (PNG-tiedosto + metadata).
    public enum MapImage {
        public static let typeValue = "mapimage"
        public static let spotIDKey = "spotID"
        public static let zoomKey = "zoom"
        /// JSON-koodattu OfflineMapCalibration merkkijonona.
        public static let calibrationKey = "calibration"

        public static func metadata(spotID: UUID, calibration: OfflineMapCalibration) -> [String: Any]? {
            guard let data = try? JSONEncoder().encode(calibration),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return ["type": typeValue, spotIDKey: spotID.uuidString,
                    zoomKey: calibration.zoom, calibrationKey: json]
        }

        public static func decode(_ metadata: [String: Any]) -> (spotID: UUID, calibration: OfflineMapCalibration)? {
            guard metadata["type"] as? String == typeValue,
                  let idString = metadata[spotIDKey] as? String,
                  let spotID = UUID(uuidString: idString),
                  let json = metadata[calibrationKey] as? String,
                  let calibration = try? JSONDecoder().decode(OfflineMapCalibration.self, from: Data(json.utf8))
            else { return nil }
            return (spotID, calibration)
        }
    }

    /// Puhelin → kello: vesialuemaski (JSON-tiedosto + metadata). Kello käyttää
    /// maskia session segmentointiin ("olenko vesialueella") täysin offline.
    public enum WaterMaskFile {
        public static let typeValue = "watermask"
        public static let spotIDKey = "spotID"
        public static let zoomKey = "zoom"

        public static func metadata(spotID: UUID, zoom: Int) -> [String: Any] {
            ["type": typeValue, spotIDKey: spotID.uuidString, zoomKey: zoom]
        }

        public static func decode(_ metadata: [String: Any]) -> (spotID: UUID, zoom: Int)? {
            guard metadata["type"] as? String == typeValue,
                  let idString = metadata[spotIDKey] as? String,
                  let spotID = UUID(uuidString: idString),
                  let zoom = metadata[zoomKey] as? Int
            else { return nil }
            return (spotID, zoom)
        }
    }

    /// Kello → puhelin -tuuliarvosana (transferUserInfo-avaimet). Sessio
    /// yksilöidään alkuhetkellä, koska arvosana annetaan siirron jälkeen.
    public enum RatingMessage {
        public static let typeKey = "type"
        public static let typeValue = "rating"
        public static let startKey = "start"
        public static let ratingKey = "rating"

        public static func encode(startDate: Date, rating: WindRating) -> [String: Any] {
            [typeKey: typeValue, startKey: startDate.timeIntervalSince1970, ratingKey: rating.rawValue]
        }

        public static func decode(_ userInfo: [String: Any]) -> (startDate: Date, rating: WindRating)? {
            guard userInfo[typeKey] as? String == typeValue,
                  let start = userInfo[startKey] as? TimeInterval,
                  let raw = userInfo[ratingKey] as? Int,
                  let rating = WindRating(rawValue: raw)
            else { return nil }
            return (Date(timeIntervalSince1970: start), rating)
        }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
