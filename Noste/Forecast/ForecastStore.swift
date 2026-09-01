import Foundation
import NosteCore

/// Hakee ja välimuistittaa spottien ennusteet, ja työntää suosikkien ennusteet kelloon.
@MainActor
final class ForecastStore: ObservableObject {

    @Published private(set) var forecasts: [UUID: SpotForecast] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published var lastError: String?

    /// Palvelinasetus voi muuttua kesken käytön, joten asiakas luodaan hakukohtaisesti.
    private var client: OpenMeteoClient {
        OpenMeteoClient(server: ServerSettings.current)
    }
    private static let cacheKey = "noste.forecastCache"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? WatchSync.decode([UUID: SpotForecast].self, from: data) {
            forecasts = cached
        }
    }

    func forecast(for spot: SpotData) -> SpotForecast? {
        forecasts[spot.id]
    }

    /// Hakee ennusteen, jos välimuistissa oleva on yli 30 min vanha (tai force).
    /// ephemeral: tilapäinen piste (kartan napautus, julkinen spotti) — ennuste
    /// näytetään mutta ei talleteta eikä työnnetä kelloon suosikkien tilalle.
    func refresh(spot: SpotData, force: Bool = false, allSpots: [SpotData] = [], ephemeral: Bool = false) async {
        if !force, let cached = forecasts[spot.id], Date().timeIntervalSince(cached.fetchedAt) < 1800 {
            return
        }
        guard !loading.contains(spot.id) else { return }
        loading.insert(spot.id)
        defer { loading.remove(spot.id) }
        do {
            let forecast = try await client.forecast(for: spot)
            forecasts[spot.id] = forecast
            lastError = nil
            guard !ephemeral else { return }
            persist()
            pushToWatch(allSpots: allSpots.isEmpty ? [spot] : allSpots)
        } catch {
            lastError = "Ennusteen haku epäonnistui: \(error.localizedDescription)"
        }
    }

    /// Päivittää kaikkien suosikkien ennusteet (appin avautuessa).
    func refreshFavorites(spots: [SpotData]) async {
        for spot in spots.filter(\.isFavorite) {
            await refresh(spot: spot, allSpots: spots)
        }
    }

    private func persist() {
        if let data = try? WatchSync.encode(forecasts) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private func pushToWatch(allSpots: [SpotData]) {
        let favorites = allSpots.filter(\.isFavorite)
        let relevant = (favorites.isEmpty ? allSpots : favorites).compactMap { forecasts[$0.id] }
        PhoneConnectivity.shared.pushSnapshot(spots: allSpots, forecasts: relevant)
    }
}
