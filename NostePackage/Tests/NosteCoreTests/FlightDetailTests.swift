import XCTest
@testable import NosteCore

final class FlightDetailTests: XCTestCase {

    /// Pumppisessio: 10 s melonta, 30 s lento (nopeus 3, hetkellisesti 4), 20 s melonta.
    private var speeds: [Double] {
        [Double](repeating: 1.0, count: 10)
            + [Double](repeating: 3.0, count: 10)
            + [Double](repeating: 4.0, count: 5)
            + [Double](repeating: 3.0, count: 15)
            + [Double](repeating: 1.0, count: 20)
    }

    func testPerFlightMetrics() {
        let points = makeTrack(speeds: speeds)
        let rides = RideSegmenter.analyze(points: points, config: .forSport(.pumpFoil))
        XCTAssertEqual(rides.count, 1)

        // Pumput sekunnin välein lennon sisällä + pari ulkopuolella.
        let strokes: [TimeInterval] = [5.0] + (12...38).map(Double.init) + [45.0]
        let flights = FlightDetail.compute(
            segments: rides.segments,
            points: points,
            strokeTimes: strokes,
            maxPlausibleSpeed: Sport.pumpFoil.maxPlausibleSpeed
        )

        XCTAssertEqual(flights.count, 1)
        let flight = flights[0]
        XCTAssertEqual(flight.duration, 30, accuracy: 0.01)
        XCTAssertEqual(flight.strokeCount, 27, "vain lennon sisällä olevat pumput")
        XCTAssertEqual(flight.cadence, 54, accuracy: 0.5)
        XCTAssertEqual(flight.maxSpeed, 4.0, accuracy: 0.01)
        XCTAssertEqual(flight.distance, 95, accuracy: 3)
        XCTAssertEqual(flight.averageSpeed, flight.distance / 30, accuracy: 0.01)
    }

    func testImplausibleSpeedExcludedFromFlightMax() {
        var points = makeTrack(speeds: speeds)
        points[20].speed = 50 // häiriöpiikki lennon sisällä (pumpin katto 9 m/s)
        let rides = RideSegmenter.analyze(points: points, config: .forSport(.pumpFoil))
        let flights = FlightDetail.compute(
            segments: rides.segments, points: points, strokeTimes: [],
            maxPlausibleSpeed: Sport.pumpFoil.maxPlausibleSpeed
        )
        XCTAssertEqual(flights[0].maxSpeed, 4.0, accuracy: 0.01)
    }

    func testSummarizeProducesFlightsWithPumpCounts() {
        // Sama sessio motion-datalla: 1 Hz pumppaussini vain lennon aikana.
        let points = makeTrack(speeds: speeds)
        let motion = (0..<(60 * 50)).map { i -> MotionSample in
            let t = Double(i) / 50
            let active = t >= 10 && t < 40
            return MotionSample(t: t, verticalAcceleration: active ? 3.0 * sin(2 * .pi * 1.0 * t) : 0.0)
        }
        let summary = SessionAnalyzer.summarize(sport: .pumpFoil, startDate: .now, points: points, motion: motion)

        XCTAssertEqual(summary.flights?.count, 1)
        let flight = summary.flights![0]
        XCTAssertTrue((25...30).contains(flight.strokeCount), "strokeCount oli \(flight.strokeCount)")
        XCTAssertEqual(flight.cadence, 56, accuracy: 6)
        XCTAssertEqual(summary.pumps?.totalBoutTime ?? 0, 27, accuracy: 4, "aktiivinen pumppausaika")
    }

    func testSwimStrokesAreNotCountedAsPumps() {
        // Pumppisessio: lento [10,40), tyyntä [40,45), sitten UINTIA takaisin
        // laiturille [45,60) — käsivedot näyttävät ranteessa pumppaukselta,
        // mutta vauhti (0,8 m/s) paljastaa uinnin.
        let speeds = [Double](repeating: 1.0, count: 10)
            + [Double](repeating: 3.0, count: 30)
            + [Double](repeating: 1.0, count: 5)
            + [Double](repeating: 0.8, count: 15)
        let motion = (0..<(60 * 50)).map { i -> MotionSample in
            let t = Double(i) / 50
            let active = (t >= 10 && t < 40) || (t >= 45 && t < 60)
            return MotionSample(t: t, verticalAcceleration: active ? 3.0 * sin(2 * .pi * 1.0 * t) : 0.0)
        }
        let summary = SessionAnalyzer.summarize(sport: .pumpFoil, startDate: .now, points: makeTrack(speeds: speeds), motion: motion)
        let pumps = summary.pumps!

        // Ilman porttia laskuri näyttäisi ~40; uinnin vedot on suodatettu pois.
        XCTAssertTrue((24...31).contains(pumps.strokeCount), "strokeCount oli \(pumps.strokeCount)")
        XCTAssertEqual(summary.flights?.first?.strokeCount, pumps.strokeCount, "kaikki pumput lennon sisällä")

        // Uintiaika tunnistuu: hidas vauhti + voimakas käsiliike.
        XCTAssertEqual(pumps.swimTime ?? 0, 14, accuracy: 3)
    }

    func testCalmPaddlingIsNeitherPumpingNorSwimming() {
        // Rauhallinen melonta 1,0 m/s ilman käsiliikettä: ei pumppuja, ei uintia.
        let speeds = [Double](repeating: 1.0, count: 60)
        let motion = (0..<(60 * 50)).map { i in
            MotionSample(t: Double(i) / 50, verticalAcceleration: 0.1)
        }
        let summary = SessionAnalyzer.summarize(sport: .pumpFoil, startDate: .now, points: makeTrack(speeds: speeds), motion: motion)
        XCTAssertEqual(summary.pumps?.strokeCount, 0)
        XCTAssertNil(summary.pumps?.swimTime)
    }

    func testFlightsSurviveJSONRoundTrip() throws {
        let points = makeTrack(speeds: speeds)
        let summary = SessionAnalyzer.summarize(sport: .pumpFoil, startDate: Date(timeIntervalSince1970: 1_700_000_000), points: points)
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.flights, summary.flights)

        // Vanha yhteenveto ilman flights-kenttää dekoodautuu yhä.
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as! [String: Any]
        var trimmed = old
        trimmed.removeValue(forKey: "flights")
        let oldData = try JSONSerialization.data(withJSONObject: trimmed)
        let oldSummary = try JSONDecoder().decode(SessionSummary.self, from: oldData)
        XCTAssertNil(oldSummary.flights)
    }
}
