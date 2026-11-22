import Foundation
import XCTest
@testable import CoreDomain

final class QuickGroceryTests: XCTestCase {
    func testPrivateListReviewKeepsContainerCountSeparateFromContentsAcrossReopenAndDuplicateReview() throws {
        for (wording, name) in [("2 cartons of oat milk", "oat milk"), ("2 cartones de leche de avena", "leche de avena")] {
            var shop = ShoppingLedger()
            XCTAssertNil(try QuickGrocery.stage(wording, in: shop))
            let staged = try shop.stageImport(text: wording, reviewPackageCounts: true)
            let row = try XCTUnwrap(staged.lines.first)
            XCTAssertEqual(row.name, name)
            XCTAssertEqual(row.reviewedPackages, .init(count: 2, kind: .carton))
            XCTAssertNil(row.quantity)
            XCTAssertNil(row.originalPack)
            XCTAssertNil(row.unresolvedReason)
            XCTAssertTrue(shop.lines.isEmpty)

            var edited = try JSONDecoder().decode(StagedListImport.self, from: JSONEncoder().encode(staged))
            edited.lines[0].reviewedPackages = .init(count: 3, kind: .bottle)
            try shop.commitImport(edited)
            shop = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
            try shop.validate()
            try shop.commitImport(edited)
            XCTAssertEqual(shop.lines.map(\.id), [row.proposedLineID])
            let source = try XCTUnwrap(shop.contributions.first)
            XCTAssertEqual(source.id, row.id)
            XCTAssertEqual(source.productName, name)
            XCTAssertEqual(source.originalText, wording)
            XCTAssertEqual(source.reviewedPackages, .init(count: 3, kind: .bottle))
            XCTAssertEqual(shop.importBatches.first?.originalText, wording)
            XCTAssertNil(try shop.quantity(forLineID: row.proposedLineID))
            XCTAssertNil(shop.itemPackages[row.proposedLineID])

            let repeatReview = try shop.stageImport(text: wording, reviewPackageCounts: true)
            let repeated = try XCTUnwrap(repeatReview.lines.first)
            XCTAssertEqual(repeated.duplicateLineIDs, [row.proposedLineID])
            let options = try XCTUnwrap(shop.importMatchOptions(for: repeatReview, decisions: [:])[repeated.id])
            XCTAssertFalse(options.contains { $0.canMerge || $0.canAdd })
            XCTAssertThrowsError(try shop.commitImport(repeatReview))
            try shop.commitImport(repeatReview, decisions: [repeated.id: .skip])
            XCTAssertEqual(shop.contributions, [source])
        }
    }

    func testOnlyExplicitContainerAndPlainProductWordingChangesPrivateListReview() throws {
        let shop = ShoppingLedger()
        let cases: [(String, GroceryPackageCount.Kind)] = [
            ("a bag of rice", .bag), ("dos bolsas de arroz", .bag), ("1 bottle of tea", .bottle),
            ("2 botellas de té", .bottle), ("1 can of peas", .can), ("2 latas de frijoles", .can),
            ("3 boxes of pasta", .box), ("1 caja de pasta", .box), ("1 pack of wraps", .pack),
            ("2 paquetes de tortillas", .pack), ("un cartón de leche", .carton)
        ]
        for (wording, kind) in cases {
            let row = try XCTUnwrap(shop.stageImport(text: wording, reviewPackageCounts: true).lines.first)
            XCTAssertEqual(row.reviewedPackages?.kind, kind, wording)
            XCTAssertNil(row.quantity, wording)
        }
        for wording in ["2 cartons", "2 carton labels", "2 cartons of", "2 cartons of of milk",
                        "1/2 carton of milk", "0 cartons of milk", "1–2 cartons of milk", "2 cartons of 1 L milk",
                        "2 cartons of milk per person", "2 cartones de leche y pan", "2 bags of rice for Friday",
                        "2 jars of jam", "2 cases of water", "2 cans of beans, 15 oz each",
                        "2 kg rice", "2 apples", "12 wraps", "1 pack of 6 wraps"] {
            let plain = try XCTUnwrap(shop.stageImport(text: wording).lines.first)
            let reviewed = try XCTUnwrap(shop.stageImport(text: wording, reviewPackageCounts: true).lines.first)
            XCTAssertNil(reviewed.reviewedPackages, wording)
            XCTAssertEqual(reviewed.quantity, plain.quantity, wording)
            XCTAssertEqual(reviewed.originalPack, plain.originalPack, wording)
            XCTAssertEqual(reviewed.name, plain.name, wording)
            XCTAssertEqual(reviewed.unresolvedReason, plain.unresolvedReason, wording)
        }
        var invalid = try shop.stageImport(text: "1 carton of milk", reviewPackageCounts: true)
        XCTAssertNil(try shop.stageImport(text: "1 carton of milk", source: .photoOCR, reviewPackageCounts: true).lines.first?.reviewedPackages)
        XCTAssertNil(try shop.stageImport(text: "1 carton of milk", source: .selectedText).lines.first?.reviewedPackages)
        invalid.lines[0].quantity = Quantity(amount: .one, unit: .liter, originalLiteral: "1")
        var current = shop
        XCTAssertThrowsError(try current.commitImport(invalid))
        XCTAssertTrue(current.lines.isEmpty)
    }

    func testPlainGroceryCanReplayThenUndoOnlyItsSource() throws {
        var shop = ShoppingLedger()
        _ = try shop.addManualLine(name: "Milk", quantity: nil)
        let preview = try XCTUnwrap(QuickGrocery.stage("  huevos  ", in: shop))
        XCTAssertEqual(preview.lines.first?.name, "huevos")
        XCTAssertNil(preview.lines.first?.quantity)
        XCTAssertNil(preview.lines.first?.unresolvedReason)
        try shop.commitImport(preview)
        let saved = try JSONEncoder().encode(shop)
        var reopened = try JSONDecoder().decode(ShoppingLedger.self, from: saved)
        try reopened.commitImport(preview)
        XCTAssertEqual(reopened.search("").map(\.name), ["Milk", "huevos"])
        XCTAssertNil(try QuickGrocery.stage("HUEVOS", in: reopened))
        try reopened.setChecked(lineID: preview.lines[0].proposedLineID, checked: true)
        XCTAssertNil(try QuickGrocery.stage("huevos", in: reopened))
        try reopened.undoImport(batchID: preview.id)
        XCTAssertEqual(reopened.search("").map(\.name), ["Milk"])
        XCTAssertThrowsError(try reopened.commitImport(preview))
        XCTAssertNotNil(try QuickGrocery.stage("huevos", in: reopened))
    }

    func testReviewedPackageCountSurvivesReopenWithoutSupplyingIngredientUnits() throws {
        var shop = ShoppingLedger()
        let milk = try XCTUnwrap(QuickGrocery.stage("Milk", in: shop))
        try shop.commitImport(milk)
        let source = try XCTUnwrap(shop.contributions.first)
        let lineID = source.lineID
        let packages = GroceryPackageCount(count: 2, kind: .carton)
        let oldData = try JSONEncoder().encode(shop)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("reviewedPackages"))
        shop = try JSONDecoder().decode(ShoppingLedger.self, from: oldData)
        try shop.updateContribution(contributionID: source.id, quantity: nil, notes: "Organic", reviewedPackages: packages)

        let reopened = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        try reopened.validate()
        let saved = try XCTUnwrap(reopened.contributions.first)
        XCTAssertEqual(saved.reviewedPackages, packages)
        XCTAssertEqual(saved.originalText, "Milk")
        XCTAssertNil(saved.originalPack)
        XCTAssertEqual(saved.notes, "Organic")
        XCTAssertEqual(reopened.importBatches.first?.preview, milk)
        XCTAssertNil(try reopened.quantity(forLineID: lineID))
        XCTAssertNil(reopened.itemPackages[lineID])

        let liters = Quantity(amount: .one, unit: .liter, originalLiteral: "1")
        XCTAssertTrue(reopened.matchingLines(name: "Milk", quantity: liters).isEmpty)
        XCTAssertThrowsError(try shop.updateContribution(contributionID: source.id, quantity: liters, notes: "", reviewedPackages: packages))
        XCTAssertThrowsError(try shop.updateContribution(contributionID: source.id, quantity: nil, notes: "", reviewedPackages: .init(count: 0, kind: .bag)))
        XCTAssertEqual(shop, reopened)
        try shop.updateContribution(contributionID: source.id, quantity: nil, notes: "Cold")
        XCTAssertEqual(shop.contributions.first?.reviewedPackages, packages)
        let beforePick = shop
        XCTAssertThrowsError(try shop.pickPart(lineID: lineID, amount: .one, expectedRevision: shop.revisionID))
        XCTAssertEqual(shop, beforePick)
        try shop.setChecked(lineID: lineID, checked: true)
        XCTAssertTrue(shop.lines[0].isChecked)
        XCTAssertNil(try shop.pickedQuantity(forLineID: lineID))
        XCTAssertNil(shop.lines[0].tripPick)
        try shop.setChecked(lineID: lineID, checked: false)
        XCTAssertEqual(shop.contributions.first?.reviewedPackages, packages)
        try shop.updateContribution(contributionID: source.id, quantity: liters, notes: "Organic")
        XCTAssertNil(shop.contributions.first?.reviewedPackages)
        XCTAssertEqual(try shop.quantity(forLineID: lineID)?.unit, .liter)
    }

    func testReviewedContainersAndIngredientAmountsOnOneLineHaveNoMeasuredTotal() throws {
        var shop = ShoppingLedger()
        let first = try shop.stageImport(text: "1 milk")
        try shop.commitImport(first)
        let lineID = first.lines[0].proposedLineID
        let second = try shop.stageImport(text: "2 milk")
        try shop.commitImport(second, decisions: [second.lines[0].id: .addToLine(lineID)])
        XCTAssertEqual(try shop.quantity(forLineID: lineID)?.amount, try Rational(3))
        try shop.updateContribution(contributionID: first.lines[0].id, quantity: nil, notes: "", reviewedPackages: .init(count: 1, kind: .carton))
        XCTAssertNil(try shop.quantity(forLineID: lineID))
        XCTAssertEqual(shop.contributions(forLineID: lineID).last?.quantity?.amount, try Rational(2))

        let cans = try shop.stageImport(text: "2 cans of beans")
        try shop.commitImport(cans)
        let before = shop
        XCTAssertThrowsError(try shop.updateContribution(contributionID: cans.lines[0].id, quantity: nil, notes: "",
                                                         reviewedPackages: .init(count: 1, kind: .box)))
        XCTAssertEqual(shop, before)
        XCTAssertEqual(shop.contributions.last?.originalPack, cans.lines[0].originalPack)
    }

    func testQuantitiesRequestsAndListsGoToReviewWithOriginalWording() throws {
        let shop = ShoppingLedger()
        for text in ["2 kg rice", "3½ cups flour", "six bananas", "seis plátanos", "puñado de nueces",
                     "one or two boxes", "leche sin lactosa", "milk for Alex", "eggs, milk", "milk\neggs", "1–2 apples",
                     "0 lemons", "-1 lemon", "1 kg lemons", "1 box lemons", "1 lemon or lime", "1 ½ lemons"] {
            XCTAssertNil(try QuickGrocery.stage(text, in: shop), text)
        }
        for text in ["Oats", "Arroz blanco", "Bananas", "arroz integral", "Greek yogurt", "plátanos", "limo\u{301}n", "rigatoni"] {
            XCTAssertEqual(try QuickGrocery.stage(text, in: shop)?.lines.first?.name, text)
        }
        var pickup = ShoppingLedger()
        for (text, name, count) in [("1 lemon", "lemon", 1), ("2 limones", "limones", 2), ("3 plátanos", "plátanos", 3)] {
            let row = try XCTUnwrap(QuickGrocery.stage(text, in: pickup))
            let proposed = try XCTUnwrap(row.lines.first)
            XCTAssertEqual(proposed.name, name)
            XCTAssertEqual(proposed.quantity?.amount, try Rational(Int64(count)))
            XCTAssertEqual(proposed.quantity?.unit, .count)
            XCTAssertEqual(proposed.quantity?.originalLiteral, text)
            try pickup.commitImport(row)
            try pickup.commitImport(row)
            XCTAssertNil(try QuickGrocery.stage(text, in: pickup))
        }
        XCTAssertEqual(pickup.lines.count, 3)
    }

    func testOnlyExactProductOrConfirmedAliasCanShowStockWithoutAChoice() {
        let whole = UUID(), rye = UUID(), absent = UUID()
        let products = [(whole, "Whole wheat bread"), (rye, "Rye bread"), (whole, "Whole wheat bread")]
        let choice = GroceryPantryCandidates(name: "bread", products: products, confirmedAliases: [])
        XCTAssertNil(choice.unambiguous)
        XCTAssertEqual(choice.possible, [whole, rye])
        let exact = GroceryPantryCandidates(name: "  RYE bread ", products: products, confirmedAliases: [absent])
        XCTAssertEqual(exact.unambiguous, rye)
        let alias = GroceryPantryCandidates(name: "WW BRD", products: products, confirmedAliases: [whole])
        XCTAssertEqual(alias.unambiguous, whole)
        let ambiguous = GroceryPantryCandidates(name: "Rye bread", products: products, confirmedAliases: [whole])
        XCTAssertNil(ambiguous.unambiguous)
        XCTAssertEqual(ambiguous.possible, [whole, rye])
        XCTAssertTrue(GroceryPantryCandidates(name: "wheat flour", products: products, confirmedAliases: []).possible.isEmpty)
    }

    func testDepartmentChoicesIncludeOnlyThisShopsCustomDepartmentsAndLocalizedDefaults() throws {
        var shop = ShoppingLedger(basis: ShopBasis(branch: "North"))
        try shop.addManualLine(name: "Hummus", quantity: nil)
        try shop.addManualLine(name: "Pita", quantity: nil)
        let other = ShoppingLedger(basis: ShopBasis(branch: "South"))
        var layout = LedgerListLayout()
        try layout.setDepartment("Deli", for: shop.lines[0], in: shop, remember: false)
        try layout.setStoreOrder(["Deli", "International foods", "Dairy"], in: shop)
        try layout.setStoreOrder(["Back counter"], in: other)
        let english = layout.departmentChoices(in: shop, spanish: false)
        let spanish = layout.departmentChoices(in: shop, spanish: true)
        XCTAssertEqual(english.filter { $0 == "Deli" }.count, 1)
        XCTAssertEqual(english.filter { $0 == "Dairy" }.count, 1)
        XCTAssertTrue(english.contains("International foods"))
        XCTAssertTrue(spanish.contains("Deli"))
        XCTAssertTrue(spanish.contains("Lácteos"))
        XCTAssertFalse(english.contains("Back counter"))
        XCTAssertFalse(spanish.contains(""))
    }

    func testNewRowInOlderListUsesLatestConfirmedBranchCorrection() throws {
        var taught = ShoppingLedger(basis: ShopBasis(branch: "North"))
        try taught.addManualLine(name: "Milk", quantity: nil)
        var old = ShoppingLedger(basis: taught.basis)
        try old.addManualLine(name: "Milk", quantity: nil)
        var layout = LedgerListLayout()
        try layout.setDepartment("Cold cases", for: taught.lines[0], in: taught, remember: true)
        var updated = old
        try updated.addManualLine(name: "Milk", quantity: nil)
        layout.applyDepartmentMemory(to: [updated], previous: [old])
        XCTAssertEqual(layout.department(for: updated.lines[0], in: updated), GroceryDepartment.dairy.label(spanish: GroceryDepartment.usesSpanish))
        XCTAssertEqual(layout.department(for: updated.lines[1], in: updated), "Cold cases")
    }

    func testBilingualDepartmentSuggestionsYieldToBranchAndCanBeCleared() throws {
        XCTAssertEqual(GroceryDepartment.suggested(for: "LECHE ENTERA")?.label(spanish: true), "Lácteos")
        XCTAssertEqual(GroceryDepartment.suggested(for: "milk")?.label(spanish: false), "Dairy")
        XCTAssertEqual(GroceryDepartment.suggested(for: "papel de aluminio"), .household)
        XCTAssertNil(GroceryDepartment.suggested(for: "milk chocolate"))
        var original = ShoppingLedger(basis: ShopBasis(branch: "North"))
        try original.addManualLine(name: "Milk", quantity: nil)
        var next = ShoppingLedger(basis: original.basis)
        try next.addManualLine(name: "Milk", quantity: nil)
        var other = ShoppingLedger(basis: ShopBasis(branch: "South"))
        try other.addManualLine(name: "Milk", quantity: nil)
        var layout = LedgerListLayout()
        try layout.setDepartment("", for: original.lines[0], in: original, remember: true)
        layout.applyDepartmentMemory(to: [next, other], previous: [])
        XCTAssertEqual(layout.department(for: next.lines[0], in: next), "")
        XCTAssertEqual(layout.department(for: other.lines[0], in: other), GroceryDepartment.dairy.label(spanish: GroceryDepartment.usesSpanish))
        var workspace = LedgerWorkspace(shops: [original, next, other], selectedShopID: next.id)
        workspace.listLayout = layout
        XCTAssertEqual(try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace)), workspace)
    }
}
