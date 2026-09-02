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
    var isPublic: Bool = false
    var fetchKmByOctant: [Double]?
    var exposureByOctant: [Double]?

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
        isPublic = data.isPublic ?? false
        fetchKmByOctant = data.fetchKmByOctant
        exposureByOctant = data.exposureByOctant
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
            alertEnabled: alertEnabled ? true : nil,
            isPublic: isPublic ? true : nil,
            fetchKmByOctant: fetchKmByOctant,
            exposureByOctant: exposureByOctant
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
        isPublic = data.isPublic ?? false
        if let fetch = data.fetchKmByOctant { fetchKmByOctant = fetch }
        if let exposure = data.exposureByOctant { exposureByOctant = exposure }
    }
}

/// Oma kalusto (quiver): siivet, laudat ja foilit. Sessiot tägätään näihin,
/// ja GearAdvisor ehdottaa puutteisiin täydennystä (Lappis-demo).
@Model
final class GearRecord {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var name: String
    /// Koko tyypin yksikössä (siipi m², lauta l, foili cm²); nil = ei tiedossa.
    var size: Double?
    /// Vuosimalli; nil = ei tiedossa.
    var year: Int?
    /// Ensisijainen laji (Sport.rawValue); nil = yleiskäyttöinen.
    var primarySportRaw: String?
    var createdAt: Date

    init(type: GearType, name: String, size: Double? = nil, year: Int? = nil, primarySport: Sport? = nil) {
        id = UUID()
        typeRaw = type.rawValue
        self.name = name
        self.size = size
        self.year = year
        primarySportRaw = primarySport?.rawValue
        createdAt = Date()
    }

    var type: GearType { GearType(rawValue: typeRaw) ?? .wing }

    var primarySport: Sport? { primarySportRaw.flatMap(Sport.init(rawValue:)) }

    var info: GearInfo { GearInfo(type: type, name: name, size: size, year: year, sport: primarySport) }

    /// Esim. "Unit 4,5 m² ’24".
    var displayName: String {
        var parts = [name]
        if let size {
            let sizeText = size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size).replacingOccurrences(of: ".", with: ",")
            parts.append("\(sizeText) \(type.sizeUnit)")
        }
        if let year { parts.append("’\(String(year).suffix(2))") }
        return parts.joined(separator: " ")
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
    /// Kiihtyvyysraakadata (MotionLog-binääri) — kalibrointia varten.
    @Attribute(.externalStorage) var motionData: Data?
    var spotName: String?
    /// Spotin tunniste — nimi voi vaihtua, id ei. Vanhoilla tietueilla nil.
    var spotID: UUID?
    /// Sessiossa käytetty kalusto (GearRecord-id:t).
    var gearIDs: [UUID]?
    /// Tuuliarvosana (WindRating.rawValue; 0 = ei riittänyt, nil = ei reittausta).
    var ratingRaw: Int?
    /// Session aikana vallinnut tuuli (haetaan reittauksen yhteydessä).
    var windSpeed: Double?
    var windGust: Double?
    var windDirection: Double?
    /// Ilman lämpötila session aikaan (°C) — pumppisessioille sää tuulen sijaan.
    var airTemp: Double?

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

/// Käyttäjän oma kelivahtihälytys (ks. WindAlert). Yksi per spotti.
@Model
final class AlertRecord {
    @Attribute(.unique) var id: UUID
    var spotID: UUID
    var spotName: String
    var latitude: Double
    var longitude: Double
    var waterTypeRaw: String
    var minWind: Double
    var goodDirections: [Int]?
    var minHours: Int
    var enabled: Bool

    init(from alert: WindAlert) {
        id = alert.id
        spotID = alert.spotId
        spotName = alert.spotName
        latitude = alert.latitude
        longitude = alert.longitude
        waterTypeRaw = alert.waterType.rawValue
        minWind = alert.minWind
        goodDirections = alert.goodDirections
        minHours = alert.minHours
        enabled = alert.enabled
    }

    func update(from alert: WindAlert) {
        spotName = alert.spotName
        latitude = alert.latitude
        longitude = alert.longitude
        waterTypeRaw = alert.waterType.rawValue
        minWind = alert.minWind
        goodDirections = alert.goodDirections
        minHours = alert.minHours
        enabled = alert.enabled
    }

    var data: WindAlert {
        WindAlert(id: id, spotId: spotID, spotName: spotName, latitude: latitude, longitude: longitude,
                  waterType: WaterType(rawValue: waterTypeRaw) ?? .sea, minWind: minWind,
                  goodDirections: goodDirections, minHours: minHours, enabled: enabled)
    }
}

/// Hälytysten talletus ja vienti palvelimelle yhdestä paikasta.
enum AlertStore {
    static func alert(for spotID: UUID, context: ModelContext) -> AlertRecord? {
        ((try? context.fetch(FetchDescriptor<AlertRecord>())) ?? []).first { $0.spotID == spotID }
    }

    /// Tallettaa (tai päivittää) hälytyksen ja vie koko listan palvelimelle.
    static func upsert(_ alert: WindAlert, context: ModelContext) {
        if let existing = self.alert(for: alert.spotId, context: context) {
            existing.update(from: alert)
        } else {
            context.insert(AlertRecord(from: alert))
        }
        try? context.save()
        sync(context: context)
    }

    static func sync(context: ModelContext) {
        let alerts = ((try? context.fetch(FetchDescriptor<AlertRecord>())) ?? []).map(\.data)
        Task { await ServerClient.shared.backupAlerts(alerts) }
    }
}
