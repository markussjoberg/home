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

        // Kellon uusintalähetys (WC-siirto tai palautus) ei saa duplikoida:
        // sama alkuhetki ±2 s = sama sessio, päivitetään olemassa oleva.
        let startDate = payload.summary.startDate
        let record: SessionRecord
        if let existing = ((try? context.fetch(FetchDescriptor<SessionRecord>())) ?? [])
            .first(where: { abs($0.startDate.timeIntervalSince(startDate)) < 2 }) {
            record = existing
            record.summaryData = (try? WatchSync.encode(payload.summary)) ?? record.summaryData
            record.trackData = (try? WatchSync.encode(payload.track)) ?? record.trackData
        } else {
            record = SessionRecord(summary: payload.summary, track: payload.track)
            context.insert(record)
        }
        // Linkitä lähimpään spottiin (alle 2 km), jos jälki alkaa jostain tutusta.
        if record.spotID == nil { SpotLinker.link(record, track: payload.track, context: context) }
        // Ehtikö raakadata perille ensin?
        if let key = pendingMotion.keys.first(where: { abs($0 - startDate.timeIntervalSince1970) < 2 }) {
            record.motionData = pendingMotion.removeValue(forKey: key)
        }
        try? context.save()

        // Sessio jää puhelimeen (GPS ja syke eivät kulje palvelimelle).

        // Pumppisessiolle sää haetaan automaattisesti, ei kysytä käyttäjältä.
        // Tuuli session AJALTA (kello synkkaa usein tunteja myöhemmin, joten
        // siirtohetken havainto olisi väärältä hetkeltä); lämpötila FMI:n
        // tuoreimmasta havainnosta vain jos sessio on juuri päättynyt.
        if payload.summary.sport.countsPumps, let first = payload.track.first {
            let start = payload.summary.startDate
            let end = start.addingTimeInterval(max(1800, payload.summary.duration))
            Task { @MainActor in
                let client = OpenMeteoClient(server: ServerSettings.current)
                if record.sessionWind == nil,
                   let hours = try? await client.windHistory(latitude: first.latitude, longitude: first.longitude, from: start, to: end),
                   let wind = RatedWind.average(of: hours) {
                    record.sessionWind = wind
                }
                if Date().timeIntervalSince(end) < 3 * 3600,
                   let observation = await ServerClient.shared.observation(latitude: first.latitude, longitude: first.longitude) {
                    record.airTemp = observation.airTemp
                }
                try? context.save()
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
