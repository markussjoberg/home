import XCTest
@testable import NosteCore

final class SessionRecoveryTests: XCTestCase {
    /// Palautettu sessio tiivistetään samoin kuin normaali: laji, alku ja jälki säilyvät.
    func testSummarizeKeepsSportStartAndTrack() {
        let start = Date(timeIntervalSince1970: 1_756_000_000)
        var points: [TrackPoint] = []
        for i in 0..<120 {
            points.append(TrackPoint(t: Double(i), latitude: 60.1 + Double(i) * 0.0001, longitude: 24.9, speed: i < 60 ? 6.5 : 0.5))
        }
        let state = SessionRecovery.State(sport: .wingFoil, startDate: start, points: points, strokeTimes: [], heartRate: nil, segments: nil)
        let summary = SessionRecovery.summarize(state)
        XCTAssertEqual(summary.sport, .wingFoil)
        XCTAssertEqual(summary.startDate, start)
        XCTAssertGreaterThan(summary.duration, 100)
        XCTAssertGreaterThan(summary.distance, 0)
        XCTAssertGreaterThan(summary.rideFraction, 0)
        XCTAssertLessThanOrEqual(summary.rideFraction, 1)
    }
}
