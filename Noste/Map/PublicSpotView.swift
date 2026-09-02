import SwiftUI
import SwiftData
import NosteCore

/// Julkisen spotin kortti: tiedot, tuuli-ikkuna, kommentit ("millä keleillä
/// toimii") ja tallennus omiin spotteihin.
struct PublicSpotView: View {
    /// Alkuarvo listasta; wiki-muokkaus ja palautus päivittävät `spot`-tilan.
    init(spot: ServerClient.PublicSpot) {
        _spot = State(initialValue: spot)
    }

    @State private var spot: ServerClient.PublicSpot
    @State private var editing = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var ownSpots: [SpotRecord]

    @AppStorage("nickname") private var nickname = ""
    @ObservedObject private var account = UserAccount.shared
    @State private var comments: [ServerClient.SpotComment]?
    @State private var newComment = ""
    @State private var sending = false
    @State private var saved = false
    @State private var reportTarget: (type: String, id: String)?
    @State private var reportReason = ""
    @State private var reportSent = false
    @State private var deletionProposed: String? = nil
    @State private var objected = false

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
                deletionSection

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
                    if let description = spot.description, !description.isEmpty {
                        Text(description).font(.subheadline)
                    }
                    NavigationLink {
                        PublicSpotHistoryView(spotID: spot.id) { Task { await reloadSpot() } }
                    } label: {
                        Label("Muokkaushistoria", systemImage: "clock.arrow.circlepath").font(.subheadline)
                    }
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

                commentsSection
            }
            .navigationTitle(spot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sulje") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if account.user?.nickname != nil {
                            Button("Täydennä tietoja", systemImage: "pencil") { editing = true }
                        } else {
                            Text("Kirjaudu ja aseta nimimerkki, niin voit täydentää spotin tietoja.")
                        }
                        Button("Ilmoita spotti", systemImage: "flag") { reportTarget = ("spot", spot.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Lisää toimintoja")
                }
            }
            .alert("Ilmoita asiaton sisältö", isPresented: Binding(get: { reportTarget != nil }, set: { if !$0 { reportTarget = nil } })) {
                TextField("Miksi? (lyhyesti)", text: $reportReason)
                Button("Lähetä") {
                    guard let target = reportTarget else { return }
                    let reason = reportReason.trimmingCharacters(in: .whitespaces)
                    reportTarget = nil
                    reportReason = ""
                    Task { reportSent = await ServerClient.shared.report(targetType: target.type, targetID: target.id, reason: reason.isEmpty ? "asiaton" : reason) }
                }
                Button("Peru", role: .cancel) { reportTarget = nil }
            } message: {
                Text("Ilmoitus menee ylläpidolle. Kiitos, että pidät yhteisön asiallisena.")
            }
            .alert("Ilmoitus lähetetty", isPresented: $reportSent) { Button("OK") {} }
            .sheet(isPresented: $editing) {
                PublicSpotEditor(spot: spot) { updated in spot = updated }
            }
            .task {
                deletionProposed = spot.deletionProposed
                comments = await ServerClient.shared.spotComments(spotID: spot.id) ?? []
            }
        }
    }


    @ViewBuilder
    private var deletionSection: some View {
        if let decidesAt = deletionProposed {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Poistoehdotus").font(.subheadline.weight(.semibold))
                        Text("Luoja haluaa poistaa spotin. Poisto toteutuu \(Self.dateText(decidesAt)), ellei kukaan spottiin osallistunut vastusta.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if objected {
                    Text("Vastustuksesi on kirjattu — spotti säilyy.").font(.caption).foregroundStyle(.green)
                } else {
                    Button("Vastusta poistoa") {
                        Task {
                            if await ServerClient.shared.objectDeletion(spotID: spot.id) {
                                objected = true
                                deletionProposed = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private var commentsSection: some View {
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
                    .contextMenu {
                        if let me = account.user?.id, comment.userId == me {
                            Button("Poista kommenttini", role: .destructive) {
                                Task {
                                    if await ServerClient.shared.deleteComment(spotID: spot.id, commentID: comment.id) {
                                        self.comments = await ServerClient.shared.spotComments(spotID: spot.id) ?? comments
                                    }
                                }
                            }
                        } else {
                            Button("Ilmoita kommentti", systemImage: "flag") {
                                reportTarget = ("comment", comment.id)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }

            VStack(spacing: 8) {
                // Kirjautuneella kirjoittaja on tilin nimimerkki (palvelin pakottaa sen).
                if let accountName = account.user?.nickname, !accountName.isEmpty {
                    Text("Kommentoit nimellä \(accountName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if nickname.isEmpty {
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
                              || effectiveAuthor.isEmpty)
                }
            }
        } header: {
            Text("Kokemukset")
        }
    }

    /// Palautuksen tai muokkauksen jälkeen: tuorein versio listauksesta.
    private func reloadSpot() async {
        if let fresh = (await ServerClient.shared.publicSpots())?.first(where: { $0.id == spot.id }) {
            spot = fresh
        }
    }

    private var effectiveAuthor: String {
        (account.user?.nickname ?? nickname).trimmingCharacters(in: .whitespaces)
    }

    private func send() {
        let author = effectiveAuthor
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
        guard let date = ISO8601.parse(iso) else { return "" }
        return date.formatted(.dateTime.day().month())
    }
}
