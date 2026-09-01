import XCTest
@testable import NosteCore

final class TurnDetectorTests: XCTestCase {

    /// Rakentaa jäljen suunnista: sekunnin askel, annettu nopeus ja kulkusuunta.
    private func track(_ legs: [(heading: Double, speed: Double, seconds: Int)]) -> [TrackPoint] {
        var points: [TrackPoint] = []
        var lat = 60.15, lon = 24.95, t = 0.0
        let metersPerDegLat = 111_320.0
        for leg in legs {
            for _ in 0..<leg.seconds {
                let rad = leg.heading * .pi / 180
                lat += leg.speed * cos(rad) / metersPerDegLat
                lon += leg.speed * sin(rad) / (metersPerDegLat * cos(lat * .pi / 180))
                points.append(TrackPoint(t: t, latitude: lat, longitude: lon, speed: leg.speed, horizontalAccuracy: 5))
                t += 1
            }
        }
        return points
    }

    /// Jiipi: itään 6 m/s, käännös etelän kautta länteen (tuuli pohjoisesta).
    func testDetectsFoiledJibe() {
        var legs: [(Double, Double, Int)] = [(90, 6, 30)]
        for step in 1...8 { legs.append((90.0 + Double(step) * 22.5, 5.0, 1)) } // 90° → 270° etelän kautta
        legs.append((270, 6, 30))
        let analysis = TurnDetector.analyze(points: track(legs), config: .init(sport: .wingFoil))
        XCTAssertEqual(analysis.count, 1)
        let turn = analysis.turns[0]
        XCTAssertTrue(turn.onFoil, "nopeus ei pudonnut alle kosketuskynnyksen")
        XCTAssertEqual(GeoMath.angularDistance(turn.midHeading, 180), 0, accuracy: 30, "keskisuunta ~etelä")
        // Tuuli pohjoisesta (0°) → keula myötätuuleen = jiipi.
        XCTAssertEqual(TurnAnalysis.kind(of: turn, windDirection: 0), .jibe)
        XCTAssertEqual(analysis.jibes(windDirection: 0).count, 1)
        XCTAssertEqual(analysis.tacks(windDirection: 0).count, 0)
    }

    /// Tacki: itään, käännös pohjoisen kautta länteen — vastatuulen läpi.
    func testDetectsTackAndTouchdown() {
        var legs: [(Double, Double, Int)] = [(90, 6, 30)]
        for step in 1...8 { legs.append((90.0 - Double(step) * 22.5, 2.0, 1)) } // pohjoisen kautta, hidastuen
        legs.append((270, 6, 30))
        let analysis = TurnDetector.analyze(points: track(legs), config: .init(sport: .wingFoil))
        XCTAssertEqual(analysis.count, 1)
        let turn = analysis.turns[0]
        XCTAssertFalse(turn.onFoil, "vauhti putosi alle kosketuskynnyksen (2 < 2,5)")
        XCTAssertEqual(TurnAnalysis.kind(of: turn, windDirection: 0), .tack)
    }

    /// Pitkä loiva kaartelu ei ole käännös.
    func testSlowArcIsNotATurn() {
        var legs: [(Double, Double, Int)] = []
        for step in 0..<36 { legs.append((Double(step) * 5, 6.0, 4)) } // 180° / 144 s
        let analysis = TurnDetector.analyze(points: track(legs), config: .init(sport: .wingFoil))
        XCTAssertEqual(analysis.count, 0)
    }

    /// Kävelyvauhdissa pyörähtely ei ole jiippi.
    func testSlowSpeedTurnIgnored() {
        var legs: [(Double, Double, Int)] = [(90, 1.0, 20)]
        for step in 1...8 { legs.append((90.0 + Double(step) * 22.5, 1.0, 1)) }
        legs.append((270, 1.0, 20))
        let analysis = TurnDetector.analyze(points: track(legs), config: .init(sport: .wingFoil))
        XCTAssertEqual(analysis.count, 0)
    }

    func testAnalyzerAttachesTurns() {
        var legs: [(Double, Double, Int)] = [(90, 6, 30)]
        for step in 1...8 { legs.append((90.0 + Double(step) * 22.5, 5.0, 1)) }
        legs.append((270, 6, 30))
        let summary = SessionAnalyzer.summarize(sport: .wingFoil, startDate: .now, points: track(legs))
        XCTAssertEqual(summary.turns?.count, 1)
        // Pumppilaji ei laske käännöksiä.
        let pump = SessionAnalyzer.summarize(sport: .pumpFoil, startDate: .now, points: track(legs))
        XCTAssertNil(pump.turns)
    }
}
