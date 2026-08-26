import XCTest
@testable import NosteCore

final class SpotWindProfileTests: XCTestCase {

    /// Melkki-esimerkki: SW toimii kun puhaltaa, heikko SW floppaa, itä ei toimi.
    private var profile: SpotWindProfile {
        SpotWindProfile(sessions: [
            .init(rating: .five, wind: RatedWind(speed: 9, gust: 12, direction: 225)),
            .init(rating: .four, wind: RatedWind(speed: 11, gust: 15, direction: 225)),
            .init(rating: .four, wind: RatedWind(speed: 8, gust: 11, direction: 230)),
            .init(rating: .one, wind: RatedWind(speed: 5, gust: 7, direction: 225)),
            .init(rating: .insufficient, wind: RatedWind(speed: 4, gust: 6, direction: 225)),
            .init(rating: .four, wind: RatedWind(speed: 10, gust: 13, direction: 270)),
            .init(rating: .one, wind: RatedWind(speed: 10, gust: 13, direction: 90))
        ])
    }

    func testPredictionsMatchReference() {
        XCTAssertEqual(profile.predictedRating(speed: 10, direction: 225) ?? -1, 4.09, accuracy: 0.05)
        XCTAssertEqual(profile.predictedRating(speed: 4.5, direction: 225) ?? -1, 1.45, accuracy: 0.05)
        XCTAssertEqual(profile.predictedRating(speed: 10, direction: 90) ?? -1, 1.03, accuracy: 0.05)
        XCTAssertEqual(profile.predictedRating(speed: 12, direction: 250) ?? -1, 4.16, accuracy: 0.05)
    }

    func testNoPredictionWithoutNearbyEvidence() {
        XCTAssertNil(profile.predictedRating(speed: 10, direction: 0), "pohjoistuulesta ei ole dataa")
    }

    func testNoPredictionBeforeEnoughSessions() {
        let sparse = SpotWindProfile(sessions: [
            .init(rating: .five, wind: RatedWind(speed: 9, gust: 12, direction: 225)),
            .init(rating: .four, wind: RatedWind(speed: 10, gust: 13, direction: 225))
        ])
        XCTAssertFalse(sparse.isReady)
        XCTAssertNil(sparse.predictedRating(speed: 9, direction: 225))
    }

    func testDirectionSummariesExcludeInsufficient() {
        let summaries = profile.directionSummaries()
        let southwest = summaries.first { $0.octant == 5 }
        XCTAssertEqual(southwest?.count, 4, "riittämätön tuuli ei kerro suunnasta")
        XCTAssertEqual(southwest?.averageRating ?? 0, 3.5, accuracy: 0.01)
        XCTAssertEqual(profile.goodOctants, [5], "W:stä vasta yksi sessio, E ei toimi")
    }

    func testAngularDifferenceWrapsNorth() {
        XCTAssertEqual(SpotWindProfile.angularDifference(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(SpotWindProfile.angularDifference(90, 270), 180, accuracy: 0.001)
    }

    func testRatedWindAverageWrapsNorth() {
        let hours = [
            WindHour(time: Date(timeIntervalSince1970: 0), speed: 8, gust: 11, direction: 350),
            WindHour(time: Date(timeIntervalSince1970: 3600), speed: 10, gust: 13, direction: 10)
        ]
        let average = RatedWind.average(of: hours)
        XCTAssertEqual(average?.speed ?? 0, 9, accuracy: 0.001)
        let direction = average?.direction ?? -1
        XCTAssertTrue(direction < 1 || direction > 359, "suunta oli \(direction) — pitäisi olla ~0°")
    }
}
