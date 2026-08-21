import XCTest
@testable import NosteCore

/// Deterministinen kohinageneraattori (LCG), jotta testit ovat toistettavia.
struct SeededNoise {
    private var state: UInt64
    init(seed: UInt64 = 42) { state = seed }
    /// Palauttaa arvon väliltä [0, 1).
    mutating func next() -> Double {
        state = (state &* 1_103_515_245 &+ 12345) % (1 << 31)
        return Double(state) / Double(1 << 31)
    }
}

final class PumpDetectorTests: XCTestCase {

    private func samples(duration: TimeInterval, rate: Double = 50, signal: (TimeInterval) -> Double) -> [MotionSample] {
        (0..<Int(duration * rate)).map { i in
            let t = Double(i) / rate
            return MotionSample(t: t, verticalAcceleration: signal(t))
        }
    }

    func testCountsSinePumping() {
        // 0,9 Hz pumppaus 60 s → ~54 sykliä; ensimmäiset menetetään alustukseen.
        let analysis = PumpDetector.analyze(samples(duration: 60) { t in
            3.0 * sin(2 * .pi * 0.9 * t)
        })
        XCTAssertTrue((50...56).contains(analysis.strokeCount), "strokeCount oli \(analysis.strokeCount)")
        XCTAssertEqual(analysis.bouts.count, 1)
        XCTAssertEqual(analysis.averageCadence, 54, accuracy: 3)
    }

    func testIgnoresNoise() {
        var noise = SeededNoise()
        let analysis = PumpDetector.analyze(samples(duration: 60) { _ in
            (noise.next() - 0.5) * 0.6
        })
        XCTAssertEqual(analysis.strokeCount, 0)
    }

    func testIgnoresSwellRocking() {
        // Maininkikeinunta 0,25 Hz + kohina ei saa laskea pumpuiksi.
        var noise = SeededNoise(seed: 7)
        let analysis = PumpDetector.analyze(samples(duration: 60) { t in
            0.8 * sin(2 * .pi * 0.25 * t) + (noise.next() - 0.5) * 0.4
        })
        XCTAssertEqual(analysis.strokeCount, 0)
    }

    func testSeparatesBouts() {
        // Kaksi 20 s pumppausjaksoa, välissä 10 s tauko.
        let analysis = PumpDetector.analyze(samples(duration: 60) { t in
            let active = t < 20 || (t >= 30 && t < 50)
            return active ? 3.0 * sin(2 * .pi * 1.0 * t) : 0.0
        })
        XCTAssertTrue((36...42).contains(analysis.strokeCount), "strokeCount oli \(analysis.strokeCount)")
        XCTAssertEqual(analysis.bouts.count, 2)
        XCTAssertEqual(analysis.averageCadence, 60, accuracy: 5)
    }

    func testStreamingMatchesBatch() {
        let data = samples(duration: 30) { t in 3.0 * sin(2 * .pi * 1.0 * t) }
        let detector = PumpDetector()
        for sample in data { detector.add(sample) }
        XCTAssertEqual(detector.finish(), PumpDetector.analyze(data))
    }
}
