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

    private let isNew: Bool
    @State private var hasWindLimits: Bool
    @State private var minWind: Double
    @State private var maxWind: Double

    private static let compassNames = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    init(draft: SpotData, onDone: @escaping (Action) -> Void) {
        _draft = State(initialValue: draft)
        self.onDone = onDone
        self.isNew = draft.name.isEmpty
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

                if ServerSettings.current != nil {
                    Section {
                        Toggle("Kelivahti", isOn: alertBinding)
                            .disabled(!windowDefined)
                    } footer: {
                        Text(windowDefined
                             ? "Palvelin vahtii ennustetta ja ilmoittaa (ntfy), kun tuuli-ikkuna osuu vähintään 2 h putkeen."
                             : "Määritä ensin tuuli-ikkuna, niin kelivahdilla on mitä vahtia.")
                    }
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

    private var windowDefined: Bool {
        hasWindLimits || draft.goodDirections?.isEmpty == false
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

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { draft.alertEnabled ?? false },
            set: { draft.alertEnabled = $0 ? true : nil }
        )
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
