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

    func testTrackPointDecodesWithoutAccuracyField() throws {
        // Vanha talletettu jälki ilman horizontalAccuracy-kenttää ei saa kadota.
        let old = #"{"t":1.5,"latitude":60.1,"longitude":24.9,"speed":5.2}"#
        let point = try JSONDecoder().decode(TrackPoint.self, from: Data(old.utf8))
        XCTAssertEqual(point.horizontalAccuracy, -1)
        XCTAssertEqual(point.speed, 5.2, accuracy: 0.001)
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

    func testSummaryDecodesWithoutSegmentsField() throws {
        // Vanha talletettu yhteenveto ilman segments-kenttää dekoodautuu yhä.
        let summary = SessionAnalyzer.summarize(
            sport: .wingFoil, startDate: .now, points: makeTrack(speeds: [1, 3, 3, 1])
        )
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(summary)) as! [String: Any]
        json.removeValue(forKey: "segments")
        let decoded = try JSONDecoder().decode(
            SessionSummary.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.segments)
        XCTAssertEqual(decoded.duration, summary.duration, accuracy: 0.001)
    }

    // MARK: - Segmentoitu analyysi

    /// Sessio, jonka lopussa ajetaan autolla: koko jälki tallentuu (kesto),
    /// mutta matka, maksiminopeus ja ennätykset tulevat vain vesijaksosta.
    func testTransitTailExcludedFromMetricsButNotDuration() {
        // 60 s purjehdusta 6 m/s + 60 s autoilua 25 m/s.
        let speeds = [Double](repeating: 6.0, count: 60) + [Double](repeating: 25.0, count: 60)
        let points = makeTrack(speeds: speeds)
        let segments = [
            SessionSegment(start: 0, end: 60, kind: .water),
            SessionSegment(start: 60, end: 119, kind: .transit)
        ]
        let summary = SessionAnalyzer.summarize(
            sport: .wingFoil, startDate: .now, points: points, segments: segments
        )
        XCTAssertEqual(summary.duration, 119, accuracy: 0.01, "kesto = koko tallenne")
        XCTAssertEqual(summary.waterDuration, 60, accuracy: 0.01)
        XCTAssertEqual(summary.maxSpeed, 6.0, accuracy: 0.01, "autoilu ei ole maksiminopeus")
        // Matka vain vesijaksosta (~6 m/s * 60 s), ei autoilun ~1500 m.
        XCTAssertEqual(summary.distance, 360, accuracy: 20)
        if let records = summary.speedRecords {
            XCTAssertEqual(records.best2s, 6.0, accuracy: 0.1, "ennätys ei synny autossa")
        }
        XCTAssertEqual(summary.segments, segments)
    }

    /// Maissa-jakso keskellä (tauko rannalla) ei katkaise mitään eikä kadota
    /// dataa — molempien vesijaksojen suoritukset lasketaan.
    func testLandBreakBetweenWaterWindows() {
        let speeds = [Double](repeating: 6.0, count: 30)   // vesi: lento
            + [Double](repeating: 0.2, count: 120)          // rannalla
            + [Double](repeating: 6.0, count: 30)           // vesi: toinen lento
        let points = makeTrack(speeds: speeds)
        let segments = [
            SessionSegment(start: 0, end: 30, kind: .water),
            SessionSegment(start: 30, end: 150, kind: .land),
            SessionSegment(start: 150, end: 179, kind: .water)
        ]
        let summary = SessionAnalyzer.summarize(
            sport: .wingFoil, startDate: .now, points: points, segments: segments
        )
        XCTAssertEqual(summary.rides.count, 2, "molemmat lennot löytyvät")
        XCTAssertEqual(summary.duration, 179, accuracy: 0.01)
        XCTAssertEqual(summary.waterDuration, 59, accuracy: 0.01)
    }

    /// Pelkkiä vesisegmenttejä sisältävä analyysi = sama tulos kuin ilman
    /// segmenttejä (nopea polku, ei jakoa ikkunoihin).
    func testAllWaterSegmentsMatchesPlainAnalysis() {
        let speeds = [Double](repeating: 1.0, count: 10) + [Double](repeating: 6.0, count: 30)
        let points = makeTrack(speeds: speeds)
        let plain = SessionAnalyzer.summarize(sport: .wingFoil, startDate: .now, points: points)
        let segmented = SessionAnalyzer.summarize(
            sport: .wingFoil, startDate: .now, points: points,
            segments: [SessionSegment(start: 0, end: 39, kind: .water)]
        )
        XCTAssertEqual(segmented.distance, plain.distance, accuracy: 0.001)
        XCTAssertEqual(segmented.maxSpeed, plain.maxSpeed, accuracy: 0.001)
        XCTAssertEqual(segmented.rides.count, plain.rides.count)
    }
}

extension SessionAnalyzerTests {

    /// Surffi: aalto vaatii punnerruksen. Sama nopeusprofiili ilman
    /// pop-up-piikkiä (tuuliajelehdinta) ei ole aalto.
    func testSurfWaveRequiresPopup() {
        // 30 s melontaa 1 m/s + 20 s laskua 4 m/s + 10 s melontaa.
        let speeds = [Double](repeating: 1.0, count: 30)
            + [Double](repeating: 4.0, count: 20)
            + [Double](repeating: 1.0, count: 10)
        let points = makeTrack(speeds: speeds)

        // Melontakohinaa + punnerruspiikki juuri ennen irtoamista (t=29).
        var withPopup: [MotionSample] = []
        for i in 0..<(60 * 50) {
            let t = Double(i) / 50
            var value = sin(t * 4) * 0.8
            if t >= 28.6 && t < 29.0 { value = 7.5 } // pop-up + ponnistus
            withPopup.append(MotionSample(t: t, verticalAcceleration: value))
        }
        let surf = SessionAnalyzer.summarize(sport: .surf, startDate: .now, points: points, motion: withPopup)
        XCTAssertEqual(surf.rides.count, 1, "punnerrus vahvistaa aallon")
        XCTAssertEqual(surf.rides.totalDuration, 20, accuracy: 3, "aaltoaika")

        // Sama ilman piikkiä → ei aaltoa.
        let calm = (0..<(60 * 50)).map { MotionSample(t: Double($0) / 50, verticalAcceleration: sin(Double($0) / 50 * 4) * 0.8) }
        let drift = SessionAnalyzer.summarize(sport: .surf, startDate: .now, points: points, motion: calm)
        XCTAssertEqual(drift.rides.count, 0, "ajelehdinta ilman punnerrusta ei ole aalto")

        // Ilman kiihtyvyysdataa nopeus riittää (ei voida vahvistaa).
        let noMotion = SessionAnalyzer.summarize(sport: .surf, startDate: .now, points: points)
        XCTAssertEqual(noMotion.rides.count, 1)
    }
}
