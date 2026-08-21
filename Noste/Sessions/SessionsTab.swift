import SwiftUI
import SwiftData
import MapKit
import NosteCore

struct SessionsTab: View {
    @Query(sort: \SessionRecord.startDate, order: .reverse) private var sessions: [SessionRecord]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "Ei sessioita",
                        systemImage: "figure.surfing",
                        description: Text("Aloita sessio kellosta — se ilmestyy tänne automaattisesti.")
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
                if let spotName = record.spotName {
                    Text(spotName).font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        List {
            if !record.track.isEmpty {
                Section {
                    SessionTrackMap(track: record.track, rides: record.summary?.rides.segments ?? [])
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                }
            }
            if let summary = record.summary {
                Section("Yhteenveto") {
                    row("Kesto", Format.duration(summary.duration))
                    row("Matka", Format.distance(summary.distance))
                    row("Maksiminopeus", Format.speedKmh(summary.maxSpeed))
                    row("Keskinopeus liikkeessä", Format.speedKmh(summary.averageMovingSpeed))
                }
                if summary.sport.usesFoil {
                    Section("Foili") {
                        row("Foiliaika", "\(Format.duration(summary.rides.totalDuration)) (\(Format.percent(summary.rideFraction)))")
                        row("Lentoja", "\(summary.rides.count)")
                        if let longest = summary.rides.longestByDuration {
                            row("Pisin lento", "\(Format.duration(longest.duration)) · \(Format.distance(longest.distance))")
                        }
                        row("Keskinopeus foililla", Format.speedKmh(summary.rides.averageSpeed))
                    }
                }
                if let pumps = summary.pumps {
                    Section("Pumppaus") {
                        row("Pumput", "\(pumps.strokeCount)")
                        row("Kadenssi", String(format: "%.0f/min", pumps.averageCadence))
                        row("Pumppausjaksoja", "\(pumps.bouts.count)")
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
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}

/// Reitti kartalla: foilijaksot korostettuna vihreällä.
struct SessionTrackMap: View {
    let track: [TrackPoint]
    let rides: [RideSegment]

    var body: some View {
        Map {
            MapPolyline(coordinates: track.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            })
            .stroke(.gray, lineWidth: 3)

            ForEach(Array(rides.enumerated()), id: \.offset) { _, ride in
                let points = track.filter { $0.t >= ride.start && $0.t <= ride.end }
                MapPolyline(coordinates: points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(.green, lineWidth: 4)
            }
        }
    }
}
