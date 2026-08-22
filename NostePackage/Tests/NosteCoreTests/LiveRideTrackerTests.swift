import XCTest
@testable import NosteCore

final class LiveRideTrackerTests: XCTestCase {

    private func run(_ speeds: [Double], sport: Sport) -> LiveRideTracker.State {
        let tracker = LiveRideTracker(sport: sport)
        for (i, speed) in speeds.enumerated() {
            tracker.add(t: Double(i), speed: speed)
        }
        return tracker.current
    }

    func testCountsFlightsAndAccumulatesTime() {
        let speeds = [Double](repeating: 1, count: 10)
            + [Double](repeating: 6, count: 30)
            + [Double](repeating: 1, count: 10)
            + [Double](repeating: 6, count: 5)
            + [Double](repeating: 1, count: 5)
        let state = run(speeds, sport: .wingFoil)
        XCTAssertEqual(state.rideCount, 2)
        XCTAssertEqual(state.totalRideTime, 35, accuracy: 0.01)
        XCTAssertFalse(state.isRiding)
        XCTAssertEqual(state.currentRideDuration, 0)
    }

    func testTooShortFlightNotCounted() {
        let state = run([1, 1, 6, 6, 1, 1, 1], sport: .wingFoil)
        XCTAssertEqual(state.rideCount, 0)
        XCTAssertEqual(state.totalRideTime, 2, accuracy: 0.01)
    }

    func testCurrentFlightDurationMidRide() {
        let speeds = [Double](repeating: 1, count: 5) + [Double](repeating: 3, count: 8)
        let state = run(speeds, sport: .pumpFoil)
        XCTAssertTrue(state.isRiding)
        XCTAssertEqual(state.currentRideDuration, 7, accuracy: 0.01)
        XCTAssertEqual(state.rideCount, 1, "käynnissä oleva lento lasketaan heti minimikeston täytyttyä")
    }

    func testUnknownSpeedDoesNotEndRide() {
        let state = run([1, 6, 6, -1, -1, 6, 6, 6], sport: .wingFoil)
        XCTAssertTrue(state.isRiding)
        XCTAssertEqual(state.rideCount, 1)
    }
}
