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
    var goodDirections: [Int]?
    var minWind: Double?
    var maxWind: Double?
    var alertEnabled: Bool = false

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
        goodDirections = data.goodDirections
        minWind = data.minWind
        maxWind = data.maxWind
        alertEnabled = data.alertEnabled ?? false
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
            notes: notes,
            goodDirections: goodDirections,
            minWind: minWind,
            maxWind: maxWind,
            alertEnabled: alertEnabled ? true : nil
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
        goodDirections = data.goodDirections
        minWind = data.minWind
        maxWind = data.maxWind
        alertEnabled = data.alertEnabled ?? false
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
    /// Tuuliarvosana (WindRating.rawValue; 0 = ei riittänyt, nil = ei reittausta).
    var ratingRaw: Int?
    /// Session aikana vallinnut tuuli (haetaan reittauksen yhteydessä).
    var windSpeed: Double?
    var windGust: Double?
    var windDirection: Double?

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

    var rating: WindRating? {
        get { ratingRaw.flatMap(WindRating.init(rawValue:)) }
        set { ratingRaw = newValue?.rawValue }
    }

    var sessionWind: RatedWind? {
        get {
            guard let windSpeed, let windGust, let windDirection else { return nil }
            return RatedWind(speed: windSpeed, gust: windGust, direction: windDirection)
        }
        set {
            windSpeed = newValue?.speed
            windGust = newValue?.gust
            windDirection = newValue?.direction
        }
    }
}
