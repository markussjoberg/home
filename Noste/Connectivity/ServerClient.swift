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
        var airTemp: Double?

        var date: Date? {
            ISO8601.parse(time)
        }
    }

    private struct ObservationResponse: Codable {
        var observation: Observation?
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
        Self.attachUserToken(&request)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 15
        return request
    }

    /// Kirjautuneen istuntotunniste mukaan — palvelin tunnistaa omistajan ja kirjoittajan.
    private static func attachUserToken(_ request: inout URLRequest) {
        if let token = UserAccount.shared.token {
            request.setValue(token, forHTTPHeaderField: "X-User-Token")
        }
    }

    // MARK: - Tili

    enum AccountResult { case success(UserAccount.User); case unauthorized; case unavailable }
    enum NicknameResult { case success(UserAccount.User); case failure(String) }

    /// Applen identity token → palvelimen istunto. ownerKey sitoo laitteen tiliin.
    func signInWithApple(identityToken: String, ownerKey: String) async -> (token: String, user: UserAccount.User)? {
        struct Upload: Codable { var identityToken: String; var ownerKey: String }
        struct Reply: Codable { var token: String; var user: UserAccount.User }
        guard let body = try? JSONEncoder().encode(Upload(identityToken: identityToken, ownerKey: ownerKey)),
              let request = communityRequest(path: "api/auth/apple", method: "POST", body: body),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return nil }
        return (reply.token, reply.user)
    }

    func me() async -> AccountResult {
        struct Reply: Codable { var user: UserAccount.User }
        guard let request = request(path: "api/me"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .unavailable }
        if http.statusCode == 401 { return .unauthorized }
        guard http.statusCode == 200, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return .unavailable }
        return .success(reply.user)
    }

    func setNickname(_ nickname: String, ownerKey: String) async -> NicknameResult {
        struct Upload: Codable { var nickname: String; var ownerKey: String }
        struct Reply: Codable { var user: UserAccount.User? ; var error: String? }
        guard let body = try? JSONEncoder().encode(Upload(nickname: nickname, ownerKey: ownerKey)),
              let request = communityRequest(path: "api/me", method: "PUT", body: body),
              let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return .failure("Palvelimeen ei saatu yhteyttä.") }
        if http.statusCode == 200, let user = reply.user { return .success(user) }
        return .failure(reply.error ?? "Nimimerkkiä ei voitu asettaa.")
    }

    /// Tilin poisto palvelimelta (App Store vaatii). true = poistettu.
    func deleteAccount() async -> Bool {
        guard let request = communityRequest(path: "api/me", method: "DELETE"),
              let (_, response) = try? await URLSession.shared.data(for: request)
        else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// APNs-laitetunniste tilille (kutsutaan joka käynnistyksessä kirjautuneena).
    func registerPushToken(_ token: String, sandbox: Bool) async {
        struct Upload: Codable { var token: String; var sandbox: Bool }
        guard UserAccount.shared.token != nil,
              let body = try? JSONEncoder().encode(Upload(token: token, sandbox: sandbox)),
              let request = communityRequest(path: "api/me/push-token", method: "PUT", body: body)
        else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    func logout() async {
        guard let request = communityRequest(path: "api/auth/logout", method: "POST") else { return }
        _ = try? await URLSession.shared.data(for: request)
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
            var sport: String?
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
                imageURL: item.image,
                sport: item.sport.flatMap(Sport.init(rawValue:))
            )
        }
    }

    // MARK: - FMI-aallokko (poiju + WAM)

    struct WaveBuoy: Codable {
        var time: String
        var latitude: Double
        var longitude: Double
        var waveHeight: Double?
        var waveDirection: Double?
        var wavePeriod: Double?
        var waterTemp: Double?
    }

    struct WaveHourForecast: Codable, Identifiable {
        var time: String
        var height: Double
        var direction: Double?
        var period: Double?

        var id: String { time }
        var date: Date? { ISO8601.parse(time) }
    }

    struct WaveData: Codable {
        var buoy: WaveBuoy?
        var forecast: [WaveHourForecast]
    }

    /// FMI:n aaltopoijuhavainto + WAM-pisteennuste merispoteille.
    func wave(latitude: Double, longitude: Double) async -> WaveData? {
        guard let request = request(path: "api/wave", query: [
            URLQueryItem(name: "lat", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", longitude))
        ]) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(WaveData.self, from: data)
        else { return nil }
        return decoded
    }

    struct SeaStation: Codable {
        var latitude: Double
        var longitude: Double
        var time: String
        var waveHeight: Double?
        var waveDirection: Double?
        var wavePeriod: Double?
        var waterTemp: Double?
        var windSpeed: Double?
        var windGust: Double?
        var windDirection: Double?
    }

    struct SeaState: Codable {
        var buoys: [SeaStation]
        var stations: [SeaStation]
    }

    /// Merisää kartalle: kaikki aaltopoijut ja tuuliasemat alueella.
    func seaState(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) async -> SeaState? {
        guard let request = request(path: "api/seastate", query: [
            URLQueryItem(name: "bbox", value: String(format: "%.1f,%.1f,%.1f,%.1f", minLon, minLat, maxLon, maxLat))
        ]) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SeaState.self, from: data)
        else { return nil }
        return decoded
    }

    /// Tuulihila partikkelianimaatioon: 9×9 Open-Meteo-solua alueelle, kaikki
    /// ennustetunnit (aikajana selaa ilman uusia hakuja).
    func windField(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) async -> WindFieldSeries? {
        guard let request = request(path: "api/windfield", query: [
            URLQueryItem(name: "bbox", value: String(format: "%.2f,%.2f,%.2f,%.2f", minLon, minLat, maxLon, maxLat))
        ]) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(WindFieldSeries.self, from: data)
        else { return nil }
        return decoded
    }

    /// Aaltohila (korkeus, suunta, periodi) kaikille ennustetunneille; maapisteet
    /// karsittu palvelimella, mukana todella haettu alue.
    func waveField(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) async -> WaveFieldSeries? {
        guard let request = request(path: "api/wavefield", query: [
            URLQueryItem(name: "bbox", value: String(format: "%.2f,%.2f,%.2f,%.2f", minLon, minLat, maxLon, maxLat))
        ]) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(WaveFieldSeries.self, from: data)
        else { return nil }
        return decoded
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
        /// Yhteinen kuvaus (wiki).
        var description: String?
        /// exact | coarse (muille pyöristetty sijainti).
        var precision: String?
        var updatedAt: String
        var commentCount: Int
        /// Oma (tili tai sidottu laite) — palvelin päättää.
        var mine: Bool?
        /// Avoin poistoehdotus: toteutuu tänä hetkenä ellei vastusteta.
        var deletionProposed: String?
    }

    struct SpotComment: Codable, Identifiable {
        var id: String
        var author: String
        var userId: String?
        var text: String
        var windMs: Double?
        var windDir: Double?
        var createdAt: String
    }

    enum UnpublishResult { case deleted, proposed(decidesAt: String), failed }

    /// Vapaamuotoinen JSON (versiohistorian sisältö).
    enum JSONValue: Codable {
        case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
            else { self = .object(try c.decode([String: JSONValue].self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .bool(let b): try c.encode(b)
            case .null: try c.encodeNil()
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }
    }

    struct SpotRevision: Codable, Identifiable {
        var id: Int
        var createdAt: String
        var editor: String
        var data: [String: JSONValue]
    }

    /// Wiki-muokkaus: tallentaa julkisen spotin tiedot (palvelin rajaa mitä muu kuin omistaja saa muuttaa)
    /// ja palauttaa päivitetyn spotin listauksesta.
    func updatePublicSpot(_ spot: PublicSpot) async -> PublicSpot? {
        struct Upload: Codable {
            var name: String; var latitude: Double; var longitude: Double; var waterType: String; var sports: [String]
            var goodDirections: [Int]?; var minWind: Double?; var maxWind: Double?; var description: String?; var precision: String?; var ownerKey: String
        }
        let upload = Upload(name: spot.name, latitude: spot.latitude, longitude: spot.longitude, waterType: spot.waterType,
                            sports: spot.sports, goodDirections: spot.goodDirections, minWind: spot.minWind, maxWind: spot.maxWind,
                            description: spot.description, precision: spot.precision, ownerKey: ServerSettings.deviceKey)
        guard let body = try? JSONEncoder().encode(upload),
              let request = communityRequest(path: "api/public/spots/\(spot.id)", method: "PUT", body: body),
              let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (await publicSpots())?.first { $0.id == spot.id }
    }

    func spotHistory(spotID: String) async -> [SpotRevision]? {
        struct Reply: Codable { var revisions: [SpotRevision] }
        guard let request = request(path: "api/public/spots/\(spotID)/history"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.revisions
    }

    func restoreRevision(spotID: String, revisionID: Int) async -> Bool {
        struct Upload: Codable { var ownerKey: String }
        guard let body = try? JSONEncoder().encode(Upload(ownerKey: ServerSettings.deviceKey)),
              let request = communityRequest(path: "api/public/spots/\(spotID)/history/\(revisionID)/restore", method: "POST", body: body),
              let (_, response) = try? await URLSession.shared.data(for: request)
        else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    struct MyComment: Codable, Identifiable {
        var id: String
        var spotId: String
        var text: String
        var createdAt: String
    }
    struct MyContent: Codable {
        var spots: [PublicSpot]
        var comments: [MyComment]
    }

    struct Notification: Codable, Identifiable {
        var id: Int
        var kind: String
        var spotId: String
        var spotName: String
        var message: String
        var createdAt: String
        var read: Bool
    }

    func notifications() async -> [Notification]? {
        struct Reply: Codable { var notifications: [Notification] }
        guard let request = request(path: "api/me/notifications"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.notifications
    }

    /// Lukemattomien määrä tilin merkkiin.
    func unreadNotifications() async -> Int? {
        struct Reply: Codable { var unread: Int }
        guard let request = request(path: "api/me/notifications"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.unread
    }

    func markNotificationsRead() async {
        guard let request = communityRequest(path: "api/me/notifications/read", method: "POST", body: Data("{}".utf8)) else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Tilin julkaistut spotit ja kommentit (vaatii kirjautumisen).
    func myContent() async -> MyContent? {
        guard let request = request(path: "api/me/content"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(MyContent.self, from: data)
    }

    /// Ilmoitus asiattomasta spotista tai kommentista.
    func report(targetType: String, targetID: String, reason: String) async -> Bool {
        struct Upload: Codable { var targetType: String; var targetId: String; var reason: String; var ownerKey: String }
        guard let body = try? JSONEncoder().encode(Upload(targetType: targetType, targetId: targetID, reason: reason, ownerKey: ServerSettings.deviceKey)),
              let request = communityRequest(path: "api/public/reports", method: "POST", body: body),
              let (_, response) = try? await URLSession.shared.data(for: request)
        else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func deleteComment(spotID: String, commentID: String) async -> Bool {
        guard let request = communityRequest(path: "api/public/spots/\(spotID)/comments/\(commentID)", method: "DELETE"),
              let (_, response) = try? await URLSession.shared.data(for: request)
        else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Vastustaa avointa poistoehdotusta (vain spottiin osallistunut).
    func objectDeletion(spotID: String) async -> Bool {
        struct Upload: Codable { var ownerKey: String }
        guard let body = try? JSONEncoder().encode(Upload(ownerKey: ServerSettings.deviceKey)),
              let request = communityRequest(path: "api/public/spots/\(spotID)/deletion/object", method: "POST", body: body),
              let (_, response) = try? await URLSession.shared.data(for: request)
        else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
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
            var description: String?
            var precision: String
            var ownerKey: String
        }
        let upload = Upload(
            name: spot.name, latitude: spot.latitude, longitude: spot.longitude,
            waterType: spot.waterType.rawValue, sports: spot.sports.map(\.rawValue),
            goodDirections: spot.goodDirections, minWind: spot.minWind, maxWind: spot.maxWind,
            description: spot.notes.isEmpty ? nil : spot.notes,
            precision: spot.coarseLocation == true ? "coarse" : "exact",
            ownerKey: ServerSettings.deviceKey
        )
        guard let body = try? JSONEncoder().encode(upload),
              let request = communityRequest(path: "api/public/spots/\(spot.id.uuidString)", method: "PUT", body: body)
        else { return }
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Poistaa julkaisun. Jos muut ovat lisänneet sisältöä, palvelin tekee
    /// poistoehdotuksen (202) joka toteutuu määräajan jälkeen ellei vastusteta.
    @discardableResult
    func unpublishSpot(id: UUID) async -> UnpublishResult {
        struct Reply: Codable { struct Proposal: Codable { var decidesAt: String }; var proposal: Proposal? }
        guard let request = communityRequest(
            path: "api/public/spots/\(id.uuidString)", method: "DELETE",
            query: [URLQueryItem(name: "ownerKey", value: ServerSettings.deviceKey)]
        ), let (data, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse
        else { return .failed }
        if http.statusCode == 202, let decidesAt = (try? JSONDecoder().decode(Reply.self, from: data))?.proposal?.decidesAt {
            return .proposed(decidesAt: decidesAt)
        }
        return http.statusCode == 200 ? .deleted : .failed
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
        Self.attachUserToken(&request)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 15
        return request
    }

    /// Vie koko spottilistan palvelimelle (varmuuskopio + kelivahdin lähtödata).
    /// Omat spotit palvelimelle: kirjautuneena tilin alle (varmuuskopio +
    /// kelivahdin sijainnit), kehittäjän omalla palvelimella vanhaan admin-listaan.
    /// Puhelin on totuus, palvelin kopio.
    func backupSpots(_ spots: [SpotData]) async {
        guard let body = try? JSONEncoder().encode(spots) else { return }
        if UserAccount.shared.token != nil, let request = communityRequest(path: "api/me/spots", method: "PUT", body: body) {
            _ = try? await URLSession.shared.data(for: request)
        } else if let request = request(path: "api/spots", method: "PUT", body: body) {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Käyttäjän kelivahtihälytykset palvelimelle (koko lista korvaa edellisen).
    func backupAlerts(_ alerts: [WindAlert]) async {
        guard let body = try? JSONEncoder().encode(alerts) else { return }
        if UserAccount.shared.token != nil, let request = communityRequest(path: "api/me/alerts", method: "PUT", body: body) {
            _ = try? await URLSession.shared.data(for: request)
        } else if let request = request(path: "api/alerts", method: "PUT", body: body) {
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Tilin spotit palautusta varten (uusi puhelin, uudelleenasennus).
    func fetchMySpots() async -> [SpotData]? {
        struct Reply: Codable { var spots: [SpotData] }
        guard UserAccount.shared.token != nil, let request = request(path: "api/me/spots"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.spots
    }

    func fetchMyAlerts() async -> [WindAlert]? {
        struct Reply: Codable { var alerts: [WindAlert] }
        guard UserAccount.shared.token != nil, let request = request(path: "api/me/alerts"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.alerts
    }

    // Sessioita (GPS-jälki, syke, kiihtyvyys) ei viedä palvelimelle: ne pysyvät
    // puhelimessa ja HealthKitissä. Laitteiden välinen siirto tehdään tarvittaessa
    // käyttäjän omaan iCloudiin (CloudKit), ei meidän palvelimelle.
}
