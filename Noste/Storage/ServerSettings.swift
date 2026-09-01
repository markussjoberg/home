import Foundation
import NosteCore

/// Palvelinasetukset. Appiin on sisäänrakennettu noste-server, joten kartat ja
/// ennusteet toimivat suoraan ilman mitään asetuksia — Asetukset-välilehden
/// kentät ovat vain ylikirjoitus (kehitys / oma palvelin).
enum ServerSettings {
    static let baseURLKey = "serverBaseURL"
    static let tokenKey = "serverToken"

    /// Sisäänrakennettu palvelin: lukureitit (tiilet, ennusteet, havainnot,
    /// spotmeta, rannat) client-tokenilla. Synkka ja kelivahti vaativat oman
    /// NOSTE_TOKENin (asetuksista). Mahdollinen premium-rajaus tehdään tähän.
    static let builtIn = ServerConfig(
        baseURL: URL(string: "https://aihiolabs.com/noste")!,
        token: "4efb3362d837279535557a81dd7e6b3f"
    )

    /// Käytettävä palvelin: käyttäjän oma jos asetettu, muuten sisäänrakennettu.
    static var current: ServerConfig? {
        userConfigured ?? builtIn
    }

    /// Vain käyttäjän itse asettama palvelin (täysi NOSTE_TOKEN). Synkka ja
    /// kelivahti käyttävät tätä — sisäänrakennettu client-token ei niihin riitä.
    static var userConfigured: ServerConfig? {
        let defaults = UserDefaults.standard
        return config(
            base: defaults.string(forKey: baseURLKey) ?? "",
            token: defaults.string(forKey: tokenKey) ?? ""
        )
    }

    static func config(base rawBase: String, token rawToken: String) -> ServerConfig? {
        let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !token.isEmpty,
              let url = URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base),
              url.scheme != nil
        else { return nil }
        return ServerConfig(baseURL: url, token: token)
    }

    /// Laitekohtainen avain julkisten spottien omistajuuteen (vain lisääjä voi
    /// muokata omiaan). Luodaan kerran; palvelin näkee vain hashin.
    static var deviceKey: String {
        let defaults = UserDefaults.standard
        if let key = defaults.string(forKey: "deviceKey") { return key }
        let key = UUID().uuidString
        defaults.set(key, forKey: "deviceKey")
        return key
    }

    /// Tiilitemplate palvelimen proxyyn (MKTileOverlay-muoto).
    static func tileTemplate(layer: String, server: ServerConfig) -> String {
        "\(server.baseURL.absoluteString)/api/tiles/\(layer)/{z}/{x}/{y}.png?token=\(server.token)"
    }
}
