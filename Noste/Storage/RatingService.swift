import Foundation
import SwiftData
import NosteCore

/// Tuuliarvosanan käsittely: talleta arvosana, hae session ajalta toteutunut
/// tuuli (Open-Meteon historia) ja vie päivitetty sessio palvelimelle.
/// Näistä pareista (tuuli, tähdet) spotin tuuliprofiili oppii.
@MainActor
enum RatingService {

    static func apply(rating: WindRating, to record: SessionRecord, context: ModelContext) async {
        record.rating = rating
        try? context.save()

        // Toteutunut tuuli session ajalta (kerran; historia kattaa ~7 vrk).
        if record.sessionWind == nil, let first = record.track.first {
            let client = OpenMeteoClient(server: ServerSettings.current)
            let start = record.startDate
            let end = start.addingTimeInterval(max(1800, record.summary?.duration ?? 3600))
            if let hours = try? await client.windHistory(
                latitude: first.latitude, longitude: first.longitude, from: start, to: end
            ), let wind = RatedWind.average(of: hours) {
                record.sessionWind = wind
                try? context.save()
            }
        }

        if let summary = record.summary {
            await ServerClient.shared.backupSession(
                WatchSync.SessionPayload(summary: summary, track: record.track),
                id: record.id,
                rating: record.rating,
                wind: record.sessionWind,
                motion: record.motionData
            )
        }
    }

    /// Rakentaa spotin tuuliprofiilin reittatuista sessioista.
    /// Spotin sessiot id:llä; vanhat tietueet ilman id:tä täsmätään nimellä.
    static func profile(spotID: UUID? = nil, spotName: String, sessions: [SessionRecord]) -> SpotWindProfile {
        let rated: [SpotWindProfile.RatedSession] = sessions.compactMap { record in
            let linked = (spotID != nil && record.spotID == spotID)
                || (record.spotID == nil && record.spotName == spotName)
            guard linked,
                  let rating = record.rating,
                  let wind = record.sessionWind
            else { return nil }
            return SpotWindProfile.RatedSession(rating: rating, wind: wind)
        }
        return SpotWindProfile(sessions: rated)
    }
}
