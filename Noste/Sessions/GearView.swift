import SwiftUI
import SwiftData
import NosteCore

/// Oma kalusto: lista tyypeittäin, lisäys/muokkaus ja Lappis-ehdotukset.
/// Ehdotusten tuotteet ja hinnat tulevat lappis.fi:n julkisesta katalogista
/// palvelimen välimuistin kautta — linkit vievät kauppaan. (Kaupallista
/// yhteistyötä ei vielä ole; tämä on pilotti jota pitchataan Lappikselle.)
struct GearView: View {
    @Query(sort: \GearRecord.createdAt) private var gear: [GearRecord]
    @Environment(\.modelContext) private var modelContext
    @State private var editing: GearRecord?
    @State private var showAdd = false
    @State private var catalog: [GearCatalogItem] = []

    private var suggestions: [GearSuggestion] {
        GearAdvisor.suggestions(
            quiver: gear.map(\.info),
            catalog: catalog,
            currentYear: Calendar.current.component(.year, from: Date())
        )
    }

    var body: some View {
        List {
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { suggestion in
                        LappisSuggestionCard(suggestion: suggestion)
                    }
                } header: {
                    Text("Lappis suosittelee")
                } footer: {
                    Text("Tuotteet ja hinnat: lappis.fi. Ehdotus perustuu vain oman kalustosi aukkoihin — ei mainontaa, ei kaupallista yhteistyötä (pilotti).")
                }
            }

            if gear.isEmpty {
                ContentUnavailableView(
                    "Ei kalustoa",
                    systemImage: "backpack",
                    description: Text("Lisää siivet, laudat ja foilit — sessiot voi tägätä kalustoon, ja näet millä setillä mikäkin sessio meni.")
                )
            } else {
                ForEach(GearType.allCases) { type in
                    let items = gear.filter { $0.type == type }
                    if !items.isEmpty {
                        Section(type.displayName + (items.count > 1 ? "t" : "")) {
                            ForEach(items) { item in
                                Button {
                                    editing = item
                                } label: {
                                    Label(item.displayName, systemImage: type.symbolName)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .onDelete { offsets in
                                for offset in offsets { modelContext.delete(items[offset]) }
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Kalusto")
        .task {
            if catalog.isEmpty, let items = await ServerClient.shared.shopCatalog() {
                catalog = items
            }
        }
        .toolbar {
            Button {
                showAdd = true
            } label: {
                Image(systemName: "plus.circle")
            }
        }
        .sheet(isPresented: $showAdd) {
            GearEditorView(record: nil)
        }
        .sheet(item: $editing) { record in
            GearEditorView(record: record)
        }
    }
}

/// Session kalustotägäys: mitä setistä käytettiin. Tallentuu SessionRecordiin,
/// jolloin kehitystä voi myöhemmin verrata kalustoittain.
struct GearTagSection: View {
    let record: SessionRecord
    @Query(sort: \GearRecord.createdAt) private var gear: [GearRecord]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Section {
            if gear.isEmpty {
                NavigationLink {
                    GearView()
                } label: {
                    Label("Lisää kalustosi, niin sessiot voi tägätä setteihin", systemImage: "backpack")
                        .font(.subheadline)
                }
            } else {
                ForEach(gear) { item in
                    Button {
                        toggle(item.id)
                    } label: {
                        HStack {
                            Label(item.displayName, systemImage: item.type.symbolName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if record.gearIDs?.contains(item.id) == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Kalusto")
        }
    }

    private func toggle(_ id: UUID) {
        var ids = Set(record.gearIDs ?? [])
        if !ids.insert(id).inserted { ids.remove(id) }
        record.gearIDs = ids.isEmpty ? nil : Array(ids)
        try? modelContext.save()
    }
}

/// Yksi Lappis-ehdotus: syy + tuote + linkki kauppaan.
struct LappisSuggestionCard: View {
    let suggestion: GearSuggestion
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: suggestion.item.url) { openURL(url) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Image(systemName: suggestion.item.type.symbolName)
                        .foregroundStyle(.orange)
                    Text(suggestion.item.name)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(suggestion.item.price) €")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Kalustoyksilön lisäys/muokkaus.
struct GearEditorView: View {
    let record: GearRecord?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var type: GearType = .wing
    @State private var name = ""
    @State private var sizeText = ""
    @State private var yearText = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Tyyppi", selection: $type) {
                    ForEach(GearType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                TextField("Merkki ja malli (esim. Duotone Unit)", text: $name)
                TextField("Koko (\(type.sizeUnit))", text: $sizeText)
                    .keyboardType(.decimalPad)
                TextField("Vuosimalli (esim. 2024)", text: $yearText)
                    .keyboardType(.numberPad)
            }
            .navigationTitle(record == nil ? "Lisää kalustoa" : "Muokkaa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Peru") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tallenna") {
                        save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let record {
                    type = record.type
                    name = record.name
                    sizeText = record.size.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
                    yearText = record.year.map(String.init) ?? ""
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let size = Double(sizeText.replacingOccurrences(of: ",", with: "."))
        let year = Int(yearText)
        if let record {
            record.typeRaw = type.rawValue
            record.name = name
            record.size = size
            record.year = year
        } else {
            modelContext.insert(GearRecord(type: type, name: name, size: size, year: year))
        }
        try? modelContext.save()
    }
}
