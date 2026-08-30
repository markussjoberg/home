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
                // v2: kuvan mukana lähtee vesialuemaski (segmentointi kellossa).
                let sentKey = "mapSent2-\(spot.id.uuidString)-z\(zoom)"
                guard !UserDefaults.standard.bool(forKey: sentKey),
                      !inFlight.contains(sentKey) else { continue }
                inFlight.insert(sentKey)
                defer { inFlight.remove(sentKey) }

                let calibration = OfflineMapCalibration.centered(
                    latitude: spot.latitude, longitude: spot.longitude, zoom: zoom, tileCount: 3
                )
                guard let stitched = await stitch(calibration: calibration, template: template),
                      let png = stitched.pngData(),
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
                    continue
                }

                if let mask = WaterMaskBuilder.build(from: stitched, calibration: calibration) {
                    PhoneWaterMasks.save(mask, spotID: spot.id)
                    if let maskData = try? JSONEncoder().encode(mask) {
                        let maskURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("watermask-\(spot.id.uuidString)-z\(zoom).json")
                        try? maskData.write(to: maskURL)
                        WCSession.default.transferFile(
                            maskURL,
                            metadata: WatchSync.WaterMaskFile.metadata(spotID: spot.id, zoom: zoom)
                        )
                    }
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
    private func stitch(calibration: OfflineMapCalibration, template: String) async -> UIImage? {
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
        return renderer.image { _ in
            let tileSize = CGFloat(calibration.tileSize)
            for (index, image) in tiles {
                let row = index / count
                let column = index % count
                image.draw(in: CGRect(x: CGFloat(column) * tileSize, y: CGFloat(row) * tileSize,
                                      width: tileSize, height: tileSize))
            }
        }
    }
}

/// Rakentaa vesialuemaskin ommellusta maastokarttakuvasta: MML-rasterin
/// vesialueet ovat vaaleansinisiä, ja 4×4 pikselin lohkon enemmistöäänestys
/// sietää syvyyskäyrät, tekstit ja rantaviivan.
enum WaterMaskBuilder {

    static let factor = 4

    static func build(from image: UIImage, calibration: OfflineMapCalibration) -> WaterMask? {
        guard let cgImage = image.cgImage else { return nil }
        let size = calibration.imageSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let grid = size / factor
        var cells = [Bool](repeating: false, count: grid * grid)
        for row in 0..<grid {
            for column in 0..<grid {
                var waterVotes = 0
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let x = column * factor + dx
                        let y = row * factor + dy
                        let offset = (y * size + x) * 4
                        let r = Int(pixels[offset])
                        let g = Int(pixels[offset + 1])
                        let b = Int(pixels[offset + 2])
                        // Vaaleansininen vesi: sininen hallitsee, vihreä välissä.
                        if b >= 190, b - r >= 20, g >= r, g <= b + 10 {
                            waterVotes += 1
                        }
                    }
                }
                cells[row * grid + column] = waterVotes * 2 >= factor * factor
            }
        }
        return WaterMask(calibration: calibration, factor: factor, waterCells: cells)
    }
}

/// Puhelimen paikallinen maskivarasto — puhelimella tallennettu sessio käyttää
/// samaa segmentointia kuin kello.
enum PhoneWaterMasks {

    private static var directory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watermasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func save(_ mask: WaterMask, spotID: UUID) {
        guard let data = try? JSONEncoder().encode(mask) else { return }
        let url = directory.appendingPathComponent("\(spotID.uuidString)-z\(mask.calibration.zoom).json")
        try? data.write(to: url, options: .atomic)
    }

    static func loadAll() -> [WaterMask] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(WaterMask.self, from: data)
        }
    }
}
