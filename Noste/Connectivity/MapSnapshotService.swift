import Foundation
import UIKit
import WatchConnectivity
import NosteCore

/// Ompelee suosikkispottien ympäriltä maastokarttatiilistä offline-karttakuvat
/// ja työntää ne kelloon: z14 (~5 km ja z15 (~2,5 km katselualue 60°N).
/// Kello piirtää kuvan päälle sijainnin ja jäljen — toimii täysin ilman verkkoa.
@MainActor
final class MapSnapshotService {

    static let shared = MapSnapshotService()
    private var inFlight: Set<String> = []
    /// 3×3 tiilen ruudukko per zoomi = 768×768 px PNG (~0,2–0,6 Mt).
    private let zooms = [14, 15]

    private init() {}

    func syncFavorites(spots: [SpotData]) async {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let template = Self.terrainTemplate() else { return }

        for spot in spots where spot.isFavorite {
            for zoom in zooms {
                let sentKey = "mapSent-\(spot.id.uuidString)-z\(zoom)"
                guard !UserDefaults.standard.bool(forKey: sentKey),
                      !inFlight.contains(sentKey) else { continue }
                inFlight.insert(sentKey)
                defer { inFlight.remove(sentKey) }

                let calibration = OfflineMapCalibration.centered(
                    latitude: spot.latitude, longitude: spot.longitude, zoom: zoom, tileCount: 3
                )
                guard let png = await stitch(calibration: calibration, template: template),
                      let metadata = WatchSync.MapImage.metadata(spotID: spot.id, calibration: calibration)
                else { continue }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("map-\(spot.id.uuidString)-z\(zoom).png")
                do {
                    try png.write(to: url)
                    WCSession.default.transferFile(url, metadata: metadata)
                    UserDefaults.standard.set(true, forKey: sentKey)
                } catch {
                    // Siirto yritetään seuraavalla synkalla uudelleen.
                }
            }
        }
    }

    /// Maastotiilien lähde: oma palvelin > suora MML-avain > ei saatavilla.
    private static func terrainTemplate() -> String? {
        if let server = ServerSettings.current {
            return ServerSettings.tileTemplate(layer: "terrain", server: server)
        }
        let key = UserDefaults.standard.string(forKey: "mmlApiKey") ?? ""
        return key.isEmpty ? nil : TileOverlays.terrainTemplate(apiKey: key)
    }

    /// Hakee ruudukon tiilet ja piirtää ne yhdeksi kuvaksi. nil jos yksikin puuttuu.
    private func stitch(calibration: OfflineMapCalibration, template: String) async -> Data? {
        var tiles: [(index: Int, image: UIImage)] = []
        let count = calibration.tileCount
        for row in 0..<count {
            for column in 0..<count {
                let urlString = template
                    .replacingOccurrences(of: "{z}", with: String(calibration.zoom))
                    .replacingOccurrences(of: "{x}", with: String(calibration.tileMinX + column))
                    .replacingOccurrences(of: "{y}", with: String(calibration.tileMinY + row))
                guard let url = URL(string: urlString),
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data)
                else { return nil }
                tiles.append((row * count + column, image))
            }
        }

        let size = CGFloat(calibration.imageSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let stitched = renderer.image { _ in
            let tileSize = CGFloat(calibration.tileSize)
            for (index, image) in tiles {
                let row = index / count
                let column = index % count
                image.draw(in: CGRect(x: CGFloat(column) * tileSize, y: CGFloat(row) * tileSize,
                                      width: tileSize, height: tileSize))
            }
        }
        return stitched.pngData()
    }
}
