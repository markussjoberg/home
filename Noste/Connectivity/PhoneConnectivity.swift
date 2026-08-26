import Foundation
import WatchConnectivity
import SwiftData
import NosteCore

/// Puhelimen pää WatchConnectivityyn: ottaa vastaan kellon sessiot ja työntää
/// kelloon spotit + tuoreimmat ennusteet offline-snapshotina.
final class PhoneConnectivity: NSObject, ObservableObject {

    static let shared = PhoneConnectivity()

    private var container: ModelContainer?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func configure(container: ModelContainer) {
        self.container = container
    }

    /// Työntää snapshotin kelloon. applicationContext säilyy kellolla, kunnes uusi tulee.
    func pushSnapshot(spots: [SpotData], forecasts: [SpotForecast]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let favorites = spots.filter(\.isFavorite)
        let snapshot = WatchSync.Snapshot(
            spots: favorites.isEmpty ? spots : favorites,
            forecasts: forecasts
        )
        guard let data = try? WatchSync.encode(snapshot) else { return }
        try? WCSession.default.updateApplicationContext([WatchSync.snapshotKey: data])
    }

    @MainActor
    private func storeSession(payload: WatchSync.SessionPayload) {
        guard let container else { return }
        let context = container.mainContext

        // Linkitä lähimpään spottiin (alle 2 km), jos jälki alkaa jostain tutusta.
        var spotName: String?
        if let first = payload.track.first {
            let spots = (try? context.fetch(FetchDescriptor<SpotRecord>())) ?? []
            let nearest = spots.min { a, b in
                distance(a, first) < distance(b, first)
            }
            if let nearest, distance(nearest, first) < 2000 {
                spotName = nearest.name
            }
        }

        let record = SessionRecord(summary: payload.summary, track: payload.track, spotName: spotName)
        context.insert(record)
        try? context.save()

        // Varmuuskopio palvelimelle (best effort — paikallinen talletus on jo tehty).
        let recordID = record.id
        Task {
            await ServerClient.shared.backupSession(payload, id: recordID)
        }
    }

    /// Kellosta tullut tuuliarvosana: etsi sessio alkuhetkellä ja käsittele.
    @MainActor
    private func applyRating(_ rating: WindRating, startDate: Date) async {
        guard let container else { return }
        let context = container.mainContext
        let records = (try? context.fetch(FetchDescriptor<SessionRecord>())) ?? []
        guard let record = records.first(where: { abs($0.startDate.timeIntervalSince(startDate)) < 2 }) else { return }
        await RatingService.apply(rating: rating, to: record, context: context)
    }

    private func distance(_ spot: SpotRecord, _ point: TrackPoint) -> Double {
        GeoMath.distanceMeters(lat1: spot.latitude, lon1: spot.longitude, lat2: point.latitude, lon2: point.longitude)
    }
}

extension PhoneConnectivity: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let (startDate, rating) = WatchSync.RatingMessage.decode(userInfo) else { return }
        Task { @MainActor in
            await self.applyRating(rating, startDate: startDate)
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["type"] as? String == "session",
              let data = try? Data(contentsOf: file.fileURL),
              let payload = try? WatchSync.decode(WatchSync.SessionPayload.self, from: data)
        else { return }
        Task { @MainActor in
            self.storeSession(payload: payload)
        }
    }
}
