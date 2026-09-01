import XCTest
@testable import NosteCore

final class TrackCleanerTests: XCTestCase {

    private func point(_ t: Double, _ lat: Double, _ lon: Double, accuracy: Double = 5) -> TrackPoint {
        TrackPoint(t: t, latitude: lat, longitude: lon, speed: 5, horizontalAccuracy: accuracy)
    }

    func testDropsTeleportOutlier() {
        // Tasaista etenemistä + yksi villi piste 10 km pohjoiseen.
        var points = (0..<60).map { point(Double($0), 60.15 + Double($0) * 0.00005, 24.95) }
        points[30] = point(30, 60.25, 24.95) // ~11 km hyppy sekunnissa
        let cleaned = TrackCleaner.clean(points, maxPlausibleSpeed: 20)
        XCTAssertEqual(cleaned.count, 59)
        XCTAssertFalse(cleaned.contains { $0.latitude > 60.2 })
    }

    func testWildFirstFixDoesNotAnchorTrack()  {
        var points = (0..<60).map { point(Double($0), 60.15 + Double($0) * 0.00005, 24.95) }
        points[0] = point(0, 60.35, 24.95) // kylmäkäynnistyksen haamufix
        let cleaned = TrackCleaner.clean(points, maxPlausibleSpeed: 20)
        XCTAssertFalse(cleaned.contains { $0.latitude > 60.3 })
        XCTAssertGreaterThan(cleaned.count, 50)
    }

    func testNormalTrackUntouched() {
        let points = (0..<60).map { point(Double($0), 60.15 + Double($0) * 0.00005, 24.95) }
        XCTAssertEqual(TrackCleaner.clean(points, maxPlausibleSpeed: 20).count, 60)
    }

    func testBadAccuracyDropped() {
        var points = (0..<20).map { point(Double($0), 60.15, 24.95 + Double($0) * 0.00005) }
        points[10] = point(10, 60.15, 24.9505, accuracy: 300)
        let cleaned = TrackCleaner.clean(points, maxPlausibleSpeed: 20)
        XCTAssertEqual(cleaned.count, 19)
    }
}
