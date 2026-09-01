import SwiftUI
import SwiftData
import NosteCore

/// Julkisen spotin kortti: tiedot, tuuli-ikkuna, kommentit ("millä keleillä
/// toimii") ja tallennus omiin spotteihin.
struct PublicSpotView: View {
    let spot: ServerClient.PublicSpot
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var ownSpots: [SpotRecord]

    @AppStorage("nickname") private var nickname = ""
    @State private var comments: [ServerClient.SpotComment]?
    @State private var newComment = ""
    @State private var sending = false
    @State private var saved = false

    private var alreadyOwn: Bool {
        saved || ownSpots.contains { $0.id.uuidString == spot.id }
    }

    private var windowText: String? {
        var parts: [String] = []
        if let directions = spot.goodDirections, !directions.isEmpty {
            parts.append(directions.map { GeoMath.compassName(degrees: Double($0) * 45) }.joined(separator: ", "))
        }
        if let min = spot.minWind, let max = spot.maxWind {
            parts.append("\(Int(min))–\(Int(max)) m/s")
        } else if let min = spot.minWind {
            parts.append("≥ \(Int(min)) m/s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !spot.sports.isEmpty {
                        HStack(spacing: 14) {
                            ForEach(spot.sports.compactMap(Sport.init(rawValue:))) { sport in
                                VStack(spacing: 4) {
                                    SportIcon(sport: sport, size: 26).foregroundStyle(.tint)
                                    Text(sport.displayName).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    if let windowText {
                        Label(windowText, systemImage: "wind")
                            .font(.subheadline)
                    }
                    LabeledContent("Vesistö", value: spot.waterType == "sea" ? "Meri" : "Järvi")
                } header: {
                    Text("Spotti")
                }

                Section {
                    NavigationLink {
                        SpotForecastView(spot: SpotData(
                            id: UUID(),
                            name: spot.name,
                            latitude: spot.latitude,
                            longitude: spot.longitude,
                            waterType: WaterType(rawValue: spot.waterType) ?? .lake,
                            sports: spot.sports.compactMap(Sport.init(rawValue:)),
                            goodDirections: spot.goodDirections,
                            minWind: spot.minWind,
                            maxWind: spot.maxWind
                        ), allSpots: [])
                    } label: {
                        Label("Ennuste", systemImage: "wind")
                    }
                    Button {
                        let data = SpotData(
                            id: UUID(uuidString: spot.id) ?? UUID(),
                            name: spot.name,
                            latitude: spot.latitude,
                            longitude: spot.longitude,
                            waterType: WaterType(rawValue: spot.waterType) ?? .lake,
                            sports: spot.sports.compactMap(Sport.init(rawValue:)),
                            isFavorite: false,
                            notes: "",
                            goodDirections: spot.goodDirections,
                            minWind: spot.minWind,
                            maxWind: spot.maxWind
                        )
                        modelContext.insert(SpotRecord(from: data))
                        try? modelContext.save()
                        saved = true
                    } label: {
                        Label(alreadyOwn ? "Omissa spoteissa" : "Tallenna omiin spotteihin",
                              systemImage: alreadyOwn ? "checkmark.circle.fill" : "plus.circle")
                    }
                    .disabled(alreadyOwn)
                }

                Section {
                    if let comments {
                        if comments.isEmpty {
                            Text("Ei vielä kommentteja — kerro ensimmäisenä millä keleillä täällä toimii.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(comments) { comment in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(comment.author).font(.subheadline.weight(.semibold))
                                    if let wind = comment.windMs {
                                        Text("\(Format.speedMs(wind))\(comment.windDir.map { " \(GeoMath.compassName(degrees: $0))" } ?? "")")
                                            .font(.caption)
                                            .foregroundStyle(.cyan)
                                    }
                                    Spacer()
                                    Text(Self.dateText(comment.createdAt))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(comment.text).font(.subheadline)
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        ProgressView()
                    }

                    VStack(spacing: 8) {
                        if nickname.isEmpty {
                            TextField("Nimimerkki", text: $nickname)
                                .textInputAutocapitalization(.never)
                        }
                        HStack {
                            TextField("Millä keleillä toimii?", text: $newComment, axis: .vertical)
                                .lineLimit(1...4)
                            Button {
                                send()
                            } label: {
                                Image(systemName: "paperplane.fill")
                            }
                            .disabled(sending || newComment.trimmingCharacters(in: .whitespaces).isEmpty
                                      || nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } header: {
                    Text("Kokemukset")
                }
            }
            .navigationTitle(spot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sulje") { dismiss() }
                }
            }
            .task {
                comments = await ServerClient.shared.spotComments(spotID: spot.id) ?? []
            }
        }
    }

    private func send() {
        let author = nickname.trimmingCharacters(in: .whitespaces)
        let text = newComment.trimmingCharacters(in: .whitespaces)
        guard !author.isEmpty, !text.isEmpty else { return }
        sending = true
        Task {
            if await ServerClient.shared.postComment(spotID: spot.id, author: author, text: text) {
                newComment = ""
                comments = await ServerClient.shared.spotComments(spotID: spot.id) ?? comments
            }
            sending = false
        }
    }

    private static func dateText(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(.dateTime.day().month())
    }
}
