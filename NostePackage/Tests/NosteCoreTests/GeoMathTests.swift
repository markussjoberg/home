import XCTest
@testable import NosteCore

final class GeoMathTests: XCTestCase {

    func testDistanceOneDegreeLatitude() {
        let d = GeoMath.distanceMeters(lat1: 60, lon1: 25, lat2: 61, lon2: 25)
        XCTAssertEqual(d, 111_195, accuracy: 200)
    }

    func testDistanceZero() {
        XCTAssertEqual(GeoMath.distanceMeters(lat1: 60.17, lon1: 24.94, lat2: 60.17, lon2: 24.94), 0, accuracy: 0.001)
    }

    func testBearingNorthAndEast() {
        XCTAssertEqual(GeoMath.bearingDegrees(lat1: 60, lon1: 25, lat2: 61, lon2: 25), 0, accuracy: 0.1)
        XCTAssertEqual(GeoMath.bearingDegrees(lat1: 0, lon1: 25, lat2: 0, lon2: 26), 90, accuracy: 0.1)
    }

    func testCompassNames() {
        XCTAssertEqual(GeoMath.compassName(degrees: 0), "N")
        XCTAssertEqual(GeoMath.compassName(degrees: 90), "E")
        XCTAssertEqual(GeoMath.compassName(degrees: 225), "SW")
        XCTAssertEqual(GeoMath.compassName(degrees: 315), "NW")
        XCTAssertEqual(GeoMath.compassName(degrees: 337.4), "NW")
        XCTAssertEqual(GeoMath.compassName(degrees: 359), "N")
    }

    func testFormatHelpers() {
        XCTAssertEqual(Format.duration(65), "1:05")
        XCTAssertEqual(Format.duration(3671), "1:01:11")
        XCTAssertEqual(Format.speedMs(8.24), "8,2 m/s")
        XCTAssertEqual(Format.distance(1234), "1,2 km")
        XCTAssertEqual(Format.distance(420), "420 m")
        XCTAssertEqual(Format.percent(0.42), "42 %")
    }
}
