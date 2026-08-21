import SwiftUI
import NosteCore

/// Offline-ennuste: näyttää puhelimen viimeksi työntämän snapshotin suosikkispoteille.
struct ForecastGlanceView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityManager

    var body: some View {
        List {
            if let snapshot = connectivity.snapshot {
                ForEach(snapshot.forecasts, id: \.spotID) { forecast in
                    Section {
                        let hours = forecast.upcoming(from: Date(), hours: 8).wind
                        if hours.isEmpty {
                            Text("Ennuste vanhentunut").foregroundStyle(.secondary)
                        }
                        ForEach(hours) { hour in
                            HStack {
                                Text(hour.time, format: .dateTime.hour())
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                                Spacer()
                                Image(systemName: "arrow.up")
                                    .rotationEffect(.degrees(hour.direction + 180))
                                Text(Format.speedMs(hour.speed))
                                    .fontWeight(.medium)
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
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Ei ennustetta — avaa puhelimen appi kerran verkossa.")
            }
        }
        .navigationTitle("Ennuste")
    }
}
