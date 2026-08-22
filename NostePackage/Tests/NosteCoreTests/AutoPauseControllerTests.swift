import XCTest
@testable import NosteCore

final class AutoPauseControllerTests: XCTestCase {

    private func run(_ controller: AutoPauseController,
                     _ segments: [(count: Int, speed: Double, dist: Double)],
                     stopOnEnd: Bool = true) -> [(t: TimeInterval, event: AutoPauseController.Event)] {
        var events: [(TimeInterval, AutoPauseController.Event)] = []
        var t: TimeInterval = 0
        for segment in segments {
            for _ in 0..<segment.count {
                let event = controller.add(t: t, speed: segment.speed, distanceFromStart: segment.dist)
                if event != .none {
                    events.append((t, event))
                    if stopOnEnd, case .endSession = event { return events }
                }
                t += 1
            }
        }
        return events
    }

    func testRestOnWaterPausesAndAutoResumes() {
        let events = run(AutoPauseController(sport: .wingFoil), [
            (100, 6.0, 500),   // purjehditaan
            (130, 0.3, 500),   // lepo vesillä
            (30, 6.0, 500)     // taas menoksi
        ])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, .pause(nearStart: false))
        XCTAssertEqual(events[0].t, 190, accuracy: 2)
        XCTAssertEqual(events[1].event, .resume)
        XCTAssertEqual(events[1].t, 235, accuracy: 2)
    }

    func testBeachExitDoesNotResumeOnCityDriving() {
        // Palataan lähtöpaikkaan → paussi 45 s:ssa. Kaupunkiajo 13 m/s on wingille
        // uskottava nopeus, mutta lähtöpaikkapaussi ei jatku automaattisesti.
        // Moottoritienopeus päättää session.
        let events = run(AutoPauseController(sport: .wingFoil), [
            (50, 5.0, 300),
            (70, 0.2, 30),     // rannassa
            (30, 1.0, 30),     // kävelyä
            (50, 13.0, 2000),  // kaupunkiajoa
            (45, 25.0, 5000)   // moottoritie
        ])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, .pause(nearStart: true))
        XCTAssertEqual(events[0].t, 95, accuracy: 2)
        XCTAssertEqual(events[1].event, .endSession(reason: .drivingDetected))
    }

    func testPumpFoilDrivingDetectedAnywhere() {
        // Pumpin katto 9 m/s: kaupunkiajo tunnistetaan vaikka paussi tuli muualla.
        let events = run(AutoPauseController(sport: .pumpFoil), [
            (30, 2.5, 400),
            (95, 0.2, 400),
            (35, 13.0, 1000)
        ])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, .pause(nearStart: false))
        XCTAssertEqual(events[1].event, .endSession(reason: .drivingDetected))
    }

    func testLongPauseSuggestsEnd() {
        let controller = AutoPauseController(sport: .wingFoil)
        let events = run(controller, [(30, 4.0, 300), (95, 0.1, 300)])
        XCTAssertEqual(events.first?.event, .pause(nearStart: false))
        // 21 min myöhemmin.
        let event = controller.add(t: 125 + 21 * 60, speed: 0.1, distanceFromStart: 300)
        XCTAssertEqual(event, .endSession(reason: .pauseTimeout))
    }

    func testBriefStopDoesNotPause() {
        let events = run(AutoPauseController(sport: .wingFoil), [
            (20, 5.0, 60),
            (35, 0.3, 60),   // 35 s pysähdys lähtöpaikalla — alle 45 s rajan
            (25, 5.0, 200)
        ])
        XCTAssertTrue(events.isEmpty)
    }

    func testManualPauseNeverAutoResumes() {
        let controller = AutoPauseController(sport: .wingFoil)
        controller.manualPause(t: 10)
        for t in 11...30 {
            XCTAssertEqual(controller.add(t: Double(t), speed: 6.0, distanceFromStart: 500), .none)
        }
        controller.manualResume()
        XCTAssertEqual(controller.mode, .running)
    }

    func testHeartRateStats() {
        let samples = [HeartRateSample(t: 0, bpm: 120), HeartRateSample(t: 5, bpm: 150), HeartRateSample(t: 10, bpm: 135)]
        let stats = HeartRateStats.from(samples)
        XCTAssertEqual(stats?.average ?? 0, 135, accuracy: 0.01)
        XCTAssertEqual(stats?.max ?? 0, 150, accuracy: 0.01)
        XCTAssertNil(HeartRateStats.from([]))
    }
}
