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
                    TextField("https://noste.esimerkki.fi", text: $serverBase)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Token (NOSTE_TOKEN)", text: $serverToken)
                    if serverConfigured {
                        Label("Palvelin käytössä — kartat ja ennusteet kulkevat sen kautta", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                } header: {
                    Text("Oma palvelin")
                } footer: {
                    Text("noste-server (ks. repo: server/) välimuistittaa ennusteet, proxyttää karttatiilet (MML-avain palvelimella) ja ajaa kelivahtia. Ilman palvelinta appi hakee suoraan lähteistä.")
                }

                if !serverConfigured {
                    Section {
                        TextField("API-avain", text: $mmlApiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("Maastokartta (MML)")
                    } footer: {
                        Text("Tarvitaan vain ilman omaa palvelinta. Maanmittauslaitoksen ilmainen API-avain: maanmittauslaitos.fi → Rajapinnat → API-avain.")
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
                        Text("Merikartta")
                    } footer: {
                        Text("Traficomin avoin rasterimerikartta. Osoitteessa {z}/{y}/{x} korvataan tiilikoordinaateilla. Huom: ei navigointikäyttöön.")
                    }
                }

                Section {
                    LabeledContent("Ennusteet", value: "Open-Meteo" + (serverConfigured ? " (oma palvelin)" : ""))
                    LabeledContent("Versio", value: "0.1")
                } header: {
                    Text("Tietoa")
                } footer: {
                    Text("Sääennusteet: Open-Meteo (CC BY 4.0). Ennuste on malli — vesille lähdetään omalla harkinnalla.")
                }
            }
            .navigationTitle("Asetukset")
        }
    }
}
