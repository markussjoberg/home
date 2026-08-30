import SwiftUI
import NosteCore

struct StartView: View {
    @EnvironmentObject private var workout: WorkoutManager
    @EnvironmentObject private var connectivity: WatchConnectivityManager

    var body: some View {
        List {
            if let notice = workout.notice {
                Section {
                    Label(notice, systemImage: "arrow.counterclockwise.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(Sport.allCases) { sport in
                    Button {
                        workout.start(sport: sport)
                    } label: {
                        Label { Text(sport.displayName).font(.system(.headline, design: .rounded)) } icon: {
                            SportIcon(sport: sport, size: 24).foregroundStyle(.tint)
                        }
                    }
                }
            } header: {
                Text("Aloita sessio")
            }

            if !connectivity.offlineMaps.isEmpty {
                Section {
                    NavigationLink {
                        OfflineMapView()
                    } label: {
                        Label("Kartta (offline)", systemImage: "map")
                    }
                }
            }

            if let snapshot = connectivity.snapshot {
                Section {
                    NavigationLink {
                        ForecastGlanceView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Ennuste", systemImage: "wind")
                            if let hint = windNow(snapshot) {
                                Text(hint)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Noste")
    }

    /// "Nyt 8,2 m/s SW @ Kotispotti" — ensimmäisen suosikin tuore tunti.
    private func windNow(_ snapshot: WatchSync.Snapshot) -> String? {
        guard let forecast = snapshot.forecasts.first,
              let hour = forecast.upcoming(from: Date(), hours: 1).wind.first
        else { return nil }
        return "Nyt \(Format.speedMs(hour.speed)) \(hour.directionName) @ \(forecast.spotName)"
    }
}
