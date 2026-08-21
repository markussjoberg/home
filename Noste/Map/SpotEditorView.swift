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

    init(draft: SpotData, onDone: @escaping (Action) -> Void) {
        _draft = State(initialValue: draft)
        self.onDone = onDone
        self.isNew = draft.name.isEmpty
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
                        Toggle(sport.displayName, isOn: Binding(
                            get: { draft.sports.contains(sport) },
                            set: { on in
                                if on {
                                    if !draft.sports.contains(sport) { draft.sports.append(sport) }
                                } else {
                                    draft.sports.removeAll { $0 == sport }
                                }
                            }
                        ))
                    }
                }

                Section("Muistiinpanot") {
                    TextField("Esim. toimivat tuulensuunnat, pysäköinti…", text: $draft.notes, axis: .vertical)
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
                        onDone(.save(data))
                        dismiss()
                    }
                }
            }
        }
    }
}
