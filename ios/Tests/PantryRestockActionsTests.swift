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
        let measured = try PantryRestockReview.stage(food: "5 spice", text: "5 spice", source: .typed, id: UUID(), shop: shop,
                                                      suggestedAmount: Quantity(amount: try Rational(3), unit: .count, originalLiteral: "3"))
        XCTAssertEqual(measured.lines.first?.name, "5 spice")
        XCTAssertEqual(measured.lines.first?.quantity?.amount, try Rational(3))
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

    func testTwoManualRestocksAreIndependentAndReviewedOnceEach() throws {
        var shop = ShoppingLedger(title: "Friday")
        for food in ["Tortillas", "Beans"] {
            let workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id)
            XCTAssertEqual(PantryRestockReview.destination(food: food, workspace: workspace, closed: [], requestNames: []),
                           .shop(shop.id, shop.title))
            let draft = try PantryRestockReview.stage(food: food, text: food, source: .typed, id: UUID(), shop: shop)
            let row = try XCTUnwrap(draft.lines.first)
            XCTAssertNil(row.quantity)
            _ = try shop.commitImport(draft, decisions: [row.id: .addNew])
            _ = try shop.commitImport(draft, decisions: [row.id: .addNew])
        }
        XCTAssertEqual(shop.lines.map(\.name), ["Tortillas", "Beans"])
    }

    func testMinimumRestockCarriesAReviewedProductAcrossFirstAndExistingListsPlacementAndDelivery() throws {
        let product = UUID(), originalBatch = UUID(), scope = PantryDigestScope(origin: UUID(),
            identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        func q(_ n: Int64) throws -> Quantity { .init(amount: try Rational(n), unit: .count, originalLiteral: String(n)) }
        let minimum = PantryStapleMinimum(foodID: product, anchorLotID: originalBatch, target: try q(4), afterHolds: true)
        let token = minimum.productLink(in: scope), name = "5 spice"
        let now = Date()
        for firstList in [false, true] {
            var shop = ShoppingLedger()
            let staged: StagedListImport
            if firstList {
                var content = FirstListContents()
                content.shopID = shop.id; content.original = "Salt"; content.preview = try shop.stageImport(text: "Salt", importID: content.importID)
                let appended = try content.appending(name, pantryFood: true, shop: shop, pantrySuggestedAmount: q(3), pantryProductLink: token)
                staged = try XCTUnwrap(appended.preview)
            } else {
                staged = try PantryRestockReview.stage(food: name, text: name, source: .typed, id: UUID(), shop: shop,
                                                       suggestedAmount: q(3), productLink: token)
            }
            let row = try XCTUnwrap(staged.lines.first { $0.name == name })
            XCTAssertEqual(row.pantryProductLink, token)
            _ = try shop.commitImport(staged)
            _ = try shop.commitImport(staged)
            let line = try XCTUnwrap(shop.lines.first { $0.name == name })
            XCTAssertNotEqual(line.id, product)
            let order = try PickupLedger(orderID: UUID(), orderLines: [.init(id: line.id, branchID: "Main", name: name, ordered: q(3))])
            var journey = PickupJourney(id: shop.id, savedAt: now)
            journey.pickup = order
            journey.mealSource = .init(ledgerWorkspaceID: UUID(), shop: shop, needs: [], details: [], bindings: [])
            let reopened = try JSONDecoder().decode(PickupJourney.self, from: JSONEncoder().encode(journey))
            let linked = try XCTUnwrap(PantryPlacedProductLinks(journeys: [reopened]).byProduct[token])
            XCTAssertEqual(linked, [line.id])
            let arriving = try minimum.incoming([reopened], linkedLineIDs: linked)
            XCTAssertEqual(arriving?.amount, try Rational(3))
            XCTAssertEqual(minimum.proposal(shortfall: try q(3), incoming: arriving)?.amount, .zero)
            let key = ReceiptKey(sourceEventID: "delivery", orderLineID: line.id, branchID: "Main", segmentID: "1")
            _ = try journey.pickup?.receive(.init(key: key, itemName: name, received: q(3), disposition: .received, receivedAt: now))
            XCTAssertEqual(try minimum.incoming([journey], linkedLineIDs: linked)?.amount, .zero)
            func batch(_ foodID: UUID, _ count: Int64) throws -> InventoryLot {
                let id = UUID()
                return .init(id: id, foodID: foodID, name: name, source: .manual(originID: scope.origin, sourceID: id),
                             revision: 1, location: .cupboard, unit: .count, count: .exact(try q(count)),
                             observationID: UUID(), confirmedAt: now, updatedAt: now)
            }
            let lots = try [batch(product, 1), batch(line.id, 3)]
            let available = try InventoryProjection.build(originID: scope.origin, lots: lots, reservations: [], at: now)
            XCTAssertEqual(try minimum.shortfall(lots: lots, projection: available, linkedLineIDs: linked)?.amount, .zero)
            journey.mealSource = nil
            XCTAssertNil(PantryPlacedProductLinks(journeys: [journey]).byProduct[token], "Unlinked older orders have no product identity proof")
        }
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

extension PantryRestockActionsTests {
    @MainActor func testStandingCheckMissedFridaysTravelAndConcurrentAnswersWithoutInventoryHistory() throws {
        let zone = "America/Mexico_City"
        let friday = try MealDay(year: 2026, month: 11, day: 6, timeZoneIdentifier: zone)
        let check = try PantryStandingCheck(name: "  Café   molido  ", weeks: 2, first: friday)
        // The device is already on Saturday in Tokyo. The schedule still belongs to Friday in Mexico.
        let travel = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T04:00:00Z"))
        XCTAssertEqual(check.name, "Café molido")
        XCTAssertTrue(check.due(at: travel))
        XCTAssertFalse(check.due(at: friday.date!.addingTimeInterval(-86_400)))
        XCTAssertEqual(try check.answering(.skipped, at: travel).next.iso8601, "2026-12-04")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PantryDigestStore(folder: folder, scheduler: PantryDigestNotifications(isolated: true))
        let scope = PantryDigestScope(origin: UUID(), identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let access = PantryDigestAccess(scope: scope) { true }
        try store.updateStandingCheck(nil, next: check, access: access)
        var pending = check
        var shop = ShoppingLedger(title: "Friday")
        pending.adding = .init(workspace: UUID(), shop: shop.id, createFirst: false)
        try store.updateStandingCheck(check, next: pending, access: access)
        XCTAssertThrowsError(try store.updateStandingCheck(check, next: check.answering(.have, at: travel), access: access))
        try pending.addToTrip(&shop)
        try pending.addToTrip(&shop)
        XCTAssertEqual(shop.lines.map(\.name), ["Café molido"])
        XCTAssertNil(shop.contributions(forLineID: shop.lines[0].id).first?.quantity)
        XCTAssertEqual(shop.importBatches.map(\.id), [check.occurrence])
        let reopened = PantryDigestStore(folder: folder, scheduler: PantryDigestNotifications(isolated: true))
        XCTAssertEqual(try reopened.document(scope).standingChecks, [pending])
        let next = try pending.answering(.shopping, at: travel)
        try reopened.updateStandingCheck(pending, next: next, access: access)
        XCTAssertThrowsError(try reopened.updateStandingCheck(pending, next: next, access: access))
        var sameItem = try PantryStandingCheck(name: "CAFÉ MOLIDO", weeks: 1, first: friday)
        try sameItem.addToTrip(&shop)
        XCTAssertEqual(shop.lines.count, 1)
        sameItem = try sameItem.answering(.have, at: travel)
        XCTAssertFalse(sameItem.due(at: travel))
        let saved = try reopened.document(scope)
        XCTAssertFalse(saved.enabled)
        XCTAssertTrue(saved.rules.isEmpty)
    }
}
