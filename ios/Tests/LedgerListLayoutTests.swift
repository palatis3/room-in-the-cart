import XCTest
import PDFKit
import UIKit
import CoreDomain
@testable import RoomInTheCart

@MainActor final class LedgerListLayoutTests: XCTestCase {
    private func populated(_ branch: String) throws -> ShoppingLedger {
        var shop = ShoppingLedger(title: "Saturday list", basis: ShopBasis(branch: branch))
        for (name, aisle) in [("Apples", "Produce"), ("Milk", "Dairy"), ("Soap", "")] {
            let id = try shop.addManualLine(name: name, quantity: Quantity(amount: .one, unit: .count, originalLiteral: "1 item"), notes: "Private note")
            try shop.updateLine(lineID: id, name: name, notes: "Private note", aisle: aisle)
        }
        return shop
    }

    func testShoppingRowRetainsDeliberateUnmeasuredRecipeDecision() throws {
        var shop = ShoppingLedger()
        _ = try shop.chooseMeal(.init(title: "Sopa", ingredients: [
            .init(name: "Maíz", quantity: nil, checkedWithoutAmount: true),
            .init(name: "Caldo", quantity: nil)
        ]))
        let corn = try XCTUnwrap(shop.lines.first { $0.name == "Maíz" })
        let broth = try XCTUnwrap(shop.lines.first { $0.name == "Caldo" })
        XCTAssertEqual(shop.shoppingRowQuantity(for: corn), tonightText("Checked by hand · unmeasured"))
        XCTAssertNil(try shop.quantity(forLineID: corn.id))
        XCTAssertEqual(shop.shoppingRowQuantity(for: broth), ledgerText("Quantity unresolved"))
    }

    func testOnlyOneUnqualifiedNameOmitsTheQuantityFromShoppingRows() throws {
        var shop = ShoppingLedger()
        let oats = try XCTUnwrap(QuickGrocery.stage("Oats", in: shop))
        try shop.commitImport(oats)
        let plain = try XCTUnwrap(shop.lines.first)
        XCTAssertNil(shop.shoppingRowQuantity(for: plain))
        XCTAssertNil(try shop.quantity(forLineID: plain.id))
        XCTAssertEqual(ledgerQuantity(try shop.quantity(forLineID: plain.id)), ledgerText("Quantity unresolved"))

        try shop.updateLine(lineID: plain.id, name: "Rolled oats", notes: "", aisle: "")
        let renamed = try XCTUnwrap(shop.lines.first)
        XCTAssertNil(shop.shoppingRowQuantity(for: renamed))
        XCTAssertNil(try shop.quantity(forLineID: renamed.id))
        XCTAssertEqual(shop.contributions(forLineID: renamed.id).map(\.originalText), ["Oats"])
        try shop.updateLine(lineID: plain.id, name: "2 bags of oats", notes: "", aisle: "")
        XCTAssertEqual(shop.shoppingRowQuantity(for: try XCTUnwrap(shop.lines.first)), ledgerText("Quantity unresolved"))

        let unknown = try shop.stageImport(text: "2–3 bags of rice")
        try shop.commitImport(unknown)
        XCTAssertEqual(shop.shoppingRowQuantity(for: try XCTUnwrap(shop.lines.last)), ledgerText("Quantity unresolved"))

        _ = try shop.addProtectedNeed(name: "Milk", quantity: nil, purpose: "School lunch")
        XCTAssertEqual(shop.shoppingRowQuantity(for: try XCTUnwrap(shop.lines.last)), ledgerText("Quantity unresolved"))

        let amount = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        _ = try shop.addManualLine(name: "Apple", quantity: amount)
        XCTAssertEqual(shop.shoppingRowQuantity(for: try XCTUnwrap(shop.lines.last)), ledgerQuantity(amount))
    }

    func testBulkPluralHintComparesOnlyIncludedRowsWithTheSameMeasuredAmount() throws {
        let shop = ShoppingLedger()
        let preview = try shop.stageImport(text: "2 manzanas\n2 manzana\n1 manzana\n2 kg manzana\n2 manzanas verdes")
        let original = LedgerImportReview.initialChoices(preview)
        let initial = LedgerImportReview(shop: shop, preview: preview, choices: original)
        XCTAssertEqual(initial.similarEarlierLines, [preview.lines[1].id: 0])
        XCTAssertEqual(initial.choices, original)
        var skipping = original
        skipping[preview.lines[0].id] = .skip
        let revised = LedgerImportReview(shop: shop, preview: preview, choices: skipping)
        XCTAssertTrue(revised.similarEarlierLines.isEmpty)
        XCTAssertEqual(revised.choices, skipping)

        let reverse = try shop.stageImport(text: "3 lime\n3 limes")
        let reverseReview = LedgerImportReview(shop: shop, preview: reverse, choices: LedgerImportReview.initialChoices(reverse))
        XCTAssertEqual(reverseReview.similarEarlierLines, [reverse.lines[1].id: 0])
        XCTAssertTrue(reverseReview.isComplete)

        let repeated = try shop.stageImport(text: "2 apples\n2 apples")
        let separate = Dictionary(uniqueKeysWithValues: repeated.lines.map { ($0.id, ImportResolution.addNew) })
        let keepBoth = LedgerImportReview(shop: shop, preview: repeated, choices: separate)
        XCTAssertEqual(keepBoth.similarEarlierLines, [repeated.lines[1].id: 0])
        XCTAssertTrue(keepBoth.isComplete)
        var saved = shop
        try saved.commitImport(repeated, decisions: keepBoth.choices)
        XCTAssertEqual(saved.lines.count, 2)
        XCTAssertEqual(saved.contributions.map(\.originalText), ["2 apples", "2 apples"])
    }

    func testChangingPickupsClearsOnlyThePreviousListsFilter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        await model.open()
        let started = await model.startShop(title: "Saturday")
        XCTAssertTrue(started)
        let first = try XCTUnwrap(model.shop?.id)
        model.search = "beans"
        await model.selectShop(first)
        let edited = await model.editShop(key: "add-beans", shopID: first) {
            _ = try $0.addManualLine(name: "beans", quantity: nil)
        }
        XCTAssertTrue(edited)
        XCTAssertEqual(model.search, "beans")
        let next = await model.startShop(title: "Sunday")
        XCTAssertTrue(next)
        XCTAssertEqual(model.search, "")
        model.search = "tomatoes"
        await model.selectShop(first)
        XCTAssertEqual(model.search, "")
        XCTAssertEqual(model.shop?.search(model.search).map(\.name), ["beans"])
    }

    func testRememberedDepartmentSurvivesRealLedgerReopenAndScopedRecordsProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.sqlite")
        let model = LedgerModel(databaseURL: url)
        await model.open()
        let original = try populated("Market North")
        let starting = await model.change(key: "department-start") { workspace in
            workspace.shops = [original]
            workspace.selectedShopID = original.id
        }
        XCTAssertTrue(starting)
        let remembered = await model.change(key: "remember-apples") { workspace in
            try workspace.listLayout.setDepartment("Fresh fruit", for: original.lines[0], in: original, remember: true)
            try workspace.listLayout.setDepartment("Private cooler", for: original.lines[1], in: original, remember: true)
        }
        XCTAssertTrue(remembered)
        var next = ShoppingLedger(basis: ShopBasis(branch: "Market North"))
        let apples = try next.addManualLine(name: "Apples", quantity: nil)
        let created = await model.change(key: "next-department-list") { workspace in
            workspace.shops.append(next)
            workspace.selectedShopID = next.id
        }
        XCTAssertTrue(created)
        let reopened = LedgerModel(databaseURL: url)
        await reopened.open()
        let shop = try XCTUnwrap(reopened.shop)
        XCTAssertEqual(shop, next)
        let scoped = try RecordsNativeCodec.ledgerScope(reopened.workspace, shop: shop)
        XCTAssertEqual(scoped.listLayout.groups(shop: shop, search: "fruit").flatMap(\.lines).map(\.id), [apples])
        let restored = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(scoped))
        XCTAssertEqual(restored.listLayout.groups(shop: shop).map(\.aisle), ["Fresh fruit"])
        let encoded = String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Private cooler"))
        XCTAssertEqual(reopened.workspace.shops.first, original)
    }

    func testNewStoreNameCorrectionsPreserveReorderedAisles() throws {
        let shop = try populated("Market A")
        var layout = LedgerListLayout()
        _ = try layout.matchStore(in: shop, to: nil)
        try layout.setStoreOrder(["Dairy", "Produce"], in: shop)
        var draft = LedgerDepartmentOrderDraft(layout: layout, shop: shop)
        draft.select(.new, scope: .storeDefault, in: layout, shop: shop)
        XCTAssertFalse(draft.isNameValid(in: layout), "The initial branch name already belongs to another store.")
        XCTAssertEqual(draft.aisles, ["Produce", "Dairy"])
        draft.name = "Another market"
        XCTAssertTrue(draft.isNameValid(in: layout))
        draft.aisles.swapAt(0, 1)
        draft.name = "Market A"
        XCTAssertFalse(draft.isNameValid(in: layout))
        XCTAssertEqual(draft.aisles, ["Dairy", "Produce"])
        draft.name = "Market A Annex"
        XCTAssertTrue(draft.isNameValid(in: layout))
        XCTAssertEqual(draft.aisles, ["Dairy", "Produce"])
        try draft.matchChosenStore(in: &layout, shop: shop)
        try layout.setStoreOrder(draft.aisles, in: shop)
        XCTAssertEqual(layout.aisleNames(in: shop), ["Dairy", "Produce"])
        XCTAssertEqual(layout.departmentDirectory?.stores.values.first { $0.name == "Market A Annex" }?.order, draft.aisles)
    }

    func testStoreOrderShopOverrideSearchAndOriginalIdentitySurviveRelaunch() throws {
        var a = try populated("Market A")
        let b = try populated("Market A"), other = try populated("Market B")
        var workspace = LedgerWorkspace(shops: [a,b,other], selectedShopID: a.id)
        workspace.listLayout.storeAisles["Market A"] = ["Dairy", "Produce"]
        for shop in workspace.shops {
            var layout = ShopListLayout(); layout.mode = .aisle; layout.branch = shop.basis.branch
            workspace.listLayout.shopLayouts[shop.id.uuidString.lowercased()] = layout
        }
        workspace.listLayout.shopLayouts[a.id.uuidString.lowercased()]?.aisleOverride = ["Produce","Dairy"]
        workspace.listLayout.storeAisles["Other private store"] = ["Private group"]
        workspace.listLayout.storeAisles["Market A"]?.append("Other shop aisle")
        let scoped = try RecordsNativeCodec.ledgerScope(workspace, shop:b)
        XCTAssertEqual(scoped.listLayout.storeAisles,["Market A":["Dairy","Produce"]])
        XCTAssertEqual(scoped.listLayout.shopLayouts.keys.sorted(),[b.id.uuidString.lowercased()])
        let before = a.lines.map(\.id)
        workspace = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(workspace.listLayout.groups(shop:b).map(\.aisle),["Dairy","Produce",""])
        XCTAssertEqual(workspace.listLayout.groups(shop:a).map(\.aisle),["Produce","Dairy",""])
        XCTAssertEqual(workspace.listLayout.groups(shop:other).map(\.aisle),["Produce","Dairy",""])
        XCTAssertEqual(workspace.listLayout.groups(shop:b, search:"Milk").flatMap(\.lines).map(\.id),[b.lines[1].id])
        workspace.listLayout.shopLayouts[a.id.uuidString.lowercased()]?.mode = .manual
        workspace.listLayout.shopLayouts[a.id.uuidString.lowercased()]?.lineOrder = Array(before.reversed())
        XCTAssertEqual(workspace.listLayout.groups(shop:a).flatMap(\.lines).map(\.id),Array(before.reversed()))
        try a.handle(lineID:before[0],by:"Sam"); try a.trash(lineID:before[1])
        XCTAssertEqual(workspace.listLayout.groups(shop:a).flatMap(\.lines).map(\.id),[before[2]])
        XCTAssertEqual(a.lines.map(\.id),before)
        workspace.listLayout.shopLayouts[a.id.uuidString.lowercased()]?.mode = .entered
        XCTAssertEqual(workspace.listLayout.groups(shop:workspace.shops[0]).flatMap(\.lines).map(\.id),before)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(workspace)) as? [String:Any])
        legacy.removeValue(forKey:"listLayout")
        let decoded = try JSONDecoder().decode(LedgerWorkspace.self,from:JSONSerialization.data(withJSONObject:legacy))
        XCTAssertEqual(decoded.listLayout,LedgerListLayout())
    }

    func testManualOrderPreservesHiddenPositionsThroughReorderAndReopen() throws {
        var shop = try populated("Corner Market")
        let ids = shop.lines.map(\.id)
        let checked = ids[0], handled = ids[1], trashed = ids[2]
        let first = try shop.addManualLine(name: "Wraps", quantity: nil)
        let second = try shop.addManualLine(name: "Wraps", quantity: nil)
        var layout = ShopListLayout()
        layout.mode = .manual
        // The trashed item and the second Wraps row have never been manually ranked.
        layout.lineOrder = [first, handled, checked]
        try shop.setChecked(lineID: checked, checked: true)
        try shop.handle(lineID: handled, by: "Shopper")
        try shop.trash(lineID: trashed)
        try layout.setActiveOrder([second, first], in: shop)
        XCTAssertEqual(layout.lineOrder, [second, handled, checked, trashed, first])
        XCTAssertThrowsError(try layout.setActiveOrder([first, first], in: shop))
        XCTAssertThrowsError(try layout.setActiveOrder([second], in: shop))
        try shop.reopen(lineID: checked)
        try shop.reopen(lineID: handled)
        try shop.restore(lineID: trashed)
        var saved = LedgerListLayout()
        saved.shopLayouts[shop.id.uuidString.lowercased()] = layout
        let restored = try JSONDecoder().decode(LedgerListLayout.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.groups(shop: shop).flatMap(\.lines).map(\.id), [second, handled, checked, trashed, first])
        XCTAssertEqual(shop.lines.map(\.id), ids + [first, second])
    }

    func testSystemPrintFormatterPaginatesAndOmitsPrivateNotesAndInactiveItems() throws {
        var shop = try populated("Corner Market")
        try shop.handle(lineID: shop.lines[1].id, by: "Private helper")
        for i in 1...35 { _ = try shop.addManualLine(name: "Package number \(i)", quantity: nil) }
        let literal = "<Flour> & \"Rice\""
        _ = try shop.addManualLine(name: literal, quantity: nil)
        var imported = try shop.stageImport(text: "2 15 oz (425 g) cans of beans, no salt added")
        // Keep the shopper's edited total distinct from the package facts on the original label.
        imported.lines[0].quantity = Quantity(amount: try Rational(45), unit: .ounce, originalLiteral: "45")
        try shop.commitImport(imported)
        let captured = CaptureImportLine(originalText: "Private transcription", name: "rolled oats", packCount: 3,
            amountPerPack: Quantity(amount: try Rational(12), unit: .ounce, originalLiteral: "12 oz"), purpose: "Private breakfast", exclusions: ["added salt", "added salt"])
        let uncertain = CaptureImportLine(originalText: "Maybe eight bags", name: "lentils", packCount: 8,
            amountPerPack: captured.amountPerPack, unresolvedFields: [.packCount])
        try shop.commitImport(shop.stageCaptureImport(id: UUID(), originalText: "Voice draft", source: .voice, lines: [captured, uncertain]))
        let hidden = try shop.addManualLine(name: "Private extra", quantity: nil, exclusions: ["retired restriction"])
        try shop.setChecked(lineID: hidden, checked: true)
        _ = try shop.addManualLine(name: "Crackers", quantity: nil, exclusions: ["<sesame> & nuts"])
        let listing = LargePrintList(shop: shop, layout: LedgerListLayout())
        let renderer = LetterPageRenderer(formatter: listing.printFormatter())
        let data = UIGraphicsPDFRenderer(bounds:renderer.paperRect).pdfData { context in
            let count = renderer.numberOfPages
            renderer.prepare(forDrawingPages:NSRange(location:0,length:count))
            for i in 0..<count { context.beginPage(); renderer.drawPage(at:i,in:renderer.paperRect) }
        }
        let pdf = try XCTUnwrap(PDFDocument(data:data))
        XCTAssertGreaterThan(pdf.pageCount,1)
        var numberedItems: [String] = []
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            let lines = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
            let folio = ledgerFormat("Page %lld of %lld", Int64(index + 1), Int64(pdf.pageCount))
            XCTAssertTrue(page.string?.contains(folio) == true)
            let footers = lines.filter { $0.string?.contains("Room in the Cart") == true }
            XCTAssertEqual(footers.count, 1, "Page \(index + 1)")
            let footer = try XCTUnwrap(footers.first).bounds(for: page)
            XCTAssertLessThan(footer.maxY, 70)
            let body = lines.filter {
                $0.string?.contains("Room in the Cart") == false && $0.string?.contains(folio) == false
            }
            numberedItems += body.compactMap(\.string).filter { $0.hasPrefix("Package number ") }
            if let last = body.last?.string {
                XCTAssertFalse(last.hasPrefix("Package number "), "Each item and its quantity must print on the same page")
            }
            XCTAssertFalse(body.isEmpty, "A footer must not create a blank page")
            XCTAssertTrue(body.allSatisfy { $0.bounds(for: page).minY > footer.maxY })
        }
        let text = try XCTUnwrap(pdf.string)
        for wanted in ["Corner Market","Apples","Soap","Package number 35",literal] { XCTAssertTrue(text.contains(wanted),wanted) }
        let ounce = UnitOfMeasure.ounce.displayName
        XCTAssertTrue(text.contains("beans, no salt added"))
        XCTAssertTrue(text.contains("45 " + ounce))
        XCTAssertTrue(text.contains(ledgerFormat("Original package label (%lld × %@)", Int64(2), "15 " + ounce)))
        XCTAssertTrue(text.contains(captureText("Packs") + ": 3"))
        XCTAssertTrue(text.contains(captureText("Usable amount per pack") + ": 12 " + ounce))
        XCTAssertFalse(text.contains(captureText("Packs") + ": 8"))
        XCTAssertEqual(text.components(separatedBy: ledgerFormat("Exclusions: %@", "added salt")).count - 1, 1)
        XCTAssertTrue(text.contains(ledgerFormat("Exclusions: %@", "<sesame> & nuts")))
        XCTAssertFalse(text.contains("retired restriction"))
        XCTAssertEqual(numberedItems, (1...35).map { "Package number \($0)" })
        for hidden in ["Private note","Private helper","Milk","Private transcription","Private breakfast","Maybe eight bags"] { XCTAssertFalse(text.contains(hidden),hidden) }
    }
}

private final class LetterPageRenderer: PickupPrintPageRenderer {
    override var paperRect: CGRect { CGRect(x:0,y:0,width:612,height:792) }
    override var printableRect: CGRect { paperRect.insetBy(dx:36,dy:36) }
}
