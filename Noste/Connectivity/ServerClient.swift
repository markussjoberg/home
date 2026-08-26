import Foundation
import NosteCore

/// noste-serverin asiakas. Kaikki toiminnot ovat "best effort" — palvelimen
/// puuttuminen tai verkkovirhe ei koskaan riko paikallista toimintaa.
struct ServerClient {

    /// FMI-havainto palvelimen kautta.
    struct Observation: Codable {
        var time: String
        var latitude: Double
        var longitude: Double
        var windSpeed: Double?
        var windGust: Double?
        var windDirection: Double?

        var date: Date? {
            ISO8601DateFormatter().date(from: time)
        }
    }

    private struct ObservationResponse: Codable {
        var observation: Observation?
    }

    private struct SessionUpload: Codable {
        var id: String
        var startDate: String
        var sport: String
        var summary: SessionSummary
        var track: [TrackPoint]
        var rating: Int?
        var wind: RatedWind?
    }

    static let shared = ServerClient()

    private func request(path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let server = ServerSettings.current else { return nil }
        var components = URLComponents(
            url: server.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 15
        return request
    }

    /// Toteutunut tuuli lähimmältä FMI-asemalta; nil jos palvelinta ei ole tai haku epäonnistuu.
    func observation(latitude: Double, longitude: Double) async -> Observation? {
        guard let request = request(path: "api/observation", query: [
            URLQueryItem(name: "lat", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", longitude))
        ]) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ObservationResponse.self, from: data)
        else { return nil }
        return decoded.observation
    }

    /// Vie koko spottilistan palvelimelle (varmuuskopio + kelivahdin lähtödata).
    func backupSpots(_ spots: [SpotData]) async {
        guard let body = try? JSONEncoder().encode(spots),
              let request = request(path: "api/spots", method: "PUT", body: body)
        else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Vie yhden session palvelimelle raakajälkineen. Vakaa id → uudelleenvienti
    /// (esim. reittauksen jälkeen) päivittää saman session, ei duplikoi.
    func backupSession(_ payload: WatchSync.SessionPayload, id: UUID,
                       rating: WindRating? = nil, wind: RatedWind? = nil) async {
        let upload = SessionUpload(
            id: id.uuidString,
            startDate: ISO8601DateFormatter().string(from: payload.summary.startDate),
            sport: payload.summary.sport.rawValue,
            summary: payload.summary,
            track: payload.track,
            rating: rating?.rawValue,
            wind: wind
        )
        guard let body = try? JSONEncoder().encode(upload),
              let request = request(path: "api/sessions", method: "POST", body: body)
        else { return }
        _ = try? await URLSession.shared.data(for: request)
    }
}
