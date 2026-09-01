import SwiftUI
import MapKit

/// Aaltokenttä kartan päällä FMI:n merisään tapaan: aallonkorkeus yhden sävyn
/// tummuutena vain vesialueella, kulkusuunta nuolina säännöllisessä ruudukossa.
/// Hila tulee palvelimelta (Open-Meteo marine, karkea ~5–10 km); vesialue
/// eristetään Applen peruskartan snapshotista samalla pikselivärikikalla kuin
/// kellon vesimaski. Poijuhavainnot nudjaavat mallia lähialueellaan.
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

/// Poijukorjaus: ln(havaittu / mallinnettu) poijun kohdalla, jo ennusteen
/// etäisyyden mukaan vaimennettuna.
struct WaveCorrection {
    var latitude: Double
    var longitude: Double
    var logRatio: Double
}

struct WaveField {
    var cells: [WaveCell]
    var spacingLat: Double
    var spacingLon: Double
    var mask: WaterSnapshotMask?
    var corrections: [WaveCorrection]

    /// spanLat/spanLon = palvelimen todella hakema alue (laajennettu
    /// vähimmäiskokoon, jotta karkea aaltomalli erottuu myös lähizoomilla).
    init(cells: [WaveCell], spanLat: Double, spanLon: Double, gridSize: Int = 9,
         mask: WaterSnapshotMask? = nil, corrections: [WaveCorrection] = []) {
        self.cells = cells
        spacingLat = max(spanLat / Double(gridSize - 1), 1e-4)
        spacingLon = max(spanLon / Double(gridSize - 1), 1e-4)
        self.mask = mask
        self.corrections = corrections
    }

    var isEmpty: Bool { cells.isEmpty }

    struct Sample {
        var height: Double
        /// Kulkusuunnan yksikkövektori (itä, pohjoinen) — painotettu keskiarvo.
        var u: Double
        var v: Double
        var period: Double
        /// Painojen summa: pieni = ei vesidataa lähellä.
        var weight: Double
    }

    /// Gaussisesti painotettu näyte lähisoluista (σ = 0,5 solua, säde 1,5 solua
    /// — väri ei valu kauas maalle). Korkeus poijukorjattuna.
    func sample(atLat lat: Double, lon: Double) -> Sample {
        var sumH = 0.0, sumU = 0.0, sumV = 0.0, sumP = 0.0, sumW = 0.0
        for cell in cells {
            let dLat = (cell.latitude - lat) / spacingLat
            let dLon = (cell.longitude - lon) / spacingLon
            let dist2 = dLat * dLat + dLon * dLon
            guard dist2 < 2.25 else { continue }
            let weight = exp(-dist2 / 0.5)
            // Suunta = mistä aallot tulevat → kulku vastakkaiseen suuntaan.
            let rad = (cell.direction + 180) * .pi / 180
            sumU += sin(rad) * weight
            sumV += cos(rad) * weight
            sumH += cell.height * weight
            sumP += cell.period * weight
            sumW += weight
        }
        guard sumW > 0 else { return Sample(height: 0, u: 0, v: 0, period: 0, weight: 0) }
        let height = sumH / sumW * correctionFactor(atLat: lat, lon: lon)
        return Sample(height: height, u: sumU / sumW, v: sumV / sumW, period: sumP / sumW, weight: sumW)
    }

    func height(atLat lat: Double, lon: Double) -> (height: Double, weight: Double) {
        let s = sample(atLat: lat, lon: lon)
        return (s.height, s.weight)
    }

    /// Poijunudjaus: log-suhteiden gaussinen keskiarvo (σ ≈ 60 km). Taustapaino
    /// vetää kohti puhdasta mallia kun poijut ovat kaukana.
    func correctionFactor(atLat lat: Double, lon: Double) -> Double {
        guard !corrections.isEmpty else { return 1 }
        var sum = 0.0
        var sumW = 0.5
        for c in corrections {
            let dLat = (c.latitude - lat) * 111.0
            let dLon = (c.longitude - lon) * 111.0 * cos(lat * .pi / 180)
            let d2 = dLat * dLat + dLon * dLon
            let w = exp(-d2 / (2 * 60 * 60))
            sum += c.logRatio * w
            sumW += w
        }
        return exp(sum / sumW)
    }

    /// FMI:n merisään tapainen asteikko: yksi sininen sävy, joka tummenee
    /// korkeuden mukaan. 0,5 m foilattavaa, 2 m kovaa, 3 m+ violettia.
    static let colorStops: [(height: Double, rgb: (Double, Double, Double))] = [
        (0.0, (0.80, 0.91, 1.00)),
        (0.5, (0.50, 0.75, 0.98)),
        (1.0, (0.22, 0.52, 0.92)),
        (1.5, (0.12, 0.33, 0.80)),
        (2.0, (0.09, 0.17, 0.62)),
        (3.0, (0.28, 0.06, 0.48)),
    ]
    static let fillAlpha = 0.72

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

// MARK: - Vesimaski Applen peruskartasta

/// Vesialue kentän alueelta: Applen peruskartan snapshot luokitellaan pikseli
/// kerrallaan vedeksi/maaksi. Vesiväri kalibroidaan itse aaltosoluista (ne ovat
/// varmasti vettä), joten teemasta tai kartan väreistä ei tarvitse tietää.
struct WaterSnapshotMask {
    let width: Int
    let height: Int
    /// Rivi kerrallaan, true = vettä.
    let water: [Bool]
    /// Lineaarinen kuvaus: x = ax·lon + bx, y = ay·mercY(lat) + by (pikseleitä).
    let ax: Double, bx: Double, ay: Double, by: Double
    /// Kuvan kattama alue karttapisteinä (Mercator ↔ Mercator, joten lineaarinen).
    let mapRect: MKMapRect

    static let size = 768

    static func mercY(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }
    static func latitude(mercY y: Double) -> Double { (2 * atan(exp(y)) - .pi / 2) * 180 / .pi }

    func pixel(lat: Double, lon: Double) -> (x: Int, y: Int)? {
        let px = ax * lon + bx
        let py = ay * Self.mercY(lat) + by
        guard px >= 0, py >= 0, px < Double(width), py < Double(height) else { return nil }
        return (Int(px), Int(py))
    }

    /// nil = kuvan ulkopuolella (ei tietoa).
    func isWater(lat: Double, lon: Double) -> Bool? {
        guard let p = pixel(lat: lat, lon: lon) else { return nil }
        return water[p.y * width + p.x]
    }

    func coordinate(pixelX x: Double, y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: Self.latitude(mercY: (y - by) / ay), longitude: (x - bx) / ax)
    }

    /// Ottaa snapshotin ja luokittelee. nil jos snapshot ei onnistu (offline).
    @MainActor
    static func build(center: CLLocationCoordinate2D, spanLat: Double, spanLon: Double, waterSamples: [CLLocationCoordinate2D]) async -> WaterSnapshotMask? {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon))
        options.size = CGSize(width: size, height: size)
        options.scale = 1
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        config.showsTraffic = false
        options.preferredConfiguration = config
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        // Kuvaus koordinaateista pikseleihin kahdesta tunnetusta pisteestä.
        let west = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude - spanLon / 4)
        let east = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude + spanLon / 4)
        let south = CLLocationCoordinate2D(latitude: center.latitude - spanLat / 4, longitude: center.longitude)
        let north = CLLocationCoordinate2D(latitude: center.latitude + spanLat / 4, longitude: center.longitude)
        let pw = snapshot.point(for: west), pe = snapshot.point(for: east)
        let ps = snapshot.point(for: south), pn = snapshot.point(for: north)
        let ax = Double(pe.x - pw.x) / (east.longitude - west.longitude)
        let bx = Double(pw.x) - ax * west.longitude
        let ay = Double(ps.y - pn.y) / (mercY(south.latitude) - mercY(north.latitude))
        let by = Double(pn.y) - ay * mercY(north.latitude)
        guard ax.isFinite, ay.isFinite, ax != 0, ay != 0 else { return nil }

        guard let cgImage = snapshot.image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> WaterSnapshotMask? in
            classify(cgImage: cgImage, ax: ax, bx: bx, ay: ay, by: by, waterSamples: waterSamples)
        }.value
    }

    private static func classify(cgImage: CGImage, ax: Double, bx: Double, ay: Double, by: Double,
                                 waterSamples: [CLLocationCoordinate2D]) -> WaterSnapshotMask? {
        let w = size, h = size
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Vesiväri = aaltosolujen kohdalta luettujen pikselien mediaani.
        var rs: [Int] = [], gs: [Int] = [], bs: [Int] = []
        for sample in waterSamples {
            let px = ax * sample.longitude + bx
            let py = ay * mercY(sample.latitude) + by
            guard px >= 0, py >= 0, px < Double(w), py < Double(h) else { continue }
            let offset = (Int(py) * w + Int(px)) * 4
            rs.append(Int(pixels[offset])); gs.append(Int(pixels[offset + 1])); bs.append(Int(pixels[offset + 2]))
        }
        func median(_ v: [Int]) -> Int { let s = v.sorted(); return s[s.count / 2] }
        // Oletus (Applen vaalea kartta), jos yhtään solua ei osu kuvaan.
        let water = rs.isEmpty ? (r: 165, g: 205, b: 245) : (r: median(rs), g: median(gs), b: median(bs))

        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            let dr = abs(Int(pixels[o]) - water.r)
            let dg = abs(Int(pixels[o + 1]) - water.g)
            let db = abs(Int(pixels[o + 2]) - water.b)
            mask[i] = dr + dg + db <= 48
        }

        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: latitude(mercY: (0 - by) / ay), longitude: (0 - bx) / ax))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: latitude(mercY: (Double(h) - by) / ay), longitude: (Double(w) - bx) / ax))
        let rect = MKMapRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        return WaterSnapshotMask(width: w, height: h, water: mask, ax: ax, bx: bx, ay: ay, by: by, mapRect: rect)
    }
}

// MARK: - Rasteri

/// Valmis kuva kentästä maskin resoluutiolla: klipattu rantaviivaan, piirretään
/// yhdellä vedolla joka tiileen. Kenttä näytteistetään karkeasti ja interpoloidaan.
struct WaveFieldRaster {
    let id = UUID()
    let image: CGImage
    let mapRect: MKMapRect

    static func build(field: WaveField) -> WaveFieldRaster? {
        guard let mask = field.mask, !field.isEmpty else { return nil }
        let w = mask.width, h = mask.height
        let coarse = 96
        var heights = [Double](repeating: 0, count: coarse * coarse)
        var weights = [Double](repeating: 0, count: coarse * coarse)
        for j in 0..<coarse {
            for i in 0..<coarse {
                let coord = mask.coordinate(pixelX: (Double(i) + 0.5) / Double(coarse) * Double(w),
                                            y: (Double(j) + 0.5) / Double(coarse) * Double(h))
                let s = field.height(atLat: coord.latitude, lon: coord.longitude)
                heights[j * coarse + i] = s.height
                weights[j * coarse + i] = s.weight
            }
        }

        // Väri-LUT 0…3,2 m.
        let lut: [(UInt8, UInt8, UInt8)] = (0..<256).map { i in
            let c = WaveField.rgb(forHeight: Double(i) / 80)
            return (UInt8(c.0 * 255), UInt8(c.1 * 255), UInt8(c.2 * 255))
        }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let fy = max(0, min(Double(coarse - 1), (Double(y) + 0.5) / Double(h) * Double(coarse) - 0.5))
            let j0 = Int(fy), j1 = min(coarse - 1, j0 + 1)
            let ty = fy - Double(j0)
            for x in 0..<w {
                let idx = y * w + x
                guard mask.water[idx] else { continue }
                let fx = max(0, min(Double(coarse - 1), (Double(x) + 0.5) / Double(w) * Double(coarse) - 0.5))
                let i0 = Int(fx), i1 = min(coarse - 1, i0 + 1)
                let tx = fx - Double(i0)
                func lerp(_ a: [Double]) -> Double {
                    let top = a[j0 * coarse + i0] * (1 - tx) + a[j0 * coarse + i1] * tx
                    let bottom = a[j1 * coarse + i0] * (1 - tx) + a[j1 * coarse + i1] * tx
                    return top * (1 - ty) + bottom * ty
                }
                let weight = lerp(weights)
                guard weight > 0.2 else { continue }
                let height = lerp(heights)
                let alpha = WaveField.fillAlpha * min(1, weight / 0.6)
                let c = lut[max(0, min(255, Int(height * 80)))]
                let o = idx * 4
                pixels[o] = UInt8(Double(c.0) * alpha)
                pixels[o + 1] = UInt8(Double(c.1) * alpha)
                pixels[o + 2] = UInt8(Double(c.2) * alpha)
                pixels[o + 3] = UInt8(alpha * 255)
            }
        }

        guard let context = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { return nil }
        return WaveFieldRaster(image: image, mapRect: mask.mapRect)
    }
}

// MARK: - MapKit-overlay

/// MKOverlay-kuori: kattaa koko maailman, piirtäjä rajaa itse datan mukaan.
final class WaveFieldMapOverlay: NSObject, MKOverlay {
    let field: WaveField
    let raster: WaveFieldRaster?
    init(field: WaveField, raster: WaveFieldRaster?) {
        self.field = field
        self.raster = raster
    }
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: MKMapRect.world.midX, y: MKMapRect.world.midY).coordinate
    }
    var boundingMapRect: MKMapRect { .world }
}

final class WaveFieldRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let overlay = overlay as? WaveFieldMapOverlay, !overlay.field.isEmpty else { return }
        let field = overlay.field
        let scale = Double(zoomScale)

        if let raster = overlay.raster {
            // Kuva on jo klipattu vesialueeseen: yksi veto per tiili.
            let rect = self.rect(for: raster.mapRect)
            ctx.saveGState()
            ctx.interpolationQuality = .medium
            // MapKitin konteksti kasvaa alaspäin, CGImage piirtyy ylösalaisin → käännetään.
            ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(raster.image, in: rect)
            ctx.restoreGState()
        } else {
            // Ilman maskia (offline / snapshot kesken): karkeat ruudut, reunat häivytettynä.
            let block = 12.0 / scale
            ctx.setShouldAntialias(false)
            var y = floor(mapRect.minY / block) * block
            while y < mapRect.maxY {
                var x = floor(mapRect.minX / block) * block
                while x < mapRect.maxX {
                    let center = MKMapPoint(x: x + block / 2, y: y + block / 2).coordinate
                    let sample = field.height(atLat: center.latitude, lon: center.longitude)
                    if sample.weight > 0.2 {
                        let alpha = min(1, sample.weight / 0.6) * WaveField.fillAlpha
                        let c = WaveField.rgb(forHeight: sample.height)
                        ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
                        ctx.fill(rect(for: MKMapRect(x: x, y: y, width: block, height: block)))
                    }
                    x += block
                }
                y += block
            }
            ctx.setShouldAntialias(true)
        }

        // Kulkusuunta säännöllisessä ~64 pt ruudukossa (maailmaan ankkuroituna):
        // nuoli osoittaa minne aallot kulkevat, pituus periodin mukaan.
        let step = 64.0 / scale
        let reach = step
        var y = floor((mapRect.minY - reach) / step) * step
        while y < mapRect.maxY + reach {
            var x = floor((mapRect.minX - reach) / step) * step
            while x < mapRect.maxX + reach {
                defer { x += step }
                let mapPoint = MKMapPoint(x: x, y: y)
                let coord = mapPoint.coordinate
                if let mask = field.mask, mask.isWater(lat: coord.latitude, lon: coord.longitude) != true { continue }
                let s = field.sample(atLat: coord.latitude, lon: coord.longitude)
                guard s.weight > 0.3, s.u != 0 || s.v != 0 else { continue }
                let origin = point(for: mapPoint)
                let angle = atan2(s.u, s.v)
                let length = (6 + min(s.period, 9) * 1.2) / scale
                let tip = CGPoint(x: origin.x + sin(angle) * length, y: origin.y - cos(angle) * length)
                let head = 3.5 / scale
                let path = CGMutablePath()
                path.move(to: origin)
                path.addLine(to: tip)
                for side in [-1.0, 1.0] {
                    let a = angle + .pi + side * 0.5
                    path.move(to: tip)
                    path.addLine(to: CGPoint(x: tip.x + sin(a) * head, y: tip.y - cos(a) * head))
                }
                // Tumma reunus + valkoinen viiva: erottuu sekä vaaleasta että tummasta täytöstä.
                ctx.setLineCap(.round)
                ctx.setLineWidth(2.6 / scale)
                ctx.setStrokeColor(UIColor(red: 0.03, green: 0.08, blue: 0.25, alpha: 0.35).cgColor)
                ctx.addPath(path)
                ctx.strokePath()
                ctx.setLineWidth(1.2 / scale)
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
                ctx.addPath(path)
                ctx.strokePath()
            }
            y += step
        }
    }
}

/// Väriasteikko karttaan (aallonkorkeus metreinä).
struct WaveLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Aallot")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LinearGradient(
                stops: WaveField.colorStops.map { .init(color: WaveField.color(forHeight: $0.height), location: $0.height / 3.0) },
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 96, height: 8)
            .clipShape(Capsule())
            .overlay(alignment: .leading) { Text("0").font(.system(size: 8)).offset(y: 10) }
            .overlay(alignment: .center) { Text("1,5").font(.system(size: 8)).offset(y: 10) }
            .overlay(alignment: .trailing) { Text("3 m").font(.system(size: 8)).offset(y: 10) }
        }
        .padding(.bottom, 8)
    }
}
