import Foundation
import MapKit
import CoreImage
import UIKit

/// Karttatasot. Maastokartta ja merikartta piirretään WMTS-tiilinä Applen kartan päälle.
/// Kun oma palvelin on määritetty, tiilet haetaan sen proxyn kautta (avaimet
/// palvelimella, tiilivälimuisti palvelimella); muuten suoraan lähteistä.
enum MapLayer: String, CaseIterable, Identifiable {
    case standard
    case terrain
    case marine
    case aerial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Perus"
        case .terrain: return "Maasto"
        case .marine: return "Meri"
        case .aerial: return "Ilma"
        }
    }
}

enum TileOverlays {

    /// MML avoin karttakuvapalvelu suoraan (WMTS REST, EPSG:3857). Vaatii ilmaisen
    /// API-avaimen: https://www.maanmittauslaitos.fi/rajapinnat/api-avaimen-ohje
    static func terrainTemplate(apiKey: String) -> String {
        "https://avoin-karttakuva.maanmittauslaitos.fi/avoin/wmts/1.0.0/maastokartta/default/WGS84_Pseudo-Mercator/{z}/{y}/{x}.png?api-key=\(apiKey)"
    }

    /// Traficomin avoin rasterimerikartta suoraan (WMTS). Osoitteen voi vaihtaa
    /// asetuksista, jos endpoint muuttuu.
    static let defaultMarineTemplate =
        "https://julkinen.traficom.fi/rasteripalvelu/wmts?service=WMTS&request=GetTile&version=1.0.0&layer=Traficom:Merikarttasarjat%20public&style=default&tilematrixset=WGS84_Pseudo-Mercator&format=image/png&TileMatrix=WGS84_Pseudo-Mercator:{z}&TileRow={y}&TileCol={x}"

    /// Lähteiden todelliset zoomialueet (mitattu proxyn läpi 2026-09):
    /// maasto ja ilmakuva vastaavat z2–18, merikartta vain z5–15. Lähteen
    /// maksimin yli zoomattaessa TunedTileOverlay hakee ylimmän tason tiilen
    /// ja rajaa+skaalaa siitä oikean osan — tarkin taso ei koskaan katoa.
    static func overlay(template: String, replacesContent: Bool, muted: Bool = false,
                        minimumZ: Int = 2, sourceMaxZ: Int = 18) -> MKTileOverlay {
        let overlay = TunedTileOverlay(urlTemplate: template, sourceMaxZ: sourceMaxZ, muted: muted)
        overlay.canReplaceMapContent = replacesContent
        overlay.maximumZ = 22
        overlay.minimumZ = minimumZ
        return overlay
    }
}

/// Tiilitaso, joka osaa kaksi asiaa:
/// 1. Overzoom: lähteen maksimitason yli zoomattaessa haetaan ylimmän tason
///    tiili ja rajataan+skaalataan siitä oikea osa — MapKit ei tee tätä itse,
///    joten ilman tätä taso katoaa tarkimman tason jälkeen.
/// 2. Sävytys (muted): maastokartan vesi minttuun, maa harmaasävyyn, vesidata
///    (syvyyskäyrät, nimet — kylläinen sininen) tummana petrolina. Käsittely
///    vain näytölle; kellon offline-kartat ja vesialuemaski käyttävät
///    alkuperäisiä värejä.
final class TunedTileOverlay: MKTileOverlay {

    /// MML ja Traficom kattavat vain Suomen — rajataan taso Suomeen, jolloin
    /// ulkomailla (esim. Norjan-reissu) Applen pohjakartta näkyy normaalisti
    /// eikä taso peitä maailmaa tyhjällä.
    override var boundingMapRect: MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: 70.5, longitude: 18.0))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: 58.5, longitude: 32.5))
        return MKMapRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    private let sourceMaxZ: Int
    private let muted: Bool
    private static let cache = NSCache<NSString, NSData>()
    /// Overzoomin katto: 256/2^5 = 8 px lähdetiilestä — syvemmällä sama kuva.
    private static let maxOverzoomSteps = 5

    init(urlTemplate: String, sourceMaxZ: Int, muted: Bool) {
        self.sourceMaxZ = sourceMaxZ
        self.muted = muted
        super.init(urlTemplate: urlTemplate)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let key = "\(muted ? "m" : "p"):\(urlTemplate?.hashValue ?? 0):\(path.z)/\(path.x)/\(path.y)" as NSString
        if let cached = Self.cache.object(forKey: key) {
            result(cached as Data, nil)
            return
        }

        if path.z <= sourceMaxZ {
            super.loadTile(at: path) { [muted] data, error in
                guard let data else { return result(nil, error) }
                let processed = muted ? (Self.recolor(data) ?? data) : data
                Self.cache.setObject(processed as NSData, forKey: key)
                result(processed, nil)
            }
            return
        }

        // Overzoom: hae lähdetiili maksimitasolta ja rajaa+skaalaa oma osa.
        let steps = min(path.z - sourceMaxZ, Self.maxOverzoomSteps)
        let clampedZ = path.z - steps
        let factor = 1 << (path.z - clampedZ)
        let parent = MKTileOverlayPath(x: path.x / factor, y: path.y / factor,
                                       z: clampedZ, contentScaleFactor: path.contentScaleFactor)
        super.loadTile(at: parent) { [muted] data, error in
            guard let data else { return result(nil, error) }
            let processed = muted ? (Self.recolor(data) ?? data) : data
            guard let cropped = Self.cropAndScale(
                processed,
                subX: path.x - parent.x * factor,
                subY: path.y - parent.y * factor,
                factor: factor
            ) else { return result(processed, nil) }
            Self.cache.setObject(cropped as NSData, forKey: key)
            result(cropped, nil)
        }
    }

    /// Rajaa lähdetiilestä (subX, subY) -osan 1/factor-koossa ja skaalaa 256²:een.
    private static func cropAndScale(_ data: Data, subX: Int, subY: Int, factor: Int) -> Data? {
        guard let source = UIImage(data: data)?.cgImage, factor > 1 else { return nil }
        let side = source.width / factor
        guard side > 0 else { return nil }
        let rect = CGRect(x: subX * side, y: subY * side, width: side, height: side)
        guard let sub = source.cropping(to: rect) else { return nil }
        let out = 256
        guard let context = CGContext(
            data: nil, width: out, height: out, bitsPerComponent: 8,
            bytesPerRow: out * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(sub, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let image = context.makeImage() else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    private static func recolor(_ data: Data) -> Data? {
        guard let source = UIImage(data: data)?.cgImage else { return nil }
        let width = source.width
        let height = source.height
        guard width > 0, height > 0, width * height <= 1024 * 1024 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[offset])
            let g = Double(pixels[offset + 1])
            let b = Double(pixels[offset + 2])
            // Sininen hallitsee → vesialuetta. Kylläisyys erottaa datan
            // täytöstä: syvyyskäyrät ja vesistöjen nimet ovat kylläistä
            // sinistä (sat ≥ ~70 %), täyttö vaaleaa (sat ~10–50 %).
            if b - r >= 18, b - g >= -12, b >= 120 {
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
                if saturation >= 0.68 {
                    // Syvyyskäyrä / nimi / väylä: tumma petroli — erottuu mintusta.
                    pixels[offset] = 22
                    pixels[offset + 1] = 92
                    pixels[offset + 2] = 104
                } else {
                    // Täyttö: kirkkaus talteen, sävy kiinteä mint (~172°).
                    let value = min(1.0, maxC / 255 * 1.03)
                    pixels[offset] = UInt8(value * 0.70 * 255)
                    pixels[offset + 1] = UInt8(value * 0.96 * 255)
                    pixels[offset + 2] = UInt8(value * 0.92 * 255)
                }
            } else {
                // Maa → pehmeä harmaasävy (nostettu musta, ettei teksti huuda).
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                let soft = UInt8(min(255, 42 + luma * 0.84))
                pixels[offset] = soft
                pixels[offset + 1] = soft
                pixels[offset + 2] = soft
            }
        }

        guard let output = context.makeImage() else { return nil }
        return UIImage(cgImage: output).pngData()
    }
}
