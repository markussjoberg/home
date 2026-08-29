import SwiftUI
import SwiftData
import NosteCore

struct RootView: View {
    @StateObject private var forecastStore = ForecastStore()
    @Query private var spots: [SpotRecord]

    var body: some View {
        TabView {
            MapTab()
                .tabItem { Label("Kartta", systemImage: "map") }
            ForecastTab()
                .tabItem { Label("Ennuste", systemImage: "wind") }
            SessionsTab()
                .tabItem { Label("Sessiot", systemImage: "chart.bar") }
            SettingsTab()
                .tabItem { Label("Asetukset", systemImage: "gearshape") }
        }
        .environmentObject(forecastStore)
        .task {
            let data = spots.map(\.data)
            await forecastStore.refreshFavorites(spots: data)
            await MapSnapshotService.shared.syncFavorites(spots: data)
        }
    }
}
