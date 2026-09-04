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

    // Rantainfra-kerros: OSM + Lipas palvelimen kautta, haku näkyvältä alueelta.
    @AppStorage("mapPlacesEnabled") private var placesEnabled = false
    @AppStorage("mapPlacesFilter") private var placesFilterRaw = ""
    @State private var mapPlaces: [ServerClient.Place] = []
    @State private var placesCache: [String: [ServerClient.Place]] = [:]
    @State private var selectedPlace: ServerClient.Place?
    @State private var showPlaceFilter = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var zoomedOut = false

    // Merisää-kerros: FMI:n poijut + tuuliasemat näkyvältä alueelta.
    @AppStorage("mapSeaState") private var seaStateEnabled = false
    /// Kenttien tila ja logiikka (hilat, aikajana, maski, poijunudjaus).
    @StateObject private var fields = MarineFieldsModel()
    /// Ennustepiste (Windy-tyyliin): napautettu kohta, jonka arvot luetaan kentistä.
    @State private var probeCoordinate: CLLocationCoordinate2D?
    /// Kartalta napautettu oma spotti: kortti, ei suoraan editori.
    @State private var selectedSpot: SpotData?
    /// Yhteisöviesti (esim. poisto eteni ehdotuksena, koska muut ovat lisänneet sisältöä).
    @State private var communityNotice: String?
    /// Panoroinnin/zoomin aikana tuulipartikkelit piilotetaan: SwiftUI-kerros
    /// ei seuraa karttaa liikkeen aikana, joten ne hyppäisivät lopussa.
    @State private var isMapMoving = false
    @State private var currentRegion: MKCoordinateRegion?

    // Julkiset spotit: yhteinen pooli palvelimelta, kaikkien nähtävillä.
    @State private var publicSpots: [ServerClient.PublicSpot] = []
    @State private var selectedPublicSpot: ServerClient.PublicSpot?
    /// Ennuste mille tahansa pisteelle (rantakohde tms.) ilman spotin luontia.
    @State private var forecastPoint: SpotData?
    @State private var mapCenter = CLLocationCoordinate2D(latitude: 62.5, longitude: 26.0)
    // Keskityskomento kartalle: nil koordinaatti = oma sijainti.
    @State private var centerTick = 0
    @State private var centerCoordinate: CLLocationCoordinate2D?
    @State private var showSearch = false

    private var layer: MapLayer { MapLayer(rawValue: layerRaw) ?? .standard }

    /// Julkiset spotit ilman omia (omat piirtyvät omina merkkeinään).
    private var visiblePublicSpots: [ServerClient.PublicSpot] {
        let ownIDs = Set(spots.map { $0.id.uuidString })
        return publicSpots.filter { !ownIDs.contains($0.id) }
    }

    private var placesFilter: Set<String> {
        get { Set(placesFilterRaw.split(separator: "|").map(String.init)) }
    }

    private var visiblePlaces: [ServerClient.Place] {
        guard placesEnabled else { return [] }
        let filter = placesFilter
        return filter.isEmpty ? mapPlaces : mapPlaces.filter { filter.contains($0.category) }
    }

    private func refreshSeaState(_ region: MKCoordinateRegion) {
        guard seaStateEnabled else { return }
        fields.refresh(region: region)
    }

    /// Julkaisun poisto voi edetä ehdotuksena: kerrotaan käyttäjälle miksi ja milloin.
    @MainActor
    private func handleUnpublish(_ result: ServerClient.UnpublishResult) {
        guard case .proposed(let decidesAt) = result else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fi_FI")
        f.dateStyle = .medium
        f.timeStyle = .short
        let when = ISO8601.parse(decidesAt).map { f.string(from: $0) } ?? "7 päivän kuluttua"
        communityNotice = "Muut ovat lisänneet spottiin sisältöä, joten julkinen spotti ei poistu heti. Poisto toteutuu \(when), ellei kukaan osallistunut vastusta. Oma yksityinen kopiosi on jo poistettu tai piilotettu."
    }


    /// Hakee rantainfran näkyvän alueen keskeltä (viive perää nopeaa panorointia).
    private func regionChanged(_ region: MKCoordinateRegion) {
        mapCenter = region.center
        currentRegion = region
        refreshSeaState(region)
        guard placesEnabled else { return }
        zoomedOut = region.span.latitudeDelta > 0.45
        guard !zoomedOut else { return }
        fetchTask?.cancel()
        fetchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let radius = min(6000.0, max(1500.0, region.span.latitudeDelta * 111_000 / 2))
            let key = String(format: "%.2f,%.2f,%.0f", region.center.latitude, region.center.longitude, radius)
            if let cached = placesCache[key] {
                mapPlaces = cached
                return
            }
            if let all = await ServerClient.shared.placesAll(
                latitude: region.center.latitude, longitude: region.center.longitude, radius: radius
            ), !Task.isCancelled {
                placesCache[key] = all
                mapPlaces = all
            }
        }
    }

    /// Maastotiilet: oma palvelin > suora MML-avain > sisäänrakennettu palvelin.
    /// Karttatasot toimivat siis ilman mitään asetuksia.
    private var terrainTemplate: String? {
        if let server = ServerSettings.config(base: serverBase, token: serverToken) {
            return ServerSettings.tileTemplate(layer: "terrain", server: server)
        }
        if !mmlApiKey.isEmpty {
            return TileOverlays.terrainTemplate(apiKey: mmlApiKey)
        }
        return ServerSettings.tileTemplate(layer: "terrain", server: ServerSettings.builtIn)
    }

    private var marineTemplateResolved: String {
        if let server = ServerSettings.config(base: serverBase, token: serverToken) {
            return ServerSettings.tileTemplate(layer: "marine", server: server)
        }
        if marineTemplate != TileOverlays.defaultMarineTemplate {
            return marineTemplate
        }
        return ServerSettings.tileTemplate(layer: "marine", server: ServerSettings.builtIn)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                SpotMapView(
                    spots: spots.map(\.data),
                    layer: layer,
                    terrainTemplate: terrainTemplate,
                    marineTemplate: marineTemplateResolved,
                    places: visiblePlaces,
                    publicSpots: visiblePublicSpots,
                    seaState: seaStateEnabled ? fields.seaState : nil,
                    waveField: seaStateEnabled ? fields.waveField : nil,
                    waveRaster: seaStateEnabled ? fields.waveRaster : nil,
                    probeCoordinate: probeCoordinate,
                    onLongPress: { coordinate in
                        editingSpot = SpotData(
                            name: "",
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                    },
                    onSelectSpot: { spot in
                        selectedSpot = spot
                        selectedPlace = nil
                        probeCoordinate = nil
                    },
                    onSelectPlace: { place in
                        selectedPlace = place
                    },
                    onSelectPublicSpot: { spot in
                        selectedPublicSpot = spot
                    },
                    onTap: { coordinate in
                        selectedSpot = nil
                        // Ennustepiste vain kun kentät ovat ladattuna — muuten napautus on neutraali.
                        guard seaStateEnabled else { return }
                        probeCoordinate = coordinate
                        selectedPlace = nil
                    },
                    onRegionWillChange: { withAnimation(.easeOut(duration: 0.15)) { isMapMoving = true } },
                    onRegionChange: { region in
                        withAnimation(.easeIn(duration: 0.4)) { isMapMoving = false }
                        regionChanged(region)
                    },
                    centerTick: centerTick,
                    centerCoordinate: centerCoordinate
                )
                .ignoresSafeArea(edges: .top)

                if seaStateEnabled, !isMapMoving, let region = currentRegion, fields.windModel.isReady {
                    WindFieldOverlay(model: fields.windModel, region: region)
                        .ignoresSafeArea(edges: .top)
                        .transition(.opacity)
                }

                VStack(spacing: 8) {
                    if let spot = selectedSpot {
                        // Pikakortti: napautus avaa spotin sää- ja infosivun, jonka
                        // takana muokkaus on.
                        SpotCard(
                            spot: spot,
                            onOpen: { forecastPoint = spot },
                            onClose: { selectedSpot = nil }
                        )
                    }
                    if let coordinate = probeCoordinate, seaStateEnabled {
                        ForecastProbeCard(
                            coordinate: coordinate,
                            timeLabel: fields.timelineLabel,
                            wind: fields.probeWind(at: coordinate),
                            wave: fields.probeWave(at: coordinate),
                            onForecast: {
                                let onWater = fields.waveField?.mask?.isWater(lat: coordinate.latitude, lon: coordinate.longitude)
                                forecastPoint = SpotData(
                                    name: "Ennustepiste",
                                    latitude: coordinate.latitude,
                                    longitude: coordinate.longitude,
                                    waterType: onWater == false ? .lake : .sea
                                )
                            },
                            onMakeSpot: {
                                editingSpot = SpotData(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude)
                                probeCoordinate = nil
                            },
                            onClose: { probeCoordinate = nil }
                        )
                    }
                    if let place = selectedPlace {
                        PlaceCard(place: place, onForecast: {
                            forecastPoint = SpotData(
                                name: place.name ?? place.category,
                                latitude: place.latitude,
                                longitude: place.longitude,
                                waterType: .lake
                            )
                            selectedPlace = nil
                        }, onMakeSpot: {
                            editingSpot = SpotData(
                                name: place.name ?? place.category,
                                latitude: place.latitude,
                                longitude: place.longitude
                            )
                            selectedPlace = nil
                        }, onClose: { selectedPlace = nil })
                    } else if placesEnabled && zoomedOut {
                        Text("Lähennä karttaa nähdäksesi rantainfran")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    if seaStateEnabled, let status = fields.status, fields.timelineHours == 0 {
                        Text(status)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    if seaStateEnabled, fields.timelineHours > 0 {
                        VStack(spacing: 2) {
                            HStack {
                                if fields.waveField != nil { WaveLegend() }
                                Spacer()
                                Text(fields.timelineLabel)
                                    .font(.caption.monospacedDigit().weight(.medium))
                                if fields.timelineOffset > 0 {
                                    Button("Nyt") { fields.timelineOffset = 0 }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                }
                            }
                            Slider(value: $fields.timelineOffset, in: 0...max(1, fields.timelineHours), step: 1)
                                .accessibilityLabel("Ennusteen ajankohta")
                                .accessibilityValue(fields.timelineLabel)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                    }
                    Picker("Taso", selection: $layerRaw) {
                        ForEach(MapLayer.allCases) { layer in
                            Text(layer.displayName).tag(layer.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    Text("Lisää spotti +-napista tai painamalla karttaa pitkään")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 10) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .accessibilityLabel("Hae paikkaa")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        seaStateEnabled.toggle()
                        if seaStateEnabled {
                            // Haetaan heti — muuten kerros ilmestyisi vasta panoroinnin jälkeen.
                            if let region = currentRegion { refreshSeaState(region) }
                        } else {
                            fields.clear()
                            probeCoordinate = nil
                        }
                    } label: {
                        Image(systemName: seaStateEnabled ? "water.waves" : "water.waves")
                            .accessibilityLabel("Merisää-kerros")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(seaStateEnabled ? Color.accentColor : .secondary)
                    }
                    Button {
                        MapLocation.requestPermission()
                        centerCoordinate = nil
                        centerTick += 1
                    } label: {
                        Image(systemName: "location")
                            .accessibilityLabel("Oma sijainti")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(Color.accentColor)
                    }
                    // Eksplisiittinen spotin lisäys: kartan keskipisteeseen.
                    Button {
                        editingSpot = SpotData(
                            name: "",
                            latitude: mapCenter.latitude,
                            longitude: mapCenter.longitude
                        )
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel("Lisää spotti")
                            .font(.title3.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(Color.accentColor)
                    }
                    Button {
                        placesEnabled.toggle()
                        if !placesEnabled {
                            mapPlaces = []
                            selectedPlace = nil
                        }
                    } label: {
                        Image(systemName: placesEnabled ? "beach.umbrella.fill" : "beach.umbrella")
                            .accessibilityLabel("Rantainfra")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(placesEnabled ? Color.accentColor : .secondary)
                    }
                    if placesEnabled {
                        Button {
                            showPlaceFilter = true
                        } label: {
                            Image(systemName: placesFilter.isEmpty
                                  ? "line.3.horizontal.decrease.circle"
                                  : "line.3.horizontal.decrease.circle.fill")
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(placesFilter.isEmpty ? .secondary : Color.accentColor)
                        }
                    }
                }
                .padding(.trailing, 12)
                .padding(.top, 4)
            }
            .sheet(isPresented: $showPlaceFilter) {
                PlaceFilterSheet(selected: Binding(
                    get: { placesFilter },
                    set: { placesFilterRaw = $0.sorted().joined(separator: "|") }
                ))
            }
            .alert("Julkinen spotti on yhteinen", isPresented: Binding(get: { communityNotice != nil }, set: { if !$0 { communityNotice = nil } })) {
                Button("OK") { communityNotice = nil }
            } message: {
                Text(communityNotice ?? "")
            }
            .sheet(item: $editingSpot) { spot in
                SpotEditorView(draft: spot, isNew: !spots.contains { $0.id == spot.id }) { action in
                    handle(action, original: spot)
                }
            }
            .sheet(item: $selectedPublicSpot) { spot in
                PublicSpotView(spot: spot)
            }
            .sheet(isPresented: $showSearch) {
                MapSearchSheet(near: mapCenter) { coordinate in
                    centerCoordinate = coordinate
                    centerTick += 1
                }
            }
            .sheet(item: $forecastPoint) { point in
                NavigationStack {
                    // Oma spotti saa täyden listan (ennuste talletetaan ja kelloon);
                    // tilapäinen piste tyhjän → ei ylikirjoita suosikkeja.
                    SpotForecastView(
                        spot: point,
                        allSpots: spots.contains { $0.id == point.id } ? spots.map(\.data) : [],
                        // Oman spotin asetukset ovat spottisivun takana, eivät kartalla.
                        onEdit: spots.contains(where: { $0.id == point.id }) ? {
                            forecastPoint = nil
                            selectedSpot = nil
                            editingSpot = point
                        } : nil
                    )
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Sulje") { forecastPoint = nil }
                            }
                        }
                }
            }
            .task {
                if let shared = await ServerClient.shared.publicSpots() {
                    publicSpots = shared
                }
            }
        }
    }

    private func handle(_ action: SpotEditorView.Action, original: SpotData) {
        SpotEditing.apply(action, original: original, spots: spots, context: modelContext, forecastStore: forecastStore,
                          effects: .init(
                              publicSpotsChanged: { publicSpots = $0 },
                              unpublished: { handleUnpublish($0) }
                          ))
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
    /// Rantainfra-kerroksen kohteet (tyhjä = kerros pois).
    var places: [ServerClient.Place] = []
    /// Muiden jakamat julkiset spotit.
    var publicSpots: [ServerClient.PublicSpot] = []
    /// Merisää (poijut + tuuliasemat); nil = kerros pois.
    var seaState: ServerClient.SeaState?
    /// Aaltokenttä värjättynä merelle (osa Merisää-kerrosta); nil = pois.
    var waveField: WaveField?
    /// Valmis, vesialueeseen klipattu kuva kentästä (nil = piirretään ruuduista).
    var waveRaster: WaveFieldRaster?
    /// Ennustepisteen merkki; nil = ei näytetä.
    var probeCoordinate: CLLocationCoordinate2D?
    var onLongPress: (CLLocationCoordinate2D) -> Void
    var onSelectSpot: (SpotData) -> Void
    var onSelectPlace: (ServerClient.Place?) -> Void = { _ in }
    var onSelectPublicSpot: (ServerClient.PublicSpot) -> Void = { _ in }
    /// Napautus tyhjään kohtaan kartalla (merkit hoitaa MapKit itse).
    var onTap: (CLLocationCoordinate2D) -> Void = { _ in }
    var onRegionWillChange: () -> Void = {}
    var onRegionChange: (MKCoordinateRegion) -> Void = { _ in }
    /// Keskityskomento: tick kasvaa → keskitä (nil koordinaatti = oma sijainti).
    var centerTick = 0
    var centerCoordinate: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        // Zoomikatto ~z20: syvemmällä mikään tiililähde (Apple mukaan lukien)
        // ei näytä enää mitään — käyttäjä ei voi zoomata tyhjään.
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 400)
        // Aloitusnäkymä: Suomi.
        map.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 62.5, longitude: 26.0),
            span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 12)
        )
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        map.addGestureRecognizer(longPress)
        // Napautus = ennustepiste. Tuplanapautus (zoom) ei saa laukaista sitä,
        // eikä merkkien napautuksia kaapata — delegaatti suodattaa.
        let doubleTap = UITapGestureRecognizer()
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = context.coordinator
        map.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        tap.require(toFail: doubleTap)
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        updateOverlay(map, context: context)
        updateWaveOverlay(map, context: context)
        updateProbeAnnotation(map)
        updateAnnotations(map)
        updatePlaceAnnotations(map, context: context)
        if centerTick != context.coordinator.lastCenterTick {
            context.coordinator.lastCenterTick = centerTick
            if let target = centerCoordinate ?? map.userLocation.location?.coordinate {
                map.setRegion(MKCoordinateRegion(
                    center: target,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.09)
                ), animated: true)
            } else if centerCoordinate == nil {
                context.coordinator.pendingCenterOnUser = true
            }
        }
    }

    /// Rantainfran merkit vaihdetaan könttänä, kun haettu joukko vaihtuu.
    private func updatePlaceAnnotations(_ map: MKMapView, context: Context) {
        let signature = "\(places.count):\(places.first.map { "\($0.latitude),\($0.longitude)" } ?? "")"
        if signature != context.coordinator.placesSignature {
            context.coordinator.placesSignature = signature
            map.removeAnnotations(map.annotations.compactMap { $0 as? PlaceAnnotation })
            map.addAnnotations(places.map(PlaceAnnotation.init))
        }
        let publicSignature = "\(publicSpots.count):\(publicSpots.map(\.id).joined())"
        if publicSignature != context.coordinator.publicSpotsSignature {
            context.coordinator.publicSpotsSignature = publicSignature
            map.removeAnnotations(map.annotations.compactMap { $0 as? PublicSpotAnnotation })
            map.addAnnotations(publicSpots.map(PublicSpotAnnotation.init))
        }
        let seaSignature = seaState.map { "\($0.buoys.count):\($0.stations.count):\($0.buoys.first?.time ?? "")" } ?? "off"
        if seaSignature != context.coordinator.seaStateSignature {
            context.coordinator.seaStateSignature = seaSignature
            map.removeAnnotations(map.annotations.compactMap { $0 as? SeaStateAnnotation })
            if let seaState {
                map.addAnnotations(seaState.buoys.map { SeaStateAnnotation(kind: .buoy, data: $0) })
                map.addAnnotations(seaState.stations.map { SeaStateAnnotation(kind: .station, data: $0) })
            }
        }
    }

    private func updateOverlay(_ map: MKMapView, context: Context) {
        let signature: String
        switch layer {
        case .standard: signature = "standard"
        case .terrain: signature = "terrain:\(terrainTemplate ?? "")"
        case .marine: signature = "marine:\(marineTemplate)"
        case .aerial: signature = "aerial"
        }
        guard signature != context.coordinator.overlaySignature else { return }
        context.coordinator.overlaySignature = signature

        map.removeOverlays(map.overlays)
        context.coordinator.waveSignature = "" // aaltokenttä lisätään uudelleen tiilien päälle
        // Ilma käyttää Applen satelliittikuvastoa (tarkempi ja globaali kuin
        // MML-ortot); muut tasot normaalia pohjakarttaa + tiilioverlayta.
        // Vaimennettu peruskartta (Windyn tapaan): säädata ja merkit erottuvat,
        // kartta ei kilpaile värillä.
        map.preferredConfiguration = layer == .aerial
            ? MKImageryMapConfiguration()
            : MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        switch layer {
        case .standard:
            break
        case .terrain:
            if let template = terrainTemplate {
                map.addOverlay(TileOverlays.overlay(template: template, replacesContent: true, muted: true), level: .aboveLabels)
            }
        case .marine:
            map.addOverlay(TileOverlays.overlay(template: marineTemplate, replacesContent: false,
                                                minimumZ: 5, sourceMaxZ: 15), level: .aboveLabels)
        case .aerial:
            break // Applen kuvasto tulee preferredConfigurationista.
        }
    }

    /// Aaltokenttä vaihdetaan könttänä kun data vaihtuu (tai tiilet luotiin uudelleen).
    private func updateWaveOverlay(_ map: MKMapView, context: Context) {
        let signature = waveField.map { field in
            let first = field.cells.first.map { "\($0.latitude),\($0.longitude),\($0.height),\($0.direction)" } ?? ""
            return "\(field.cells.count):\(field.spacingLat):\(first):\(field.corrections.count):\(field.mask != nil):\(waveRaster?.id.uuidString ?? "-")"
        } ?? "off"
        guard signature != context.coordinator.waveSignature else { return }
        context.coordinator.waveSignature = signature
        map.removeOverlays(map.overlays.filter { $0 is WaveFieldMapOverlay })
        if let waveField, !waveField.isEmpty {
            map.addOverlay(WaveFieldMapOverlay(field: waveField, raster: waveRaster), level: .aboveLabels)
        }
    }

    /// Ennustepisteen merkki: yksi kerrallaan, siirtyy napautuksen mukana.
    private func updateProbeAnnotation(_ map: MKMapView) {
        let existing = map.annotations.compactMap { $0 as? ProbeAnnotation }
        guard let coordinate = probeCoordinate else {
            map.removeAnnotations(existing)
            return
        }
        if let current = existing.first, current.coordinate.latitude == coordinate.latitude,
           current.coordinate.longitude == coordinate.longitude, existing.count == 1 {
            return
        }
        map.removeAnnotations(existing)
        let annotation = ProbeAnnotation()
        annotation.coordinate = coordinate
        map.addAnnotation(annotation)
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

    final class ProbeAnnotation: MKPointAnnotation {}

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: SpotMapView
        var overlaySignature = ""
        var placesSignature = ""
        var publicSpotsSignature = ""
        var seaStateSignature = ""
        var waveSignature = ""
        var lastCenterTick = 0
        var pendingCenterOnUser = false

        init(parent: SpotMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            parent.onRegionWillChange()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onRegionChange(mapView.region)
        }

        /// Sijaintinappi ennen ensimmäistä paikannusta (esim. lupakysely
        /// kesken): keskitetään heti kun sijainti saapuu.
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard pendingCenterOnUser, let coordinate = userLocation.location?.coordinate else { return }
            pendingCenterOnUser = false
            mapView.setRegion(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.09)
            ), animated: true)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                // Klusterin napautus: zoomaa sisään.
                var region = mapView.region
                region.center = cluster.coordinate
                region.span.latitudeDelta /= 3
                region.span.longitudeDelta /= 3
                mapView.setRegion(region, animated: true)
                mapView.deselectAnnotation(cluster, animated: false)
            } else if let spotAnnotation = view.annotation as? SpotAnnotation {
                // Oma spotti: kortti alalaitaan MapKitin kuplan sijaan; valinta
                // puretaan heti, jotta sama merkki voi avata kortin uudelleen.
                parent.onSelectSpot(spotAnnotation.spot)
                mapView.deselectAnnotation(spotAnnotation, animated: false)
            } else if let place = view.annotation as? PlaceAnnotation {
                parent.onSelectPlace(place.place)
            } else if let publicSpot = view.annotation as? PublicSpotAnnotation {
                parent.onSelectPublicSpot(publicSpot.spot)
                mapView.deselectAnnotation(publicSpot, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if view.annotation is PlaceAnnotation {
                parent.onSelectPlace(nil)
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let map = gesture.view as? MKMapView else { return }
            parent.onTap(map.convert(gesture.location(in: map), toCoordinateFrom: map))
        }

        /// Merkkien napautukset jätetään MapKitille (valinta), muut kartalle.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is MKAnnotationView { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true // kartan omat eleet (zoom, panorointi) toimivat normaalisti
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
            if overlay is WaveFieldMapOverlay {
                return WaveFieldRenderer(overlay: overlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let spotAnnotation = annotation as? SpotAnnotation {
                let identifier = "spot"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.canShowCallout = false // kortti korvaa kuplan
                view.markerTintColor = spotAnnotation.spot.isFavorite ? .systemOrange : .systemTeal
                view.glyphImage = UIImage(systemName: spotAnnotation.spot.waterType == .sea ? "water.waves" : "drop")
                view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
                view.displayPriority = .required
                return view
            }
            if let placeAnnotation = annotation as? PlaceAnnotation {
                let identifier = "place"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.canShowCallout = false
                view.clusteringIdentifier = "place"
                view.markerTintColor = PlaceStyle.color(placeAnnotation.place.category)
                view.glyphImage = UIImage(systemName: PlaceStyle.symbol(placeAnnotation.place.category))
                view.displayPriority = .defaultLow
                return view
            }
            if let publicAnnotation = annotation as? PublicSpotAnnotation {
                let identifier = "publicSpot"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.canShowCallout = false
                view.markerTintColor = .systemPurple
                view.glyphImage = UIImage(systemName: "person.2.fill")
                view.displayPriority = .defaultHigh
                _ = publicAnnotation
                return view
            }
            if let seaAnnotation = annotation as? SeaStateAnnotation {
                let identifier = "seaChip"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? SeaChipAnnotationView)
                    ?? SeaChipAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.configure(seaAnnotation)
                view.displayPriority = seaAnnotation.kind == .buoy ? .defaultHigh : .defaultLow
                return view
            }
            if annotation is MKClusterAnnotation {
                let identifier = "placeCluster"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.canShowCallout = false
                view.markerTintColor = .systemBlue
                return view
            }
            if annotation is ProbeAnnotation {
                let identifier = "probe"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.canShowCallout = false
                view.markerTintColor = .systemIndigo
                view.glyphImage = UIImage(systemName: "scope")
                view.displayPriority = .required
                return view
            }
            return nil
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
