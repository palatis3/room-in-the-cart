import XCTest
@testable import CoreDomain

final class CaptureImportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func q(_ count: Int64, _ unit: UnitOfMeasure = .count) throws -> Quantity {
        Quantity(amount: try Rational(count), unit: unit, originalLiteral: "\(count) \(unit.rawValue)")
    }

    func testPackEvidenceAndLabelsPersistTogetherWithoutCreatingAuthorityOrReservations() throws {
        var shop = ShoppingLedger()
        let before = shop, operation = UUID()
        let row = CaptureImportLine(originalText: "two paks wraaps for lunches, send to shopper, no sesame",
            name: "wraps", packCount: 2, amountPerPack: try q(8), purpose: "protected lunches",
            destination: "shopper", exclusions: ["sesame"])
        let preview = try shop.stageCaptureImport(id: operation, originalText: row.originalText, source: .voice, lines: [row])
        XCTAssertEqual(shop, before)
        XCTAssertEqual(preview.id, operation)
        XCTAssertEqual(preview.lines[0].quantity?.amount, try Rational(16))
        XCTAssertEqual(preview.lines[0].id, row.id)
        XCTAssertEqual(preview.lines[0].proposedLineID, row.proposedLineID)
        try shop.commitImport(preview, at: date)
        XCTAssertEqual(shop.revision, 1)
        XCTAssertEqual(shop.importBatches.count, 1)
        let source = try XCTUnwrap(shop.contributions.first)
        XCTAssertEqual(source.originalText, row.originalText)
        XCTAssertEqual(source.productName, "wraps")
        XCTAssertEqual(source.exclusions, ["sesame"])
        XCTAssertEqual(source.capture?.packCount, 2)
        XCTAssertEqual(source.capture?.amountPerPack, row.amountPerPack)
        XCTAssertEqual(source.capture?.purpose, "protected lunches")
        XCTAssertEqual(source.capture?.destination, "shopper")
        XCTAssertTrue(source.notes.contains("protected lunches"))
        XCTAssertTrue(source.notes.contains("shopper"))
        XCTAssertFalse(source.source.isProtected)
        XCTAssertFalse(source.source.isMeal)
        XCTAssertEqual(source.source, .imported(batchID: operation))
        XCTAssertTrue(shop.mealOccurrences.isEmpty)
        XCTAssertTrue(shop.allocations.isEmpty)
        let reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        XCTAssertEqual(reopened, shop)
        try reopened.validate()
    }

    func testPackMathIsExactAcrossFractionalAmountsAndEquivalentUnits() throws {
        let shop = ShoppingLedger()
        let halfCup = Quantity(amount: try Rational(1, 2), unit: .cup, originalLiteral: "half cup")
        let fraction = CaptureImportLine(originalText: "three half cups flour", name: "flour", packCount: 3, amountPerPack: halfCup)
        let total = Quantity(amount: try Rational(3, 4), unit: .kilogram, originalLiteral: "0.75 kg")
        let metric = CaptureImportLine(originalText: "two 375 g bags rice, total 0.75 kg", name: "rice",
            quantity: total, packCount: 2, amountPerPack: try q(375, .gram))
        let preview = try shop.stageCaptureImport(id: UUID(), originalText: "reviewed", source: .typed, lines: [fraction, metric])
        XCTAssertEqual(preview.lines[0].quantity?.amount, try Rational(3, 2))
        XCTAssertEqual(preview.lines[0].quantity?.unit, .cup)
        XCTAssertEqual(preview.lines[1].quantity, total)
    }

    func testMissingAndAmbiguousAmountsRemainUnknownWithEvidenceRetained() throws {
        var shop = ShoppingLedger()
        let rows = [
            CaptureImportLine(originalText: "two packs wraps", name: "wraps", packCount: 2),
            CaptureImportLine(originalText: "about two apples", name: "apples", quantity: try q(2), unresolvedFields: [.quantity]),
            CaptureImportLine(originalText: "milk", name: "milk")
        ]
        let preview = try shop.stageCaptureImport(id: UUID(), originalText: "reviewed", source: .voice, lines: rows)
        XCTAssertTrue(preview.lines.allSatisfy { $0.quantity == nil })
        XCTAssertEqual(preview.lines[0].capture?.unresolvedFields, [.amountPerPack])
        XCTAssertEqual(preview.lines[1].capture?.declaredQuantity?.amount, try Rational(2))
        XCTAssertEqual(preview.lines[2].capture?.unresolvedFields, [.quantity])
        try shop.commitImport(preview, at: date)
        XCTAssertTrue(shop.contributions.allSatisfy { $0.quantity == nil })
        XCTAssertEqual(shop.contributions[0].capture?.packCount, 2)
    }

    func testExplicitZeroRemainsZeroAndIsNotConfusedWithUnknown() throws {
        var shop = ShoppingLedger()
        let row = CaptureImportLine(originalText: "zero apples", name: "apples", quantity: try q(0))
        let preview = try shop.stageCaptureImport(id: UUID(), originalText: row.originalText, source: .typed, lines: [row])
        XCTAssertEqual(preview.lines[0].quantity?.amount, .zero)
        XCTAssertEqual(preview.lines[0].capture?.unresolvedFields, [])
        try shop.commitImport(preview, at: date)
        XCTAssertEqual(shop.contributions[0].quantity?.amount, .zero)
    }

    func testOverflowNegativePackCountAndContradictoryTotalsDoNotMutate() throws {
        let shop = ShoppingLedger(), before = ShoppingLedger()
        let overflow = CaptureImportLine(originalText: "large", name: "rice", packCount: Int.max, amountPerPack: try q(2))
        XCTAssertThrowsError(try shop.stageCaptureImport(id: UUID(), originalText: "large", source: .typed, lines: [overflow])) {
            XCTAssertEqual($0 as? DomainError, .overflow)
        }
        let negative = CaptureImportLine(originalText: "negative", name: "rice", packCount: -1, amountPerPack: try q(2))
        XCTAssertThrowsError(try shop.stageCaptureImport(id: UUID(), originalText: "negative", source: .typed, lines: [negative])) {
            XCTAssertEqual($0 as? CaptureImportError, .invalidField(.packCount))
        }
        for declared in [try q(3), try q(4, .gram)] {
            let conflict = CaptureImportLine(originalText: "conflicting", name: "rice", quantity: declared, packCount: 2, amountPerPack: try q(2))
            XCTAssertThrowsError(try shop.stageCaptureImport(id: UUID(), originalText: "conflicting", source: .typed, lines: [conflict])) {
                XCTAssertEqual($0 as? CaptureImportError, .conflictingQuantity)
            }
        }
        XCTAssertEqual(shop.revision, before.revision)
        XCTAssertTrue(shop.contributions.isEmpty)
        XCTAssertTrue(shop.importBatches.isEmpty)
    }

    func testNegationAndUnresolvedExclusionsBlockWholeBatchUnlessSkipped() throws {
        for field in [CaptureImportField.negation, .exclusions, .name] {
            var shop = ShoppingLedger()
            let before = shop
            let good = CaptureImportLine(originalText: "two apples", name: "apples", quantity: try q(2))
            let blocked = CaptureImportLine(originalText: "do not buy milk?", name: "milk", quantity: try q(1), unresolvedFields: [field])
            let preview = try shop.stageCaptureImport(id: UUID(), originalText: "reviewed", source: .voice, lines: [good, blocked])
            XCTAssertNil(preview.lines[1].quantity)
            XCTAssertThrowsError(try shop.commitImport(preview, at: date)) {
                XCTAssertEqual($0 as? CaptureImportError, .reviewRequired([field]))
            }
            XCTAssertEqual(shop, before)
            try shop.commitImport(preview, decisions: [blocked.id: .skip], at: date)
            XCTAssertEqual(shop.contributions.map(\.productName), ["apples"])
            XCTAssertEqual(shop.revision, 1)
        }
    }

    func testHardExclusionFailureRollsBackEarlierRowsAndMetadata() throws {
        var shop = ShoppingLedger()
        let before = shop
        let good = CaptureImportLine(originalText: "2 rice bags", name: "rice", packCount: 2,
            amountPerPack: try q(500, .gram), purpose: "dinner", destination: "current shop")
        let forbidden = CaptureImportLine(originalText: "peanut butter without peanut", name: "peanut butter",
            quantity: try q(1), exclusions: ["peanut"])
        let preview = try shop.stageCaptureImport(id: UUID(), originalText: "reviewed", source: .typed, lines: [good, forbidden])
        XCTAssertThrowsError(try shop.commitImport(preview, at: date))
        XCTAssertEqual(shop, before)
    }

    func testDuplicateImportUsesExclusionsAndKeepsCaptureEvidenceAtomically() throws {
        var shop = ShoppingLedger()
        let target = try shop.addManualLine(name: "flour", quantity: q(1, .kilogram), exclusions: ["peanut"], at: date)
        let row = CaptureImportLine(originalText: "one bag flour 1000 g", name: "flour", packCount: 1,
            amountPerPack: try q(1_000, .gram), purpose: "bread", destination: "pickup", exclusions: ["sesame"])
        let preview = try shop.stageCaptureImport(id: UUID(), originalText: row.originalText, source: .voice, lines: [row])
        XCTAssertEqual(preview.lines[0].duplicateLineIDs, [target])
        let before = shop
        XCTAssertThrowsError(try shop.commitImport(preview))
        XCTAssertEqual(shop, before)
        try shop.commitImport(preview, decisions: [row.id: .mergeDuplicate(target)], at: date)
        XCTAssertEqual(try shop.quantity(forLineID: target)?.amount, .one)
        XCTAssertEqual(shop.contributions.last?.exclusions, ["sesame"])
        XCTAssertEqual(shop.contributions.last?.capture?.destination, "pickup")
    }

    func testDurableExactReplayAndChangedMetadataConflict() throws {
        var shop = ShoppingLedger()
        let row = CaptureImportLine(originalText: "2 packs wraaps", name: "wraps", packCount: 2,
            amountPerPack: try q(8), purpose: "lunch", destination: "Tuesday pickup", exclusions: ["sesame"])
        let preview = try shop.stageCaptureImport(id: UUID(), originalText: row.originalText, source: .voice, lines: [row])
        let encodedPreview = try JSONEncoder().encode(preview)
        try shop.commitImport(preview, at: date)
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        let retry = try JSONDecoder().decode(StagedListImport.self, from: encodedPreview)
        let before = reopened
        XCTAssertEqual(try reopened.commitImport(retry, at: date.addingTimeInterval(99)), preview.id)
        XCTAssertEqual(reopened, before)
        var changed = retry
        changed.lines[0].capture?.destination = "another shop"
        XCTAssertThrowsError(try reopened.commitImport(changed)) { XCTAssertEqual($0 as? LedgerError, .invalid("importReplay")) }
        XCTAssertEqual(reopened, before)
        changed = retry; changed.lines[0].exclusions = []
        XCTAssertThrowsError(try reopened.commitImport(changed))
        XCTAssertEqual(reopened, before)
    }

    func testStaleReviewAndTamperedDerivedQuantityLeaveLedgerUnchanged() throws {
        var shop = ShoppingLedger()
        let row = CaptureImportLine(originalText: "2 packs eight wraps", name: "wraps", packCount: 2, amountPerPack: try q(8))
        var preview = try shop.stageCaptureImport(id: UUID(), originalText: row.originalText, source: .typed, lines: [row])
        let empty = shop
        preview.lines[0].quantity = try q(1)
        XCTAssertThrowsError(try shop.commitImport(preview)) { XCTAssertEqual($0 as? CaptureImportError, .conflictingQuantity) }
        XCTAssertEqual(shop, empty)
        preview = try shop.stageCaptureImport(id: UUID(), originalText: row.originalText, source: .typed, lines: [row])
        _ = try shop.addManualLine(name: "soap", quantity: q(1), at: date)
        let before = shop
        XCTAssertThrowsError(try shop.commitImport(preview)) { XCTAssertEqual($0 as? LedgerError, .stalePreview) }
        XCTAssertEqual(shop, before)
    }

    func testCancellationIsOnlyDiscardingPreviewAndChangesNothing() throws {
        let shop = ShoppingLedger(), before = shop
        let row = CaptureImportLine(originalText: "two apples", name: "apples", quantity: try q(2), destination: "another household")
        _ = try shop.stageCaptureImport(id: UUID(), originalText: row.originalText, source: .typed, lines: [row])
        XCTAssertEqual(shop, before)
        XCTAssertEqual(shop.basis, before.basis)
    }

    func testLegacyPreviewAndContributionDecodeWithEmptyCaptureDefaults() throws {
        var shop = ShoppingLedger()
        let preview = try shop.stageImport(text: "2 apples", source: .paste)
        try shop.commitImport(preview, at: date)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shop)) as? [String: Any])
        var batches = try XCTUnwrap(json["importBatches"] as? [[String: Any]])
        var oldPreview = try XCTUnwrap(batches[0]["preview"] as? [String: Any])
        var lines = try XCTUnwrap(oldPreview["lines"] as? [[String: Any]])
        lines[0].removeValue(forKey: "capture"); lines[0].removeValue(forKey: "exclusions")
        oldPreview["lines"] = lines; batches[0]["preview"] = oldPreview; json["importBatches"] = batches
        var sources = try XCTUnwrap(json["contributions"] as? [[String: Any]])
        sources[0].removeValue(forKey: "capture"); json["contributions"] = sources
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONSerialization.data(withJSONObject: json))
        try reopened.validate()
        XCTAssertNil(reopened.contributions[0].capture)
        XCTAssertNil(reopened.importBatches[0].preview.lines[0].capture)
        XCTAssertEqual(reopened.importBatches[0].preview.lines[0].exclusions, [])
        let before = reopened
        XCTAssertEqual(try reopened.commitImport(preview), preview.id)
        XCTAssertEqual(reopened, before)
    }

    func testInvalidAndFutureCaptureMetadataRejectedOnDecode() throws {
        let metadata = CaptureImportMetadata(packCount: 2, amountPerPack: try q(8))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        json["formatVersion"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureImportMetadata.self, from: JSONSerialization.data(withJSONObject: json))) {
            XCTAssertEqual($0 as? CaptureImportError, .unsupportedVersion(99))
        }
        json["formatVersion"] = 1; json["packCount"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureImportMetadata.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}
