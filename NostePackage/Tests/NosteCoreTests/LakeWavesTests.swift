import XCTest
@testable import NosteCore

final class LakeWavesTests: XCTestCase {

    func testReferenceValues() {
        // Referenssitoteutuksella lasketut odotusarvot.
        let cases: [(u: Double, fKm: Double, hs: Double, tp: Double)] = [
            (5, 3, 0.14, 1.5),
            (8, 5, 0.29, 2.1),
            (10, 10, 0.51, 2.9),
            (12, 20, 0.87, 3.9),
            (10, 2, 0.23, 1.7)
        ]
        for c in cases {
            let estimate = LakeWaves.estimate(windSpeed: c.u, fetchMeters: c.fKm * 1000)
            XCTAssertEqual(estimate.height, c.hs, accuracy: 0.01, "Hs U=\(c.u) F=\(c.fKm)")
            XCTAssertEqual(estimate.period, c.tp, accuracy: 0.1, "Tp U=\(c.u) F=\(c.fKm)")
        }
    }

    func testFullyDevelopedCap() {
        // Valtava fetch ei kasvata aaltoa yli täysin kehittyneen merenkäynnin.
        let estimate = LakeWaves.estimate(windSpeed: 10, fetchMeters: 10_000_000)
        XCTAssertEqual(estimate.height, 0.21 * 100 / 9.81, accuracy: 0.01)
    }

    func testZeroInputs() {
        XCTAssertEqual(LakeWaves.estimate(windSpeed: 0, fetchMeters: 5000).height, 0)
        XCTAssertEqual(LakeWaves.estimate(windSpeed: 8, fetchMeters: 0).height, 0)
    }

    func testHourEstimateUsesDirectionalFetch() {
        // Fetch 10 km lännestä (oktantti 6), 0,1 km idästä.
        var fetch = [Double](repeating: 0.1, count: 8)
        fetch[6] = 10
        let west = WindHour(time: .now, speed: 10, gust: 13, direction: 270)
        let east = WindHour(time: .now, speed: 10, gust: 13, direction: 90)
        XCTAssertEqual(LakeWaves.estimate(for: west, fetchKmByOctant: fetch)?.height ?? 0, 0.51, accuracy: 0.01)
        XCTAssertNil(LakeWaves.estimate(for: east, fetchKmByOctant: fetch), "mitätön fetch → ei arviota")
        XCTAssertNil(LakeWaves.estimate(for: west, fetchKmByOctant: nil))
    }
}
