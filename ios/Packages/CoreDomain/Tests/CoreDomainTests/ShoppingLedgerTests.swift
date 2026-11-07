import XCTest
@testable import CoreDomain

final class ShoppingLedgerTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_793_664_000)
    private func q(_ amount: Int64, _ denominator: Int64 = 1, unit: UnitOfMeasure = .count) throws -> Quantity {
        Quantity(amount: try Rational(amount, denominator), unit: unit, originalLiteral: "\(amount)/\(denominator) \(unit.rawValue)")
    }
    private func source(_ ledger: ShoppingLedger, lineID: UUID) throws -> UUID {
        try XCTUnwrap(ledger.contributions(forLineID: lineID).first?.id)
    }
    private func taco(_ amount: Int64 = 6) throws -> MealTemplate {
        MealTemplate(title: "Tacos", servings: try Rational(3), ingredients: [MealIngredient(name: "wraps", quantity: try q(amount))])
    }
    private func mealSource(_ ledger: ShoppingLedger, occurrenceID: UUID) throws -> UUID {
        try XCTUnwrap(ledger.mealOccurrences.first { $0.id == occurrenceID }?.ingredientContributionIDs.first)
    }
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
    private func tampered(_ ledger: ShoppingLedger, _ change: (inout [String: Any]) -> Void) throws -> ShoppingLedger {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        change(&json)
        return try JSONDecoder().decode(ShoppingLedger.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testRefreshImportMatchesUsesEditedNamesWithoutChangingEvidenceOrIDs() throws {
        var ledger = ShoppingLedger()
        let existing = try ledger.addManualLine(name: "wraps", quantity: q(12))
        let trashed = try ledger.addManualLine(name: "WRAPS", quantity: q(12))
        try ledger.trash(lineID: trashed)
        var preview = ledger.stageImport(text: "12 rice\n6 pasta\n2 bread", source: .paste)
        preview.lines[0].name = "Wraps"
        preview.lines[1].name = " wRAPS "
        preview.lines[2].name = "rice"
        let original = preview
        let before = ledger
        let refreshed = try ledger.refreshImportMatches(preview)
        XCTAssertEqual(refreshed.lines[0].duplicateLineIDs, [existing])
        XCTAssertEqual(refreshed.lines[1].duplicateLineIDs, [existing, preview.lines[0].proposedLineID])
        XCTAssertTrue(refreshed.lines[2].duplicateLineIDs.isEmpty)
        var restoredHints = refreshed
        for index in restoredHints.lines.indices { restoredHints.lines[index].duplicateLineIDs = original.lines[index].duplicateLineIDs }
        XCTAssertEqual(restoredHints, original)
        XCTAssertEqual(ledger, before)
        XCTAssertThrowsError(try ShoppingLedger().refreshImportMatches(preview))
        _ = try ledger.addManualLine(name: "soap", quantity: q(1))
        XCTAssertThrowsError(try ledger.refreshImportMatches(preview))
        var invalid = ledger.stageImport(text: "1 soap")
        invalid.lines[0].name = " "
        XCTAssertThrowsError(try ledger.refreshImportMatches(invalid))
    }

    func testStagingPreservesOriginalAndUnknownsWithoutMutation() throws {
        let ledger = ShoppingLedger()
        let text = "  12 wraps  \n• 1/2 cup flour\nMilk\n2 scoops rice\n- 2 kg potatoes\n1 fl oz vanilla"
        let preview = ledger.stageImport(text: text, source: .paste)
        XCTAssertEqual(preview.originalText, text)
        XCTAssertEqual(preview.lines.map(\.originalText), text.components(separatedBy: .newlines))
        XCTAssertEqual(preview.lines[0].quantity?.amount, try Rational(12))
        XCTAssertEqual(preview.lines[1].quantity?.amount, try Rational(1, 2))
        XCTAssertEqual(preview.lines[1].quantity?.unit, .cup)
        XCTAssertNil(preview.lines[2].quantity)
        XCTAssertNotNil(preview.lines[2].unresolvedReason)
        XCTAssertNil(preview.lines[3].quantity)
        XCTAssertEqual(preview.lines[4].quantity?.unit, .kilogram)
        XCTAssertEqual(preview.lines[5].quantity?.unit, .fluidOunce)
        XCTAssertTrue(ledger.lines.isEmpty)
        XCTAssertEqual(ledger.revision, 0)
    }

    func testBilingualMeasuresMatchFoodWithoutChangingOriginalEvidence() throws {
        var ledger = ShoppingLedger()
        let first = ledger.stageImport(text: "1 1/2 cups of arroz\n2 onzas de queso\n2 onzas líquidas de caldo sin sal\n1 kg De Cecco")
        XCTAssertEqual(first.lines.map(\.name), ["arroz", "queso", "caldo sin sal", "De Cecco"])
        XCTAssertEqual(first.lines.map { $0.quantity?.unit }, [.cup, .ounce, .fluidOunce, .kilogram])
        XCTAssertEqual(first.lines[0].quantity?.amount, try Rational(3, 2))
        try ledger.commitImport(first)
        let repeatPaste = ledger.stageImport(text: "1½ tazas de arroz", source: .paste)
        let item = repeatPaste.lines[0]
        XCTAssertEqual(item.duplicateLineIDs, [first.lines[0].proposedLineID])
        let batch = try ledger.commitImport(repeatPaste, decisions: [item.id: .mergeDuplicate(first.lines[0].proposedLineID)])
        ledger = try roundTrip(ledger)
        XCTAssertEqual(try ledger.quantity(forLineID: first.lines[0].proposedLineID)?.amount, try Rational(3, 2))
        XCTAssertEqual(ledger.contributions.last?.originalText, "1½ tazas de arroz")
        try ledger.undoImport(batchID: batch)
        XCTAssertEqual(ledger.contributions(forLineID: first.lines[0].proposedLineID).map(\.originalText), ["1 1/2 cups of arroz"])
    }

    func testUnsupportedMeasuresAndMalformedMixedAmountsStayUnresolved() {
        let shop = ShoppingLedger()
        for text in ["2 cucharadas de arroz", "2 cucharaditas de sal", "3 manojos de cilantro",
                     "1 1/0 cups rice", "9223372036854775807 1/2 cups rice"] {
            let row = shop.stageImport(text: text).lines[0]
            XCTAssertNil(row.quantity, text)
            XCTAssertNotNil(row.unresolvedReason, text)
            XCTAssertEqual(row.originalText, text)
        }
    }

    func testPackLabelsKeepTheirExactContentsAndOriginalWordingAcrossImport() throws {
        var shop = ShoppingLedger()
        let text = "2 × 15 oz pinto beans\n2 cajas de 6 paquetes de 8 tortillas\n2 packs of 6 packs of wraps"
        let preview = shop.stageImport(text: text, source: .paste)
        XCTAssertEqual(preview.lines.map(\.name), ["pinto beans", "tortillas", "wraps"])
        XCTAssertEqual(preview.lines.map { $0.quantity?.amount }, [try Rational(30), try Rational(96), nil])
        XCTAssertEqual(preview.lines.map { $0.quantity?.unit }, [.ounce, .count, nil])
        XCTAssertNotNil(preview.lines[2].unresolvedReason)
        XCTAssertEqual(preview.lines.map { $0.originalPack?.count }, [2, 2, 2])
        XCTAssertEqual(preview.lines[0].originalPack?.amountPerPack?.amount, try Rational(15))
        for wording in ["2x15 oz pinto beans", "2x15oz pinto beans", "2 packs × 15oz pinto beans",
                        "2 15-ounce cans of pinto beans", "2 15 oz cans of pinto beans", "2 cans of pinto beans, 15 oz each",
                        "2 latas de pinto beans (15 onzas cada una)"] {
            let item = shop.stageImport(text: wording).lines[0]
            XCTAssertEqual(item.name, "pinto beans", wording)
            XCTAssertEqual(item.quantity?.amount, try Rational(30), wording)
            XCTAssertEqual(item.quantity?.unit, .ounce, wording)
            XCTAssertEqual(item.originalPack?.count, 2, wording)
            XCTAssertEqual(item.originalText, wording)
        }
        XCTAssertEqual(shop.stageImport(text: "250g Product X15").lines[0].name, "Product X15")
        XCTAssertNil(shop.stageImport(text: "7UP").lines[0].quantity)
        let mixed = shop.stageImport(text: "1 1/2kg rice").lines[0]
        XCTAssertEqual(mixed.name, "rice")
        XCTAssertEqual(mixed.quantity?.amount, try Rational(3, 2))
        XCTAssertEqual(mixed.quantity?.unit, .kilogram)
        let ambiguous = shop.stageImport(text: "2 boxes of 3 packs of beans, 15 oz each").lines[0]
        XCTAssertNil(ambiguous.quantity)
        let batch = try shop.commitImport(preview)
        shop = try roundTrip(shop)
        XCTAssertEqual(shop.importBatches.first?.originalText, text)
        XCTAssertEqual(shop.contributions.map(\.originalPack), preview.lines.map(\.originalPack))
        XCTAssertEqual(shop.contributions.map(\.originalText), text.components(separatedBy: .newlines))
        try shop.undoImport(batchID: batch)
        XCTAssertTrue(shop.search("").isEmpty)
    }

    func testDuplicatePasteNeedsExplicitDecisionAndRetryIsIdempotent() throws {
        var ledger = ShoppingLedger()
        let first = ledger.stageImport(text: "12 wraps", source: .paste)
        let firstBatch = try ledger.commitImport(first, at: instant)
        let lineID = try XCTUnwrap(ledger.lines.first?.id)
        let second = ledger.stageImport(text: "12 wraps", source: .paste)
        XCTAssertEqual(second.lines[0].duplicateLineIDs, [lineID])
        let unchanged = ledger
        XCTAssertThrowsError(try ledger.commitImport(second)) { error in
            XCTAssertEqual(error as? LedgerError, .duplicateDecisionRequired(second.lines[0].id))
        }
        XCTAssertEqual(ledger, unchanged)
        let decisions: [UUID: ImportResolution] = [second.lines[0].id: .mergeDuplicate(lineID)]
        let secondBatch = try ledger.commitImport(second, decisions: decisions, at: instant)
        XCTAssertNotEqual(firstBatch, secondBatch)
        XCTAssertEqual(ledger.contributions(forLineID: lineID).count, 2)
        XCTAssertEqual(try ledger.quantity(forLineID: lineID)?.amount, try Rational(12))
        let committed = ledger
        XCTAssertEqual(try ledger.commitImport(second, decisions: decisions), secondBatch)
        XCTAssertEqual(ledger, committed)
        XCTAssertThrowsError(try ledger.commitImport(second, decisions: [second.lines[0].id: .addNew]))
        try ledger.undoImport(batchID: secondBatch)
        XCTAssertEqual(try ledger.quantity(forLineID: lineID)?.amount, try Rational(12))
        XCTAssertThrowsError(try ledger.commitImport(second, decisions: decisions))
    }

    func testExplicitAdditionalPasteAddsQuantityAndUndoIsIsolated() throws {
        var ledger = ShoppingLedger()
        let staple = try ledger.addManualLine(name: "wraps", quantity: q(12), at: instant)
        let preview = ledger.stageImport(text: "12 wraps\n4 apples", source: .paste)
        let batch = try ledger.commitImport(preview, decisions: [preview.lines[0].id: .addToLine(staple)], at: instant)
        XCTAssertEqual(try ledger.quantity(forLineID: staple)?.amount, try Rational(24))
        let unrelated = try ledger.addManualLine(name: "soap", quantity: q(1), at: instant)
        try ledger.undoImport(batchID: batch, at: instant)
        XCTAssertEqual(try ledger.quantity(forLineID: staple)?.amount, try Rational(12))
        XCTAssertEqual(ledger.search("").map(\.id), [staple, unrelated])
        XCTAssertEqual(ledger.trash.map(\.name), ["apples"])
        let undone = ledger
        try ledger.undoImport(batchID: batch)
        XCTAssertEqual(ledger, undone)
    }

    func testAdditionalImportNeedsAnOpenLineAndPreservesCompletedEvidence() throws {
        for checked in [true, false] {
            var ledger = ShoppingLedger()
            let line = try ledger.addManualLine(name: "wraps", quantity: q(12))
            if checked { try ledger.setChecked(lineID: line, checked: true, at: instant) }
            else { try ledger.handle(lineID: line, by: "Mia", at: instant) }
            let preview = ledger.stageImport(text: "1 pear\n12 wraps", source: .paste)
            let entry = preview.lines[1]
            let before = ledger
            XCTAssertThrowsError(try ledger.commitImport(preview, decisions: [entry.id: .addToLine(line)])) {
                XCTAssertEqual($0 as? LedgerError, .incompatibleMatch)
            }
            XCTAssertEqual(ledger, before)

            let merge = [entry.id: ImportResolution.mergeDuplicate(line)]
            let batch = try ledger.commitImport(preview, decisions: merge)
            ledger = try roundTrip(ledger)
            XCTAssertEqual(try ledger.commitImport(preview, decisions: merge), batch)
            XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(12))
            XCTAssertEqual(ledger.lines.first, before.lines.first)
            try ledger.undoImport(batchID: batch)
            XCTAssertEqual(ledger.lines.first, before.lines.first)
            let fresh = ledger.stageImport(text: "12 wraps")
            try ledger.commitImport(fresh, decisions: [fresh.lines[0].id: .addNew])
            let newLine = try XCTUnwrap(ledger.lines.last)
            XCTAssertFalse(newLine.isChecked)
            XCTAssertFalse(newLine.isHandled)
            XCTAssertNotEqual(newLine.id, line)
            XCTAssertEqual(ledger.lines.first, before.lines.first)
        }
    }

    func testImportOptionsTrackOriginalSuppliesAndEarlierDecisions() throws {
        var ledger = ShoppingLedger()
        let target = try ledger.addManualLine(name: "flour", quantity: q(1, unit: .kilogram))
        let preview = ledger.stageImport(text: "500 g flour\n500 g flour\n1 kg flour\n1 cup flour\nflour")
        let rows = preview.lines
        let decisions: [UUID: ImportResolution] = [rows[0].id: .addToLine(target)]
        let choices = ledger.importMatchOptions(for: preview, decisions: decisions)
        let both = ImportMatchOption(lineID: target, canMerge: true, canAdd: true)
        let add = ImportMatchOption(lineID: target, canMerge: false, canAdd: true)
        let neither = ImportMatchOption(lineID: target, canMerge: false, canAdd: false)
        XCTAssertEqual(choices[rows[0].id], [add])
        XCTAssertEqual(choices[rows[1].id], [both])
        XCTAssertEqual(choices[rows[2].id], [both])
        XCTAssertEqual(choices[rows[3].id], [neither])
        XCTAssertEqual(choices[rows[4].id], [neither])
        XCTAssertEqual(ledger.importMatchOptions(for: preview, decisions: [rows[0].id: .skip])[rows[1].id], [add])
        let earlier = rows[0].proposedLineID
        XCTAssertEqual(ledger.importMatchOptions(for: preview, decisions: [rows[0].id: .addNew])[rows[1].id],
                       [add, ImportMatchOption(lineID: earlier, canMerge: true, canAdd: true)])
        var edited = preview
        edited.lines[0].exclusions = ["flour"]
        let editedOptions = ledger.importMatchOptions(for: edited, decisions: decisions)
        XCTAssertEqual(editedOptions[rows[0].id], [neither])
        XCTAssertEqual(editedOptions[rows[1].id], [add])
        try ledger.setChecked(lineID: target, checked: true)
        XCTAssertTrue(ledger.importMatchOptions(for: preview, decisions: decisions).isEmpty)
        let fresh = ledger.stageImport(text: "1000 g flour")
        XCTAssertEqual(ledger.importMatchOptions(for: fresh, decisions: [:])[fresh.lines[0].id],
                       [ImportMatchOption(lineID: target, canMerge: true, canAdd: false)])
    }

    func testCommittedAdditionalImportCanReplayAfterLineHandled() throws {
        var ledger = ShoppingLedger()
        let line = try ledger.addManualLine(name: "wraps", quantity: q(12))
        let preview = ledger.stageImport(text: "3 wraps")
        let decisions = [preview.lines[0].id: ImportResolution.addToLine(line)]
        let batch = try ledger.commitImport(preview, decisions: decisions)
        try ledger.handle(lineID: line, by: "Mia")
        ledger = try roundTrip(ledger)
        let saved = ledger
        XCTAssertEqual(try ledger.commitImport(preview, decisions: decisions), batch)
        XCTAssertEqual(ledger, saved)
    }

    func testTwoDuplicatesInSamePreviewRequireChoiceAndCanMergeOrAdd() throws {
        var ledger = ShoppingLedger()
        let preview = ledger.stageImport(text: "12 wraps\n12 wraps")
        XCTAssertEqual(preview.lines[1].duplicateLineIDs, [preview.lines[0].proposedLineID])
        XCTAssertThrowsError(try ledger.commitImport(preview))
        XCTAssertEqual(ledger.revision, 0)
        try ledger.commitImport(preview, decisions: [preview.lines[1].id: .mergeDuplicate(preview.lines[0].proposedLineID)])
        XCTAssertEqual(ledger.search("").count, 1)
        XCTAssertEqual(ledger.contributions.count, 2)
        XCTAssertEqual(try ledger.quantity(forLineID: preview.lines[0].proposedLineID)?.amount, try Rational(12))
        var additional = ShoppingLedger()
        let again = additional.stageImport(text: "12 wraps\n12 wraps")
        try additional.commitImport(again, decisions: [again.lines[1].id: .addNew])
        XCTAssertEqual(additional.search("").count, 2)
    }

    func testStalePreviewRejectedEvenWhenCallerErasesDuplicateHints() throws {
        var ledger = ShoppingLedger()
        var preview = ledger.stageImport(text: "12 wraps")
        _ = try ledger.addManualLine(name: "soap", quantity: q(1))
        let unchanged = ledger
        XCTAssertThrowsError(try ledger.commitImport(preview)) { XCTAssertEqual($0 as? LedgerError, .stalePreview) }
        XCTAssertEqual(ledger, unchanged)
        preview = ledger.stageImport(text: "12 wraps\n12 wraps")
        preview.lines[1].duplicateLineIDs = []
        XCTAssertThrowsError(try ledger.commitImport(preview))
        XCTAssertEqual(ledger, unchanged)
    }

    func testTacosLunchAndManualStapleConserveSourcesAcrossRemoval() throws {
        var ledger = ShoppingLedger()
        let staple = try ledger.addManualLine(name: "wraps", quantity: q(12), at: instant)
        let manual = try source(ledger, lineID: staple)
        let occurrence = try ledger.chooseMeal(taco(), at: instant)
        let demand = try mealSource(ledger, occurrenceID: occurrence)
        XCTAssertEqual(try ledger.quantity(forLineID: staple)?.amount, try Rational(12))
        let mealLine = try XCTUnwrap(ledger.contributions.first { $0.id == demand }?.lineID)
        XCTAssertEqual(try ledger.quantity(forLineID: mealLine)?.amount, try Rational(6))
        try ledger.linkContribution(contributionID: demand, within: manual, quantity: q(6), at: instant)
        let lunch = try ledger.addProtectedNeed(name: "wraps", quantity: q(2), purpose: "Lunch", within: manual, at: instant)
        XCTAssertEqual(try ledger.quantity(forLineID: staple)?.amount, try Rational(12))
        XCTAssertEqual(Set(try ledger.trashImpact(lineID: staple).map(\.id)), [demand, lunch])
        try ledger.setMealHidden(occurrenceID: occurrence, hidden: true)
        XCTAssertEqual(try ledger.quantity(forLineID: staple)?.amount, try Rational(12))
        try ledger.removeMeal(occurrenceID: occurrence, at: instant)
        XCTAssertEqual(try ledger.quantity(forLineID: staple)?.amount, try Rational(12))
        XCTAssertEqual(Set(ledger.contributions(forLineID: staple).map(\.id)), [manual, lunch])
        XCTAssertEqual(ledger.allocations.count, 1)
        XCTAssertEqual(ledger.allocations[0].demandContributionID, lunch)
        try ledger.validate()
    }

    func testPartialLinkRetainsResidualAndSiblingReservationsCannotOverallocate() throws {
        var ledger = ShoppingLedger()
        let line = try ledger.addManualLine(name: "wraps", quantity: q(12))
        let manual = try source(ledger, lineID: line)
        let occurrence = try ledger.chooseMeal(taco())
        let demand = try mealSource(ledger, occurrenceID: occurrence)
        try ledger.linkContribution(contributionID: demand, within: manual, quantity: q(3))
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(15))
        try ledger.linkContribution(contributionID: demand, within: manual, quantity: q(6))
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(12))
        _ = try ledger.addProtectedNeed(name: "wraps", quantity: q(6), purpose: "Lunches", within: manual)
        let unchanged = ledger
        XCTAssertThrowsError(try ledger.addProtectedNeed(name: "wraps", quantity: q(1), purpose: "Extra lunch", within: manual))
        XCTAssertEqual(ledger, unchanged)
        XCTAssertThrowsError(try ledger.linkContribution(contributionID: demand, within: manual, quantity: q(7)))
        XCTAssertEqual(ledger, unchanged)
        try ledger.unlinkContribution(contributionID: demand)
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(18))
    }

    func testUndoOriginalImportRetainsLinkedMealAndLunchAsDemands() throws {
        var ledger = ShoppingLedger()
        let preview = ledger.stageImport(text: "12 wraps")
        let batch = try ledger.commitImport(preview)
        let line = try XCTUnwrap(ledger.lines.first?.id)
        let imported = try source(ledger, lineID: line)
        let occurrence = try ledger.chooseMeal(taco())
        let demand = try mealSource(ledger, occurrenceID: occurrence)
        try ledger.linkContribution(contributionID: demand, within: imported, quantity: q(6))
        let lunch = try ledger.addProtectedNeed(name: "wraps", quantity: q(2), purpose: "Lunch", within: imported)
        try ledger.undoImport(batchID: batch)
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(8))
        XCTAssertEqual(Set(ledger.contributions(forLineID: line).map(\.id)), [demand, lunch])
        XCTAssertTrue(ledger.allocations.isEmpty)
        XCTAssertFalse(ledger.lines.first { $0.id == line }!.isTrashed)
        try ledger.validate()
    }

    func testDuplicateAliasCannotDoubleReservationCapacityAndUndoRehomesSurvivors() throws {
        var ledger = ShoppingLedger()
        let first = ledger.stageImport(text: "12 wraps")
        let originalBatch = try ledger.commitImport(first)
        let line = try XCTUnwrap(ledger.lines.first?.id)
        let original = try source(ledger, lineID: line)
        let second = ledger.stageImport(text: "12 wraps")
        try ledger.commitImport(second, decisions: [second.lines[0].id: .mergeDuplicate(line)])
        let alias = second.lines[0].id
        let occurrence = try ledger.chooseMeal(taco(8))
        let demand = try mealSource(ledger, occurrenceID: occurrence)
        try ledger.linkContribution(contributionID: demand, within: original, quantity: q(8))
        let unchanged = ledger
        XCTAssertThrowsError(try ledger.addProtectedNeed(name: "wraps", quantity: q(5), purpose: "Lunch", within: alias))
        XCTAssertEqual(ledger, unchanged)
        let lunch = try ledger.addProtectedNeed(name: "wraps", quantity: q(4), purpose: "Lunch", within: alias)
        try ledger.undoImport(batchID: originalBatch)
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(12))
        XCTAssertEqual(Set(ledger.allocations.map(\.supplyContributionID)), [alias])
        XCTAssertEqual(Set(ledger.allocations.map(\.demandContributionID)), [demand, lunch])
        try ledger.validate()
    }

    func testRemovingMiddleDuplicatePreservesEquivalence() throws {
        var ledger = ShoppingLedger()
        let manualLine = try ledger.addManualLine(name: "wraps", quantity: q(12))
        let manual = try source(ledger, lineID: manualLine)
        for _ in 0..<3 {
            let preview = ledger.stageImport(text: "12 wraps")
            try ledger.commitImport(preview, decisions: [preview.lines[0].id: .mergeDuplicate(manualLine)])
        }
        XCTAssertEqual(ledger.contributions(forLineID: manualLine).count, 4)
        try ledger.removeContribution(contributionID: manual)
        XCTAssertEqual(ledger.contributions(forLineID: manualLine).count, 3)
        XCTAssertEqual(try ledger.quantity(forLineID: manualLine)?.amount, try Rational(12))
        try ledger.validate()
    }

    func testCheckedHandledTrashRestoreAreIndependentAndDurableByID() throws {
        var ledger = ShoppingLedger()
        let first = try ledger.addManualLine(name: "milk", quantity: q(1))
        let second = try ledger.addManualLine(name: "milk", quantity: q(1))
        let third = try ledger.addManualLine(name: "milk", quantity: q(1))
        try ledger.setChecked(lineID: first, checked: true, at: instant)
        try ledger.handle(lineID: second, by: "Mia", at: instant)
        try ledger.trash(lineID: third, at: instant)
        var basis = ledger.basis; basis.branch = "New branch"
        try ledger.updateBasis(basis, at: instant)
        ledger = try roundTrip(ledger)
        try ledger.validate()
        XCTAssertEqual(ledger.search("milk").map(\.id), [first, second])
        XCTAssertEqual(ledger.recentlyChecked.map(\.id), [first])
        XCTAssertEqual(ledger.handled.map(\.id), [second])
        XCTAssertEqual(ledger.trash.map(\.id), [third])
        XCTAssertEqual(ledger.handled[0].handledBy, "Mia")
        try ledger.restore(lineID: third)
        try ledger.reopen(lineID: first)
        XCTAssertEqual(ledger.search("milk").map(\.id), [first, second, third])
        XCTAssertFalse(ledger.lines[0].isChecked)
        XCTAssertTrue(ledger.lines[1].isHandled)
        XCTAssertEqual(ledger.lines.map(\.originalOrder), [0, 1, 2])
        try ledger.trash(lineID: second)
        try ledger.restore(lineID: second)
        XCTAssertTrue(ledger.lines[1].isHandled)
        try ledger.reopen(lineID: second)
        XCTAssertNil(ledger.lines[1].handledBy)
    }

    func testTrashPreservesActiveNeedAndSearchFindsNotesButNotTrash() throws {
        var ledger = ShoppingLedger()
        let line = try ledger.addManualLine(name: "rice", quantity: q(1), notes: "Use for Friday")
        try ledger.updateLine(lineID: line, name: "rice", notes: "Use for Friday", aisle: "Pantry")
        XCTAssertEqual(ledger.search("Friday").map(\.id), [line])
        XCTAssertEqual(ledger.search("pantry").map(\.id), [line])
        try ledger.trash(lineID: line)
        XCTAssertTrue(ledger.search("Friday").isEmpty)
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, .one)
        try ledger.restore(lineID: line)
        XCTAssertEqual(ledger.search("rice").map(\.id), [line])
    }

    func testMealTemplateAndOccurrenceAreIndependentAndSchedulingKeepsIDs() throws {
        var template = try taco()
        template.sourceURL = "https://invalid.example/removed-recipe"
        var ledger = ShoppingLedger(basis: ShopBasis(timeZoneIdentifier: "America/Los_Angeles"))
        let occurrence = try ledger.chooseMeal(template)
        let sourceIDs = ledger.mealOccurrences[0].ingredientContributionIDs
        XCTAssertNil(ledger.mealOccurrences[0].scheduledDay)
        var workspace = LedgerWorkspace(shops: [ledger], mealTemplates: [template], selectedShopID: ledger.id)
        workspace = try roundTrip(workspace)
        try workspace.validate()
        let pickerDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-04T01:00:00Z"))
        try workspace.shops[0].scheduleMeal(occurrenceID: occurrence, on: pickerDate)
        XCTAssertEqual(workspace.shops[0].mealOccurrences[0].scheduledDay?.iso8601, "2026-11-03")
        XCTAssertEqual(workspace.shops[0].mealOccurrences[0].ingredientContributionIDs, sourceIDs)
        XCTAssertEqual(workspace.shops[0].mealOccurrences.count, 1)
        try workspace.shops[0].updateMeal(occurrenceID: occurrence, title: "This week's tacos", notes: "Mild")
        try workspace.shops[0].updateContribution(contributionID: sourceIDs[0], quantity: q(8), notes: "Guests")
        XCTAssertEqual(workspace.mealTemplates[0], template)
        workspace.mealTemplates[0].title = "Usual dinner"
        XCTAssertEqual(workspace.shops[0].mealOccurrences[0].title, "This week's tacos")
        XCTAssertEqual(workspace.shops[0].mealOccurrences[0].sourceURL, template.sourceURL)
        try workspace.validate()
    }

    func testDateOnlyValidationAndDSTCalendarDays() throws {
        XCTAssertThrowsError(try MealDay(year: 2026, month: 2, day: 29, timeZoneIdentifier: "America/New_York"))
        XCTAssertThrowsError(try MealDay(year: 2026, month: 11, day: 1, timeZoneIdentifier: "Not/AZone"))
        let day = try MealDay(year: 2026, month: 11, day: 1, timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(try MealDay(date: XCTUnwrap(day.date), timeZoneIdentifier: day.timeZoneIdentifier), day)
        XCTAssertThrowsError(try MealDay(date: Date(timeIntervalSinceReferenceDate: .infinity), timeZoneIdentifier: "UTC"))
    }

    func testAllBasisChangesInvalidateQuoteAndNoOpDoesNot() throws {
        let variations: [(inout ShopBasis) -> Void] = [
            { $0.branch = "Another branch" }, { $0.mode = .delivery },
            { $0.slot = self.instant }, { $0.timeZoneIdentifier = "America/Chicago" },
            { $0.cap = Money(minorUnits: 3500) }, { $0.capScope = .dinnersOnly },
            { $0.capFirmness = .flexible }, { $0.fixedReserve = Money(minorUnits: 200) },
            { $0.knownFees = Money(minorUnits: 300) }
        ]
        for change in variations {
            var ledger = ShoppingLedger(basis: ShopBasis(timeZoneIdentifier: "UTC"))
            let quote = LedgerQuoteReference(basisRevision: 0, ledgerRevision: 0, createdAt: instant)
            try ledger.attachQuote(quote)
            let unchanged = ledger
            try ledger.updateBasis(ledger.basis, at: instant)
            XCTAssertEqual(ledger, unchanged)
            var basis = ledger.basis; change(&basis)
            try ledger.updateBasis(basis, at: instant)
            XCTAssertEqual(ledger.basisRevision, 1)
            XCTAssertEqual(ledger.revision, 1)
            XCTAssertNil(ledger.quoteReference)
            XCTAssertThrowsError(try ledger.attachQuote(quote))
        }
        var ledger = ShoppingLedger()
        var invalid = ledger.basis; invalid.cap = Money(minorUnits: -1)
        let unchanged = ledger
        XCTAssertThrowsError(try ledger.updateBasis(invalid))
        XCTAssertEqual(ledger, unchanged)
    }

    func testMatchingRejectsExclusionsIncompatibleProductsAndUnknownUnits() throws {
        var ledger = ShoppingLedger()
        let flour = try ledger.addManualLine(name: "flour", quantity: q(1000, unit: .gram))
        XCTAssertEqual(ledger.matchingLines(name: "FLOUR", quantity: try q(1, unit: .kilogram)).map(\.id), [flour])
        XCTAssertTrue(ledger.matchingLines(name: "flour", quantity: try q(1, unit: .cup)).isEmpty)
        XCTAssertTrue(ledger.matchingLines(name: "flour", quantity: nil).isEmpty)
        XCTAssertTrue(ledger.matchingLines(name: "flour", quantity: try q(1, unit: .kilogram), exclusions: ["flour"]).isEmpty)
        XCTAssertTrue(ledger.matchingLines(name: "rice", quantity: try q(1, unit: .kilogram)).isEmpty)
        let excluded = MealTemplate(title: "Excluded dinner", ingredients: [MealIngredient(name: "peanut butter", quantity: try q(1))], exclusions: ["peanut"])
        let unchanged = ledger
        XCTAssertThrowsError(try ledger.chooseMeal(excluded))
        XCTAssertEqual(ledger, unchanged)
        var preview = ledger.stageImport(text: "1 kg flour")
        preview.lines[0].quantity = try q(1, unit: .cup)
        XCTAssertThrowsError(try ledger.commitImport(preview, decisions: [preview.lines[0].id: .mergeDuplicate(flour)]))
        XCTAssertEqual(ledger, unchanged)
    }

    func testRenamedLineRetainsSourceWordsAndCanReceiveNewMatchingSource() throws {
        var ledger = ShoppingLedger()
        let line = try ledger.addManualLine(name: "wraaps", quantity: q(12))
        let originalText = ledger.contributions[0].originalText
        try ledger.updateLine(lineID: line, name: "wraps", notes: "Corrected", aisle: "Bread")
        let preview = ledger.stageImport(text: "12 wraps")
        try ledger.commitImport(preview, decisions: [preview.lines[0].id: .mergeDuplicate(line)])
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(12))
        XCTAssertEqual(ledger.contributions[0].originalText, originalText)
        XCTAssertEqual(ledger.contributions[0].productName, "wraps")
    }

    func testRetailerTermsKeepDisplacedObservationsAndRejectStaleReview() throws {
        let original = ShopBasis(branch: "West", mode: .pickup, slot: instant, timeZoneIdentifier: "America/New_York",
            cap: Money(minorUnits: 3800), knownFees: .zero,
            retailerPreview: .init(total: Money(minorUnits: 3670), source: "Retailer page", capturedAt: instant,
                                   includedCharges: ["Service, delivery", "Tax"]))
        let changes: [(inout ShopBasis) -> Void] = [
            { $0.branch = "East" }, { $0.slot = nil }, { $0.mode = .delivery },
            { $0.timeZoneIdentifier = "America/Chicago" }, { $0.capScope = .dinnersOnly }
        ]
        for change in changes {
            var ledger = ShoppingLedger(basis: original)
            var proposed = original
            change(&proposed)
            let revision = ledger.revisionID
            try ledger.updateBasis(proposed, reviewing: revision)
            XCTAssertNil(ledger.basis.retailerPreview); XCTAssertNil(ledger.basis.knownFees)
            let restored = try roundTrip(ledger)
            XCTAssertEqual(restored.revisions.last?.previousRetailerBasis, original)
            XCTAssertThrowsError(try ledger.updateBasis(original, reviewing: revision))
            XCTAssertEqual(ledger, restored)
        }
        var ledger = ShoppingLedger(basis: original)
        var newCap = original
        newCap.cap = Money(minorUnits: 4000); newCap.fixedReserve = .zero
        try ledger.updateBasis(newCap)
        XCTAssertEqual(ledger.basis.retailerPreview, original.retailerPreview)
        XCTAssertEqual(ledger.basis.knownFees, .zero); XCTAssertNil(ledger.revisions.last?.previousRetailerBasis)

        var confirmed = newCap
        confirmed.branch = "East"
        confirmed.retailerPreview = .init(total: nil, source: "East app", capturedAt: instant, includedCharges: [])
        try ledger.updateBasis(confirmed, evidenceFor: confirmed.retailerTerms, reviewing: ledger.revisionID)
        XCTAssertEqual(ledger.basis, confirmed, "A freshly entered zero fee remains an observed zero")
        XCTAssertEqual(try roundTrip(ledger).revisions.last?.previousRetailerBasis, newCap)
    }

    func testRetailerPreviewStoresScopeAndUnknownFactsWithoutInventingTotals() throws {
        var ledger = ShoppingLedger()
        var basis = ledger.basis
        basis.cap = Money(minorUnits: 3500); basis.capScope = .dinnersOnly
        basis.retailerPreview = LedgerRetailerPreview(source: "Retailer checkout", capturedAt: instant, includedCharges: ["Delivery"])
        try ledger.updateBasis(basis)
        let restored = try roundTrip(ledger)
        XCTAssertNil(restored.basis.retailerPreview?.total)
        XCTAssertNil(restored.basis.knownFees)
        XCTAssertEqual(restored.basis.capScope, .dinnersOnly)
        XCTAssertEqual(restored.basis.retailerPreview?.includedCharges, ["Delivery"])
        let unchanged = ledger
        basis.retailerPreview?.total = Money(minorUnits: -1)
        XCTAssertThrowsError(try ledger.updateBasis(basis))
        XCTAssertEqual(ledger, unchanged)
    }

    func testZeroDemandCanBeConfirmedDuplicateWithoutBecomingUnknown() throws {
        var ledger = ShoppingLedger()
        let line = try ledger.addManualLine(name: "wraps", quantity: q(0))
        let preview = ledger.stageImport(text: "0 wraps")
        try ledger.commitImport(preview, decisions: [preview.lines[0].id: .mergeDuplicate(line)])
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, .zero)
    }

    func testExactUnitMergeAndFractionalAllocation() throws {
        var ledger = ShoppingLedger()
        let line = try ledger.addManualLine(name: "rice", quantity: q(1, unit: .kilogram))
        let manual = try source(ledger, lineID: line)
        let preview = ledger.stageImport(text: "1000 g rice")
        try ledger.commitImport(preview, decisions: [preview.lines[0].id: .mergeDuplicate(line)])
        _ = try ledger.addProtectedNeed(name: "rice", quantity: q(250, unit: .gram), purpose: "Lunch", within: manual)
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, .one)
        XCTAssertEqual(try ledger.quantity(forLineID: line)?.unit, .kilogram)
        let prior = ledger
        XCTAssertThrowsError(try ledger.updateContribution(contributionID: manual, quantity: nil, notes: "Unknown"))
        XCTAssertEqual(ledger, prior)
    }

    func testUnknownsStayUnresolvedAndInvalidLinkIsAtomic() throws {
        var ledger = ShoppingLedger()
        let line = try ledger.addManualLine(name: "wraps", quantity: nil)
        XCTAssertNil(try ledger.quantity(forLineID: line))
        let occurrence = try ledger.chooseMeal(taco())
        let demand = try mealSource(ledger, occurrenceID: occurrence)
        let manual = try source(ledger, lineID: line)
        let prior = ledger
        XCTAssertThrowsError(try ledger.linkContribution(contributionID: demand, within: manual, quantity: q(6)))
        XCTAssertThrowsError(try ledger.linkContribution(contributionID: demand, within: demand, quantity: q(6)))
        XCTAssertThrowsError(try ledger.addProtectedNeed(name: "wraps", quantity: nil, purpose: "Lunch", within: manual))
        XCTAssertEqual(ledger, prior)
    }

    func testRemoveIndividualMealAndImportContributionPreservesOtherSources() throws {
        var ledger = ShoppingLedger()
        let preview = ledger.stageImport(text: "12 wraps\n4 apples")
        let batch = try ledger.commitImport(preview)
        try ledger.removeContribution(contributionID: preview.lines[1].id)
        XCTAssertEqual(ledger.search("").map(\.name), ["wraps"])
        let occurrence = try ledger.chooseMeal(taco())
        let demand = try mealSource(ledger, occurrenceID: occurrence)
        try ledger.removeContribution(contributionID: demand)
        XCTAssertNil(ledger.mealOccurrences[0].removedAt)
        try ledger.validate()
        try ledger.removeMeal(occurrenceID: occurrence)
        try ledger.undoImport(batchID: batch)
        XCTAssertTrue(ledger.search("").isEmpty)
        try ledger.validate()
    }

    func testPersistedCorruptionIsRejectedBeforeMutationCanTrap() throws {
        var ledger = ShoppingLedger()
        let line = try ledger.addManualLine(name: "wraps", quantity: q(12))
        let extremeOrder = try tampered(ledger) { json in
            var lines = json["lines"] as! [[String: Any]]; lines[0]["originalOrder"] = Int.max; json["lines"] = lines
        }
        XCTAssertThrowsError(try extremeOrder.validate())
        var corrupted = extremeOrder
        XCTAssertThrowsError(try corrupted.addManualLine(name: "soap", quantity: q(1)))
        let duplicate = try tampered(ledger) { json in
            let lines = json["lines"] as! [[String: Any]]; json["lines"] = lines + lines
        }
        XCTAssertThrowsError(try duplicate.validate())
        let dangling = try tampered(ledger) { json in
            var sources = json["contributions"] as! [[String: Any]]; sources[0]["lineID"] = UUID().uuidString; json["contributions"] = sources
        }
        XCTAssertThrowsError(try dangling.validate())
        let wrongHead = try tampered(ledger) { $0["revisionID"] = UUID().uuidString }
        XCTAssertThrowsError(try wrongHead.validate())
        let wrongHandler = try tampered(ledger) { json in
            var lines = json["lines"] as! [[String: Any]]; lines[0]["handledBy"] = "Mia"; json["lines"] = lines
        }
        XCTAssertThrowsError(try wrongHandler.validate())
        var workspace = LedgerWorkspace(shops: [ledger], selectedShopID: UUID())
        XCTAssertThrowsError(try workspace.validate())
        workspace.selectedShopID = ledger.id
        XCTAssertNoThrow(try workspace.validate())
        XCTAssertEqual(ledger.search("").map(\.id), [line])
    }

    func testPersistedAllocationCycleDanglingAndOverallocationAreRejected() throws {
        var ledger = ShoppingLedger()
        let line = try ledger.addManualLine(name: "wraps", quantity: q(12))
        let manual = try source(ledger, lineID: line)
        let occurrence = try ledger.chooseMeal(taco())
        let demand = try mealSource(ledger, occurrenceID: occurrence)
        try ledger.linkContribution(contributionID: demand, within: manual, quantity: q(6))
        let selfEdge = try tampered(ledger) { json in
            var edges = json["allocations"] as! [[String: Any]]; edges[0]["supplyContributionID"] = demand.uuidString; json["allocations"] = edges
        }
        XCTAssertThrowsError(try selfEdge.validate())
        let dangling = try tampered(ledger) { json in
            var edges = json["allocations"] as! [[String: Any]]; edges[0]["supplyContributionID"] = UUID().uuidString; json["allocations"] = edges
        }
        XCTAssertThrowsError(try dangling.validate())
        let overallocated = try tampered(ledger) { json in
            var edges = json["allocations"] as! [[String: Any]]
            var quantity = edges[0]["quantity"] as! [String: Any]
            quantity["amount"] = ["numerator": 13, "denominator": 1]
            edges[0]["quantity"] = quantity; json["allocations"] = edges
        }
        XCTAssertThrowsError(try overallocated.validate())
        let preview = ledger.stageImport(text: "12 wraps")
        try ledger.commitImport(preview, decisions: [preview.lines[0].id: .mergeDuplicate(line)])
        let cycle = try tampered(ledger) { json in
            var edges = json["allocations"] as! [[String: Any]]
            var reversed = edges.last!
            reversed["id"] = UUID().uuidString
            reversed["demandContributionID"] = manual.uuidString
            reversed["supplyContributionID"] = preview.lines[0].id.uuidString
            edges.append(reversed); json["allocations"] = edges
        }
        XCTAssertThrowsError(try cycle.validate())
    }

    func testRandomizedLinkedDemandConservationAndRemoval() throws {
        var random: UInt64 = 0xB02CA47
        func next(_ max: UInt64) -> Int64 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return Int64((random >> 32) % max)
        }
        for _ in 0..<150 {
            let supply = next(100) + 1
            let demand = next(100) + 1
            let linked = min(supply, demand)
            let protected = next(UInt64(supply - linked + 1))
            var ledger = ShoppingLedger()
            let line = try ledger.addManualLine(name: "wraps", quantity: q(supply))
            let manual = try source(ledger, lineID: line)
            let occurrence = try ledger.chooseMeal(taco(demand))
            let meal = try mealSource(ledger, occurrenceID: occurrence)
            try ledger.linkContribution(contributionID: meal, within: manual, quantity: q(linked))
            if protected > 0 { _ = try ledger.addProtectedNeed(name: "wraps", quantity: q(protected), purpose: "Lunch", within: manual) }
            XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(supply + demand - linked))
            try ledger.removeMeal(occurrenceID: occurrence)
            XCTAssertEqual(try ledger.quantity(forLineID: line)?.amount, try Rational(supply))
            try ledger.validate()
        }
    }
}
