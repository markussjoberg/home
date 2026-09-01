import XCTest
@testable import NosteCore

final class ISO8601Tests: XCTestCase {
    func testParsesWithAndWithoutFractionalSeconds() {
        // JS toISOString() kirjoittaa millisekunnit, FMI ei.
        let js = ISO8601.parse("2026-08-21T12:00:00.000Z")
        let plain = ISO8601.parse("2026-08-21T12:00:00Z")
        XCTAssertNotNil(js)
        XCTAssertEqual(js, plain)
        XCTAssertNil(ISO8601.parse("ei aika"))
    }
}
