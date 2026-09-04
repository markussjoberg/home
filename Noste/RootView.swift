import SwiftUI
import SwiftData
import NosteCore

struct RootView: View {
    @StateObject private var forecastStore = ForecastStore()
    @Query private var spots: [SpotRecord]

    @State private var selection: Tab = .map
    @State private var showRecorder = false

    enum Tab: Hashable {
        case map, forecast, record, sessions, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            MapTab()
                .tabItem { Label("Kartta", systemImage: "map") }
                .tag(Tab.map)
            ForecastTab()
                .tabItem { Label("Spotit", systemImage: "star") }
                .tag(Tab.forecast)
            // Keskimmäinen "nappi": valinta avaa tallennuksen eikä jää tabiksi.
            Color.clear
                .tabItem { Label("Tallenna", systemImage: "record.circle.fill") }
                .tag(Tab.record)
            SessionsTab()
                .tabItem { Label("Sessiot", systemImage: "chart.bar") }
                .tag(Tab.sessions)
            SettingsTab()
                .tabItem { Label("Asetukset", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .onChange(of: selection) { previous, current in
            if current == .record {
                showRecorder = true
                selection = previous
            }
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecordSessionView()
        }
        .environmentObject(forecastStore)
        // Tumma ensin: kuvavetoinen ilme, isot luvut erottuvat myös kirkkaassa.
        .preferredColorScheme(.dark)
        .task {
            let data = spots.map(\.data)
            await forecastStore.refreshFavorites(spots: data)
            await MapSnapshotService.shared.syncFavorites(spots: data)
        }
    }
}
