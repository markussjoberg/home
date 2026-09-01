import XCTest
@testable import NosteCore

final class WebMercatorTests: XCTestCase {

    func testTileXYMatchesKnownReference() {
        // Helsingin edusta z12 — sama ankkuri kuin palvelimen tiilitesteissä.
        let tile = WebMercator.tileXY(latitude: 60.15, longitude: 24.95, zoom: 12)
        XCTAssertEqual(Int(floor(tile.x)), 2331)
        XCTAssertEqual(Int(floor(tile.y)), 1186)
    }

    func testMetersPerPixel() {
        // z14 @ 60°N ≈ 4,78 m/px.
        XCTAssertEqual(WebMercator.metersPerPixel(latitude: 60, zoom: 14), 4.78, accuracy: 0.05)
    }

    func testCenteredCalibrationProjectsCenterNearMiddle() {
        let calibration = OfflineMapCalibration.centered(latitude: 60.15, longitude: 24.95, zoom: 14, tileCount: 3)
        XCTAssertEqual(calibration.imageSize, 768)
        let center = calibration.point(latitude: 60.15, longitude: 24.95)
        // Keskipiste osuu keskimmäiseen tiileen (256–512 px).
        XCTAssertTrue((256...512).contains(center.x), "x oli \(center.x)")
        XCTAssertTrue((256...512).contains(center.y), "y oli \(center.y)")
        XCTAssertTrue(calibration.contains(latitude: 60.15, longitude: 24.95))
        XCTAssertFalse(calibration.contains(latitude: 61.0, longitude: 24.95))
    }

    func testPixelDistanceMatchesGroundDistance() {
        // 1 km itään z14:llä ≈ 1000 / 4,78 ≈ 209 px.
        let calibration = OfflineMapCalibration.centered(latitude: 60.0, longitude: 25.0, zoom: 14, tileCount: 3)
        let metersPerDegree = 111_320 * cos(60.0 * .pi / 180)
        let a = calibration.point(latitude: 60.0, longitude: 25.0)
        let b = calibration.point(latitude: 60.0, longitude: 25.0 + 1000 / metersPerDegree)
        XCTAssertEqual(b.x - a.x, 1000 / WebMercator.metersPerPixel(latitude: 60, zoom: 14), accuracy: 2)
        XCTAssertEqual(b.y - a.y, 0, accuracy: 0.5)
    }

    func testMotionLogRoundTrip() {
        let samples = (0..<500).map { i in
            MotionSample(t: Double(i) / 50, verticalAcceleration: 3.0 * sin(Double(i) * 0.1))
        }
        let packed = MotionLog.pack(samples)
        XCTAssertEqual(packed.count, 8 + 500 * 8)
        let unpacked = MotionLog.unpack(packed)
        XCTAssertEqual(unpacked?.count, 500)
        XCTAssertEqual(unpacked?[123].t ?? 0, samples[123].t, accuracy: 0.001)
        XCTAssertEqual(unpacked?[123].verticalAcceleration ?? 0, samples[123].verticalAcceleration, accuracy: 0.001)
        XCTAssertNil(MotionLog.unpack(Data([1, 2, 3])))
        XCTAssertEqual(MotionLog.unpack(MotionLog.pack([]))?.count, 0)
    }

    func testMapImageMetadataRoundTrip() {
        let calibration = OfflineMapCalibration.centered(latitude: 60.15, longitude: 24.95, zoom: 15, tileCount: 3)
        let id = UUID()
        let metadata = WatchSync.MapImage.metadata(spotID: id, calibration: calibration)!
        let decoded = WatchSync.MapImage.decode(metadata)
        XCTAssertEqual(decoded?.spotID, id)
        XCTAssertEqual(decoded?.calibration, calibration)
    }
}
