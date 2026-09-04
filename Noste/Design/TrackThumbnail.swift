import SwiftUI
import MapKit
import NosteCore

/// Session pieni karttakuva listaan: MKMapSnapshotter tummalla kartalla ja
/// jälki piirrettynä päälle. Kuvat välimuistissa, jotta lista rullaa kevyesti.
struct TrackThumbnail: View {
    let id: UUID
    let track: [TrackPoint]
    /// Ilman jälkeä näytetään lajin kuvake, ei "ei sijaintia" -virhettä.
    var sport: Sport? = nil
    var size: CGSize = CGSize(width: 96, height: 96)

    @State private var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceElevated)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if track.count < 2 {
                if let sport {
                    SportIcon(sport: sport, size: 34).foregroundStyle(Theme.wind.opacity(0.7))
                } else {
                    Image(systemName: "location.slash").font(.title3).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: id) { await load() }
    }

    private func load() async {
        let key = id.uuidString as NSString
        if let cached = Self.cache.object(forKey: key) { image = cached; return }
        guard track.count >= 2 else { return }
        let coords = track.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.004, (lats.max()! - lats.min()!) * 1.4),
                                    longitudeDelta: max(0.006, (lons.max()! - lons.min()!) * 1.4))
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = size
        options.scale = 2
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = config
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return }
        let rendered = UIGraphicsImageRenderer(size: size).image { ctx in
            snapshot.image.draw(at: .zero)
            let path = UIBezierPath()
            for (i, c) in coords.enumerated() {
                let p = snapshot.point(for: c)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.lineWidth = 2.5
            path.lineJoinStyle = .round
            UIColor(Theme.ride).setStroke()
            path.stroke()
            _ = ctx
        }
        Self.cache.setObject(rendered, forKey: key)
        image = rendered
    }
}
