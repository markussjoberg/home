import SwiftUI
import MapKit
import CoreLocation

/// Sijaintiluvan pyyntö kartan paikannusnappia varten (manageri pidetään
/// elossa, jotta järjestelmän kysely ehtii näkyä).
enum MapLocation {
    static let manager = CLLocationManager()

    static func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}

/// Paikkahaku kartalle: nimi → MKLocalSearch → valinta keskittää kartan.
struct MapSearchSheet: View {
    let near: CLLocationCoordinate2D
    let onPick: (CLLocationCoordinate2D) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty && !query.isEmpty && !searching {
                    Text("Ei tuloksia")
                        .foregroundStyle(.secondary)
                }
                ForEach(results, id: \.self) { item in
                    Button {
                        onPick(item.placemark.coordinate)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Tuntematon")
                                .foregroundStyle(.primary)
                            if let locality = item.placemark.locality ?? item.placemark.administrativeArea {
                                Text(locality)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Järvi, ranta, paikkakunta…")
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { _, _ in
                // Haku vasta kun kirjoitus tauolla — kevyt debounce.
                Task {
                    let snapshot = query
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if snapshot == query, !snapshot.isEmpty { search() }
                }
            }
            .navigationTitle("Hae kartalta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sulje") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func search() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: near,
            span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 6)
        )
        searching = true
        MKLocalSearch(request: request).start { response, _ in
            results = response?.mapItems ?? []
            searching = false
        }
    }
}
