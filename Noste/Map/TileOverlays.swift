import Foundation
import MapKit

/// Karttatasot. Maastokartta ja merikartta piirretään WMTS-tiilinä Applen kartan päälle.
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

    /// MML avoin karttakuvapalvelu (WMTS REST, EPSG:3857). Vaatii ilmaisen API-avaimen:
    /// https://www.maanmittauslaitos.fi/rajapinnat/api-avaimen-ohje
    static func terrainOverlay(apiKey: String) -> MKTileOverlay {
        let template = "https://avoin-karttakuva.maanmittauslaitos.fi/avoin/wmts/1.0.0/maastokartta/default/WGS84_Pseudo-Mercator/{z}/{y}/{x}.png?api-key=\(apiKey)"
        let overlay = MKTileOverlay(urlTemplate: template)
        overlay.canReplaceMapContent = true
        overlay.maximumZ = 18
        overlay.minimumZ = 4
        return overlay
    }

    /// Merikarttataso. Oletuspohja Traficomin avoin rasterimerikartta (WMTS);
    /// osoitteen voi vaihtaa asetuksista, jos endpoint muuttuu.
    static func marineOverlay(urlTemplate: String) -> MKTileOverlay {
        let overlay = MKTileOverlay(urlTemplate: urlTemplate)
        overlay.canReplaceMapContent = false
        overlay.maximumZ = 17
        overlay.minimumZ = 4
        return overlay
    }

    static let defaultMarineTemplate =
        "https://julkinen.traficom.fi/rasteripalvelu/wmts?service=WMTS&request=GetTile&version=1.0.0&layer=Traficom:Merikarttasarja%20C&style=default&tilematrixset=WGS84_Pseudo-Mercator&format=image/png&TileMatrix={z}&TileRow={y}&TileCol={x}"
}
