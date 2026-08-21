import Foundation
import NosteCore

/// Oman palvelimen asetukset (Asetukset-välilehti kirjoittaa, muut lukevat).
enum ServerSettings {
    static let baseURLKey = "serverBaseURL"
    static let tokenKey = "serverToken"

    /// Määritetty palvelin, tai nil jos osoite/token puuttuu.
    static var current: ServerConfig? {
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

    /// Tiilitemplate palvelimen proxyyn (MKTileOverlay-muoto).
    static func tileTemplate(layer: String, server: ServerConfig) -> String {
        "\(server.baseURL.absoluteString)/api/tiles/\(layer)/{z}/{x}/{y}.png?token=\(server.token)"
    }
}
