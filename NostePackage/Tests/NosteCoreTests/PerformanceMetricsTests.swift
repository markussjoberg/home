import XCTest
@testable import NosteCore

final class PerformanceMetricsTests: XCTestCase {

    func testStartAttemptsAndSuccessRate() {
        // Pumppi: 1 s lässähtänyt startti + 30 s onnistunut lento.
        var all = [Double](repeating: 1.0, count: 10)
        all.append(3.0)                                   // t=10: nousi hetkeksi
        all += [Double](repeating: 1.0, count: 9)         // t=11..19: lässähti
        all += [Double](repeating: 3.0, count: 30)        // t=20..49: lento
        all += [Double](repeating: 1.0, count: 10)
        let analysis = RideSegmenter.analyze(points: makeTrack(speeds: all), config: .forSport(.pumpFoil))
        XCTAssertEqual(analysis.count, 1)
        XCTAssertEqual(analysis.attemptCount, 2)
        XCTAssertEqual(analysis.successRate ?? 0, 0.5, accuracy: 0.001)
    }

    func testGlideRatioFromBoutOverlap() {
        let segment = RideSegment(start: 10, end: 40, distance: 90)
        let flights = FlightDetail.compute(
            segments: [segment],
            points: makeTrack(speeds: [Double](repeating: 3.0, count: 50)),
            strokeTimes: (12...25).map(Double.init),
            maxPlausibleSpeed: 9,
            bouts: [RideSegment(start: 12, end: 25, distance: 0)]
        )
        XCTAssertEqual(flights[0].pumpingTime ?? -1, 13, accuracy: 0.01)
        XCTAssertEqual(flights[0].glideRatio ?? -1, 1 - 13.0 / 30.0, accuracy: 0.01)
    }

    func testSpeedRecords() {
        // 30 s @ 5 m/s, sitten 30 s @ 3 m/s.
        let speeds = [Double](repeating: 5.0, count: 30) + [Double](repeating: 3.0, count: 30)
        let records = SpeedRecords.compute(points: makeTrack(speeds: speeds), maxPlausibleSpeed: 20)
        XCTAssertEqual(records?.best2s ?? 0, 5.0, accuracy: 0.01)
        XCTAssertEqual(records?.best10s ?? 0, 5.0, accuracy: 0.01)
        XCTAssertEqual(records?.best100m ?? 0, 5.0, accuracy: 0.05)
    }

    func testSpeedRecordsIgnoreSpikesAndShortData() {
        var points = makeTrack(speeds: [Double](repeating: 5.0, count: 30))
        points[10].speed = 80
        let records = SpeedRecords.compute(points: points, maxPlausibleSpeed: 20)
        XCTAssertEqual(records?.best2s ?? 0, 5.0, accuracy: 0.01)
        XCTAssertNil(SpeedRecords.compute(points: Array(points.prefix(2)), maxPlausibleSpeed: 20))
    }

    func testNoHundredMeterRecordOnShortDistance() {
        // 30 s @ 2 m/s = 58 m — ei sadan metrin ennätystä.
        let records = SpeedRecords.compute(points: makeTrack(speeds: [Double](repeating: 2.0, count: 30)), maxPlausibleSpeed: 20)
        XCTAssertEqual(records?.best100m ?? -1, 0)
        XCTAssertEqual(records?.best2s ?? 0, 2.0, accuracy: 0.01)
    }

    func testGPXExport() {
        let track = [
            TrackPoint(t: 0, latitude: 60.1, longitude: 24.9, speed: 3),
            TrackPoint(t: 1, latitude: 60.1001, longitude: 24.9001, speed: 3)
        ]
        let gpx = GPXExporter.gpx(track: track, startDate: Date(timeIntervalSince1970: 1_700_000_000), name: "Pumppi & testi")
        XCTAssertTrue(gpx.contains(#"<trkpt lat="60.100000" lon="24.900000">"#))
        XCTAssertTrue(gpx.contains("Pumppi &amp; testi"))
        XCTAssertTrue(gpx.contains("<time>2023-11-14T"))
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt").count - 1, 2)
    }
}
