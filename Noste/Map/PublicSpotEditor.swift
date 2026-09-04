import SwiftUI
import NosteCore

/// Julkisen spotin wiki-muokkaus: kuka tahansa nimimerkillä kirjautunut voi
/// täydentää kuvausta, lajeja, suuntia ja rajoja. Sijainti ja nimi ovat
/// omistajan — ne näytetään, ei muokata.
struct PublicSpotEditor: View {
    let spot: ServerClient.PublicSpot
    var onSaved: (ServerClient.PublicSpot) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var description: String
    @State private var sports: Set<String>
    @State private var directions: [Int]?
    @State private var hasLimits: Bool
    @State private var minWind: Double
    @State private var maxWind: Double
    @State private var saving = false
    @State private var error: String?

    init(spot: ServerClient.PublicSpot, onSaved: @escaping (ServerClient.PublicSpot) -> Void) {
        self.spot = spot
        self.onSaved = onSaved
        _description = State(initialValue: spot.description ?? "")
        _sports = State(initialValue: Set(spot.sports))
        _directions = State(initialValue: spot.goodDirections)
        _hasLimits = State(initialValue: spot.minWind != nil || spot.maxWind != nil)
        _minWind = State(initialValue: spot.minWind ?? 6)
        _maxWind = State(initialValue: spot.maxWind ?? 15)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pysäköinti, launch, karikot, etiketti…", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Kuvaus")
                } footer: {
                    Text("Yhteinen teksti — kirjoita niin kuin toivoisit itse lukevasi. Historia tallentaa jokaisen version.")
                }
                Section("Lajit") {
                    ForEach(Sport.allCases) { sport in
                        Toggle(sport.displayName, isOn: Binding(
                            get: { sports.contains(sport.rawValue) },
                            set: { on in if on { sports.insert(sport.rawValue) } else { sports.remove(sport.rawValue) } }
                        ))
                    }
                }
                Section("Toimivat suunnat") {
                    HStack { Spacer(); CompassRoseSelector(selected: $directions); Spacer() }
                }
                Section("Voimakkuusrajat") {
                    Toggle("Rajat käytössä", isOn: $hasLimits)
                    if hasLimits {
                        Stepper("Vähintään \(Int(minWind)) m/s", value: $minWind, in: 2...25, step: 1)
                        Stepper("Enintään \(Int(maxWind)) m/s", value: $maxWind, in: 4...35, step: 1)
                    }
                }
                Section {
                    LabeledContent("Nimi", value: spot.name)
                    LabeledContent("Sijainti", value: String(format: "%.4f, %.4f", spot.latitude, spot.longitude))
                } footer: {
                    Text("Nimen ja sijainnin muuttaa vain spotin lisääjä.")
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .navigationTitle("Täydennä spottia")
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .listRowBackground(Theme.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Peru") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "…" : "Tallenna") { Task { await save() } }.disabled(saving)
                }
            }
        }
    }

    private func save() async {
        saving = true
        var updated = spot
        updated.description = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
        updated.sports = Sport.allCases.map(\.rawValue).filter { sports.contains($0) }
        updated.goodDirections = directions
        updated.minWind = hasLimits ? minWind : nil
        updated.maxWind = hasLimits ? min(maxWind, 35) : nil
        if let saved = await ServerClient.shared.updatePublicSpot(updated) {
            onSaved(saved)
            dismiss()
        } else {
            error = "Tallennus ei onnistunut. Tarkista että olet kirjautunut ja nimimerkki on asetettu."
        }
        saving = false
    }
}

/// Muokkaushistoria: kuka, milloin, ja palautus versioon.
struct PublicSpotHistoryView: View {
    let spotID: String
    var onRestored: () -> Void
    @State private var revisions: [ServerClient.SpotRevision]?
    @State private var confirm: ServerClient.SpotRevision?

    var body: some View {
        List {
            if let revisions {
                if revisions.isEmpty { Text("Ei historiaa.").foregroundStyle(.secondary) }
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(revision.editor).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(ISO8601.parse(revision.createdAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(summary(revision.data)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        if index == 0 {
                            Text("Nykyinen versio").font(.caption2).foregroundStyle(.tint)
                        } else {
                            Button("Palauta tämä versio") { confirm = revision }.font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Historia")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .listRowBackground(Theme.surface)
        .task { revisions = await ServerClient.shared.spotHistory(spotID: spotID) }
        .confirmationDialog("Palautetaanko tämä versio?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Palauta") {
                guard let revision = confirm else { return }
                confirm = nil
                Task {
                    if await ServerClient.shared.restoreRevision(spotID: spotID, revisionID: revision.id) {
                        revisions = await ServerClient.shared.spotHistory(spotID: spotID)
                        onRestored()
                    }
                }
            }
            Button("Peru", role: .cancel) { confirm = nil }
        } message: {
            Text("Palautus tekee uuden version vanhalla sisällöllä — mitään ei katoa historiasta.")
        }
    }

    private func summary(_ data: [String: ServerClient.JSONValue]) -> String {
        var parts: [String] = []
        if case .string(let d)? = data["description"], !d.isEmpty { parts.append(d) }
        if case .array(let dirs)? = data["goodDirections"], !dirs.isEmpty {
            let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
            parts.append(dirs.compactMap { if case .number(let n) = $0, Int(n) < 8 { return names[Int(n)] } else { return nil } }.joined(separator: " "))
        }
        if case .number(let min)? = data["minWind"] { parts.append("≥ \(Int(min)) m/s") }
        return parts.isEmpty ? "Perustiedot" : parts.joined(separator: " · ")
    }
}
