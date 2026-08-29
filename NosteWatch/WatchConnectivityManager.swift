import Foundation
import WatchConnectivity
import NosteCore

/// Kellon pää WatchConnectivityyn: vastaanottaa spotit + ennustesnapshotin puhelimelta
/// ja lähettää valmiit sessiot puhelimeen. Snapshot talletetaan levylle, joten se on
/// käytettävissä täysin offline.
final class WatchConnectivityManager: NSObject, ObservableObject {

    /// Yksi offline-karttakuva: PNG levyllä + kalibrointi projisointiin.
    struct OfflineMap: Codable {
        var fileName: String
        var calibration: OfflineMapCalibration
    }

    static let shared = WatchConnectivityManager()

    @Published var snapshot: WatchSync.Snapshot?
    /// Offline-kartat spoteittain, zoomi → kuva.
    @Published var offlineMaps: [UUID: [Int: OfflineMap]] = [:]

    private override init() {
        super.init()
        snapshot = Self.loadCachedSnapshot()
        offlineMaps = Self.loadMapIndex()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    static var mapsDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    func mapImageURL(_ map: OfflineMap) -> URL {
        Self.mapsDirectory.appendingPathComponent(map.fileName)
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

    // MARK: - Offline-kartat

    private static var mapIndexURL: URL {
        mapsDirectory.appendingPathComponent("map-index.json")
    }

    private static func loadMapIndex() -> [UUID: [Int: OfflineMap]] {
        guard let data = try? Data(contentsOf: mapIndexURL),
              let index = try? JSONDecoder().decode([UUID: [Int: OfflineMap]].self, from: data)
        else { return [:] }
        // Pudota kartat joiden kuvatiedosto on siivottu pois.
        return index.mapValues { zooms in
            zooms.filter { FileManager.default.fileExists(atPath: mapsDirectory.appendingPathComponent($0.value.fileName).path) }
        }
    }

    private func registerMap(spotID: UUID, calibration: OfflineMapCalibration, from fileURL: URL) {
        let fileName = "map-\(spotID.uuidString)-z\(calibration.zoom).png"
        let destination = Self.mapsDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.copyItem(at: fileURL, to: destination)) != nil else { return }
        DispatchQueue.main.async {
            var maps = self.offlineMaps
            maps[spotID, default: [:]][calibration.zoom] = OfflineMap(fileName: fileName, calibration: calibration)
            self.offlineMaps = maps
            if let data = try? JSONEncoder().encode(maps) {
                try? data.write(to: Self.mapIndexURL)
            }
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

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let (spotID, calibration) = WatchSync.MapImage.decode(file.metadata ?? [:]) else { return }
        registerMap(spotID: spotID, calibration: calibration, from: file.fileURL)
    }
}
