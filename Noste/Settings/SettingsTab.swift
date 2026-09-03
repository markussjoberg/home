import SwiftUI
import AuthenticationServices
import NosteCore

/// Käyttäjän profiili: omat lajit (suodattaa valitsimet) ja stanssi.
enum UserProfile {
    static let sportsKey = "mySports"
    static let stanceKey = "stance"

    static var sports: [Sport] {
        let raw = UserDefaults.standard.string(forKey: sportsKey) ?? ""
        let chosen = raw.split(separator: ",").compactMap { Sport(rawValue: String($0)) }
        return chosen.isEmpty ? Sport.allCases : chosen
    }
}

struct SettingsTab: View {
    @AppStorage(ServerSettings.baseURLKey) private var serverBase = ""
    @AppStorage(ServerSettings.tokenKey) private var serverToken = ""
    @AppStorage("mmlApiKey") private var mmlApiKey = ""
    @AppStorage("marineTemplate") private var marineTemplate = TileOverlays.defaultMarineTemplate

    @AppStorage(UserProfile.sportsKey) private var mySportsRaw = ""
    @AppStorage(UserProfile.stanceKey) private var stance = ""
    /// Kehittäjäasetukset piilossa peruskäyttäjältä (5 napautusta versioon).
    @AppStorage("devMode") private var devMode = false
    @State private var versionTaps = 0

    private var serverConfigured: Bool {
        ServerSettings.config(base: serverBase, token: serverToken) != nil
    }

    private var mySports: Set<String> {
        Set(mySportsRaw.split(separator: ",").map(String.init))
    }

    private func toggleSport(_ sport: Sport) {
        var set = mySports
        if !set.insert(sport.rawValue).inserted { set.remove(sport.rawValue) }
        mySportsRaw = Sport.allCases.filter { set.contains($0.rawValue) }.map(\.rawValue).joined(separator: ",")
    }

    var body: some View {
        NavigationStack {
            Form {
                AccountSection()

                Section {
                    ForEach(Sport.allCases) { sport in
                        Button {
                            toggleSport(sport)
                        } label: {
                            HStack {
                                Label { Text(sport.displayName).foregroundStyle(.primary) } icon: {
                                    SportIcon(sport: sport, size: 22).foregroundStyle(.tint)
                                }
                                Spacer()
                                if mySports.isEmpty || mySports.contains(sport.rawValue) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    Picker("Stanssi", selection: $stance) {
                        Text("–").tag("")
                        Text("Regular").tag("regular")
                        Text("Goofy").tag("goofy")
                    }
                } header: {
                    Text("Omat lajit ja stanssi")
                } footer: {
                    Text("Valitut lajit näkyvät tallennusvalikoissa (tyhjä valinta = kaikki). Stanssi ei ole vielä käytössä — se on varattu käännösten analyysiin (heelside/toeside).")
                }

                Section {
                    LabeledContent("Versio", value: "0.1")
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Kehittäjätila: 5 napautusta versioon.
                            versionTaps += 1
                            if versionTaps >= 5 {
                                devMode.toggle()
                                versionTaps = 0
                            }
                        }
                } footer: {
                    Text("Kartat: Maanmittauslaitos ja Traficom (ei navigointikäyttöön). Sää: Open-Meteo (CC BY 4.0) ja Ilmatieteen laitos. Ennuste on malli — vesille lähdetään omalla harkinnalla.")
                }

                if devMode {
                    Section {
                        TextField("https://noste.esimerkki.fi", text: $serverBase)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Token (NOSTE_TOKEN)", text: $serverToken)
                        if serverConfigured {
                            Label("Oma palvelin käytössä — myös synkka ja kelivahti toimivat", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.footnote)
                        }
                        TextField("Oma MML-avain", text: $mmlApiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Merikartan WMTS-osoite", text: $marineTemplate, axis: .vertical)
                            .font(.caption)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Palauta merikartan oletus") {
                            marineTemplate = TileOverlays.defaultMarineTemplate
                        }
                        Button("Piilota kehittäjäasetukset") {
                            devMode = false
                        }
                    } header: {
                        Text("Kehittäjä")
                    } footer: {
                        Text("Ylikirjoitukset kehitykseen — appi toimii ilman näitä.")
                    }
                }
            }
            .navigationTitle("Asetukset")
        }
    }
}


/// Tili: Sign in with Apple + nimimerkki. Ilman tiliä appi toimii laiteavaimella;
/// tili tekee spoteista ja kommenteista käyttäjän omia laitteiden yli.
private struct AccountSection: View {
    @ObservedObject private var account = UserAccount.shared
    @Environment(\.modelContext) private var modelContext
    @State private var nicknameDraft = ""
    @State private var saving = false
    @State private var confirmDelete = false

    var body: some View {
        Section {
            if let user = account.user {
                HStack {
                    Label(user.nickname ?? "Nimimerkki puuttuu", systemImage: "person.crop.circle.fill")
                    Spacer()
                    if user.nickname == nil {
                        Text("aseta alla").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Nimimerkki (3–24 merkkiä)", text: $nicknameDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(saving ? "…" : "Tallenna") {
                        saving = true
                        Task {
                            _ = await account.setNickname(nicknameDraft.trimmingCharacters(in: .whitespaces))
                            saving = false
                        }
                    }
                    .disabled(saving || nicknameDraft.trimmingCharacters(in: .whitespaces).count < 3)
                }
                NavigationLink {
                    NotificationsView()
                } label: {
                    Label("Ilmoitukset", systemImage: "bell")
                        .badge(account.unreadNotifications)
                }
                NavigationLink {
                    MyContentView()
                } label: {
                    Label("Omat julkaisut", systemImage: "square.and.pencil")
                }
                Button("Kirjaudu ulos") {
                    Task { await account.signOut() }
                }
                Button("Poista tili", role: .destructive) { confirmDelete = true }
                    .confirmationDialog("Poistetaanko tili?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Poista tili", role: .destructive) { Task { _ = await account.deleteAccount() } }
                        Button("Peru", role: .cancel) {}
                    } message: {
                        Text("Tunnus, kirjautumiset, laitesidonnat, tilin spotit ja hälytykset poistetaan palvelimelta heti. Julkaisemasi spotit ja kommentit jäävät yhteisölle nimimerkin tekstinä, mutta niitä ei voi enää yhdistää sinuun. Puhelimen omat spotit ja sessiot säilyvät.")
                    }
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = []
                } onCompletion: { result in
                    if case .success(let authorization) = result {
                        Task {
                            await account.signIn(with: authorization)
                            if account.isSignedIn { await AccountSync.afterSignIn(context: modelContext) }
                        }
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 44)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            if let error = account.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Tili")
        } footer: {
            Text(account.user == nil
                 ? "Tilillä spotit, kelivahti ja kommentit seuraavat sinua laitteesta toiseen. Sessiot (GPS, syke) pysyvät aina puhelimessa. Ilman tiliä kaikki muu toimii, mutta omistus on laitekohtainen."
                 : "Nimimerkki näkyy kommenteissasi ja julkaisemissasi spoteissa. Sessiot pysyvät puhelimessa.")
        }
        .onAppear {
            nicknameDraft = account.user?.nickname ?? ""
            Task { await account.refresh() }
        }
    }
}
