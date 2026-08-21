import XCTest
@testable import NosteCore

/// Rakentaa GPS-jäljen sekunnin välein: piste i etenee itään nopeudella speeds[i].
func makeTrack(speeds: [Double], latitude: Double = 60.2) -> [TrackPoint] {
    let metersPerDegreeLon = 111_320 * cos(latitude * .pi / 180)
    var lon = 25.0
    var points: [TrackPoint] = []
    for (i, speed) in speeds.enumerated() {
        points.append(TrackPoint(t: Double(i), latitude: latitude, longitude: lon, speed: speed, horizontalAccuracy: 5))
        lon += speed / metersPerDegreeLon
    }
    return points
}

final class RideSegmenterTests: XCTestCase {

    private let wing = RideSegmenter.Config.forSport(.wingFoil) // takeoff 3.3, touchdown 2.5

    func testDetectsTwoFlights() {
        let speeds = [Double](repeating: 1.0, count: 10)
            + [Double](repeating: 6.0, count: 30)
            + [Double](repeating: 1.0, count: 10)
            + [Double](repeating: 6.0, count: 5)
            + [Double](repeating: 1.0, count: 5)
        let analysis = RideSegmenter.analyze(points: makeTrack(speeds: speeds), config: wing)

        XCTAssertEqual(analysis.count, 2)
        XCTAssertEqual(analysis.segments[0].start, 10)
        XCTAssertEqual(analysis.segments[0].end, 40)
        XCTAssertEqual(analysis.segments[1].duration, 5, accuracy: 0.01)
        XCTAssertEqual(analysis.totalDuration, 35, accuracy: 0.01)
        XCTAssertEqual(analysis.longestByDuration?.duration ?? 0, 30, accuracy: 0.01)
        // Lento 1: 30 väliä à 6 m = 180 m (haversine-pyöristys huomioiden).
        XCTAssertEqual(analysis.segments[0].distance, 180, accuracy: 2)
        XCTAssertEqual(analysis.averageSpeed, analysis.totalDistance / 35, accuracy: 0.01)
    }

    func testHysteresisKeepsFlightTogether() {
        // Nopeus sahaa 3,5 ↔ 2,6 — pysyy kynnysten välissä, joten lento ei katkea.
        var speeds = (0..<20).map { $0 % 2 == 0 ? 3.5 : 2.6 }
        speeds += [Double](repeating: 1.0, count: 5)
        let analysis = RideSegmenter.analyze(points: makeTrack(speeds: speeds), config: wing)
        XCTAssertEqual(analysis.count, 1)
        XCTAssertEqual(analysis.segments[0].start, 0)
        XCTAssertEqual(analysis.segments[0].end, 20)
    }

    func testMergesShortGap() {
        let speeds = [Double](repeating: 6.0, count: 10) + [1.0]
            + [Double](repeating: 6.0, count: 10)
            + [Double](repeating: 1.0, count: 4)
        let analysis = RideSegmenter.analyze(points: makeTrack(speeds: speeds), config: wing)
        XCTAssertEqual(analysis.count, 1)
        XCTAssertEqual(analysis.segments[0].end, 21)
    }

    func testDropsTooShortSegments() {
        let speeds = [1.0, 1.0, 6.0, 6.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0] // 2 s lento < 3 s minimi
        let analysis = RideSegmenter.analyze(points: makeTrack(speeds: speeds), config: wing)
        XCTAssertEqual(analysis.count, 0)
    }

    func testRoughnessGatesTakeoff() {
        // Nopeus riittäisi hetkestä 5 alkaen, mutta signaali on tärisevä hetkeen 15 asti.
        var speeds = [Double](repeating: 1.0, count: 5)
        speeds += [Double](repeating: 3.5, count: 55)
        var motion: [MotionSample] = []
        for i in 0..<(60 * 50) {
            let t = Double(i) / 50
            motion.append(MotionSample(t: t, verticalAcceleration: t < 15 ? (i % 2 == 0 ? 3.0 : -3.0) : 0.0))
        }
        var config = wing
        config.maxTakeoffRoughness = 1.0

        let analysis = RideSegmenter.analyze(
            points: makeTrack(speeds: speeds),
            roughness: RideSegmenter.roughness(of: motion),
            config: config
        )
        XCTAssertEqual(analysis.count, 1)
        XCTAssertGreaterThanOrEqual(analysis.segments[0].start, 15)
        XCTAssertLessThanOrEqual(analysis.segments[0].start, 18)

        // Ilman tärinäporttia lento alkaisi jo hetkellä 5.
        let ungated = RideSegmenter.analyze(points: makeTrack(speeds: speeds), config: wing)
        XCTAssertEqual(ungated.segments[0].start, 5)
    }
}
