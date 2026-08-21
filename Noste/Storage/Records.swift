import Foundation
import SwiftData
import NosteCore

@Model
final class SpotRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var waterTypeRaw: String
    var sportsRaw: [String]
    var isFavorite: Bool
    var notes: String
    var createdAt: Date

    init(from data: SpotData) {
        id = data.id
        name = data.name
        latitude = data.latitude
        longitude = data.longitude
        waterTypeRaw = data.waterType.rawValue
        sportsRaw = data.sports.map(\.rawValue)
        isFavorite = data.isFavorite
        notes = data.notes
        createdAt = Date()
    }

    var data: SpotData {
        SpotData(
            id: id,
            name: name,
            latitude: latitude,
            longitude: longitude,
            waterType: WaterType(rawValue: waterTypeRaw) ?? .sea,
            sports: sportsRaw.compactMap(Sport.init(rawValue:)),
            isFavorite: isFavorite,
            notes: notes
        )
    }

    func update(from data: SpotData) {
        name = data.name
        latitude = data.latitude
        longitude = data.longitude
        waterTypeRaw = data.waterType.rawValue
        sportsRaw = data.sports.map(\.rawValue)
        isFavorite = data.isFavorite
        notes = data.notes
    }
}

@Model
final class SessionRecord {
    @Attribute(.unique) var id: UUID
    var startDate: Date
    var sportRaw: String
    /// JSON-koodattu SessionSummary.
    var summaryData: Data
    /// JSON-koodattu [TrackPoint] — raakajälki uudelleenanalyysiä ja karttaa varten.
    var trackData: Data?
    var spotName: String?

    init(id: UUID = UUID(), summary: SessionSummary, track: [TrackPoint], spotName: String? = nil) {
        self.id = id
        self.startDate = summary.startDate
        self.sportRaw = summary.sport.rawValue
        self.summaryData = (try? WatchSync.encode(summary)) ?? Data()
        self.trackData = try? WatchSync.encode(track)
        self.spotName = spotName
    }

    var sport: Sport { Sport(rawValue: sportRaw) ?? .wingFoil }

    var summary: SessionSummary? {
        try? WatchSync.decode(SessionSummary.self, from: summaryData)
    }

    var track: [TrackPoint] {
        guard let trackData else { return [] }
        return (try? WatchSync.decode([TrackPoint].self, from: trackData)) ?? []
    }
}
