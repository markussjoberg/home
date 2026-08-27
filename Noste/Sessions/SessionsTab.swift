import SwiftUI
import SwiftData
import MapKit
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

private struct SessionRow: View {
    let record: SessionRecord

    var body: some View {
        HStack {
            Image(systemName: record.sport.symbolName)
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 32)
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

    var body: some View {
        List {
            if !record.track.isEmpty {
                Section {
                    SessionTrackMap(track: record.track,
                                    rides: record.summary?.rides.segments ?? [],
                                    selectedStart: selectedFlightStart)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                }
            }
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

            if let summary = record.summary {
                Section("Yhteenveto") {
                    row("Kesto", Format.duration(summary.duration))
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

/// Reitti kartalla: foilijaksot vihreällä, valittu suoritus oranssilla.
struct SessionTrackMap: View {
    let track: [TrackPoint]
    let rides: [RideSegment]
    var selectedStart: TimeInterval?

    var body: some View {
        Map {
            MapPolyline(coordinates: track.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            })
            .stroke(.gray, lineWidth: 3)

            ForEach(Array(rides.enumerated()), id: \.offset) { _, ride in
                let points = track.filter { $0.t >= ride.start && $0.t <= ride.end }
                let selected = selectedStart == ride.start
                MapPolyline(coordinates: points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(selected ? Color.orange : Color.green, lineWidth: selected ? 6 : 4)
            }
        }
    }
}
