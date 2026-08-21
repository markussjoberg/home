import SwiftUI
import SwiftData
import NosteCore

struct ForecastTab: View {
    @Query(sort: \SpotRecord.name) private var spots: [SpotRecord]
    @EnvironmentObject private var forecastStore: ForecastStore

    private var sortedSpots: [SpotData] {
        spots.map(\.data).sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.name < b.name
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if spots.isEmpty {
                    ContentUnavailableView(
                        "Ei spotteja",
                        systemImage: "mappin.slash",
                        description: Text("Lisää ensimmäinen spotti kartalta pitkällä painalluksella.")
                    )
                } else {
                    List(sortedSpots) { spot in
                        NavigationLink {
                            SpotForecastView(spot: spot, allSpots: sortedSpots)
                        } label: {
                            SpotRow(spot: spot, forecast: forecastStore.forecast(for: spot))
                        }
                    }
                }
            }
            .navigationTitle("Ennuste")
        }
    }
}

private struct SpotRow: View {
    let spot: SpotData
    let forecast: SpotForecast?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    if spot.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption)
                    }
                    Text(spot.name).font(.headline)
                }
                Text(spot.waterType.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let hour = forecast?.upcoming(from: Date(), hours: 1).wind.first {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .rotationEffect(.degrees(hour.direction + 180))
                        .foregroundStyle(.cyan)
                    VStack(alignment: .trailing) {
                        Text(Format.speedMs(hour.speed)).fontWeight(.medium)
                        Text("puuskat \(Format.speedMs(hour.gust))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct SpotForecastView: View {
    let spot: SpotData
    let allSpots: [SpotData]
    @EnvironmentObject private var forecastStore: ForecastStore

    var body: some View {
        List {
            if let error = forecastStore.lastError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            if let forecast = forecastStore.forecast(for: spot) {
                let upcoming = forecast.upcoming(from: Date(), hours: 48)
                Section("Tuuli") {
                    ForEach(upcoming.wind) { hour in
                        WindRow(hour: hour, wave: wave(for: hour.time, in: upcoming))
                    }
                }
                Section {
                    Text("Haettu \(forecast.fetchedAt, format: .dateTime.day().month().hour().minute()) · Open-Meteo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if forecastStore.loading.contains(spot.id) {
                ProgressView()
            } else {
                Text("Ei ennustetta vielä.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(spot.name)
        .toolbar {
            Button {
                Task { await forecastStore.refresh(spot: spot, force: true, allSpots: allSpots) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .task {
            await forecastStore.refresh(spot: spot, allSpots: allSpots)
        }
    }

    private func wave(for time: Date, in forecast: SpotForecast) -> WaveHour? {
        forecast.waves?.first { $0.time == time }
    }
}

private struct WindRow: View {
    let hour: WindHour
    let wave: WaveHour?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(hour.time, format: .dateTime.weekday(.abbreviated).hour())
                    .font(.subheadline)
                if let wave {
                    Text(String(format: "aalto %.1f m · %.0f s", wave.height, wave.period)
                        .replacingOccurrences(of: ".", with: ","))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(hour.directionName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.up")
                .rotationEffect(.degrees(hour.direction + 180))
                .foregroundStyle(.cyan)
            VStack(alignment: .trailing) {
                Text(Format.speedMs(hour.speed)).fontWeight(.medium)
                Text(Format.speedMs(hour.gust)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 70, alignment: .trailing)
        }
    }
}
