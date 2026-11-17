import XCTest
@testable import CoreDomain

final class FoodKeeperReferenceTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) throws -> MealDay {
        try MealDay(year: y, month: m, day: d, timeZoneIdentifier: "America/New_York")
    }

    func testBilingualStableIDsAndSpecificStorageConditions() throws {
        let source = try FoodKeeperReference.bundled()
        XCTAssertEqual(source.version, 128)
        XCTAssertEqual(source.products.count, 654)
        for language in [FoodKeeperLanguage.english, .spanish] {
            XCTAssertEqual(source.search("pollo enlatado", language: language).map(\.id), [142])
            XCTAssertEqual(source.search("canned chicken", language: language).map(\.id), [142])
            XCTAssertTrue(source.search(" KEFIR ", language: language).contains { $0.id == 25 })
        }
        XCTAssertTrue(source.search("hard boiled eggs", language: .english).contains { $0.id == 23 })
        XCTAssertTrue(source.search("Dry lentils", language: .english).isEmpty)
        XCTAssertTrue(source.suggestedTerms(for: "Dry lentils").contains("lentils"))
        XCTAssertTrue(source.search("lentils", language: .english).contains { $0.id == 334 })
        let chicken = try XCTUnwrap(source.products.first { $0.id == 142 })
        XCTAssertEqual(chicken.rule(for: .refrigeratedOpened)?.guidance(.english), "3 - 4 Days")
        XCTAssertEqual(chicken.rule(for: .refrigeratedOpened)?.guidance(.spanish), "3 - 4 Días")
        XCTAssertNil(chicken.rule(for: .refrigeratedThawed))
        XCTAssertNil(chicken.rule(for: .refrigerated))
        XCTAssertEqual(chicken.rule(for: .pantryPurchased)?.unit, .years)
        let kefir = try XCTUnwrap(source.products.first { $0.id == 25 })
        XCTAssertEqual(kefir.rule(for: .refrigeratedPurchased)?.unit, .weeks)
        XCTAssertEqual(kefir.rule(for: .refrigeratedOpened)?.unit, .days)
        XCTAssertEqual(kefir.rule(for: .frozen)?.guidance(.spanish), "No Recomendado")
        XCTAssertTrue(Set(source.products.map(\.id)).isDisjoint(with: [221, 645, 264, 496]))
    }

    func testSavedQualityRangeRetainsProvenanceAndRejectsUnsupportedOrChangedEvidence() throws {
        let reference = try FoodKeeperReference.bundled()
        let opened = try date(2026, 10, 30)
        let today = try date(2026, 11, 1)
        let range = try XCTUnwrap(reference.reviewedRange(productID: 142, condition: .refrigeratedOpened,
            storage: .refrigerator, event: .opened, start: opened, asOf: today, historyConfirmed: true))
        let restored = try JSONDecoder().decode(FoodKeeperReviewedRange.self, from: JSONEncoder().encode(range))
        XCTAssertEqual(restored, range)
        XCTAssertEqual(restored.version, 128)
        XCTAssertEqual(restored.earliest, try date(2026, 11, 2))
        XCTAssertEqual(restored.latest, try date(2026, 11, 3))
        XCTAssertTrue(restored.matches(reference, asOf: today))
        let stale = FoodKeeperReviewedRange(version: 127, productID: 142, storage: .refrigerator,
            condition: .refrigeratedOpened, event: .opened, start: opened, earliest: restored.earliest, latest: restored.latest)
        XCTAssertFalse(stale.matches(reference, asOf: today))
        for (product, condition, event) in [(179, FoodKeeperCondition.refrigeratedOpened, FoodKeeperStartingEvent.opened),
                                            (142, .refrigeratedThawed, .thawed), (9999, .refrigeratedOpened, .opened)] {
            XCTAssertNil(reference.reviewedRange(productID: product, condition: condition, storage: .refrigerator,
                event: event, start: opened, asOf: today, historyConfirmed: true))
        }
    }

    func testDatedReviewRequiresConfirmedHistoryLocationEventAndLocalDay() throws {
        let source = try FoodKeeperReference.bundled()
        let chicken = try XCTUnwrap(source.products.first { $0.id == 142 })
        let opened = try date(2026, 10, 30), today = try date(2026, 10, 31)
        let window = try XCTUnwrap(chicken.window(for: .refrigeratedOpened, storage: .refrigerator, event: .opened,
                                                  start: opened, asOf: today, historyConfirmed: true))
        XCTAssertEqual(window.earliest, try date(2026, 11, 2))
        XCTAssertEqual(window.latest, try date(2026, 11, 3))
        XCTAssertNil(chicken.window(for: .refrigeratedOpened, storage: .refrigerator, event: .purchased, start: opened, asOf: today, historyConfirmed: true))
        XCTAssertNil(chicken.window(for: .refrigeratedOpened, storage: .freezer, event: .opened, start: opened, asOf: today, historyConfirmed: true))
        XCTAssertNil(chicken.window(for: .refrigeratedOpened, storage: .refrigerator, event: .opened, start: opened, asOf: today, historyConfirmed: false))
        XCTAssertNil(chicken.window(for: .refrigeratedOpened, storage: .refrigerator, event: .opened, start: today, asOf: opened, historyConfirmed: true))
        let invalid = try JSONDecoder().decode(MealDay.self, from: Data(#"{"year":2026,"month":9,"day":31,"timeZoneIdentifier":"America/New_York"}"#.utf8))
        XCTAssertNil(chicken.window(for: .refrigeratedOpened, storage: .refrigerator, event: .opened, start: invalid, asOf: today, historyConfirmed: true))
        let fruit = try XCTUnwrap(source.products.first { $0.id == 179 })
        XCTAssertEqual(fruit.rule(for: .refrigerated)?.guidance(.english), "Package use-by date")
        XCTAssertEqual(fruit.rule(for: .refrigeratedOpened)?.guidance(.spanish), "4 Días")
        XCTAssertFalse(fruit.supportsDateWindow(for: .refrigeratedOpened))
        let eggs = try XCTUnwrap(source.products.first { $0.id == 17 })
        XCTAssertEqual(eggs.rule(for: .refrigeratedPurchased)?.minimum, 7)
        XCTAssertEqual(eggs.rule(for: .refrigeratedOpened)?.maximum, 3)
        XCTAssertFalse(eggs.supportsDateWindow(for: .frozen))
    }
}
