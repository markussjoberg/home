import SwiftUI
import NosteCore

/// Offline-ennuste: näyttää puhelimen viimeksi työntämän snapshotin suosikkispoteille.
/// Spotin tuuli-ikkunaan osuvat tunnit korostetaan vihreällä — rannassa riittää
/// vilkaisu: "nouseeko tästä vielä".
struct ForecastGlanceView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityManager

    var body: some View {
        List {
            if let snapshot = connectivity.snapshot {
                ForEach(snapshot.forecasts, id: \.spotID) { forecast in
                    let spot = snapshot.spots.first { $0.id == forecast.spotID }
                    Section {
                        let hours = forecast.upcoming(from: Date(), hours: 8).wind
                        if hours.isEmpty {
                            Text("Ennuste vanhentunut").foregroundStyle(.secondary)
                        }
                        ForEach(hours) { hour in
                            let match = spot?.matches(hour) == true
                            HStack {
                                Text(hour.time, format: .dateTime.hour())
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                                Spacer()
                                Image(systemName: "arrow.up")
                                    .rotationEffect(.degrees(hour.direction + 180))
                                    .foregroundStyle(match ? .green : .cyan)
                                Text(Format.speedMs(hour.speed))
                                    .fontWeight(match ? .bold : .medium)
                                    .foregroundStyle(match ? .green : .primary)
                                Text("(\(Int(hour.gust.rounded())))")
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                            }
                        }
                    } header: {
                        Text(forecast.spotName)
                    }
                }
                Section {
                    Text("Päivitetty \(snapshot.updatedAt, format: .dateTime.day().month().hour().minute())")
                        .font(.footnote)
                        .foregroundStyle(staleness(snapshot) > 6 * 3600 ? .orange : .secondary)
                }
            } else {
                Text("Ei ennustetta — avaa puhelimen appi kerran verkossa.")
            }
        }
        .navigationTitle("Ennuste")
    }

    private func staleness(_ snapshot: WatchSync.Snapshot) -> TimeInterval {
        Date().timeIntervalSince(snapshot.updatedAt)
    }
}
