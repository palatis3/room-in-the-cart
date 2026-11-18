import CoreDomain
import XCTest
@testable import RoomInTheCart

@MainActor final class PantryRestockActionsTests: XCTestCase {
    func testNoShopAndChangingSelectionsUseTheReviewedOpenPickup() throws {
        let food = "Ketchup"
        let first = ShoppingLedger(title: "Friday"), second = ShoppingLedger(title: "Saturday")
        var workspace = LedgerWorkspace()
        func review(closed: Set<UUID> = [], requests: [String] = []) -> PantryRestockReview {
            PantryRestockReview.destination(food: food, workspace: workspace, closed: closed, requestNames: requests)
        }
        XCTAssertEqual(review(), .firstList)
        XCTAssertEqual(PantryRestockReview.destination(food: food, workspace: workspace, closed: [],
            requestNames: [], sharedLineNames: ["Ketchup"]), .onList)
        XCTAssertEqual(review(requests: ["ketchup"]), .pendingRequest)
        workspace = LedgerWorkspace(shops: [first, second], selectedShopID: first.id)
        XCTAssertEqual(review(), .shop(first.id, first.title))
        XCTAssertEqual(review(closed: [first.id]), .chooseShop)
        workspace.selectedShopID = second.id
        XCTAssertEqual(review(), .shop(second.id, second.title))
        var updated = first
        let line = try updated.addManualLine(name: "  KÉTCHUP ", quantity: nil)
        workspace.shops[0] = updated
        XCTAssertEqual(review(), .onList)
        XCTAssertEqual(review(closed: [first.id]), .shop(second.id, second.title))
        try updated.setChecked(lineID: line, checked: true)
        workspace.shops[0] = updated
        XCTAssertEqual(review(requests: ["Tomato ketchup"]), .shop(second.id, second.title))
        XCTAssertEqual(review(requests: ["ketchup"]), .pendingRequest)
    }

    func testLiteralFoodStartsWithoutPurchaseAmountAndRetryKeepsOneLine() throws {
        XCTAssertEqual(PantryRestockReview.foodName("5\nspice"), "5 spice")
        var shop = ShoppingLedger()
        let draft = try PantryRestockReview.stage(food: "5 spice", text: "5 spice", source: .typed, id: UUID(), shop: shop)
        let row = try XCTUnwrap(draft.lines.first)
        XCTAssertEqual(row.name, "5 spice")
        XCTAssertNil(row.quantity)
        XCTAssertNil(row.originalPack)
        XCTAssertTrue(PantryRestockReview.draftIncludes(food: "5 spice", text: "apples\n5 SPICE", preview: nil))
        XCTAssertTrue(PantryRestockReview.draftIncludes(food: "5 SPICE", text: "", preview: draft))
        XCTAssertFalse(PantryRestockReview.draftIncludes(food: "5 spice", text: "apples", preview: nil))
        XCTAssertTrue(shop.lines.isEmpty)
        let decisions: [UUID: ImportResolution] = [row.id: .addNew]
        _ = try shop.commitImport(draft, decisions: decisions)
        _ = try shop.commitImport(draft, decisions: decisions)
        XCTAssertEqual(shop.lines.count, 1)
        let existing = try XCTUnwrap(shop.lines.first)
        XCTAssertNil(try shop.quantity(forLineID: existing.id))
        let again = try PantryRestockReview.stage(food: "5 spice", text: "5 spice\n2 wraps", source: .typed, id: UUID(), shop: shop)
        XCTAssertEqual(again.lines.first?.duplicateLineIDs, [existing.id])
        XCTAssertEqual(again.lines.last?.quantity?.amount, try Rational(2))
    }

    func testRunningLowCheckDateSurvivesDeniedPermissionAndCannotBeDuplicatedOrSavedAfterLock() async throws {
        let origin = UUID(), lotID = UUID(), time = Date()
        let lot = InventoryLot(id: lotID, foodID: UUID(), name: "Ketchup", source: .manual(originID: origin, sourceID: lotID),
            revision: 1, location: .fridge, openedAt: nil, unit: .count, count: .someLeft,
            observationID: UUID(), confirmedAt: time, updatedAt: time, useFirst: false)
        XCTAssertTrue(PantryRestockReview.canSetCheckDate(for: lot))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PantryDigestStore(folder: folder, scheduler: PantryDigestNotifications(isolated: true))
        let scope = PantryDigestScope(origin: origin, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let day = try MealDay(date: time.addingTimeInterval(86_400), timeZoneIdentifier: "America/New_York")
        try await store.saveDay(scope, lot: lot, day: day, authorized: { true })
        let saved = try store.document(scope)
        try await store.saveDay(scope, lot: lot, day: day, authorized: { true })
        XCTAssertFalse(saved.enabled)
        XCTAssertEqual(saved.rules.map(\.lotID), [lot.id])
        XCTAssertEqual(try store.document(scope), saved)
        do {
            try await store.setAlerts(scope, enabled: true, minute: 720, authorized: { true })
            XCTFail("A denied notification permission cannot enable delivery")
        } catch PantryDigestFailure.denied {}
        do {
            try await store.saveDay(scope, lot: lot, day: nil, authorized: { false })
            XCTFail("A lost workspace cannot edit the saved date")
        } catch PantryDigestFailure.changed {}
        XCTAssertEqual(try store.document(scope), saved)
    }
}
