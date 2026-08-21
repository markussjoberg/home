import Foundation
import MapKit

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
        "https://julkinen.traficom.fi/rasteripalvelu/wmts?service=WMTS&request=GetTile&version=1.0.0&layer=Traficom:Merikarttasarja%20C&style=default&tilematrixset=WGS84_Pseudo-Mercator&format=image/png&TileMatrix={z}&TileRow={y}&TileCol={x}"

    static func overlay(template: String, replacesContent: Bool) -> MKTileOverlay {
        let overlay = MKTileOverlay(urlTemplate: template)
        overlay.canReplaceMapContent = replacesContent
        overlay.maximumZ = 18
        overlay.minimumZ = 4
        return overlay
    }
}
