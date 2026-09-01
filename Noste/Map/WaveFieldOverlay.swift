import SwiftUI
import MapKit

/// Aaltokenttä kartan päällä: aallonkorkeus värjättynä merialueelle ja
/// kulkusuunta nuolina hilan pisteissä. Sama resepti kuin tuulikentässä
/// (karkea Open-Meteo-hila palvelimelta), mutta MapKitin omana overlayna:
/// liimautuu karttaan panoroidessa ja jää chippien alle. Staattinen — MapKit
/// piirtää tiilet uudelleen vain kun data tai zoom vaihtuu.
struct WaveCell: Codable {
    var latitude: Double
    var longitude: Double
    /// Merkitsevä aallonkorkeus (m).
    var height: Double
    /// Aaltojen tulosuunta (°).
    var direction: Double
    /// Aaltoperiodi (s).
    var period: Double
}

/// Hila ja sen solutiheys haetun alueen mukaan. Maapisteet puuttuvat
/// (palvelin karsi null-arvot), joten pehmennys jätetään maan yllä tyhjäksi.
struct WaveField {
    var cells: [WaveCell]
    var spacingLat: Double
    var spacingLon: Double

    /// spanLat/spanLon = palvelimen todella hakema alue (laajennettu
    /// vähimmäiskokoon, jotta karkea aaltomalli erottuu myös lähizoomilla).
    init(cells: [WaveCell], spanLat: Double, spanLon: Double, gridSize: Int = 9) {
        self.cells = cells
        spacingLat = max(spanLat / Double(gridSize - 1), 1e-4)
        spacingLon = max(spanLon / Double(gridSize - 1), 1e-4)
    }

    var isEmpty: Bool { cells.isEmpty }

    /// Gaussisesti painotettu korkeus pisteessä sekä painojen summa
    /// (pieni summa = ei vesidataa lähellä → jätetään värjäämättä).
    func height(atLat lat: Double, lon: Double) -> (height: Double, weight: Double) {
        var sumH = 0.0, sumW = 0.0
        for cell in cells {
            let dLat = (cell.latitude - lat) / spacingLat
            let dLon = (cell.longitude - lon) / spacingLon
            let dist2 = dLat * dLat + dLon * dLon
            guard dist2 < 2.25 else { continue } // 1,5 solun säde: väri ei valu kauas maalle
            let weight = exp(-dist2 / 0.5) // σ = 0,5 solua
            sumH += cell.height * weight
            sumW += weight
        }
        return sumW > 0 ? (sumH / sumW, sumW) : (0, 0)
    }

    /// Väriasteikko Itämeren mittakaavassa: 0,3 m on jo foilattavaa,
    /// 2 m kovaa keliä. Alapää on vaalea sininen, jotta tyynikin meri erottuu
    /// satelliittikuvan tummasta vedestä: sininen → turkoosi → vihreä →
    /// keltainen → oranssi → magenta.
    static let colorStops: [(height: Double, rgb: (Double, Double, Double))] = [
        (0.0, (0.45, 0.65, 1.00)),
        (0.4, (0.25, 0.85, 0.95)),
        (0.8, (0.55, 0.92, 0.40)),
        (1.2, (0.98, 0.85, 0.20)),
        (1.8, (0.98, 0.50, 0.15)),
        (2.6, (0.90, 0.20, 0.65)),
    ]

    static func rgb(forHeight h: Double) -> (Double, Double, Double) {
        let stops = colorStops
        if h <= stops[0].height { return stops[0].rgb }
        for i in 1..<stops.count where h <= stops[i].height {
            let (h0, c0) = stops[i - 1]
            let (h1, c1) = stops[i]
            let t = (h - h0) / (h1 - h0)
            return (c0.0 + (c1.0 - c0.0) * t, c0.1 + (c1.1 - c0.1) * t, c0.2 + (c1.2 - c0.2) * t)
        }
        return stops[stops.count - 1].rgb
    }

    static func color(forHeight h: Double) -> Color {
        let c = rgb(forHeight: h)
        return Color(red: c.0, green: c.1, blue: c.2)
    }
}

/// MKOverlay-kuori: kattaa koko maailman, piirtäjä rajaa itse datan mukaan.
final class WaveFieldMapOverlay: NSObject, MKOverlay {
    let field: WaveField
    init(field: WaveField) { self.field = field }
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: MKMapRect.world.midX, y: MKMapRect.world.midY).coordinate
    }
    var boundingMapRect: MKMapRect { .world }
}

final class WaveFieldRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let field = (overlay as? WaveFieldMapOverlay)?.field, !field.isEmpty else { return }
        let scale = Double(zoomScale)

        // Värikenttä ~12 pt:n ruutuina. Ruudukko ankkuroidaan maailman
        // koordinaatteihin, jotta tiilien rajat eivät näy saumoina; reunoilla
        // painon mukaan häivytys, niin että väri loppuu pehmeästi rantaan.
        let block = 12.0 / scale
        ctx.setShouldAntialias(false)
        var y = floor(mapRect.minY / block) * block
        while y < mapRect.maxY {
            var x = floor(mapRect.minX / block) * block
            while x < mapRect.maxX {
                let center = MKMapPoint(x: x + block / 2, y: y + block / 2).coordinate
                let sample = field.height(atLat: center.latitude, lon: center.longitude)
                if sample.weight > 0.2 {
                    let alpha = min(1, sample.weight / 0.7) * 0.5
                    let c = WaveField.rgb(forHeight: sample.height)
                    ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
                    ctx.fill(rect(for: MKMapRect(x: x, y: y, width: block, height: block)))
                }
                x += block
            }
            y += block
        }

        // Kulkusuunta hilan pisteissä: suunta on mistä aallot tulevat →
        // nuoli osoittaa minne ne kulkevat. Pituus periodin mukaan.
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.2 / scale)
        ctx.setLineCap(.round)
        let reach = 40.0 / scale
        let visible = mapRect.insetBy(dx: -reach, dy: -reach)
        for cell in field.cells {
            let mapPoint = MKMapPoint(CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude))
            guard visible.contains(mapPoint) else { continue }
            let origin = point(for: mapPoint)
            let rad = (cell.direction + 180) * .pi / 180
            let length = (5 + min(cell.period, 9) * 1.4) / scale
            let tip = CGPoint(x: origin.x + sin(rad) * length, y: origin.y - cos(rad) * length)
            ctx.move(to: origin)
            ctx.addLine(to: tip)
            let head = 3.5 / scale
            for side in [-1.0, 1.0] {
                let angle = rad + .pi + side * 0.5
                ctx.move(to: tip)
                ctx.addLine(to: CGPoint(x: tip.x + sin(angle) * head, y: tip.y - cos(angle) * head))
            }
            ctx.strokePath()
        }
    }
}
