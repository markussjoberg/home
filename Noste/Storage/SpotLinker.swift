import Foundation
import SwiftData
import NosteCore

/// Linkittää session lähimpään omaan spottiin (alle 2 km jäljen alusta).
/// Sama sääntö kello- ja puhelinsessioille, jotta molemmat opettavat spottia.
enum SpotLinker {
    static let maxDistanceMeters = 2000.0

    static func nearestSpot(to point: TrackPoint, context: ModelContext) -> SpotRecord? {
        let spots = (try? context.fetch(FetchDescriptor<SpotRecord>())) ?? []
        let nearest = spots.min { distance($0, point) < distance($1, point) }
        guard let nearest, distance(nearest, point) < maxDistanceMeters else { return nil }
        return nearest
    }

    /// Asettaa tietueelle spotin nimen ja id:n, jos jälki alkaa tutusta paikasta.
    static func link(_ record: SessionRecord, track: [TrackPoint], context: ModelContext) {
        guard let first = track.first, let spot = nearestSpot(to: first, context: context) else { return }
        record.spotName = spot.name
        record.spotID = spot.id
    }

    private static func distance(_ spot: SpotRecord, _ point: TrackPoint) -> Double {
        GeoMath.distanceMeters(lat1: spot.latitude, lon1: spot.longitude, lat2: point.latitude, lon2: point.longitude)
    }
}
