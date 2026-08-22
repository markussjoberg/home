import XCTest
@testable import NosteCore

final class SpotWindWindowTests: XCTestCase {

    private func hour(speed: Double, direction: Double) -> WindHour {
        WindHour(time: Date(timeIntervalSince1970: 1_750_000_000), speed: speed, gust: speed * 1.4, direction: direction)
    }

    func testCompassOctant() {
        XCTAssertEqual(SpotData.compassOctant(degrees: 0), 0)     // N
        XCTAssertEqual(SpotData.compassOctant(degrees: 44), 1)    // NE
        XCTAssertEqual(SpotData.compassOctant(degrees: 225), 5)   // SW
        XCTAssertEqual(SpotData.compassOctant(degrees: 337.4), 7) // NW
        XCTAssertEqual(SpotData.compassOctant(degrees: 350), 0)   // N (kierto)
    }

    func testMatchingRequiresWindow() {
        let spot = SpotData(name: "X", latitude: 60, longitude: 25)
        XCTAssertFalse(spot.hasWindWindow)
        XCTAssertFalse(spot.matches(hour(speed: 10, direction: 225)), "ilman ikkunaa ei korosteta mitään")
    }

    func testSpeedAndDirectionWindow() {
        let spot = SpotData(name: "X", latitude: 60, longitude: 25,
                            goodDirections: [5, 6], minWind: 7, maxWind: 14) // SW, W
        XCTAssertTrue(spot.matches(hour(speed: 9, direction: 240)))
        XCTAssertFalse(spot.matches(hour(speed: 5, direction: 240)), "liian heikko")
        XCTAssertFalse(spot.matches(hour(speed: 16, direction: 240)), "liian kova")
        XCTAssertFalse(spot.matches(hour(speed: 9, direction: 90)), "väärä suunta")
    }

    func testDirectionsOnlyWindow() {
        let spot = SpotData(name: "X", latitude: 60, longitude: 25, goodDirections: [0])
        XCTAssertTrue(spot.matches(hour(speed: 2, direction: 355)))
        XCTAssertFalse(spot.matches(hour(speed: 12, direction: 180)))
    }

    func testOldDataDecodesWithoutNewFields() throws {
        let old = """
        {"id":"11111111-2222-3333-4444-555555555555","name":"Vanha","latitude":60.1,
        "longitude":24.9,"waterType":"sea","sports":["wingFoil"],"isFavorite":true,"notes":""}
        """
        let spot = try JSONDecoder().decode(SpotData.self, from: Data(old.utf8))
        XCTAssertNil(spot.goodDirections)
        XCTAssertNil(spot.minWind)
        XCTAssertFalse(spot.hasWindWindow)
    }
}
