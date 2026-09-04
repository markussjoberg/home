import SwiftUI
import SwiftData
import Charts
import NosteCore

struct ForecastTab: View {
    @Query(sort: \SpotRecord.name) private var spots: [SpotRecord]
    @EnvironmentObject private var forecastStore: ForecastStore
    @Environment(\.modelContext) private var modelContext
    @State private var editingSpot: SpotData?
    @State private var notice: String?

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
                        ZStack {
                            NavigationLink {
                                SpotForecastView(spot: spot, allSpots: sortedSpots, onEdit: { editingSpot = spot })
                            } label: { EmptyView() }
                            .opacity(0) // kortti itse on nappi, ei oikean reunan nuolta
                            SpotRow(spot: spot, forecast: forecastStore.forecast(for: spot))
                        }
                        .cardRow()
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Theme.background)
                    .refreshable {
                        for spot in sortedSpots {
                            await forecastStore.refresh(spot: spot, force: true, allSpots: sortedSpots)
                        }
                    }
                }
            }
            .sheet(item: $editingSpot) { spot in
                SpotEditorView(draft: spot, isNew: false) { action in
                    SpotEditing.apply(action, original: spot, spots: spots, context: modelContext, forecastStore: forecastStore,
                                      effects: .init(unpublished: { result in
                                          if case .proposed = result {
                                              notice = "Muut ovat lisänneet spottiin sisältöä, joten julkinen spotti ei poistu heti. Poisto toteutuu 7 päivän kuluttua, ellei kukaan osallistunut vastusta."
                                          }
                                      }))
                    editingSpot = nil
                }
            }
            .alert("Julkinen spotti on yhteinen", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK") { notice = nil }
            } message: { Text(notice ?? "") }
            .navigationTitle("Spotit")
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
        HStack(spacing: 14) {
            if let exposure = spot.exposureByOctant, exposure.count == 8 {
                ExposureRoseGlyph(exposure: exposure, diameter: 40)
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: spot.waterType == .sea ? "water.waves" : "drop.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.wind)
                    .frame(width: 48, height: 48)
                    .background(Theme.surfaceElevated, in: Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spot.name).font(.cardTitle).lineLimit(1)
                    if spot.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(Theme.ride).font(.caption)
                    }
                }
                if let match = nextMatch {
                    Label {
                        Text("Keli osuu \(match, format: .dateTime.weekday(.abbreviated).hour())")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .font(.statLabel)
                    .foregroundStyle(Theme.ok)
                } else {
                    Text(spot.waterType.displayName).font(.statLabel).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 8)
            if let hour = forecast?.upcoming(from: Date(), hours: 1).wind.first {
                WindGlyph(speed: hour.speed, gust: hour.gust, direction: hour.direction, size: 30)
            } else {
                Text("—").font(.stat(30)).foregroundStyle(Theme.muted)
            }
        }
        .card()
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
    /// Oman spotin muokkaus (nil = ei omaa spottia, esim. tilapäinen piste).
    var onEdit: (() -> Void)? = nil
    @EnvironmentObject private var forecastStore: ForecastStore
    @Query private var allSessions: [SessionRecord]
    @State private var observation: ServerClient.Observation?
    @State private var selectedTime: Date?
    @State private var places: [ServerClient.Place]?
    @State private var mediumRange: [MediumRangeDay]?
    @State private var fmiWave: ServerClient.WaveData?

    /// Spotin oppiva tuuliprofiili reittatuista sessioista.
    private var profile: SpotWindProfile {
        RatingService.profile(spotID: spot.id, spotName: spot.name, sessions: allSessions)
    }

    var body: some View {
        List {
            if let error = forecastStore.lastError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }

            // Pääluvut ensin: ennuste nyt isona, havainto ja aalto sen rinnalla.
            if let now = forecastStore.forecast(for: spot)?.upcoming(from: Date(), hours: 1).wind.first {
                HStack(alignment: .top, spacing: 16) {
                    WindGlyph(speed: now.speed, gust: now.gust, direction: now.direction, size: 44)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(GeoMath.compassName(degrees: now.direction))
                            .font(.stat(26))
                        Text(spot.matches(now) ? "ikkunassa" : "ennuste nyt")
                            .font(.statLabel)
                            .foregroundStyle(spot.matches(now) ? Theme.ok : Theme.muted)
                        if let buoy = fmiWave?.buoy, let height = buoy.waveHeight {
                            Text(String(format: "aalto %.1f m", height).replacingOccurrences(of: ".", with: ","))
                                .font(.statLabel).foregroundStyle(Theme.wind)
                        }
                    }
                }
                .card()
                .cardRow()
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

            if spot.waterType == .sea, let wave = fmiWave,
               wave.buoy != nil || !wave.forecast.isEmpty {
                Section {
                    if let buoy = wave.buoy, let height = buoy.waveHeight {
                        HStack {
                            Image(systemName: "water.waves").foregroundStyle(.cyan)
                            Text("Poiju nyt")
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(String(format: "%.1f m · %.0f s", height, buoy.wavePeriod ?? 0))
                                    .fontWeight(.semibold)
                                if let temp = buoy.waterTemp {
                                    Text(String(format: "vesi %.1f °C", temp))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.subheadline)
                    }
                    ForEach(waveRows) { hour in
                        HStack {
                            if let date = hour.date {
                                Text(date, format: .dateTime.weekday(.abbreviated).hour())
                                    .font(.subheadline)
                                    .frame(width: 76, alignment: .leading)
                            }
                            if surfWindowMatches(hour) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                            Spacer()
                            if let direction = hour.direction {
                                Image(systemName: "arrow.up")
                                    .rotationEffect(.degrees(direction + 180))
                                    .foregroundStyle(.cyan)
                                    .font(.caption)
                            }
                            Text(String(format: "%.1f m", hour.height))
                                .font(.subheadline.weight(.medium))
                                .frame(width: 52, alignment: .trailing)
                            Text(String(format: "%.0f s", hour.period ?? 0))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                } header: {
                    Text("Aallokko — FMI poiju + WAM")
                } footer: {
                    if spot.sports.contains(.surf) && spot.exposureByOctant != nil {
                        Text("✓ = aallokko osuu spotin avoimeen suuntaan ≥ 0,5 m — surffi-ikkuna.")
                    }
                }
            }

            if spot.exposureByOctant?.count == 8 || places?.isEmpty == false {
                Section("Ranta & maasto") {
                    exposureRow
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
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .listRowBackground(Theme.surface)
        .toolbar {
            Button {
                Task { await refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Päivitä ennuste")
            if let onEdit {
                Button("Muokkaa", action: onEdit)
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
                Text("\(profile.sessionCount) reitattua sessiota")
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

    /// WAM-rivit: seuraavat 24 h kolmen tunnin välein.
    private var waveRows: [ServerClient.WaveHourForecast] {
        guard let forecast = fmiWave?.forecast else { return [] }
        return forecast.enumerated().filter { $0.offset % 3 == 0 && $0.offset < 24 }.map(\.element)
    }

    /// Surffi-ikkuna: aallon tulosuunta osuu spotin avoimeen oktanttiin ja
    /// korkeus riittää.
    private func surfWindowMatches(_ hour: ServerClient.WaveHourForecast) -> Bool {
        guard spot.sports.contains(.surf),
              let exposure = spot.exposureByOctant, exposure.count == 8,
              let direction = hour.direction, hour.height >= 0.5 else { return false }
        let octant = Int((direction + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return exposure[octant] >= SpotData.openExposure
    }

    private func refresh(force: Bool) async {
        // Tilapäinen piste (allSpots tyhjä) ei saa ylikirjoittaa kellon snapshotia
        // eikä kasvattaa ennustecachea.
        await forecastStore.refresh(spot: spot, force: force, allSpots: allSpots, ephemeral: allSpots.isEmpty)
        observation = await ServerClient.shared.observation(latitude: spot.latitude, longitude: spot.longitude)
        if spot.waterType == .sea, fmiWave == nil {
            fmiWave = await ServerClient.shared.wave(latitude: spot.latitude, longitude: spot.longitude)
        }
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

    /// Maaston avoimuus: kompassiruusu kuvana, suojaisat suunnat lyhyesti tekstinä
    /// (lista kaikista suunnista oli raskas lukea).
    @ViewBuilder
    private var exposureRow: some View {
        if let exposure = spot.exposureByOctant, exposure.count == 8 {
            let name = { (i: Int) in GeoMath.compassName(degrees: Double(i) * 45) }
            let open = (0..<8).filter { exposure[$0] >= SpotData.openExposure }
            let sheltered = (0..<8).filter { exposure[$0] <= 0.3 }.map(name)
            HStack(spacing: 14) {
                ExposureRoseGlyph(exposure: exposure)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Avoimuus tuulelle")
                        .font(.subheadline)
                    Text(sheltered.isEmpty
                         ? (open.count == 8 ? "Avoin joka suunnasta" : "Ei suojaisia suuntia")
                         : "Suojainen: \(sheltered.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Avoin \(open.count) suunnasta kahdeksasta" + (sheltered.isEmpty ? "" : ", suojainen \(sheltered.joined(separator: ", "))"))
        }
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
                // Järviarvio näytetään vasta kun siitä on jotain (0,0 m on kohinaa);
                // desimaalipilkku vaihdetaan vain lukuihin, ei tekstiin.
                if let wave, !(waveEstimated && wave.height < 0.05) {
                    let height = String(format: "%.1f", wave.height).replacingOccurrences(of: ".", with: ",")
                    let period = String(format: "%.0f", wave.period)
                    Text(waveEstimated ? "aalto ~\(height) m · \(period) s (arvio)" : "aalto \(height) m · \(period) s")
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
