import SwiftUI
import CoreLocation
import NosteCore

/// Offline-kartta: puhelimen ompelema maastokarttakuva spotin ympäriltä,
/// päälle piirretään oma sijainti, spotti ja kuljettu jälki — täysin ilman
/// verkkoa. Napautus vaihtaa zoomia (z15 ≈ 2,5 km / z14 ≈ 5 km katselualue).
struct OfflineMapView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityManager
    @EnvironmentObject private var workout: WorkoutManager
    @State private var detailZoom = true

    var body: some View {
        Group {
            if let entry = currentMap() {
                mapCanvas(entry.map, spot: entry.spot)
                    .onTapGesture { detailZoom.toggle() }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "map")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Ei offline-karttaa — merkitse spotti suosikiksi ja avaa puhelimen appi kerran verkossa.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }

    /// Kartta lähimmältä spotilta, jolle kuva löytyy; muuten ensimmäinen saatavilla.
    private func currentMap() -> (map: WatchConnectivityManager.OfflineMap, spot: SpotData?)? {
        let spots = connectivity.snapshot?.spots ?? []
        let zoom = detailZoom ? 15 : 14

        var candidates: [(distance: Double, spotID: UUID)] = []
        for spotID in connectivity.offlineMaps.keys {
            let spot = spots.first { $0.id == spotID }
            if let coordinate = workout.lastCoordinate, let spot {
                candidates.append((GeoMath.distanceMeters(
                    lat1: coordinate.latitude, lon1: coordinate.longitude,
                    lat2: spot.latitude, lon2: spot.longitude
                ), spotID))
            } else {
                candidates.append((.infinity, spotID))
            }
        }
        guard let chosen = candidates.min(by: { $0.distance < $1.distance }) else { return nil }
        let zooms = connectivity.offlineMaps[chosen.spotID] ?? [:]
        guard let map = zooms[zoom] ?? zooms.values.first else { return nil }
        return (map, spots.first { $0.id == chosen.spotID })
    }

    private func mapCanvas(_ map: WatchConnectivityManager.OfflineMap, spot: SpotData?) -> some View {
        let calibration = map.calibration
        let uiImage = UIImage(contentsOfFile: connectivity.mapImageURL(map).path)

        return Canvas { context, size in
            guard let uiImage else { return }

            // Keskitä käyttäjään; ilman sijaintia spottiin (kuvan keskelle).
            let focus: (x: Double, y: Double)
            if let coordinate = workout.lastCoordinate,
               calibration.contains(latitude: coordinate.latitude, longitude: coordinate.longitude, margin: 128) {
                focus = calibration.point(latitude: coordinate.latitude, longitude: coordinate.longitude)
            } else if let spot {
                focus = calibration.point(latitude: spot.latitude, longitude: spot.longitude)
            } else {
                focus = (Double(calibration.imageSize) / 2, Double(calibration.imageSize) / 2)
            }
            let offsetX = focus.x - size.width / 2
            let offsetY = focus.y - size.height / 2
            func toScreen(_ p: (x: Double, y: Double)) -> CGPoint {
                CGPoint(x: p.x - offsetX, y: p.y - offsetY)
            }

            let imageSize = CGFloat(calibration.imageSize)
            context.draw(
                Image(uiImage: uiImage),
                in: CGRect(x: -offsetX, y: -offsetY, width: imageSize, height: imageSize)
            )

            // Kuljettu jälki.
            let crumbs = workout.breadcrumb
            if crumbs.count > 1 {
                var path = Path()
                path.move(to: toScreen(calibration.point(latitude: crumbs[0].latitude, longitude: crumbs[0].longitude)))
                for point in crumbs.dropFirst() {
                    path.addLine(to: toScreen(calibration.point(latitude: point.latitude, longitude: point.longitude)))
                }
                context.stroke(path, with: .color(.cyan), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            // Spotti.
            if let spot {
                let p = toScreen(calibration.point(latitude: spot.latitude, longitude: spot.longitude))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.orange))
            }

            // Oma sijainti.
            if let coordinate = workout.lastCoordinate {
                let p = toScreen(calibration.point(latitude: coordinate.latitude, longitude: coordinate.longitude))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.blue))
            }

            // Mittakaavajana ja zoomivihje.
            let meters = WebMercator.metersPerPixel(latitude: spot?.latitude ?? 60, zoom: calibration.zoom) * 60
            context.draw(
                Text(String(format: "%.0f m — z%d", meters, calibration.zoom))
                    .font(.system(size: 11))
                    .foregroundStyle(.white),
                at: CGPoint(x: size.width / 2, y: size.height - 10)
            )
        }
        .ignoresSafeArea(edges: .bottom)
    }
}
