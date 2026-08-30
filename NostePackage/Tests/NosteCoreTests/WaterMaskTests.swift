import XCTest
@testable import NosteCore

final class WaterMaskTests: XCTestCase {

    /// Maski, jonka ruudukon oikea puolisko on vettä.
    private func rightHalfWaterMask() -> WaterMask {
        let calibration = OfflineMapCalibration.centered(
            latitude: 60.15, longitude: 24.95, zoom: 14, tileCount: 3
        )
        let factor = 4
        let grid = calibration.imageSize / factor // 192
        var cells = [Bool](repeating: false, count: grid * grid)
        for row in 0..<grid {
            for column in (grid / 2)..<grid {
                cells[row * grid + column] = true
            }
        }
        return WaterMask(calibration: calibration, factor: factor, waterCells: cells)
    }

    func testWaterAndLandLookup() {
        let mask = rightHalfWaterMask()
        // Keskipisteestä itään (oikealle) = vettä, länteen = maata.
        XCTAssertEqual(mask.isWater(latitude: 60.15, longitude: 24.96), true)
        XCTAssertEqual(mask.isWater(latitude: 60.15, longitude: 24.94), false)
    }

    func testOutsideCoverageIsNil() {
        let mask = rightHalfWaterMask()
        XCTAssertNil(mask.isWater(latitude: 61.5, longitude: 24.95))
        XCTAssertNil(mask.isWater(latitude: 60.15, longitude: 25.5))
    }

    func testRoundTripCodable() throws {
        let mask = rightHalfWaterMask()
        let data = try JSONEncoder().encode(mask)
        let decoded = try JSONDecoder().decode(WaterMask.self, from: data)
        XCTAssertEqual(decoded, mask)
        XCTAssertEqual(decoded.isWater(latitude: 60.15, longitude: 24.96), true)
    }

    func testIndexPrefersFinestZoomAndFallsThrough() {
        let coarse = rightHalfWaterMask() // z14
        // z15-maski, joka väittää samaa aluetta maaksi — tarkempi voittaa.
        let fineCalibration = OfflineMapCalibration.centered(
            latitude: 60.15, longitude: 24.95, zoom: 15, tileCount: 3
        )
        let fineGrid = fineCalibration.imageSize / 4
        let fine = WaterMask(
            calibration: fineCalibration, factor: 4,
            waterCells: [Bool](repeating: false, count: fineGrid * fineGrid)
        )
        let index = WaterMaskIndex(masks: [coarse, fine])
        // Piste molempien alueella: z15 (maa) vastaa.
        XCTAssertEqual(index.isWater(latitude: 60.15, longitude: 24.96), false)
        // Piste ~1,4 km etelään: vain z14 kattaa (z15 loppuu ~1,2 km) —
        // z14:n oikea puolisko on vettä.
        XCTAssertEqual(index.isWater(latitude: 60.1374, longitude: 24.96), true)
        // Kummankin ulkopuolella: nil.
        XCTAssertNil(index.isWater(latitude: 62.0, longitude: 24.95))
    }
}
