import SwiftUI
import NosteCore

struct SettingsTab: View {
    @AppStorage("mmlApiKey") private var mmlApiKey = ""
    @AppStorage("marineTemplate") private var marineTemplate = TileOverlays.defaultMarineTemplate

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("API-avain", text: $mmlApiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Maastokartta (MML)")
                } footer: {
                    Text("Maanmittauslaitoksen avoin karttakuvapalvelu vaatii ilmaisen API-avaimen. Hae avain: maanmittauslaitos.fi → Rajapinnat → API-avain.")
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

                Section {
                    LabeledContent("Ennusteet", value: "Open-Meteo")
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
