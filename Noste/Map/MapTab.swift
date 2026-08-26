import SwiftUI
import SwiftData
import MapKit
import NosteCore

struct MapTab: View {
    @Query(sort: \SpotRecord.name) private var spots: [SpotRecord]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var forecastStore: ForecastStore

    @AppStorage("mmlApiKey") private var mmlApiKey = ""
    @AppStorage("marineTemplate") private var marineTemplate = TileOverlays.defaultMarineTemplate
    @AppStorage("mapLayer") private var layerRaw = MapLayer.standard.rawValue
    @AppStorage(ServerSettings.baseURLKey) private var serverBase = ""
    @AppStorage(ServerSettings.tokenKey) private var serverToken = ""

    @State private var editingSpot: SpotData?

    private var layer: MapLayer { MapLayer(rawValue: layerRaw) ?? .standard }

    /// Maastotiilien lähde: oma palvelin > suora MML > ei saatavilla.
    private var terrainTemplate: String? {
        if let server = ServerSettings.config(base: serverBase, token: serverToken) {
            return ServerSettings.tileTemplate(layer: "terrain", server: server)
        }
        return mmlApiKey.isEmpty ? nil : TileOverlays.terrainTemplate(apiKey: mmlApiKey)
    }

    private var marineTemplateResolved: String {
        if let server = ServerSettings.config(base: serverBase, token: serverToken) {
            return ServerSettings.tileTemplate(layer: "marine", server: server)
        }
        return marineTemplate
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                SpotMapView(
                    spots: spots.map(\.data),
                    layer: layer,
                    terrainTemplate: terrainTemplate,
                    marineTemplate: marineTemplateResolved,
                    onLongPress: { coordinate in
                        editingSpot = SpotData(
                            name: "",
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                    },
                    onSelectSpot: { spot in
                        editingSpot = spot
                    }
                )
                .ignoresSafeArea(edges: .top)

                VStack(spacing: 8) {
                    if layer == .terrain && terrainTemplate == nil {
                        Text("Maastokartta vaatii oman palvelimen tai MML:n API-avaimen — lisää asetuksista.")
                            .font(.footnote)
                            .padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Picker("Taso", selection: $layerRaw) {
                        ForEach(MapLayer.allCases) { layer in
                            Text(layer.displayName).tag(layer.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    Text("Lisää spotti painamalla karttaa pitkään")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }
            .sheet(item: $editingSpot) { spot in
                SpotEditorView(draft: spot) { action in
                    handle(action, original: spot)
                }
            }
        }
    }

    private func handle(_ action: SpotEditorView.Action, original: SpotData) {
        switch action {
        case .save(let data):
            let record: SpotRecord
            if let existing = spots.first(where: { $0.id == data.id }) {
                existing.update(from: data)
                record = existing
            } else {
                record = SpotRecord(from: data)
                modelContext.insert(record)
            }
            try? modelContext.save()
            // @Query päivittyy asynkronisesti — rakenna ajantasainen lista itse.
            var updated = spots.map(\.data).filter { $0.id != data.id }
            updated.append(data)
            let context = modelContext
            Task {
                await forecastStore.refresh(spot: data, force: true, allSpots: updated)
                await ServerClient.shared.backupSpots(updated)
                // Maastoanalyysi kerran per spotti: fetch + avoimuus ilmansuunnittain.
                if record.fetchKmByOctant == nil,
                   let meta = await ServerClient.shared.spotMeta(latitude: data.latitude, longitude: data.longitude) {
                    let sorted = meta.octants.sorted { $0.octant < $1.octant }
                    record.fetchKmByOctant = sorted.map(\.fetchKm)
                    record.exposureByOctant = sorted.map(\.exposure)
                    try? context.save()
                }
            }
        case .delete:
            if let existing = spots.first(where: { $0.id == original.id }) {
                modelContext.delete(existing)
                try? modelContext.save()
                let remaining = spots.map(\.data).filter { $0.id != original.id }
                Task {
                    await ServerClient.shared.backupSpots(remaining)
                }
            }
        case .cancel:
            break
        }
        editingSpot = nil
    }
}

/// MKMapView-kääre: SwiftUI:n Map ei tue tiilitasoja (MKTileOverlay), tämä tukee.
struct SpotMapView: UIViewRepresentable {
    var spots: [SpotData]
    var layer: MapLayer
    /// nil = maastotiilille ei ole lähdettä (ei palvelinta eikä MML-avainta).
    var terrainTemplate: String?
    var marineTemplate: String
    var onLongPress: (CLLocationCoordinate2D) -> Void
    var onSelectSpot: (SpotData) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        // Aloitusnäkymä: Suomi.
        map.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 62.5, longitude: 26.0),
            span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 12)
        )
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        map.addGestureRecognizer(longPress)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        updateOverlay(map, context: context)
        updateAnnotations(map)
    }

    private func updateOverlay(_ map: MKMapView, context: Context) {
        let signature: String
        switch layer {
        case .standard: signature = "standard"
        case .terrain: signature = "terrain:\(terrainTemplate ?? "")"
        case .marine: signature = "marine:\(marineTemplate)"
        }
        guard signature != context.coordinator.overlaySignature else { return }
        context.coordinator.overlaySignature = signature

        map.removeOverlays(map.overlays)
        switch layer {
        case .standard:
            break
        case .terrain:
            if let template = terrainTemplate {
                map.addOverlay(TileOverlays.overlay(template: template, replacesContent: true), level: .aboveLabels)
            }
        case .marine:
            map.addOverlay(TileOverlays.overlay(template: marineTemplate, replacesContent: false), level: .aboveLabels)
        }
    }

    private func updateAnnotations(_ map: MKMapView) {
        let existing = map.annotations.compactMap { $0 as? SpotAnnotation }
        let currentIDs = Set(spots.map(\.id))
        let existingIDs = Set(existing.map(\.spot.id))

        map.removeAnnotations(existing.filter { !currentIDs.contains($0.spot.id) })
        for spot in spots {
            if let annotation = existing.first(where: { $0.spot.id == spot.id }) {
                annotation.spot = spot
                annotation.coordinate = CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
            } else if !existingIDs.contains(spot.id) {
                map.addAnnotation(SpotAnnotation(spot: spot))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: SpotMapView
        var overlaySignature = ""

        init(parent: SpotMapView) {
            self.parent = parent
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map = gesture.view as? MKMapView else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            parent.onLongPress(coordinate)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tiles)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let spotAnnotation = annotation as? SpotAnnotation else { return nil }
            let identifier = "spot"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = true
            view.markerTintColor = spotAnnotation.spot.isFavorite ? .systemOrange : .systemTeal
            view.glyphImage = UIImage(systemName: spotAnnotation.spot.waterType == .sea ? "water.waves" : "drop")
            view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let annotation = view.annotation as? SpotAnnotation else { return }
            parent.onSelectSpot(annotation.spot)
        }
    }
}

final class SpotAnnotation: NSObject, MKAnnotation {
    var spot: SpotData
    dynamic var coordinate: CLLocationCoordinate2D

    var title: String? { spot.name.isEmpty ? "Nimetön spotti" : spot.name }
    var subtitle: String? { spot.waterType.displayName }

    init(spot: SpotData) {
        self.spot = spot
        self.coordinate = CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
    }
}
