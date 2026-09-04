import SwiftUI
import MapKit
import NosteCore

/// Spottisivun minikartta Windyn tapaan: tuulipartikkelit, aaltokenttä ja
/// poijut spotin ympäriltä samalla aikajanalla kuin kartalla. Oma malli,
/// alue keskitetään spottiin.
struct SpotFieldMap: View {
    let spot: SpotData
    @StateObject private var fields = MarineFieldsModel()
    @State private var region: MKCoordinateRegion
    @State private var isMoving = false

    init(spot: SpotData) {
        self.spot = spot
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.7)
        ))
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                SpotMapView(
                    spots: [spot],
                    layer: .standard,
                    terrainTemplate: nil,
                    marineTemplate: "",
                    seaState: fields.seaState,
                    waveField: fields.waveField,
                    waveRaster: fields.waveRaster,
                    onLongPress: { _ in },
                    onSelectSpot: { _ in },
                    onRegionWillChange: { isMoving = true },
                    onRegionChange: { new in
                        isMoving = false
                        region = new
                        fields.refresh(region: new)
                    },
                    centerTick: 1,
                    centerCoordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
                )
                if !isMoving, fields.windModel.isReady {
                    WindFieldOverlay(model: fields.windModel, region: region)
                }
                if let status = fields.status, fields.timelineHours == 0 {
                    Text(status)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

            if fields.timelineHours > 0 {
                HStack {
                    if fields.waveField != nil { WaveLegend() }
                    Spacer()
                    Text(fields.timelineLabel).font(.caption.monospacedDigit().weight(.medium))
                    if fields.timelineOffset > 0 {
                        Button("Nyt") { fields.timelineOffset = 0 }
                            .font(.caption).buttonStyle(.bordered).controlSize(.mini)
                    }
                }
                Slider(value: $fields.timelineOffset, in: 0...max(1, fields.timelineHours), step: 1)
                    .accessibilityLabel("Ennusteen ajankohta")
                    .accessibilityValue(fields.timelineLabel)
            }
        }
        .task {
            // Hae heti, ei odoteta ensimmäistä panorointia.
            fields.refresh(region: region, debounce: 0)
        }
    }
}
