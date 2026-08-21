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

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
