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

    /// Maastoanalyysi: fetch (km) ja avoimuus (0–1) ilmansuunnittain.
    struct SpotMetaOctant: Codable {
        var octant: Int
        var fetchKm: Double
        var exposure: Double
    }

    struct SpotMetaResponse: Codable {
        var latitude: Double
        var longitude: Double
        var elevation: Double
        var octants: [SpotMetaOctant]
    }

    /// Rantainfo (OSM + Lipas).
    struct Place: Codable, Identifiable {
        var category: String
        var name: String?
        var latitude: Double
        var longitude: Double
        var distanceM: Int
        var source: String

        var id: String { "\(category)-\(latitude)-\(longitude)" }
    }

    private struct PlacesResponse: Codable {
        var nearest: [Place]
        var all: [Place]?
    }

    static let shared = ServerClient()

    private func request(path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) -> URLRequest? {
        // Lukureitit toimivat sisäänrakennetulla palvelimella; synkka vaatii
        // käyttäjän oman palvelimen (täysi token) — muuten ei yritetä turhaan.
        let server = method == "GET" ? ServerSettings.current : ServerSettings.userConfigured
        guard let server else { return nil }
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

    /// Spotin maastoanalyysi (fetch + avoimuus). Palvelin laskee korkeusdatasta
    /// ja välimuistittaa pysyvästi — maasto ei muutu.
    func spotMeta(latitude: Double, longitude: Double) async -> SpotMetaResponse? {
        guard let request = request(path: "api/spotmeta", query: [
            URLQueryItem(name: "lat", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", longitude))
        ]) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SpotMetaResponse.self, from: data)
        else { return nil }
        return decoded
    }

    /// Lähimmät rantapalvelut kategorioittain (uimaranta, laituri, luiska, parkki…).
    func places(latitude: Double, longitude: Double) async -> [Place]? {
        guard let request = request(path: "api/places", query: [
            URLQueryItem(name: "lat", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", longitude))
        ]) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(PlacesResponse.self, from: data)
        else { return nil }
        return decoded.nearest
    }

    /// KAIKKI rantapalvelut säteellä — kartan rantainfra-kerrokselle.
    func placesAll(latitude: Double, longitude: Double, radius: Double) async -> [Place]? {
        guard let request = request(path: "api/places", query: [
            URLQueryItem(name: "lat", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "radius", value: String(Int(radius)))
        ]) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(PlacesResponse.self, from: data)
        else { return nil }
        return decoded.all ?? decoded.nearest
    }

    /// Lappis-katalogi kalustosuosituksiin (palvelin välimuistittaa kaupan
    /// julkisen Store API:n). nil jos haku epäonnistuu — ehdotukset vain jäävät pois.
    func shopCatalog() async -> [GearCatalogItem]? {
        struct Item: Codable {
            var id: String
            var type: String
            var name: String
            var size: Double?
            var year: Int?
            var price: Int
            var url: String
            var image: String?
        }
        struct CatalogResponse: Codable { var store: String; var items: [Item] }
        guard let request = request(path: "api/shop/catalog") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(CatalogResponse.self, from: data)
        else { return nil }
        return decoded.items.compactMap { item in
            guard let type = GearType(rawValue: item.type) else { return nil }
            return GearCatalogItem(
                id: item.id, type: type, name: item.name, size: item.size,
                year: item.year ?? 0, price: item.price, url: item.url,
                imageURL: item.image
            )
        }
    }

    // MARK: - Julkiset spotit ja kommentit

    struct PublicSpot: Codable, Identifiable {
        var id: String
        var name: String
        var latitude: Double
        var longitude: Double
        var waterType: String
        var sports: [String]
        var goodDirections: [Int]?
        var minWind: Double?
        var maxWind: Double?
        var updatedAt: String
        var commentCount: Int
    }

    struct SpotComment: Codable, Identifiable {
        var id: String
        var author: String
        var text: String
        var windMs: Double?
        var windDir: Double?
        var createdAt: String
    }

    func publicSpots() async -> [PublicSpot]? {
        struct ListResponse: Codable { var spots: [PublicSpot] }
        guard let request = request(path: "api/public/spots") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ListResponse.self, from: data)
        else { return nil }
        return decoded.spots
    }

    /// Julkaisee spotin yhteiseen pooliin. Best effort — virhe ei riko mitään.
    func publishSpot(_ spot: SpotData) async {
        struct Upload: Codable {
            var name: String
            var latitude: Double
            var longitude: Double
            var waterType: String
            var sports: [String]
            var goodDirections: [Int]?
            var minWind: Double?
            var maxWind: Double?
            var ownerKey: String
        }
        let upload = Upload(
            name: spot.name, latitude: spot.latitude, longitude: spot.longitude,
            waterType: spot.waterType.rawValue, sports: spot.sports.map(\.rawValue),
            goodDirections: spot.goodDirections, minWind: spot.minWind, maxWind: spot.maxWind,
            ownerKey: ServerSettings.deviceKey
        )
        guard let body = try? JSONEncoder().encode(upload),
              let request = communityRequest(path: "api/public/spots/\(spot.id.uuidString)", method: "PUT", body: body)
        else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    func unpublishSpot(id: UUID) async {
        guard let request = communityRequest(
            path: "api/public/spots/\(id.uuidString)", method: "DELETE",
            query: [URLQueryItem(name: "ownerKey", value: ServerSettings.deviceKey)]
        ) else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    func spotComments(spotID: String) async -> [SpotComment]? {
        struct CommentsResponse: Codable { var comments: [SpotComment] }
        guard let request = request(path: "api/public/spots/\(spotID)/comments") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(CommentsResponse.self, from: data)
        else { return nil }
        return decoded.comments
    }

    func postComment(spotID: String, author: String, text: String) async -> Bool {
        struct Upload: Codable { var author: String; var text: String }
        guard let body = try? JSONEncoder().encode(Upload(author: author, text: text)),
              let request = communityRequest(path: "api/public/spots/\(spotID)/comments", method: "POST", body: body)
        else { return false }
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Yhteisöreitit toimivat myös sisäänrakennetulla palvelimella (toisin kuin
    /// yksityinen synkka, joka vaatii oman palvelimen).
    private func communityRequest(path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest? {
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
