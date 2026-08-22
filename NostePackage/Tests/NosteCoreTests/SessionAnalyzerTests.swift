import XCTest
@testable import NosteCore

final class SessionAnalyzerTests: XCTestCase {

    func testWingSessionSummary() {
        let speeds = [Double](repeating: 1.0, count: 10)
            + [Double](repeating: 6.0, count: 30)
            + [Double](repeating: 1.0, count: 20)
        let summary = SessionAnalyzer.summarize(
            sport: .wingFoil,
            startDate: Date(timeIntervalSince1970: 1_000_000),
            points: makeTrack(speeds: speeds)
        )

        XCTAssertEqual(summary.duration, 59, accuracy: 0.01)
        // Kokonaismatka ≈ nopeuksien summa (viimeinen sekunti ei ehdi jälkeen).
        let expected = speeds.dropLast().reduce(0, +)
        XCTAssertEqual(summary.distance, expected, accuracy: 3)
        XCTAssertEqual(summary.maxSpeed, 6.0, accuracy: 0.01)
        XCTAssertEqual(summary.rides.count, 1)
        XCTAssertEqual(summary.rideFraction, 30.0 / 59.0, accuracy: 0.01)
        XCTAssertNil(summary.pumps, "wing-sessiolle ei lasketa pumppuja")
        XCTAssertGreaterThan(summary.averageMovingSpeed, 1.0)
    }

    func testPumpSessionCountsPumps() {
        let speeds = [Double](repeating: 2.5, count: 30)
        let motion = (0..<(30 * 50)).map { i -> MotionSample in
            let t = Double(i) / 50
            return MotionSample(t: t, verticalAcceleration: 3.0 * sin(2 * .pi * 1.0 * t))
        }
        let summary = SessionAnalyzer.summarize(
            sport: .pumpFoil,
            startDate: .now,
            points: makeTrack(speeds: speeds),
            motion: motion
        )
        XCTAssertNotNil(summary.pumps)
        XCTAssertGreaterThan(summary.pumps!.strokeCount, 20)
        XCTAssertEqual(summary.rides.count, 1, "pumpin irtoamisnopeus 2,2 m/s alittuu → yksi jakso")
    }

    func testStationaryJitterDoesNotAccumulateDistance() {
        // Seisotaan paikallaan: nopeus 0, sijainti värisee ±2,8 m.
        let points = (0..<60).map { i in
            TrackPoint(t: Double(i), latitude: 60.2,
                       longitude: 25.0 + (i % 2 == 1 ? 0.00005 : 0),
                       speed: 0, horizontalAccuracy: 5)
        }
        let summary = SessionAnalyzer.summarize(sport: .wingFoil, startDate: .now, points: points)
        XCTAssertEqual(summary.distance, 0, accuracy: 0.001)
        XCTAssertEqual(summary.averageMovingSpeed, 0, accuracy: 0.001)
    }

    func testUnknownSpeedFallsBackToStepSpeed() {
        // GPS ei anna nopeutta (speed -1), mutta liikutaan itään 5 m/s.
        let metersPerDegree = 111_320 * cos(60.2 * .pi / 180)
        let points = (0..<20).map { i in
            TrackPoint(t: Double(i), latitude: 60.2,
                       longitude: 25.0 + 5.0 * Double(i) / metersPerDegree,
                       speed: -1, horizontalAccuracy: 5)
        }
        let summary = SessionAnalyzer.summarize(sport: .wingFoil, startDate: .now, points: points)
        XCTAssertEqual(summary.distance, 95, accuracy: 2)
    }

    func testFiltersImplausibleSpeedSpike() {
        var points = makeTrack(speeds: [Double](repeating: 6.0, count: 20))
        points[10].speed = 80 // GPS-häiriö
        let summary = SessionAnalyzer.summarize(sport: .wingFoil, startDate: .now, points: points)
        XCTAssertEqual(summary.maxSpeed, 6.0, accuracy: 0.01)
    }

    func testSummaryRoundTripsThroughJSON() throws {
        let summary = SessionAnalyzer.summarize(
            sport: .pumpFoil,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            points: makeTrack(speeds: [1, 3, 3, 3, 1, 1])
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }
}
