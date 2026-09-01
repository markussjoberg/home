import SwiftUI
import SwiftData
import MapKit
import Charts
import NosteCore

struct SessionsTab: View {
    @Query(sort: \SessionRecord.startDate, order: .reverse) private var sessions: [SessionRecord]
    @Environment(\.modelContext) private var modelContext
    @State private var showRecorder = false

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "Ei sessioita",
                        systemImage: "figure.surfing",
                        description: Text("Aloita sessio kellosta — se ilmestyy tänne automaattisesti. Ilman kelloa voit tallentaa sessioita puhelimella (+).")
                    )
                } else {
                    List {
                        if sessions.count >= 3 {
                            Section("Kehitys") {
                                TrendChart(sessions: sessions)
                            }
                        }
                        ForEach(sessions) { session in
                            NavigationLink {
                                SessionDetailView(record: session)
                            } label: {
                                SessionRow(record: session)
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                modelContext.delete(sessions[offset])
                            }
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("Sessiot")
            .toolbar {
                NavigationLink {
                    GearView()
                } label: {
                    Image(systemName: "backpack")
                }
                Button {
                    showRecorder = true
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
            .sheet(isPresented: $showRecorder) {
                RecordSessionView()
            }
        }
    }
}

/// Kehitys sessioittain: yksi valittava mittari pylväinä (viimeiset 15 sessiota).
private struct TrendChart: View {
    let sessions: [SessionRecord]
    @State private var metric: Metric = .foilTime

    enum Metric: String, CaseIterable, Identifiable {
        case foilTime
        case longestFlight
        case pumps

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .foilTime: return "Foiliaika (min)"
            case .longestFlight: return "Pisin lento (s)"
            case .pumps: return "Pumput"
            }
        }
    }

    private var data: [(date: Date, value: Double)] {
        sessions.prefix(15).reversed().compactMap { record in
            guard let summary = record.summary else { return nil }
            let value: Double
            switch metric {
            case .foilTime: value = summary.rides.totalDuration / 60
            case .longestFlight: value = summary.rides.longestByDuration?.duration ?? 0
            case .pumps: value = Double(summary.pumps?.strokeCount ?? 0)
            }
            return value > 0 ? (record.startDate, value) : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mittari", selection: $metric) {
                ForEach(Metric.allCases) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
            .pickerStyle(.segmented)

            if data.isEmpty {
                Text("Ei vielä dataa tälle mittarille.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart(Array(data.enumerated()), id: \.offset) { _, item in
                    BarMark(
                        x: .value("Sessio", item.date, unit: .day),
                        y: .value(metric.displayName, item.value)
                    )
                    .foregroundStyle(.cyan)
                    .cornerRadius(3)
                }
                .frame(height: 130)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SessionRow: View {
    let record: SessionRecord

    var body: some View {
        HStack {
            SportIcon(sport: record.sport, size: 28)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading) {
                Text(record.sport.displayName).font(.headline)
                Text(record.startDate, format: .dateTime.day().month().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let spotName = record.spotName {
                        Text(spotName).font(.caption).foregroundStyle(.secondary)
                    }
                    if let rating = record.rating {
                        if rating == .insufficient {
                            Text("ei tuulta").font(.caption2).foregroundStyle(.orange)
                        } else {
                            StarBadge(value: rating.score, highlight: false)
                        }
                    }
                }
            }
            Spacer()
            if let summary = record.summary {
                VStack(alignment: .trailing) {
                    Text(Format.duration(summary.duration)).fontWeight(.medium)
                    if summary.sport.countsPumps, let pumps = summary.pumps {
                        Text("\(pumps.strokeCount) pumppua").font(.caption).foregroundStyle(.secondary)
                    } else if summary.sport.usesFoil {
                        Text("foili \(Format.percent(summary.rideFraction))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(Format.distance(summary.distance)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct SessionDetailView: View {
    let record: SessionRecord
    @Environment(\.modelContext) private var modelContext
    @State private var selectedFlightStart: TimeInterval?
    @State private var colorMode: SessionTrackMap.ColorMode = .foil

    var body: some View {
        List {
            if !record.track.isEmpty {
                Section {
                    SessionTrackMap(track: record.track,
                                    rides: record.summary?.rides.segments ?? [],
                                    selectedStart: selectedFlightStart,
                                    mode: colorMode,
                                    strokeTimes: record.summary?.pumps?.strokeTimes ?? [],
                                    maxSpeed: max(1, record.summary?.maxSpeed ?? 10))
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Väritys", selection: $colorMode) {
                            ForEach(SessionTrackMap.ColorMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(colorMode == .speed
                             ? "Vaalea = hidas, tumma = nopea. Pumppuiskut näkyvät valitulla suorituksella."
                             : "Vihreä = foililla. Pumppuiskut näkyvät valitulla suorituksella.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if record.sport.countsPumps {
                // Pumpparille tuuli ei ole se juttu — sää haetaan automaattisesti.
                if record.airTemp != nil || record.sessionWind != nil {
                    Section("Sää sessiossa") {
                        if let temp = record.airTemp {
                            LabeledContent("Lämpötila", value: String(format: "%.0f °C", temp))
                        }
                        if let wind = record.sessionWind {
                            LabeledContent("Tuuli", value: "\(Format.speedMs(wind.speed)) \(GeoMath.compassName(degrees: wind.direction))")
                        }
                    }
                }
            } else {
                Section {
                    RatingControl(rating: record.rating) { rating in
                        Task {
                            await RatingService.apply(rating: rating, to: record, context: modelContext)
                        }
                    }
                    if let wind = record.sessionWind {
                        LabeledContent("Tuuli sessiossa",
                                       value: "\(Format.speedMs(wind.speed)) (\(Format.speedMs(wind.gust))) \(GeoMath.compassName(degrees: wind.direction))")
                    }
                } header: {
                    Text("Millainen tuuli oli?")
                } footer: {
                    Text("Arvosanoista spotti oppii sopivat suunnat ja voimakkuudet — ja lopulta ennuste saa tähdet.")
                }
            }

            GearTagSection(record: record)

            if let summary = record.summary {
                Section("Yhteenveto") {
                    row("Kesto", Format.duration(summary.duration))
                    if summary.segments?.contains(where: { $0.kind != .water }) == true {
                        row("Vesillä", Format.duration(summary.waterDuration))
                    }
                    row("Matka", Format.distance(summary.distance))
                    row("Maksiminopeus", Format.speedKmh(summary.maxSpeed))
                    row("Keskinopeus liikkeessä", Format.speedKmh(summary.averageMovingSpeed))
                    if let heart = summary.heartRate {
                        row("Syke (keski / max)", "\(Int(heart.average.rounded())) / \(Int(heart.max.rounded()))")
                    }
                }
                if summary.sport.usesFoil {
                    Section("Foili") {
                        row("Foiliaika", "\(Format.duration(summary.rides.totalDuration)) (\(Format.percent(summary.rideFraction)))")
                        row("Lentoja", "\(summary.rides.count)")
                        if let longest = summary.rides.longestByDuration {
                            row("Pisin lento", "\(Format.duration(longest.duration)) · \(Format.distance(longest.distance))")
                        }
                        if summary.rides.count > 1 {
                            row("Keskilento", Format.duration(summary.rides.averageDuration))
                        }
                        row("Keskinopeus foililla", Format.speedKmh(summary.rides.averageSpeed))
                    }
                }
                if let pumps = summary.pumps {
                    Section("Pumppaus") {
                        if let attempts = summary.rides.attemptCount, let rate = summary.rides.successRate {
                            row("Startit", "\(summary.rides.count) / \(attempts) (\(Format.percent(rate)))")
                        }
                        row("Pumput", "\(pumps.strokeCount)")
                        row("Kadenssi", String(format: "%.0f/min", pumps.averageCadence))
                        row("Pumppausaika", Format.duration(pumps.totalBoutTime))
                        if let glide = sessionGlideRatio(summary) {
                            row("Liito-osuus", Format.percent(glide))
                        }
                        if let swimTime = pumps.swimTime {
                            row("Uinnissa", Format.duration(swimTime))
                        }
                    }
                }
                if summary.sport == .surf, summary.rides.count > 0 {
                    Section("Aallot") {
                        row("Aaltoja", "\(summary.rides.count)")
                        row("Aaltoaika", Format.duration(summary.rides.totalDuration))
                        if let longest = summary.rides.longestByDuration {
                            row("Pisin aalto", "\(Format.duration(longest.duration)) · \(Format.distance(longest.distance))")
                        }
                        row("Keskinopeus aallossa", Format.speedKmh(summary.rides.averageSpeed))
                    }
                }

                if let turns = summary.turns, turns.count > 0 {
                    Section("Käännökset") {
                        if let wind = record.sessionWind {
                            let jibes = turns.jibes(windDirection: wind.direction)
                            let tacks = turns.tacks(windDirection: wind.direction)
                            row("Jiipit", "\(jibes.count) (\(jibes.filter(\.onFoil).count) foilattua)")
                            row("Tackit", "\(tacks.count) (\(tacks.filter(\.onFoil).count) foilattua)")
                        } else {
                            row("Käännöksiä", "\(turns.count)")
                            row("Foilattuja läpi", "\(turns.foiledCount)")
                        }
                        if turns.count > 0 {
                            row("Foilattu läpi", Format.percent(Double(turns.foiledCount) / Double(turns.count)))
                        }
                    }
                }

                if let jumps = summary.jumps, let longest = jumps.longest {
                    Section("Hypyt") {
                        row("Hyppyjä", "\(jumps.count)")
                        row("Pisin air time", String(format: "%.1f s", longest.airTime))
                        row("Air time yhteensä", String(format: "%.1f s", jumps.totalAirTime))
                    }
                }

                if let dives = summary.dives {
                    Section("Sukellukset") {
                        row("Sukelluksia", "\(dives.count)")
                        row("Pinnan alla", Format.duration(dives.totalTime))
                        if let depth = dives.maxDepth {
                            row("Syvin", String(format: "%.1f m", depth))
                        }
                    }
                }

                if let records = summary.speedRecords {
                    Section("Huippunopeudet") {
                        row("Paras 2 s", Format.speedKmh(records.best2s))
                        row("Paras 10 s", Format.speedKmh(records.best10s))
                        if records.best100m > 0 {
                            row("Nopein 100 m", Format.speedKmh(records.best100m))
                        }
                    }
                }
                if let flights = summary.flights, !flights.isEmpty, summary.sport.usesFoil {
                    Section {
                        ForEach(Array(flights.enumerated()), id: \.element.id) { index, flight in
                            FlightRow(index: index + 1, flight: flight,
                                      showPumps: summary.sport.countsPumps,
                                      isSelected: selectedFlightStart == flight.start)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedFlightStart = selectedFlightStart == flight.start ? nil : flight.start
                                }
                        }
                    } header: {
                        Text("Suoritukset (\(flights.count))")
                    } footer: {
                        Text("Napauta suoritusta — sen reitti korostuu kartalla.")
                    }
                }
                if summary.sport == .surf {
                    Section("Aallot") {
                        row("Aaltoja", "\(summary.rides.count)")
                        if let longest = summary.rides.longestByDuration {
                            row("Pisin aalto", "\(Format.duration(longest.duration)) · \(Format.distance(longest.distance))")
                        }
                    }
                }
            }
        }
        .navigationTitle(record.startDate.formatted(.dateTime.day().month()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = gpxURL() {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            if let url = rawExportURL() {
                ShareLink(item: url) {
                    Image(systemName: "waveform.path")
                }
            }
        }
    }

    /// Raakadatapaketti kalibrointia varten: yhteenveto + jälki + kiihtyvyys + pumput.
    private func rawExportURL() -> URL? {
        guard let summary = record.summary else { return nil }
        let export = RawSessionExport(
            summary: summary,
            track: record.track,
            motionPacked: record.motionData,
            strokeTimes: summary.pumps?.strokeTimes
        )
        guard let data = try? JSONEncoder().encode(export) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noste-raw-\(Int(record.startDate.timeIntervalSince1970)).json")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// GPX-tiedosto jakoa varten (Strava tms.).
    private func gpxURL() -> URL? {
        let track = record.track
        guard !track.isEmpty else { return nil }
        let name = "\(record.sport.displayName) \(record.startDate.formatted(.dateTime.day().month().year()))"
        let gpx = GPXExporter.gpx(track: track, startDate: record.startDate, name: name)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noste-\(Int(record.startDate.timeIntervalSince1970)).gpx")
        do {
            try gpx.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Koko session liito-osuus lentojen pumppausajoista.
    private func sessionGlideRatio(_ summary: SessionSummary) -> Double? {
        guard let flights = summary.flights, summary.rides.totalDuration > 0 else { return nil }
        let pumping = flights.compactMap(\.pumpingTime).reduce(0, +)
        guard pumping > 0 || flights.contains(where: { $0.pumpingTime != nil }) else { return nil }
        return max(0, min(1, 1 - pumping / summary.rides.totalDuration))
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}

/// Yksittäinen suoritus: kesto, matka, pumput, frekvenssi, vauhdit.
/// Reitti näkyy kartalla vihreänä samalla aikaikkunalla.
private struct FlightRow: View {
    let index: Int
    let flight: FlightDetail
    let showPumps: Bool
    var isSelected = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("#\(index)")
                .font(.caption.weight(isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? .orange : .secondary)
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.duration(flight.duration)) · \(Format.distance(flight.distance))")
                    .font(.subheadline.weight(.medium))
                if showPumps {
                    Text(pumpLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("max \(Format.speedKmh(flight.maxSpeed))")
                    .font(.subheadline)
                Text("ka \(Format.speedKmh(flight.averageSpeed))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(isSelected ? Color.orange.opacity(0.08) : nil)
    }

    private var pumpLine: String {
        var text = String(format: "%d pumppua · %.0f/min", flight.strokeCount, flight.cadence)
        if let glide = flight.glideRatio {
            text += " · liito \(Format.percent(glide))"
        }
        return text
    }
}

/// Reitti kartalla. Foili-tilassa foilijaksot vihreällä; nopeus-tilassa jälki
/// väritetään yhden sävyn asteikolla (vaalea = hidas, tumma = nopea). Valittu
/// suoritus korostuu oranssilla ja sen pumppuiskut piirretään pisteinä reitille.
struct SessionTrackMap: View {
    enum ColorMode: String, CaseIterable, Identifiable {
        case foil
        case speed

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .foil: return "Foili"
            case .speed: return "Nopeus"
            }
        }
    }

    let track: [TrackPoint]
    let rides: [RideSegment]
    var selectedStart: TimeInterval?
    var mode: ColorMode = .foil
    var strokeTimes: [TimeInterval] = []
    var maxSpeed: Double = 10

    /// Sekventiaalinen yhden sävyn asteikko (vaalea → tumma).
    private static let speedColors: [Color] = [
        Color(red: 0.70, green: 0.93, blue: 1.00),
        Color(red: 0.39, green: 0.82, blue: 1.00),
        Color(red: 0.04, green: 0.52, blue: 1.00),
        Color(red: 0.00, green: 0.25, blue: 0.87)
    ]

    var body: some View {
        Map {
            switch mode {
            case .foil:
                MapPolyline(coordinates: coordinates(of: track))
                    .stroke(.gray, lineWidth: 3)
                ForEach(Array(rides.enumerated()), id: \.offset) { _, ride in
                    let points = track.filter { $0.t >= ride.start && $0.t <= ride.end }
                    let selected = selectedStart == ride.start
                    MapPolyline(coordinates: coordinates(of: points))
                        .stroke(selected ? Color.orange : Color.green, lineWidth: selected ? 6 : 4)
                }
            case .speed:
                ForEach(speedChunks(), id: \.id) { chunk in
                    MapPolyline(coordinates: coordinates(of: chunk.points))
                        .stroke(Self.speedColors[chunk.bucket], lineWidth: 4)
                }
                if let selectedStart, let ride = rides.first(where: { $0.start == selectedStart }) {
                    let points = track.filter { $0.t >= ride.start && $0.t <= ride.end }
                    MapPolyline(coordinates: coordinates(of: points))
                        .stroke(.orange, lineWidth: 2)
                }
            }

            // Valitun suorituksen pumppuiskut reitillä.
            if let selectedStart, let ride = rides.first(where: { $0.start == selectedStart }) {
                ForEach(strokePositions(in: ride), id: \.t) { stroke in
                    Annotation("", coordinate: stroke.coordinate) {
                        Circle()
                            .fill(.cyan)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.white, lineWidth: 1))
                    }
                }
            }
        }
    }

    private func coordinates(of points: [TrackPoint]) -> [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Peräkkäiset samaan nopeusluokkaan kuuluvat pisteet yhdeksi viivaksi.
    private func speedChunks() -> [(id: Int, points: [TrackPoint], bucket: Int)] {
        var chunks: [(id: Int, points: [TrackPoint], bucket: Int)] = []
        var current: [TrackPoint] = []
        var currentBucket = -1
        for point in track {
            let speed = max(0, min(point.speed, maxSpeed))
            let bucket = min(Self.speedColors.count - 1, Int(speed / maxSpeed * Double(Self.speedColors.count)))
            if bucket != currentBucket {
                if current.count > 1 {
                    chunks.append((chunks.count, current, currentBucket))
                }
                current = current.isEmpty ? [point] : [current.last!, point]
                currentBucket = bucket
            } else {
                current.append(point)
            }
        }
        if current.count > 1 {
            chunks.append((chunks.count, current, currentBucket))
        }
        return chunks
    }

    /// Pumppuiskujen sijainnit suorituksen sisällä (lähin jälkipiste).
    private func strokePositions(in ride: RideSegment) -> [(t: TimeInterval, coordinate: CLLocationCoordinate2D)] {
        let points = track.filter { $0.t >= ride.start && $0.t <= ride.end }
        guard !points.isEmpty else { return [] }
        return strokeTimes
            .filter { $0 >= ride.start && $0 <= ride.end }
            .prefix(200)
            .compactMap { t in
                guard let nearest = points.min(by: { abs($0.t - t) < abs($1.t - t) }) else { return nil }
                return (t, CLLocationCoordinate2D(latitude: nearest.latitude, longitude: nearest.longitude))
            }
    }
}
