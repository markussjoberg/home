import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Oma palvelin (noste-server): välimuistittaa ennusteet ja proxyttää karttatiilet.
public struct ServerConfig: Sendable, Equatable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// Rakentaa osoitteen palvelimen polkuun token-parametrilla.
    public func components(path: String) -> URLComponents {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components
    }
}

/// Open-Meteo-asiakas: tuuli (myös sisävesille) ja aallokko (Itämeri).
/// Ei API-avainta. https://open-meteo.com — ilmainen ei-kaupalliseen käyttöön.
/// Jos oma palvelin on määritetty, haut kulkevat sen läpisyötön kautta
/// (sama vastausmuoto, palvelin välimuistittaa).
public struct OpenMeteoClient {

    public enum ClientError: Error {
        case badResponse(Int)
        case emptyData
    }

    private let session: URLSession
    public var forecastDays: Int
    public var server: ServerConfig?

    public init(session: URLSession = .shared, forecastDays: Int = 3, server: ServerConfig? = nil) {
        self.session = session
        self.forecastDays = forecastDays
        self.server = server
    }

    /// Hakee spotin ennusteen: tuuli aina, aallokko vain merispoteille.
    public func forecast(for spot: SpotData, now: Date = Date()) async throws -> SpotForecast {
        async let wind = windForecast(latitude: spot.latitude, longitude: spot.longitude)
        var waves: [WaveHour]?
        if spot.waterType.hasWaveForecast {
            // Aaltomallin kattavuus voi loppua aivan rannassa — epäonnistuminen ei kaada tuulta.
            waves = try? await waveForecast(latitude: spot.latitude, longitude: spot.longitude)
        }
        return SpotForecast(spotID: spot.id, spotName: spot.name, fetchedAt: now, wind: try await wind, waves: waves)
    }

    public func windForecast(latitude: Double, longitude: Double) async throws -> [WindHour] {
        var components = server?.components(path: "api/openmeteo/forecast")
            ?? URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timezone", value: "UTC"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays))
        ]
        let data = try await fetch(components.url!)
        return try Self.decodeWind(data)
    }

    public func waveForecast(latitude: Double, longitude: Double) async throws -> [WaveHour] {
        var components = server?.components(path: "api/openmeteo/marine")
            ?? URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "hourly", value: "wave_height,wave_period,wave_direction"),
            URLQueryItem(name: "timezone", value: "UTC"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays))
        ]
        let data = try await fetch(components.url!)
        return try Self.decodeWaves(data)
    }

    /// Toteutunut tuuli aikavälillä (session reittausta varten). Open-Meteon
    /// forecast-rajapinta palauttaa myös menneet tunnit `past_days`-parametrilla;
    /// historia kattaa enintään 7 vrk taakse.
    public func windHistory(latitude: Double, longitude: Double,
                            from: Date, to: Date, now: Date = Date()) async throws -> [WindHour] {
        let daysBack = max(1, min(7, Int(ceil(now.timeIntervalSince(from) / 86_400))))
        var components = server?.components(path: "api/openmeteo/forecast")
            ?? URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "hourly", value: "wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            URLQueryItem(name: "timezone", value: "UTC"),
            URLQueryItem(name: "past_days", value: String(daysBack)),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        let data = try await fetch(components.url!)
        let margin: TimeInterval = 1800
        return try Self.decodeWind(data).filter {
            $0.time >= from.addingTimeInterval(-margin) && $0.time <= to.addingTimeInterval(margin)
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badResponse(http.statusCode)
        }
        return data
    }

    // MARK: - Dekoodaus (julkinen, jotta testattavissa ilman verkkoa)

    struct WindResponse: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let wind_speed_10m: [Double?]
            let wind_gusts_10m: [Double?]
            let wind_direction_10m: [Double?]
        }
        let hourly: Hourly
    }

    struct WaveResponse: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let wave_height: [Double?]
            let wave_period: [Double?]
            let wave_direction: [Double?]
        }
        let hourly: Hourly
    }

    /// Open-Meteon aikaleimat ovat muotoa "2026-08-21T14:00" (UTC kun timezone=UTC).
    static func parseTime(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: string)
    }

    public static func decodeWind(_ data: Data) throws -> [WindHour] {
        let response = try JSONDecoder().decode(WindResponse.self, from: data)
        let hourly = response.hourly
        var result: [WindHour] = []
        for (i, timeString) in hourly.time.enumerated() {
            guard let time = parseTime(timeString),
                  i < hourly.wind_speed_10m.count, let speed = hourly.wind_speed_10m[i],
                  i < hourly.wind_gusts_10m.count, let gust = hourly.wind_gusts_10m[i],
                  i < hourly.wind_direction_10m.count, let direction = hourly.wind_direction_10m[i]
            else { continue }
            result.append(WindHour(time: time, speed: speed, gust: gust, direction: direction))
        }
        guard !result.isEmpty else { throw ClientError.emptyData }
        return result
    }

    public static func decodeWaves(_ data: Data) throws -> [WaveHour] {
        let response = try JSONDecoder().decode(WaveResponse.self, from: data)
        let hourly = response.hourly
        var result: [WaveHour] = []
        for (i, timeString) in hourly.time.enumerated() {
            guard let time = parseTime(timeString),
                  i < hourly.wave_height.count, let height = hourly.wave_height[i],
                  i < hourly.wave_period.count, let period = hourly.wave_period[i],
                  i < hourly.wave_direction.count, let direction = hourly.wave_direction[i]
            else { continue }
            result.append(WaveHour(time: time, height: height, period: period, direction: direction))
        }
        guard !result.isEmpty else { throw ClientError.emptyData }
        return result
    }
}
