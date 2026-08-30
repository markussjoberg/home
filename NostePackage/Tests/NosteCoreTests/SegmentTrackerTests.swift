import XCTest
@testable import NosteCore

final class SegmentTrackerTests: XCTestCase {

    // MARK: - Keskeisin vaatimus: tallennus ei koskaan katkea

    /// Järviskenaario, joka aiemmin hävitti 3 h session: pitkä paikallaanolo
    /// lähtöpaikalla ei saa tuottaa mitään muuta kuin vettä — paikallaan olo
    /// on lajin ydintä, ei tauko.
    func testStationaryOnWaterStaysWaterForever() {
        let tracker = SegmentTracker(sport: .wingFoil)
        // 30 min paikallaan vedessä (tuulen odotus), sitten 5 min purjehdusta.
        for i in 0..<1800 {
            XCTAssertEqual(tracker.add(t: Double(i), speed: 0.1, isWater: true), .water)
        }
        for i in 1800..<2100 {
            XCTAssertEqual(tracker.add(t: Double(i), speed: 6.0, isWater: true), .water)
        }
        let segments = tracker.snapshot(at: 2100)
        XCTAssertEqual(segments, [SessionSegment(start: 0, end: 2100, kind: .water)])
    }

    /// Ilman vesialuetietoa (ei maskia) mikään ei koskaan muutu maissa-jaksoksi
    /// — tuntematon on aina vettä, myös paikallaan.
    func testUnknownLocationNeverBecomesLand() {
        let tracker = SegmentTracker(sport: .wingFoil)
        for i in 0..<3600 {
            XCTAssertEqual(tracker.add(t: Double(i), speed: 0.0, isWater: nil), .water)
        }
        XCTAssertEqual(tracker.snapshot(at: 3600).count, 1)
    }

    // MARK: - Maissa vesialuetiedolla

    func testSustainedLandCreatesLandSegmentBackdated() {
        let tracker = SegmentTracker(sport: .wingFoil)
        for i in 0..<600 { tracker.add(t: Double(i), speed: 3.0, isWater: true) }
        // Maihin klo 600; maissa-jakso alkaa takautuvasti hetkestä 600.
        for i in 600..<700 { tracker.add(t: Double(i), speed: 0.5, isWater: false) }
        XCTAssertEqual(tracker.currentKind, .land)
        let segments = tracker.snapshot(at: 700)
        XCTAssertEqual(segments, [
            SessionSegment(start: 0, end: 600, kind: .water),
            SessionSegment(start: 600, end: 700, kind: .land)
        ])
    }

    /// GPS-heitto rannassa (hetkellinen "maalla") ei tee maissa-jaksoa.
    func testBriefLandBlipStaysWater() {
        let tracker = SegmentTracker(sport: .wingFoil)
        for i in 0..<100 { tracker.add(t: Double(i), speed: 2.0, isWater: true) }
        for i in 100..<130 { tracker.add(t: Double(i), speed: 2.0, isWater: false) } // 30 s < 60 s
        for i in 130..<200 { tracker.add(t: Double(i), speed: 2.0, isWater: true) }
        XCTAssertEqual(tracker.currentKind, .water)
        XCTAssertEqual(tracker.snapshot(at: 200).count, 1)
    }

    func testWaterReturnsQuicklyFromLand() {
        let tracker = SegmentTracker(sport: .wingFoil)
        for i in 0..<300 { tracker.add(t: Double(i), speed: 2.0, isWater: true) }
        for i in 300..<400 { tracker.add(t: Double(i), speed: 0.3, isWater: false) }
        XCTAssertEqual(tracker.currentKind, .land)
        for i in 400..<415 { tracker.add(t: Double(i), speed: 1.0, isWater: true) }
        XCTAssertEqual(tracker.currentKind, .water)
        let segments = tracker.snapshot(at: 500)
        XCTAssertEqual(segments[1], SessionSegment(start: 300, end: 400, kind: .land))
        XCTAssertEqual(segments[2].kind, .water)
    }

    // MARK: - Siirtymä (autoilu)

    func testDrivingBecomesTransitButRecordingContinues() {
        let tracker = SegmentTracker(sport: .wingFoil)
        for i in 0..<1000 { tracker.add(t: Double(i), speed: 4.0, isWater: true) }
        // Autoon: 25 m/s (90 km/h) — wingfoilille mahdoton.
        var kind: SessionSegment.Kind = .water
        for i in 1000..<1300 { kind = tracker.add(t: Double(i), speed: 25.0, isWater: false) }
        XCTAssertEqual(kind, .transit)
        let segments = tracker.snapshot(at: 1300)
        // Siirtymä alkaa takautuvasti kovan vauhdin alusta.
        XCTAssertEqual(segments.last, SessionSegment(start: 1000, end: 1300, kind: .transit))
        XCTAssertEqual(segments.first, SessionSegment(start: 0, end: 1000, kind: .water))
    }

    func testTransitEndsWhenBackOnWater() {
        let tracker = SegmentTracker(sport: .wingFoil)
        for i in 0..<100 { tracker.add(t: Double(i), speed: 3.0, isWater: true) }
        for i in 100..<200 { tracker.add(t: Double(i), speed: 25.0, isWater: false) }
        XCTAssertEqual(tracker.currentKind, .transit)
        // Takaisin vesille (esim. toinen ranta) — vesi palauttaa nopeasti.
        for i in 200..<215 { tracker.add(t: Double(i), speed: 2.0, isWater: true) }
        XCTAssertEqual(tracker.currentKind, .water)
    }

    /// Hetkellinen GPS-nopeuspiikki ei tee siirtymää.
    func testSpeedSpikeDoesNotCreateTransit() {
        let tracker = SegmentTracker(sport: .wingFoil)
        for i in 0..<100 { tracker.add(t: Double(i), speed: 5.0, isWater: true) }
        for i in 100..<110 { tracker.add(t: Double(i), speed: 30.0, isWater: true) } // 10 s < 30 s
        for i in 110..<200 { tracker.add(t: Double(i), speed: 5.0, isWater: true) }
        XCTAssertEqual(tracker.currentKind, .water)
        XCTAssertEqual(tracker.snapshot(at: 200).count, 1)
    }
}
