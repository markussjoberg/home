import SwiftUI
import SwiftData
import NosteCore

/// Omat kelivahdit yhdessä paikassa: raja, päällä/pois, poisto. Hälytys voi olla
/// spotille tai mille tahansa kartan pisteelle (ennustepiste).
struct AlertsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AlertRecord.spotName) private var alerts: [AlertRecord]

    var body: some View {
        List {
            if alerts.isEmpty {
                Text("Ei hälytyksiä. Aseta spotin sivulta (Muokkaa → Oma hälytys) tai kartan ennustepisteestä.")
                    .foregroundStyle(.secondary)
            }
            ForEach(alerts) { alert in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(alert.spotName).font(.cardTitle).lineLimit(1)
                        Spacer()
                        Toggle("Päällä", isOn: Binding(
                            get: { alert.enabled },
                            set: { on in alert.enabled = on; save() }
                        ))
                        .labelsHidden()
                    }
                    Stepper(value: Binding(get: { alert.minWind }, set: { alert.minWind = $0; save() }), in: 3...25, step: 1) {
                        HStack {
                            Text("Hälytysraja")
                            Spacer()
                            Text("\(Int(alert.minWind)) m/s").font(.statLabel.monospacedDigit()).foregroundStyle(Theme.wind)
                        }
                    }
                    if let dirs = alert.goodDirections, !dirs.isEmpty {
                        Text("Suunnat: " + dirs.map { ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][$0] }.joined(separator: " "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                for offset in offsets { modelContext.delete(alerts[offset]) }
                save()
            }
        }
        .navigationTitle("Omat hälytykset")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }

    private func save() {
        try? modelContext.save()
        AlertStore.sync(context: modelContext)
    }
}
