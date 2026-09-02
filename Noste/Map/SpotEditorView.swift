import SwiftUI
import NosteCore

struct SpotEditorView: View {
    enum Action {
        case save(SpotData)
        case delete
        case cancel
    }

    @State var draft: SpotData
    var onDone: (Action) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // Kelivahti on käyttäjän oma hälytys omalla rajalla — ei spotin ominaisuus.
    @State private var alertEnabled = false
    @State private var alertThreshold: Double = 6
    @State private var alertLoaded = false

    private let isNew: Bool
    @State private var hasWindLimits: Bool
    @State private var minWind: Double
    @State private var maxWind: Double

    private static let compassNames = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    /// isNew: kutsuja tietää, onko spotti jo tallennettu — nimestä ei voi
    /// päätellä (rantakohteesta luotu spotti tulee nimen kanssa).
    init(draft: SpotData, isNew: Bool? = nil, onDone: @escaping (Action) -> Void) {
        _draft = State(initialValue: draft)
        self.onDone = onDone
        self.isNew = isNew ?? draft.name.isEmpty
        _hasWindLimits = State(initialValue: draft.minWind != nil || draft.maxWind != nil)
        _minWind = State(initialValue: draft.minWind ?? 6)
        _maxWind = State(initialValue: draft.maxWind ?? 15)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Spotti") {
                    TextField("Nimi", text: $draft.name)
                    Picker("Vesistö", selection: $draft.waterType) {
                        ForEach(WaterType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    Toggle("Suosikki", isOn: $draft.isFavorite)
                }

                Section("Lajit") {
                    ForEach(Sport.allCases) { sport in
                        Toggle(sport.displayName, isOn: sportBinding(sport))
                    }
                }

                Section {
                    directionGrid
                    Toggle("Voimakkuusrajat", isOn: $hasWindLimits)
                    if hasWindLimits {
                        windSlider("Vähintään", value: $minWind, range: 2...20)
                        windSlider("Enintään", value: $maxWind, range: 4...30)
                    }
                } header: {
                    Text("Tuuli-ikkuna")
                } footer: {
                    Text("Toimivat suunnat ja voimakkuus. Ennusteesta korostetaan ikkunaan osuvat tunnit — myös kellossa.")
                }

                // Vain oma palvelin: kelivahti vaatii täyden tokenin, sisäänrakennettu
                // client-token ei riitä.
                if ServerSettings.userConfigured != nil {
                    Section {
                        Toggle("Kelivahti", isOn: $alertEnabled)
                        if alertEnabled {
                            Stepper(value: $alertThreshold, in: 3...25, step: 1) {
                                HStack {
                                    Text("Hälytysraja")
                                    Spacer()
                                    Text("\(Int(alertThreshold)) m/s").foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Oma hälytys")
                    } footer: {
                        Text(alertEnabled
                             ? "Ilmoitus (ntfy), kun ennuste ylittää rajan vähintään 2 h putkeen\(draft.goodDirections?.isEmpty == false ? " spotin toimivista suunnista" : ""). Raja on sinun, ei spotin."
                             : "Henkilökohtainen ilmoitus tämän paikan ennusteesta. Spotin tuuli-ikkuna kuvaa spottia, hälytysraja on oma valintasi.")
                    }
                    .onChange(of: alertEnabled) { _, _ in saveAlert() }
                    .onChange(of: alertThreshold) { _, _ in saveAlert() }
                }

                Section {
                    Picker("Näkyvyys", selection: publicBinding) {
                        Text("Secret spot").tag(false)
                        Text("Julkinen").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(draft.isPublic == true
                         ? "Julkinen spotti näkyy kaikille Nosten käyttäjille kartalla, ja muut voivat jakaa kokemuksiaan siitä."
                         : "Secret spot näkyy vain sinulle. 🤫")
                }

                Section("Muistiinpanot") {
                    TextField("Esim. pysäköinti, karikot, laituri…", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    LabeledContent("Sijainti", value: String(format: "%.4f, %.4f", draft.latitude, draft.longitude))
                }

                if !isNew {
                    Section {
                        Button("Poista spotti", role: .destructive) {
                            onDone(.delete)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear(perform: loadAlert)
            .navigationTitle(isNew ? "Uusi spotti" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Peru") {
                        onDone(.cancel)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tallenna") {
                        var data = draft
                        if data.name.isEmpty { data.name = "Nimetön spotti" }
                        data.minWind = hasWindLimits ? min(minWind, maxWind) : nil
                        data.maxWind = hasWindLimits ? max(minWind, maxWind) : nil
                        onDone(.save(data))
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Tuuli-ikkuna

    /// Kelivahti tarvitsee minimituulen: pelkkä suunta osuisi myös tyveneen.
    private var windowDefined: Bool {
        hasWindLimits
    }

    private var directionGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Toimivat suunnat")
                .font(.subheadline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                ForEach(0..<8, id: \.self) { index in
                    let selected = draft.goodDirections?.contains(index) == true
                    Button {
                        toggleDirection(index)
                    } label: {
                        Text(Self.compassNames[index])
                            .font(.subheadline.weight(selected ? .bold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(selected ? Color.accentColor : Color(.systemGray5),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggleDirection(_ index: Int) {
        var directions = draft.goodDirections ?? []
        if let position = directions.firstIndex(of: index) {
            directions.remove(at: position)
        } else {
            directions.append(index)
        }
        draft.goodDirections = directions.isEmpty ? nil : directions.sorted()
    }

    private func windSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(Format.speedMs(value.wrappedValue)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
        }
    }

    private var publicBinding: Binding<Bool> {
        Binding(
            get: { draft.isPublic ?? false },
            set: { draft.isPublic = $0 ? true : nil }
        )
    }

    private func loadAlert() {
        guard !alertLoaded else { return }
        alertLoaded = true
        if let existing = AlertStore.alert(for: draft.id, context: modelContext) {
            alertEnabled = existing.enabled
            alertThreshold = existing.minWind
        } else {
            alertThreshold = draft.minWind ?? 6
        }
    }

    /// Hälytys talletetaan heti (oma tietue, ei osa spottia) ja viedään palvelimelle.
    private func saveAlert() {
        guard alertLoaded else { return }
        AlertStore.upsert(WindAlert(
            id: AlertStore.alert(for: draft.id, context: modelContext)?.id ?? UUID(),
            spotId: draft.id,
            spotName: draft.name.isEmpty ? "Nimetön spotti" : draft.name,
            latitude: draft.latitude,
            longitude: draft.longitude,
            waterType: draft.waterType,
            minWind: alertThreshold,
            goodDirections: draft.goodDirections?.isEmpty == false ? draft.goodDirections : nil,
            enabled: alertEnabled
        ), context: modelContext)
    }

    private func sportBinding(_ sport: Sport) -> Binding<Bool> {
        Binding(
            get: { draft.sports.contains(sport) },
            set: { on in
                if on {
                    if !draft.sports.contains(sport) { draft.sports.append(sport) }
                } else {
                    draft.sports.removeAll { $0 == sport }
                }
            }
        )
    }
}
