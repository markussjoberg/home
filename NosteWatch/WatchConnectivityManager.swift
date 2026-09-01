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
    /// Vesialuemaskit (kaikki spotit ja zoomit) session segmentointiin.
    @Published var waterMasks: [WaterMask] = []

    private override init() {
        super.init()
        snapshot = Self.loadCachedSnapshot()
        offlineMaps = Self.loadMapIndex()
        waterMasks = Self.loadWaterMasks()
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

    /// Lähettää kiihtyvyysraakadatan puhelimeen (kalibroinnin kulta-aines).
    func send(motion: [MotionSample], for startDate: Date) {
        guard !motion.isEmpty else { return }
        let data = MotionLog.pack(motion)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("motion-\(Int(startDate.timeIntervalSince1970)).bin")
        do {
            try data.write(to: url)
            WCSession.default.transferFile(url, metadata: WatchSync.MotionFile.metadata(startDate: startDate))
        } catch {
            // Raakadata jää tältä sessiolta siirtämättä; analyysi on jo tehty kellossa.
        }
    }

    /// Session lähetykset, jotka odottavat WCSessionin aktivoitumista.
    private var pendingPayloads: [(WatchSync.SessionPayload, (() -> Void)?)] = []
    /// Siirron valmistumisesta kiinnostuneet (esim. recovery-tiedoston poisto).
    private var deliveryHandlers: [URL: () -> Void] = [:]

    /// Lähettää session puhelimeen tiedostona (jälki voi olla iso).
    /// transferFile jonottaa siirron ja hoitaa sen kun puhelin on taas saatavilla.
    /// Ennen aktivoitumista lähetys jää odottamaan; onDelivered kutsutaan kun
    /// siirto on varmistunut onnistuneeksi.
    func send(payload: WatchSync.SessionPayload, onDelivered: (() -> Void)? = nil) {
        guard WCSession.default.activationState == .activated else {
            pendingPayloads.append((payload, onDelivered))
            return
        }
        do {
            let data = try WatchSync.encode(payload)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("session-\(Int(payload.summary.startDate.timeIntervalSince1970)).json")
            try data.write(to: url)
            if let onDelivered { deliveryHandlers[url] = onDelivered }
            WCSession.default.transferFile(url, metadata: ["type": "session"])
        } catch {
            // Sessio jää HealthKitiin vaikka siirto epäonnistuisi.
        }
    }

    private func flushPendingPayloads() {
        let pending = pendingPayloads
        pendingPayloads = []
        for (payload, handler) in pending {
            send(payload: payload, onDelivered: handler)
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
        if activationState == .activated {
            DispatchQueue.main.async { self.flushPendingPayloads() }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        DispatchQueue.main.async {
            guard let handler = self.deliveryHandlers.removeValue(forKey: url) else { return }
            // Virheessä käsittelijää ei kutsuta: recovery-tiedosto säilyy ja
            // seuraava käynnistys yrittää uudelleen.
            if error == nil { handler() }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let data = applicationContext[WatchSync.snapshotKey] as? Data {
            store(snapshotData: data)
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        if let (spotID, calibration) = WatchSync.MapImage.decode(metadata) {
            registerMap(spotID: spotID, calibration: calibration, from: file.fileURL)
        } else if let (spotID, zoom) = WatchSync.WaterMaskFile.decode(metadata) {
            registerWaterMask(spotID: spotID, zoom: zoom, from: file.fileURL)
        }
    }
}

// MARK: - Vesialuemaskit

extension WatchConnectivityManager {

    /// Documents (ei caches): maski on session tallennuksen luotettavuudelle
    /// tärkeä eikä saa kadota levysiivouksessa.
    private static var masksDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watermasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func loadWaterMasks() -> [WaterMask] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: masksDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(WaterMask.self, from: data)
        }
    }

    private func registerWaterMask(spotID: UUID, zoom: Int, from fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              (try? JSONDecoder().decode(WaterMask.self, from: data)) != nil else { return }
        let destination = Self.masksDirectory.appendingPathComponent("\(spotID.uuidString)-z\(zoom).json")
        try? data.write(to: destination, options: .atomic)
        let masks = Self.loadWaterMasks()
        DispatchQueue.main.async {
            self.waterMasks = masks
        }
    }
}
