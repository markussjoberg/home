import SwiftUI
import NosteCore

struct StartView: View {
    @EnvironmentObject private var workout: WorkoutManager
    @EnvironmentObject private var connectivity: WatchConnectivityManager

    var body: some View {
        List {
            Section {
                ForEach(Sport.allCases) { sport in
                    Button {
                        workout.start(sport: sport)
                    } label: {
                        Label(sport.displayName, systemImage: sport.symbolName)
                            .font(.headline)
                    }
                }
            } header: {
                Text("Aloita sessio")
            }

            if connectivity.snapshot != nil {
                Section {
                    NavigationLink {
                        ForecastGlanceView()
                    } label: {
                        Label("Ennuste", systemImage: "wind")
                    }
                }
            }
        }
        .navigationTitle("Noste")
    }
}
