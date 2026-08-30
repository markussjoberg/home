import SwiftUI
import MapKit
import NosteCore

/// Rantainfra kartalla: kategorioiden tyylit, annotaatio, suodatin ja kortti.
enum PlaceStyle {

    /// Suodattimen järjestys: vesille tärkeimmät ensin.
    static let categories = [
        "Uimaranta", "Uimapaikka", "Veneluiska", "Laituri", "Satama",
        "Veneilyn palvelupaikka", "Melontakeskus", "Sauna", "Grillipaikka",
        "Katos/laavu", "Suihku", "Pukukoppi", "Juomavesi", "Pysäköinti", "WC", "Kioski"
    ]

    static func symbol(_ category: String) -> String {
        SpotForecastView.placeSymbol(category)
    }

    static func color(_ category: String) -> UIColor {
        switch category {
        case "Uimaranta", "Uimapaikka": return .systemOrange
        case "Laituri", "Veneluiska": return .systemTeal
        case "Satama", "Veneilyn palvelupaikka": return .systemIndigo
        case "Melontakeskus": return .systemGreen
        case "Sauna", "Grillipaikka": return .systemRed
        case "Katos/laavu": return .systemBrown
        case "Suihku", "Juomavesi", "Pukukoppi": return .systemCyan
        case "Kioski": return .systemPink
        default: return .systemGray
        }
    }
}

final class PlaceAnnotation: NSObject, MKAnnotation {
    let place: ServerClient.Place
    let coordinate: CLLocationCoordinate2D

    init(place: ServerClient.Place) {
        self.place = place
        self.coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }
}

/// Kategoriasuodatin: tyhjä valinta = näytä kaikki.
struct PlaceFilterSheet: View {
    @Binding var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PlaceStyle.categories, id: \.self) { category in
                        Button {
                            if !selected.insert(category).inserted { selected.remove(category) }
                        } label: {
                            HStack {
                                Image(systemName: PlaceStyle.symbol(category))
                                    .foregroundStyle(Color(PlaceStyle.color(category)))
                                    .frame(width: 28)
                                Text(category).foregroundStyle(.primary)
                                Spacer()
                                if selected.isEmpty || selected.contains(category) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Rannat ja palvelut: OpenStreetMap ja Lipas. Valitse mitä kartalla näytetään — tyhjä valinta näyttää kaikki.")
                }
            }
            .navigationTitle("Rantainfra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kaikki") { selected = [] }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valmis") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Valitun kohteen kortti kartan alalaidassa.
struct PlaceCard: View {
    let place: ServerClient.Place
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: PlaceStyle.symbol(place.category))
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color(PlaceStyle.color(place.category)), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(place.name ?? place.category)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if place.name != nil {
                        Text(place.category)
                    }
                    Text(place.source == "lipas" ? "Lipas" : "OpenStreetMap")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                let item = MKMapItem(placemark: MKPlacemark(
                    coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)))
                item.name = place.name ?? place.category
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            } label: {
                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    .font(.title)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8, y: 2)
        .padding(.horizontal)
    }
}
