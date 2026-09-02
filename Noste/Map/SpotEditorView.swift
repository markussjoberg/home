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
                    Picker("Näkyvyys", selection: visibilityBinding) {
                        Text("Secret").tag(Visibility.secret)
                        Text("Julkinen").tag(Visibility.publicExact)
                        Text("Karkea").tag(Visibility.publicCoarse)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(visibilityFooter)
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
            HStack {
                Spacer()
                CompassRoseSelector(selected: $draft.goodDirections)
                Spacer()
            }
            Text(draft.goodDirections?.isEmpty == false
                 ? "Valittu: " + (draft.goodDirections ?? []).map { Self.compassNames[$0] }.joined(separator: ", ")
                 : "Ei valintaa — kaikki suunnat käyvät.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    private enum Visibility: Hashable { case secret, publicExact, publicCoarse }

    /// Julkinen spotti on yhteinen — kerrotaan se jo valinnassa, ei vasta poistossa.
    private var visibilityBinding: Binding<Visibility> {
        Binding(
            get: {
                guard draft.isPublic == true else { return .secret }
                return draft.coarseLocation == true ? .publicCoarse : .publicExact
            },
            set: { value in
                draft.isPublic = value == .secret ? nil : true
                draft.coarseLocation = value == .publicCoarse ? true : nil
            }
        )
    }

    private var visibilityFooter: String {
        switch visibilityBinding.wrappedValue {
        case .secret:
            return "Secret spot näkyy vain sinulle. 🤫"
        case .publicExact:
            return "Julkinen spotti on yhteinen: se näkyy kaikille kartalla, muut voivat kommentoida ja täydentää tietoja, ja muistiinpanosi lähtevät kuvaukseksi. Kun muut ovat lisänneet sisältöä, poisto etenee ehdotuksena."
        case .publicCoarse:
            return "Kuten julkinen, mutta muille näytetään sijainti noin kilometrin tarkkuudella — ranta löytyy, launch-paikka ei. Sinä näet tarkan."
        }
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
