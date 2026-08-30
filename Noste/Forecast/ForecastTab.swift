import SwiftUI
import SwiftData
import Charts
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
                    .refreshable {
                        for spot in sortedSpots {
                            await forecastStore.refresh(spot: spot, force: true, allSpots: sortedSpots)
                        }
                    }
                }
            }
            .navigationTitle("Ennuste")
            .task {
                await forecastStore.refreshFavorites(spots: sortedSpots)
            }
        }
    }
}

private struct SpotRow: View {
    let spot: SpotData
    let forecast: SpotForecast?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if spot.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption)
                    }
                    Text(spot.name).font(.headline)
                }
                if let match = nextMatch {
                    Label {
                        Text("Keli osuu \(match, format: .dateTime.weekday(.abbreviated).hour())")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.green)
                } else {
                    Text(spot.waterType.displayName).font(.caption).foregroundStyle(.secondary)
                }
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

    /// Ensimmäinen tuuli-ikkunaan osuva tunti seuraavan 48 h aikana.
    private var nextMatch: Date? {
        guard spot.hasWindWindow, let forecast else { return nil }
        return forecast.upcoming(from: Date(), hours: 48).wind.first { spot.matches($0) }?.time
    }
}

struct SpotForecastView: View {
    let spot: SpotData
    let allSpots: [SpotData]
    @EnvironmentObject private var forecastStore: ForecastStore
    @Query private var allSessions: [SessionRecord]
    @State private var observation: ServerClient.Observation?
    @State private var selectedTime: Date?
    @State private var places: [ServerClient.Place]?
    @State private var mediumRange: [MediumRangeDay]?

    /// Spotin oppiva tuuliprofiili reittatuista sessioista.
    private var profile: SpotWindProfile {
        RatingService.profile(spotName: spot.name, sessions: allSessions)
    }

    var body: some View {
        List {
            if let error = forecastStore.lastError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }

            if let observation, let speed = observation.windSpeed {
                Section {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Havainto lähiasemalta")
                                .font(.subheadline)
                            if let date = observation.date {
                                Text(date, format: .dateTime.hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(Format.speedMs(speed)).fontWeight(.semibold)
                            if let gust = observation.windGust, let direction = observation.windDirection {
                                Text("\(Format.speedMs(gust)) · \(GeoMath.compassName(degrees: direction))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if exposureText != nil || places?.isEmpty == false {
                Section("Ranta & maasto") {
                    if let exposureText {
                        Label(exposureText, systemImage: "mountain.2")
                            .font(.subheadline)
                    }
                    if let places {
                        ForEach(places) { place in
                            HStack {
                                Label(place.name ?? place.category, systemImage: Self.placeSymbol(place.category))
                                    .font(.subheadline)
                                Spacer()
                                if place.name != nil {
                                    Text(place.category)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(Format.distance(Double(place.distanceM)))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if profile.sessionCount > 0 {
                Section {
                    profileCard
                } header: {
                    Text("Spotin oppi")
                } footer: {
                    if !profile.isReady {
                        Text("Tähtiennuste käynnistyy, kun reittauksia on vähintään 5 (nyt \(profile.sessionCount)).")
                    }
                }
            }

            if let forecast = forecastStore.forecast(for: spot) {
                let upcoming = forecast.upcoming(from: Date(), hours: 48)

                Section {
                    WindChart(spot: spot, wind: upcoming.wind, selectedTime: $selectedTime)
                        .frame(height: 170)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 4, trailing: 12))
                }

                ForEach(days(of: upcoming.wind), id: \.self) { day in
                    Section(day.formatted(.dateTime.weekday(.wide).day().month())) {
                        ForEach(upcoming.wind.filter { sameDay($0.time, day) }) { hour in
                            let wave = waveInfo(for: hour, in: upcoming)
                            WindRow(hour: hour,
                                    wave: wave.wave,
                                    waveEstimated: wave.estimated,
                                    matches: spot.matches(hour),
                                    stars: profile.predictedRating(for: hour))
                        }
                    }
                }

                if let mediumRange, mediumRange.count > 3 {
                    Section {
                        ForEach(mediumRange.dropFirst(2)) { day in
                            MediumRangeRow(day: day, matches: matchesWindow(day))
                        }
                    } header: {
                        Text("Pitkä ennuste (ECMWF)")
                    } footer: {
                        Text("Päivän maksimituuli ja vallitseva suunta — suuntaa-antava reissusuunnitteluun.")
                    }
                }

                Section {
                    Text("Haettu \(forecast.fetchedAt, format: .dateTime.day().month().hour().minute()) · Open-Meteo")
                        .font(.footnote)
                        .foregroundStyle(stale(forecast) ? .orange : .secondary)
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
                Task { await refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .task {
            await refresh(force: false)
        }
    }

    /// Reittauksista opittu: sopivat suunnat ilmansuunnittain tähtineen.
    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "graduationcap.fill")
                    .foregroundStyle(.cyan)
                Text("\(profile.sessionCount) reittattua sessiota")
                    .font(.subheadline)
                Spacer()
                if !profile.goodOctants.isEmpty {
                    Text("Toimii: " + profile.goodOctants.map { GeoMath.compassName(degrees: Double($0) * 45) }.joined(separator: ", "))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            let summaries = profile.directionSummaries()
            if !summaries.isEmpty {
                HStack(spacing: 12) {
                    ForEach(summaries) { summary in
                        VStack(spacing: 2) {
                            Text(GeoMath.compassName(degrees: Double(summary.octant) * 45))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            StarBadge(value: summary.averageRating)
                            Text("\(summary.count)×")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Rantainfran kategoriaikoni (OSM + Lipas -kategoriat palvelimelta).
    static func placeSymbol(_ category: String) -> String {
        switch category {
        case "Uimaranta", "Uimapaikka": return "beach.umbrella"
        case "Laituri": return "water.waves"
        case "Veneluiska", "Rantautumispaikka": return "arrow.down.right.circle"
        case "Satama", "Veneilyn palvelupaikka": return "sailboat"
        case "Melontakeskus": return "oar.2.crossed"
        case "Sauna": return "flame.circle"
        case "Grillipaikka": return "flame"
        case "Katos/laavu": return "house.lodge"
        case "Suihku": return "shower"
        case "Pukukoppi": return "tshirt"
        case "Juomavesi": return "drop"
        case "Pysäköinti": return "parkingsign"
        case "WC": return "toilet"
        case "Kioski": return "cart"
        default: return "mappin.circle"
        }
    }

    private func refresh(force: Bool) async {
        await forecastStore.refresh(spot: spot, force: force, allSpots: allSpots)
        observation = await ServerClient.shared.observation(latitude: spot.latitude, longitude: spot.longitude)
        if places == nil {
            places = await ServerClient.shared.places(latitude: spot.latitude, longitude: spot.longitude)
        }
        if mediumRange == nil || force {
            let client = OpenMeteoClient(server: ServerSettings.current)
            mediumRange = try? await client.mediumRange(latitude: spot.latitude, longitude: spot.longitude)
        }
    }

    /// Aalto riville: merellä mallista, järvellä laskennallisesti fetchistä.
    private func waveInfo(for hour: WindHour, in forecast: SpotForecast) -> (wave: WaveHour?, estimated: Bool) {
        if let real = wave(for: hour.time, in: forecast) {
            return (real, false)
        }
        if spot.waterType == .lake,
           let estimate = LakeWaves.estimate(for: hour, fetchKmByOctant: spot.fetchKmByOctant) {
            return (WaveHour(time: hour.time, height: estimate.height, period: estimate.period, direction: hour.direction), true)
        }
        return (nil, false)
    }

    /// Maaston avoimuus tekstinä: avoimet ja suojaisat suunnat.
    private var exposureText: String? {
        guard let exposure = spot.exposureByOctant, exposure.count == 8 else { return nil }
        let name = { (i: Int) in GeoMath.compassName(degrees: Double(i) * 45) }
        let open = (0..<8).filter { exposure[$0] >= 0.7 }.map(name)
        let sheltered = (0..<8).filter { exposure[$0] <= 0.3 }.map(name)
        var parts: [String] = []
        if !open.isEmpty { parts.append("Avoin: \(open.joined(separator: ", "))") }
        if !sheltered.isEmpty { parts.append("Suojainen: \(sheltered.joined(separator: ", "))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Osuuko keskipitkän ennusteen päivä spotin tuuli-ikkunaan (karkea: maksimituuli + vallitseva suunta).
    private func matchesWindow(_ day: MediumRangeDay) -> Bool {
        spot.matches(WindHour(time: day.date, speed: day.windMax, gust: day.gustMax, direction: day.direction))
    }

    private func stale(_ forecast: SpotForecast) -> Bool {
        Date().timeIntervalSince(forecast.fetchedAt) > 3 * 3600
    }

    private func days(of hours: [WindHour]) -> [Date] {
        var seen: [Date] = []
        let calendar = Calendar.current
        for hour in hours {
            let day = calendar.startOfDay(for: hour.time)
            if seen.last != day { seen.append(day) }
        }
        return seen
    }

    private func sameDay(_ time: Date, _ day: Date) -> Bool {
        Calendar.current.startOfDay(for: time) == day
    }

    private func wave(for time: Date, in forecast: SpotForecast) -> WaveHour? {
        forecast.waves?.first { $0.time == time }
    }
}

/// Tuulikäyrä 48 h: nopeus yhtenäisenä viivana, puuskat katkoviivana ja
/// nopeus–puuska-väli samalla sävyllä himmeänä nauhana (sama suure → yksi akseli;
/// viivatyyli erottaa sarjat myös ilman värinäköä). Tuuli-ikkunaan osuvat tunnit
/// merkitään vihreällä pohjalla — sama tieto on listassa tekstinä.
private struct WindChart: View {
    let spot: SpotData
    let wind: [WindHour]
    @Binding var selectedTime: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let selected = selectedHour {
                Text("\(selected.time, format: .dateTime.weekday(.abbreviated).hour()): \(Format.speedMs(selected.speed)), puuskat \(Format.speedMs(selected.gust)), \(selected.directionName)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            } else {
                Text("Tuuli ja puuskat (m/s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart {
                // Tuuli-ikkunaosumien tausta.
                ForEach(matchRanges(), id: \.start) { range in
                    RectangleMark(
                        xStart: .value("alku", range.start),
                        xEnd: .value("loppu", range.end)
                    )
                    .foregroundStyle(.green.opacity(0.12))
                }

                ForEach(wind) { hour in
                    AreaMark(
                        x: .value("Aika", hour.time),
                        yStart: .value("Tuuli", hour.speed),
                        yEnd: .value("Puuska", hour.gust)
                    )
                    .foregroundStyle(.cyan.opacity(0.15))

                    LineMark(
                        x: .value("Aika", hour.time),
                        y: .value("m/s", hour.speed),
                        series: .value("Sarja", "Tuuli")
                    )
                    .foregroundStyle(.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    LineMark(
                        x: .value("Aika", hour.time),
                        y: .value("m/s", hour.gust),
                        series: .value("Sarja", "Puuska")
                    )
                    .foregroundStyle(.cyan.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }

                if let selected = selectedHour {
                    RuleMark(x: .value("Valinta", selected.time))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXSelection(value: $selectedTime)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
        }
    }

    private var selectedHour: WindHour? {
        guard let selectedTime else { return nil }
        return wind.min {
            abs($0.time.timeIntervalSince(selectedTime)) < abs($1.time.timeIntervalSince(selectedTime))
        }
    }

    private func matchRanges() -> [(start: Date, end: Date)] {
        guard spot.hasWindWindow else { return [] }
        var ranges: [(start: Date, end: Date)] = []
        var current: (start: Date, end: Date)?
        for hour in wind {
            if spot.matches(hour) {
                if var range = current {
                    range.end = hour.time.addingTimeInterval(3600)
                    current = range
                } else {
                    current = (hour.time, hour.time.addingTimeInterval(3600))
                }
            } else if let range = current {
                ranges.append(range)
                current = nil
            }
        }
        if let range = current { ranges.append(range) }
        return ranges
    }
}

/// Keskipitkän ennusteen päivärivi.
private struct MediumRangeRow: View {
    let day: MediumRangeDay
    let matches: Bool

    var body: some View {
        HStack {
            Text(day.date, format: .dateTime.weekday(.abbreviated).day().month())
                .font(.subheadline)
                .fontWeight(matches ? .bold : .regular)
            Spacer()
            if matches {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            Text(day.directionName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.up")
                .rotationEffect(.degrees(day.direction + 180))
                .foregroundStyle(matches ? .green : .cyan)
            VStack(alignment: .trailing) {
                Text("max \(Format.speedMs(day.windMax))")
                    .fontWeight(matches ? .bold : .medium)
                Text(Format.speedMs(day.gustMax))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 86, alignment: .trailing)
        }
    }
}

private struct WindRow: View {
    let hour: WindHour
    let wave: WaveHour?
    var waveEstimated = false
    let matches: Bool
    var stars: Double?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(hour.time, format: .dateTime.hour())
                        .font(.subheadline)
                        .fontWeight(matches ? .bold : .regular)
                    if let stars {
                        StarBadge(value: stars)
                    }
                }
                if let wave {
                    Text(String(format: waveEstimated ? "aalto ~%.1f m · %.0f s (lask.)" : "aalto %.1f m · %.0f s",
                                wave.height, wave.period)
                        .replacingOccurrences(of: ".", with: ","))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if matches {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            Text(hour.directionName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.up")
                .rotationEffect(.degrees(hour.direction + 180))
                .foregroundStyle(matches ? .green : .cyan)
            VStack(alignment: .trailing) {
                Text(Format.speedMs(hour.speed))
                    .fontWeight(matches ? .bold : .medium)
                Text(Format.speedMs(hour.gust)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 70, alignment: .trailing)
        }
        .listRowBackground(matches ? Color.green.opacity(0.08) : nil)
    }
}
