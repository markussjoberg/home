import XCTest
@testable import NosteCore

final class OpenMeteoTests: XCTestCase {

    func testParseTime() {
        let date = OpenMeteoClient.parseTime("2026-08-21T14:00")
        XCTAssertNotNil(date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date!)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.day, 21)
        XCTAssertEqual(parts.hour, 14)
        XCTAssertEqual(parts.minute, 0)
    }

    func testDecodeWindSkipsNulls() throws {
        let json = """
        {"hourly":{"time":["2026-08-21T10:00","2026-08-21T11:00","2026-08-21T12:00"],
        "wind_speed_10m":[5.2,null,7.0],
        "wind_gusts_10m":[8.1,9.0,10.4],
        "wind_direction_10m":[210,220,230]}}
        """
        let hours = try OpenMeteoClient.decodeWind(Data(json.utf8))
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours[0].speed, 5.2, accuracy: 0.001)
        XCTAssertEqual(hours[0].gust, 8.1, accuracy: 0.001)
        XCTAssertEqual(hours[0].directionName, "SW")
        XCTAssertEqual(hours[1].speed, 7.0, accuracy: 0.001)
    }

    func testDecodeWaves() throws {
        let json = """
        {"hourly":{"time":["2026-08-21T10:00"],
        "wave_height":[0.8],"wave_period":[4.5],"wave_direction":[250]}}
        """
        let hours = try OpenMeteoClient.decodeWaves(Data(json.utf8))
        XCTAssertEqual(hours.count, 1)
        XCTAssertEqual(hours[0].height, 0.8, accuracy: 0.001)
        XCTAssertEqual(hours[0].period, 4.5, accuracy: 0.001)
    }

    func testDecodeEmptyThrows() {
        let json = """
        {"hourly":{"time":[],"wind_speed_10m":[],"wind_gusts_10m":[],"wind_direction_10m":[]}}
        """
        XCTAssertThrowsError(try OpenMeteoClient.decodeWind(Data(json.utf8)))
    }

    func testForecastSnapshotRoundTripAndUpcoming() throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let wind = (0..<48).map { i in
            WindHour(time: base.addingTimeInterval(Double(i) * 3600), speed: 8, gust: 12, direction: 225)
        }
        let forecast = SpotForecast(spotID: UUID(), spotName: "Kotispotti", fetchedAt: base, wind: wind)

        let data = try JSONEncoder().encode(forecast)
        let decoded = try JSONDecoder().decode(SpotForecast.self, from: data)
        XCTAssertEqual(decoded, forecast)

        let upcoming = forecast.upcoming(from: base.addingTimeInterval(24 * 3600), hours: 12)
        XCTAssertEqual(upcoming.wind.count, 12)
        XCTAssertGreaterThan(upcoming.wind[0].time, base.addingTimeInterval(22 * 3600))
    }
}
