import SwiftUI
import NosteCore

struct SettingsTab: View {
    @AppStorage(ServerSettings.baseURLKey) private var serverBase = ""
    @AppStorage(ServerSettings.tokenKey) private var serverToken = ""
    @AppStorage("mmlApiKey") private var mmlApiKey = ""
    @AppStorage("marineTemplate") private var marineTemplate = TileOverlays.defaultMarineTemplate

    private var serverConfigured: Bool {
        ServerSettings.config(base: serverBase, token: serverToken) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Kartat ja ennusteet", value: "Nosten palvelin")
                    LabeledContent("Ennustemalli", value: "Open-Meteo")
                    LabeledContent("Versio", value: "0.1")
                } header: {
                    Text("Tietoa")
                } footer: {
                    Text("Maastokartta (MML), merikartta (Traficom — ei navigointikäyttöön), tuuli- ja aaltoennusteet (Open-Meteo, CC BY 4.0) ja FMI-havainnot tulevat suoraan Nosten palvelimelta ilman asetuksia. Ennuste on malli — vesille lähdetään omalla harkinnalla.")
                }

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
                } header: {
                    Text("Oma palvelin (valinnainen)")
                } footer: {
                    Text("Kehitykseen tai omalle noste-serverille (ks. repo: server/). Täysi token avaa myös spottien ja sessioiden varmuuskopioinnin sekä kelivahdin.")
                }

                if !serverConfigured {
                    Section {
                        TextField("API-avain", text: $mmlApiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("Oma MML-avain (valinnainen)")
                    } footer: {
                        Text("Maastokarttatiilet suoraan MML:ltä ohi Nosten palvelimen. Ilmainen API-avain: maanmittauslaitos.fi → Rajapinnat → API-avain.")
                    }

                    Section {
                        TextField("WMTS-tiiliosoite", text: $marineTemplate, axis: .vertical)
                            .font(.caption)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Palauta oletus") {
                            marineTemplate = TileOverlays.defaultMarineTemplate
                        }
                    } header: {
                        Text("Merikartan tiiliosoite (valinnainen)")
                    } footer: {
                        Text("Oletuksena merikartta tulee Nosten palvelimelta. Osoitteessa {z}/{y}/{x} korvataan tiilikoordinaateilla. Huom: ei navigointikäyttöön.")
                    }
                }
            }
            .navigationTitle("Asetukset")
        }
    }
}
