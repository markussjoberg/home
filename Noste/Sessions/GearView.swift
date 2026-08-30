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
            GearEditorView(record: nil, catalog: catalog)
        }
        .sheet(item: $editing) { record in
            GearEditorView(record: record, catalog: catalog)
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
                HStack(spacing: 10) {
                    if let imageURL = suggestion.item.imageURL, let url = URL(string: imageURL) {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: suggestion.item.type.symbolName)
                                .foregroundStyle(.orange)
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: suggestion.item.type.symbolName)
                            .foregroundStyle(.orange)
                    }
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

/// Kalustoyksilön lisäys/muokkaus. Kentät voi esitäyttää Lappiksen
/// valikoimasta — tiedot kopioidaan aina recordiin (ei viittausta katalogiin),
/// joten kalusto säilyy vaikka malli poistuisi myynnistä.
struct GearEditorView: View {
    let record: GearRecord?
    var catalog: [GearCatalogItem] = []
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var type: GearType = .wing
    @State private var name = ""
    @State private var sizeText = ""
    @State private var yearText = ""

    var body: some View {
        NavigationStack {
            Form {
                if !catalog.isEmpty {
                    Section {
                        NavigationLink {
                            CatalogPickerView(catalog: catalog, initialType: type) { item in
                                apply(item)
                            }
                        } label: {
                            Label("Valitse Lappiksen valikoimasta", systemImage: "sparkle.magnifyingglass")
                        }
                    }
                }
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

    /// Esitäyttö katalogista: vuosi omaan kenttäänsä, nimi ilman vuosilukua.
    private func apply(_ item: GearCatalogItem) {
        type = item.type
        name = item.name.replacingOccurrences(of: #"\s*\b20\d{2}\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        sizeText = item.size.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
        yearText = item.year > 0 ? String(item.year) : ""
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

/// Lappiksen valikoiman selaus esitäyttöä varten: tyyppisuodatus + haku.
struct CatalogPickerView: View {
    let catalog: [GearCatalogItem]
    let onPick: (GearCatalogItem) -> Void
    @State private var type: GearType
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    init(catalog: [GearCatalogItem], initialType: GearType, onPick: @escaping (GearCatalogItem) -> Void) {
        self.catalog = catalog
        self.onPick = onPick
        _type = State(initialValue: initialType)
    }

    private var filtered: [GearCatalogItem] {
        catalog
            .filter { $0.type == type }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Picker("Tyyppi", selection: $type) {
                ForEach(GearType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            ForEach(filtered) { item in
                Button {
                    onPick(item)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        if let imageURL = item.imageURL, let url = URL(string: imageURL) {
                            AsyncImage(url: url) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: item.type.symbolName).foregroundStyle(.secondary)
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            if let size = item.size {
                                let sizeText = size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size).replacingOccurrences(of: ".", with: ",")
                                Text("\(sizeText) \(item.type.sizeUnit)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(item.price) €")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Hae mallia")
        .navigationTitle("Lappiksen valikoima")
        .navigationBarTitleDisplayMode(.inline)
    }
}
