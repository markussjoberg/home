import Foundation
import WatchConnectivity
import SwiftData
import NosteCore

/// Puhelimen pää WatchConnectivityyn: ottaa vastaan kellon sessiot ja työntää
/// kelloon spotit + tuoreimmat ennusteet offline-snapshotina.
final class PhoneConnectivity: NSObject, ObservableObject {

    static let shared = PhoneConnectivity()

    private var container: ModelContainer?
    /// Raakadata joka saapui ennen sessiotiedostoa (siirtojärjestystä ei taata).
    private var pendingMotion: [TimeInterval: Data] = [:]

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
        let chosen = UserDefaults.standard.string(forKey: "mySports") ?? ""
        let snapshot = WatchSync.Snapshot(
            spots: favorites.isEmpty ? spots : favorites,
            forecasts: forecasts,
            preferredSports: chosen.isEmpty ? nil : chosen.split(separator: ",").map(String.init)
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

        // Kellon uusintalähetys (WC-siirto tai palautus) ei saa duplikoida:
        // sama alkuhetki ±2 s = sama sessio, päivitetään olemassa oleva.
        let startDate = payload.summary.startDate
        let record: SessionRecord
        if let existing = ((try? context.fetch(FetchDescriptor<SessionRecord>())) ?? [])
            .first(where: { abs($0.startDate.timeIntervalSince(startDate)) < 2 }) {
            record = existing
            record.summaryData = (try? WatchSync.encode(payload.summary)) ?? record.summaryData
            record.trackData = (try? WatchSync.encode(payload.track)) ?? record.trackData
            if record.spotName == nil { record.spotName = spotName }
        } else {
            record = SessionRecord(summary: payload.summary, track: payload.track, spotName: spotName)
            context.insert(record)
        }
        // Ehtikö raakadata perille ensin?
        if let key = pendingMotion.keys.first(where: { abs($0 - startDate.timeIntervalSince1970) < 2 }) {
            record.motionData = pendingMotion.removeValue(forKey: key)
        }
        try? context.save()

        // Varmuuskopio palvelimelle (best effort — paikallinen talletus on jo tehty).
        let recordID = record.id
        let motion = record.motionData
        Task {
            await ServerClient.shared.backupSession(payload, id: recordID, motion: motion)
        }

        // Pumppisessiolle tuuli ei ole se kiinnostava — haetaan sää (lämpötila +
        // toteutunut tuuli) automaattisesti FMI:ltä, ei kysytä käyttäjältä mitään.
        if payload.summary.sport.countsPumps, let first = payload.track.first {
            Task { @MainActor in
                if let observation = await ServerClient.shared.observation(
                    latitude: first.latitude, longitude: first.longitude
                ) {
                    record.airTemp = observation.airTemp
                    if let speed = observation.windSpeed, let gust = observation.windGust,
                       let direction = observation.windDirection {
                        record.sessionWind = RatedWind(speed: speed, gust: gust, direction: direction)
                    }
                    try? context.save()
                }
            }
        }
    }

    /// Kellolta saapunut kiihtyvyysraakadata: liitä sessioon ja vie palvelimelle.
    @MainActor
    private func attachMotion(_ data: Data, startDate: Date) {
        guard let container else { return }
        let context = container.mainContext
        let records = (try? context.fetch(FetchDescriptor<SessionRecord>())) ?? []
        guard let record = records.first(where: { abs($0.startDate.timeIntervalSince(startDate)) < 2 }) else {
            pendingMotion[startDate.timeIntervalSince1970] = data
            return
        }
        record.motionData = data
        try? context.save()
        if let summary = record.summary {
            let payload = WatchSync.SessionPayload(summary: summary, track: record.track)
            let recordID = record.id
            let rating = record.rating
            let wind = record.sessionWind
            Task {
                await ServerClient.shared.backupSession(payload, id: recordID, rating: rating, wind: wind, motion: data)
            }
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
        // Kiihtyvyysraakadata: liitä sessioon alkuhetken perusteella.
        if let startDate = WatchSync.MotionFile.decodeStart(file.metadata ?? [:]),
           let data = try? Data(contentsOf: file.fileURL) {
            Task { @MainActor in
                self.attachMotion(data, startDate: startDate)
            }
            return
        }

        guard file.metadata?["type"] as? String == "session",
              let data = try? Data(contentsOf: file.fileURL),
              let payload = try? WatchSync.decode(WatchSync.SessionPayload.self, from: data)
        else { return }
        Task { @MainActor in
            self.storeSession(payload: payload)
        }
    }
}
