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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Perus"
        case .terrain: return "Maasto"
        case .marine: return "Meri"
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

    static func overlay(template: String, replacesContent: Bool, muted: Bool = false) -> MKTileOverlay {
        let overlay = muted ? MutedTileOverlay(urlTemplate: template) : MKTileOverlay(urlTemplate: template)
        overlay.canReplaceMapContent = replacesContent
        overlay.maximumZ = 18
        overlay.minimumZ = 4
        return overlay
    }
}

/// Maastokartan sävytys Nosten ilmeeseen: vesialueet ovat pääasia, joten
/// maa vedetään pehmeäksi harmaasävyksi ja vesi sävytetään ocean/mint-suuntaan
/// (kirkkaus säilyy → syvyyskäyrät ja rantaviivat erottuvat yhä). Käsittely
/// tehdään per pikseli vain näytölle piirrettäville tiilille; kellon offline-
/// kartat ja vesialuemaski käyttävät alkuperäisiä värejä.
final class MutedTileOverlay: MKTileOverlay {

    private static let cache = NSCache<NSString, NSData>()

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let key = "\(path.z)/\(path.x)/\(path.y)" as NSString
        if let cached = Self.cache.object(forKey: key) {
            result(cached as Data, nil)
            return
        }
        super.loadTile(at: path) { data, error in
            guard let data, let adjusted = Self.recolor(data) else {
                result(data, error)
                return
            }
            Self.cache.setObject(adjusted as NSData, forKey: key)
            result(adjusted, nil)
        }
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
            // Sininen hallitsee → vesi (myös syvyyskäyrät ja vesitekstit).
            if b - r >= 18, b - g >= -12, b >= 120 {
                // Kirkkaus talteen, sävy kiinteä mint (~172°, sat 0,30).
                let value = min(1.0, max(r, max(g, b)) / 255 * 1.03)
                pixels[offset] = UInt8(value * 0.70 * 255)
                pixels[offset + 1] = UInt8(value * 0.96 * 255)
                pixels[offset + 2] = UInt8(value * 0.92 * 255)
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
