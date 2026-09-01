import XCTest
@testable import NosteCore

final class JumpDetectorTests: XCTestCase {

    /// Rakentaa signaalin 50 Hz: normaalia kohinaa, ja hyppyjä (vapaapudotus
    /// −9,8 m/s² + alastuloisku) annetuilla hetkillä ja kestoilla.
    private func signal(duration: TimeInterval, jumps: [(t: TimeInterval, air: TimeInterval)]) -> [MotionSample] {
        var samples: [MotionSample] = []
        let rate = 50.0
        for i in 0..<Int(duration * rate) {
            let t = Double(i) / rate
            var value = sin(t * 3) * 1.2 // normaali käsiliike
            for jump in jumps {
                if t >= jump.t && t < jump.t + jump.air {
                    value = -9.6 // vapaapudotus
                } else if t >= jump.t + jump.air && t < jump.t + jump.air + 0.15 {
                    value = 9.0 // alastuloisku
                }
            }
            samples.append(MotionSample(t: t, verticalAcceleration: value))
        }
        return samples
    }

    func testDetectsJumpsWithAirTime() {
        let analysis = JumpDetector.analyze(signal(duration: 60, jumps: [(10, 0.8), (30, 1.5)]))
        XCTAssertEqual(analysis.count, 2)
        XCTAssertEqual(analysis.jumps[0].airTime, 0.8, accuracy: 0.1)
        XCTAssertEqual(analysis.jumps[1].airTime, 1.5, accuracy: 0.1)
        XCTAssertEqual(analysis.longest?.airTime ?? 0, 1.5, accuracy: 0.1)
        XCTAssertEqual(analysis.totalAirTime, 2.3, accuracy: 0.2)
        XCTAssertGreaterThan(analysis.jumps[0].landingG, 4.0)
    }

    /// Ranteen heilautus (lyhyt pseudopudotus) ei ole hyppy.
    func testShortDropIsNotAJump() {
        let analysis = JumpDetector.analyze(signal(duration: 30, jumps: [(10, 0.2)]))
        XCTAssertEqual(analysis.count, 0)
    }

    /// Vapaapudotus ilman alastuloiskua (esim. anturihäiriö) hylätään.
    func testFreefallWithoutLandingRejected() {
        var samples = signal(duration: 30, jumps: [])
        let rate = 50.0
        for i in 0..<samples.count {
            let t = Double(i) / rate
            if t >= 10 && t < 10.8 { samples[i].verticalAcceleration = -9.6 }
            // ei iskua perään — arvot palaavat kohinaan
        }
        let analysis = JumpDetector.analyze(samples)
        XCTAssertEqual(analysis.count, 0)
    }

    /// Epäuskottavan pitkä "pudotus" (anturi jumissa) hylätään.
    func testAbsurdAirTimeRejected() {
        let analysis = JumpDetector.analyze(signal(duration: 30, jumps: [(5, 8.0)]))
        XCTAssertEqual(analysis.count, 0)
    }

    func testAnalyzerAttachesJumpsForWindSports() {
        // 60 s wingiä 6 m/s + hyppy hetkellä 20.
        let points = makeTrack(speeds: [Double](repeating: 6.0, count: 60))
        let motion = signal(duration: 60, jumps: [(20, 1.0)])
        let summary = SessionAnalyzer.summarize(sport: .wingFoil, startDate: .now, points: points, motion: motion)
        XCTAssertEqual(summary.jumps?.count, 1)
        XCTAssertEqual(summary.jumps?.longest?.airTime ?? 0, 1.0, accuracy: 0.1)
        // Pumppilaji ei laske hyppyjä.
        let pump = SessionAnalyzer.summarize(sport: .pumpFoil, startDate: .now, points: points, motion: motion)
        XCTAssertNil(pump.jumps)
    }
}
