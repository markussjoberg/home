import XCTest
@testable import NosteCore

final class GearAdvisorTests: XCTestCase {

    private let catalog = [
        GearCatalogItem(id: "w30", type: .wing, name: "Testi Wing 3.0", size: 3.0, year: 2026, price: 899, url: "https://example.fi/w30"),
        GearCatalogItem(id: "w45", type: .wing, name: "Testi Wing 4.5", size: 4.5, year: 2026, price: 949, url: "https://example.fi/w45"),
        GearCatalogItem(id: "w60", type: .wing, name: "Testi Wing 6.0", size: 6.0, year: 2026, price: 999, url: "https://example.fi/w60"),
        GearCatalogItem(id: "f11", type: .foil, name: "Testi Foil 1100", size: 1100, year: 2026, price: 1290, url: "https://example.fi/f11"),
        GearCatalogItem(id: "b95", type: .board, name: "Testi Board 95l", size: 95, year: 2025, price: 1190, url: "https://example.fi/b95"),
    ]

    func testMissingSmallWingSuggested() {
        let quiver = [GearInfo(type: .wing, name: "Iso", size: 5.0, year: 2026)]
        let suggestions = GearAdvisor.suggestions(quiver: quiver, catalog: catalog, currentYear: 2026)
        // Pienin 5,0 > 3,6 → tavoite 3,5 → lähin katalogista on 3.0.
        XCTAssertEqual(suggestions.first?.item.id, "w30")
        XCTAssertTrue(suggestions.first!.reason.contains("Kovaan tuuleen"))
    }

    func testMissingBigWingSuggested() {
        let quiver = [GearInfo(type: .wing, name: "Pikku", size: 3.5, year: 2026)]
        let suggestions = GearAdvisor.suggestions(quiver: quiver, catalog: catalog, currentYear: 2026)
        XCTAssertTrue(suggestions.contains { $0.item.id == "w45" && $0.reason.contains("Kevyeen tuuleen") })
    }

    func testGapBetweenWingsSuggested() {
        let quiver = [
            GearInfo(type: .wing, name: "Pikku", size: 3.0, year: 2026),
            GearInfo(type: .wing, name: "Iso", size: 6.0, year: 2026),
        ]
        let suggestions = GearAdvisor.suggestions(quiver: quiver, catalog: catalog, currentYear: 2026)
        // 3,0 ja 6,0 → aukko → keskikohta 4,5.
        XCTAssertTrue(suggestions.contains { $0.item.id == "w45" && $0.reason.contains("Aukko") })
    }

    func testOldGearUpgradeSuggested() {
        // Kattava valikoima (ei kokoaukkoja) mutta yksi siipi on vanha.
        let quiver = [
            GearInfo(type: .wing, name: "Wanha Wing", size: 4.5, year: 2022),
            GearInfo(type: .wing, name: "Pikku", size: 3.5, year: 2026),
            GearInfo(type: .wing, name: "Iso", size: 5.5, year: 2026),
        ]
        let suggestions = GearAdvisor.suggestions(quiver: quiver, catalog: catalog, currentYear: 2026)
        XCTAssertTrue(suggestions.contains { $0.reason.contains("vuosimallia 2022") && $0.item.id == "w45" })
    }

    func testCompleteFreshQuiverGetsNothing() {
        let quiver = [
            GearInfo(type: .wing, name: "3.5", size: 3.5, year: 2026),
            GearInfo(type: .wing, name: "4.5", size: 4.5, year: 2025),
            GearInfo(type: .wing, name: "5.5", size: 5.5, year: 2026),
            GearInfo(type: .foil, name: "Foili", size: 1100, year: 2025),
        ]
        XCTAssertTrue(GearAdvisor.suggestions(quiver: quiver, catalog: catalog, currentYear: 2026).isEmpty)
    }

    func testEmptyQuiverGetsNothing() {
        XCTAssertTrue(GearAdvisor.suggestions(quiver: [], catalog: catalog, currentYear: 2026).isEmpty)
    }

    func testDeterministicAndCapped() {
        let quiver = [GearInfo(type: .wing, name: "Wanha ja pieni puuttuu", size: 5.5, year: 2021)]
        let a = GearAdvisor.suggestions(quiver: quiver, catalog: catalog, currentYear: 2026)
        let b = GearAdvisor.suggestions(quiver: quiver, catalog: catalog, currentYear: 2026)
        XCTAssertEqual(a, b, "sama syöte → sama tulos")
        XCTAssertLessThanOrEqual(a.count, 2)
        XCTAssertFalse(a.isEmpty)
    }
}

extension GearAdvisorTests {

    /// Bugikorjaus: pumppari ei saa wingfoil-siipiehdotuksia.
    func testPumpFoilerGetsNoWingSuggestions() {
        let catalog = [
            GearCatalogItem(id: "w30", type: .wing, name: "Wing 3.0", size: 3.0, year: 2026, price: 899, url: "u", sport: .wingFoil),
            GearCatalogItem(id: "pb", type: .board, name: "Pumppilauta 2026", size: 30, year: 2026, price: 990, url: "u", sport: .pumpFoil),
            GearCatalogItem(id: "wb", type: .board, name: "Wingilauta 2026", size: 95, year: 2026, price: 1290, url: "u", sport: .wingFoil),
        ]
        // Pumppari, jolla vanha pumppilauta: ehdotus on pumppilauta, EI wingiä.
        let quiver = [GearInfo(type: .board, name: "Wanha pumppilauta", size: 32, year: 2021, sport: .pumpFoil)]
        let suggestions = GearAdvisor.suggestions(
            quiver: quiver, catalog: catalog, currentYear: 2026, userSports: [.pumpFoil]
        )
        XCTAssertFalse(suggestions.contains { $0.item.type == .wing }, "pumppari ei tarvitse siipiä")
        XCTAssertEqual(suggestions.first?.item.id, "pb", "korvaaja samasta lajista")
    }

    /// Vanhalle wingilaudalle ei ehdoteta pumppilautaa vaikka se olisi uudempi.
    func testReplacementMatchesGearSport() {
        let catalog = [
            GearCatalogItem(id: "pb", type: .board, name: "Pumppilauta 2026", size: 30, year: 2026, price: 990, url: "u", sport: .pumpFoil),
            GearCatalogItem(id: "wb", type: .board, name: "Wingilauta 2025", size: 95, year: 2025, price: 1290, url: "u", sport: .wingFoil),
        ]
        let quiver = [GearInfo(type: .board, name: "Wanha wingilauta", size: 100, year: 2021, sport: .wingFoil)]
        let suggestions = GearAdvisor.suggestions(
            quiver: quiver, catalog: catalog, currentYear: 2026, userSports: [.wingFoil, .pumpFoil]
        )
        XCTAssertEqual(suggestions.first?.item.id, "wb", "saman lajin lauta, ei pumppilautaa")
    }
}
