import Foundation
import WatchConnectivity
import NosteCore

/// Kellon pää WatchConnectivityyn: vastaanottaa spotit + ennustesnapshotin puhelimelta
/// ja lähettää valmiit sessiot puhelimeen. Snapshot talletetaan levylle, joten se on
/// käytettävissä täysin offline.
final class WatchConnectivityManager: NSObject, ObservableObject {

    static let shared = WatchConnectivityManager()

    @Published var snapshot: WatchSync.Snapshot?

    private override init() {
        super.init()
        snapshot = Self.loadCachedSnapshot()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Lähettää tuuliarvosanan puhelimeen. transferUserInfo jonottaa ja toimittaa
    /// perille, vaikka puhelin ei olisi juuri nyt saatavilla.
    func send(rating: WindRating, for startDate: Date) {
        WCSession.default.transferUserInfo(WatchSync.RatingMessage.encode(startDate: startDate, rating: rating))
    }

    /// Lähettää session puhelimeen tiedostona (jälki voi olla iso).
    /// transferFile jonottaa siirron ja hoitaa sen kun puhelin on taas saatavilla.
    func send(payload: WatchSync.SessionPayload) {
        do {
            let data = try WatchSync.encode(payload)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("session-\(Int(payload.summary.startDate.timeIntervalSince1970)).json")
            try data.write(to: url)
            WCSession.default.transferFile(url, metadata: ["type": "session"])
        } catch {
            // Sessio jää HealthKitiin vaikka siirto epäonnistuisi.
        }
    }

    // MARK: - Snapshotin levycache

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("snapshot.json")
    }

    private static func loadCachedSnapshot() -> WatchSync.Snapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? WatchSync.decode(WatchSync.Snapshot.self, from: data)
    }

    private func store(snapshotData data: Data) {
        guard let decoded = try? WatchSync.decode(WatchSync.Snapshot.self, from: data) else { return }
        try? data.write(to: Self.cacheURL)
        DispatchQueue.main.async {
            self.snapshot = decoded
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // Aktivoituessa voi odottaa viimeisin applicationContext.
        let context = session.receivedApplicationContext
        if let data = context[WatchSync.snapshotKey] as? Data {
            store(snapshotData: data)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let data = applicationContext[WatchSync.snapshotKey] as? Data {
            store(snapshotData: data)
        }
    }
}
