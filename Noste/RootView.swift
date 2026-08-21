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
            await forecastStore.refreshFavorites(spots: spots.map(\.data))
        }
    }
}
