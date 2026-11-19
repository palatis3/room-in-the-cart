import CoreDomain
import XCTest
@testable import RoomInTheCart

final class PantryVoiceBatchMatcherTests: XCTestCase {
    private func lot(_ name: String, location: InventoryLocation = .fridge) -> InventoryLot {
        let date = Date(timeIntervalSince1970: 1_000)
        return InventoryLot(id: UUID(), foodID: UUID(), name: name, source: .manual(originID: UUID(), sourceID: UUID()),
                            revision: 1, location: location, openedAt: nil, unit: .count, count: .someLeft,
                            observationID: UUID(), confirmedAt: date, updatedAt: date, useFirst: false)
    }

    func testShowsEachMatchingBatchWithoutSelectingAFirstOrExactNameAmongAlternatives() {
        let bread = lot("Bread"), rye = lot("Rye bread"), frozen = lot("Bread", location: .freezer)
        let lots = [bread, lot("Breadcrumbs"), rye, frozen]
        XCTAssertEqual(PantryVoiceBatchMatcher.suggestions(for: "bread", in: lots).map(\.id), [bread.id, rye.id, frozen.id])
        XCTAssertNil(PantryVoiceBatchMatcher.uniqueExact(for: "bread", in: lots))
        XCTAssertEqual(PantryVoiceBatchMatcher.uniqueExact(for: "  RYE bread ", in: lots)?.id, rye.id)
        XCTAssertNil(PantryVoiceBatchMatcher.uniqueExact(for: "  ", in: lots))
    }

    func testAutomaticSelectionPreservesPercentAndOtherPrintedSymbols() {
        let milk = lot("2% Milk")
        XCTAssertNil(PantryVoiceBatchMatcher.uniqueExact(for: "2 milk", in: [milk]))
        XCTAssertEqual(PantryVoiceBatchMatcher.suggestions(for: "2 milk", in: [milk]), [milk])
        XCTAssertEqual(PantryVoiceBatchMatcher.uniqueExact(for: "  2%   MILK ", in: [milk]), milk)
    }

    func testSpanishAndEnglishInflectionsSuggestButDoNotSilentlySelect() {
        let eggs = lot("Eggs"), cafe = lot("Café"), pan = lot("Pan integral")
        let lots = [lot("Eggplant"), eggs, cafe, pan]
        XCTAssertEqual(PantryVoiceBatchMatcher.suggestions(for: "egg", in: lots).map(\.id), [eggs.id])
        XCTAssertEqual(PantryVoiceBatchMatcher.suggestions(for: "panes", in: lots).map(\.id), [pan.id])
        XCTAssertEqual(PantryVoiceBatchMatcher.suggestions(for: "cafe", in: lots).map(\.id), [cafe.id])
        XCTAssertNil(PantryVoiceBatchMatcher.uniqueExact(for: "cafe", in: lots))
        XCTAssertNil(PantryVoiceBatchMatcher.uniqueExact(for: "my bottle", in: []))
    }
}
