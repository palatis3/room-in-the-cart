import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

/// Uses the same model operations as the shipping screens, with fresh model
/// instances at each durable boundary. No membership or network fixture is used.
final class FreeJourneyAcceptanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor func testFreeManualJourneySurvivesRestartFromMealsThroughNextShop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), clock: { self.now })
        var pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { self.now })
        await ledger.open(); await pickup.load()
        try requireSaved(await ledger.startShop(title: "Tuesday pickup"))
        let shopID = try XCTUnwrap(ledger.shop?.id)
        let reusable = MealTemplate(title: "Tacos", servings: try Rational(3),
            ingredients: [MealIngredient(name: "Wraps", quantity: quantity(6), exclusions: ["No sesame"])],
            sourceURL: "https://example.test/family-tacos", leadTimeMinutes: 20)
        try requireSaved(await ledger.change(key: "save-usual-dinner") { $0.mealTemplates = [reusable] })
        try requireSaved(await ledger.editShop(key: "review-meals-and-lunch", shopID: shopID) { shop in
            try shop.updateBasis(ShopBasis(branch: "Main branch", mode: .pickup, slot: self.now,
                timeZoneIdentifier: "America/New_York", cap: Money(minorUnits: 700)))
            let line = try shop.addManualLine(name: "Wraps", quantity: self.quantity(12))
            let source = try XCTUnwrap(shop.contributions(forLineID: line).first?.id)
            for meal in [reusable, MealTemplate(title: "Quesadillas", servings: try Rational(2), ingredients: [MealIngredient(name: "Wraps", quantity: self.quantity(4))])] {
                let occurrenceID = try shop.chooseMeal(meal)
                let demandID = try XCTUnwrap(shop.mealOccurrences.first { $0.id == occurrenceID }?.ingredientContributionIDs.first)
                try shop.linkContribution(contributionID: demandID, within: source, quantity: meal.ingredients[0].quantity!)
            }
            try shop.addProtectedNeed(name: "Wraps", quantity: self.quantity(2), purpose: "Tomorrow’s lunch", within: source)
            try shop.addManualLine(name: "Coffee", quantity: self.quantity(1))
        })
        let savedShop = try XCTUnwrap(ledger.shop)
        let mealIDs = savedShop.mealOccurrences.map(\.id)
        ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        await ledger.open()
        XCTAssertEqual(ledger.shop, savedShop)
        XCTAssertEqual(ledger.shop?.mealOccurrences.map(\.id), mealIDs)
        XCTAssertTrue(ledger.shop?.mealOccurrences.allSatisfy { $0.scheduledDay == nil } == true)
        XCTAssertEqual(ledger.workspace.mealTemplates.first?.sourceURL, reusable.sourceURL)

        // Choosing whole packs persists reviewed item evidence in the ledger.
        // The separate checkout store changes only after its explicit review.
        let wraps = try XCTUnwrap(savedShop.lines.first { $0.name == "Wraps" })
        let packReview = try LedgerPackReview.prepare(ledger: ledger, shopID: shopID, lineID: wraps.id,
            offerA: PackOffer(id: "eight", label: "8 wraps", usableQuantity: quantity(8), price: Money(minorUnits: 300)),
            offerB: PackOffer(id: "six", label: "6 wraps", usableQuantity: quantity(6), price: Money(minorUnits: 200)),
            itemCap: nil, at: now, source: "Reviewed family market shelf")
        XCTAssertEqual(packReview.result.offerA.packsToBuy, 2)
        XCTAssertEqual(packReview.result.offerB.packsToBuy, 2)
        XCTAssertEqual(packReview.result.offerB.purchasedAmount, try Rational(12))
        XCTAssertEqual(packReview.result.offerB.totalCost, Money(minorUnits: 400))
        XCTAssertEqual(packReview.result.scope, .itemOnly)
        try requireSaved(try await packReview.save(offerID: "six", ledger: ledger))
        let selectedPacks = ledger.workspace.packSelections
        XCTAssertEqual(selectedPacks.count, 1)
        XCTAssertNil(pickup.journey)
        ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        await ledger.open()
        XCTAssertEqual(ledger.workspace.packSelections, selectedPacks)
        let review = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: nil,
            packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        XCTAssertEqual(review.lines.first { $0.id == wraps.id }?.expectedCost, .exact(Money(minorUnits: 400)))
        try requireSaved(try await LedgerCheckoutAdapter.apply(review, ledger: ledger, pickup: pickup))
        XCTAssertEqual(pickup.journey?.plannedNeeds.filter { $0.priority == .protected }.first?.amount.amount, try Rational(2))
        let coffee = try XCTUnwrap(review.lines.first { $0.name == "Coffee" })
        try requireSaved(await pickup.change { $0.flexible.insert(coffee.id) })
        let quote = CheckoutQuote(scope: .wholeCheckout, context: review.context, pricing: .components(
            lines: [CheckoutLine(id: wraps.id, name: "Wraps", cost: .exact(Money(minorUnits: 400))), CheckoutLine(id: coffee.id, name: "Coffee", cost: .exact(Money(minorUnits: 460)))],
            lineSetComplete: true, fees: [CheckoutFee(id: "pickup", rule: .fixed(.exact(Money(minorUnits: 240))))], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)))
        try requireSaved(await pickup.setQuote(quote, cap: review.cap))
        XCTAssertEqual(pickup.result?.total.exact, Money(minorUnits: 1100))
        let deferral = try pickup.deferralPreview([coffee.id])
        try requireSaved(await pickup.applyDeferral(deferral.0))
        XCTAssertEqual(pickup.result?.total.exact, Money(minorUnits: 640))
        let protectedID = try XCTUnwrap(pickup.journey?.plannedNeeds.first { $0.priority == .protected }?.id)
        try requireSaved(await pickup.freeze())
        let frozen = try XCTUnwrap(pickup.frozenSnapshot)
        try requireSaved(await pickup.recordHandoff(.copied))
        XCTAssertNil(pickup.journey?.pickup, "Copying does not report an external placement")
        pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { self.now })
        await pickup.load()
        XCTAssertEqual(pickup.frozenSnapshot, frozen)
        XCTAssertEqual(pickup.journey?.ledgerPackSelections, selectedPacks)
        try requireSaved(await pickup.reportPlaced())
        let placed = try XCTUnwrap(pickup.journey)
        XCTAssertEqual(placed.needs.first { $0.id == protectedID }?.amount.amount, try Rational(2))
        try requireSaved(await pickup.reportPlaced())
        XCTAssertEqual(pickup.journey?.basket?.placements.count, 1)
        XCTAssertEqual(pickup.frozenSnapshot, frozen)

        let key = ReceiptKey(sourceEventID: "receipt-1", orderLineID: wraps.id, branchID: review.context.branchID, segmentID: "actual-segment-1")
        let arrival = ReceiptFragment(key: key, itemName: "Wraps", received: quantity(6), disposition: .partial, receivedAt: now)
        try requireSaved(await pickup.receive(arrival, usable: nil))
        XCTAssertEqual(pickup.allocation?.demands.first { $0.id == protectedID }?.allocated, .zero,
            "A package arrival alone does not confirm usable food")
        let usable = UsableObservation(id: UUID(), receipt: key, usable: quantity(6), confirmedAt: now, confirmedMatchToOrderLine: true)
        try requireSaved(await pickup.confirmUsable(usable))
        try requireSaved(await pickup.receive(arrival, usable: usable))
        XCTAssertEqual(pickup.journey?.pickup?.receipts.count, 1)
        XCTAssertEqual(pickup.allocation?.demands.first { $0.id == protectedID }?.shortfall, .zero)
        XCTAssertEqual(try totalShortfall(pickup), try Rational(6))
        let lot = ConfirmedStockLot(id: UUID(), foodID: wraps.id, name: "Four checked freezer wraps", usable: quantity(4), confirmedAt: now, source: .freezer)
        try requireSaved(await pickup.change { $0.stockLots.append(lot) })
        XCTAssertEqual(try totalShortfall(pickup), try Rational(2))
        let remaining = try XCTUnwrap(pickup.allocation?.demands.first { $0.shortfall != .zero })
        let repair = PickupRepair(id: UUID(), needID: remaining.id,
            instruction: "Set aside two wraps for tomorrow’s lunch. Use the four checked freezer wraps. Two dinner wraps remain short; confirm a separate repair before cooking. No sesame.",
            createdAt: now, extraTripAgreed: false, repeatMealAgreed: false, elapsedMinutes: 20, due: now.addingTimeInterval(3600))
        try requireSaved(await pickup.change { $0.repairs.append(repair) })
        XCTAssertEqual(try totalShortfall(pickup), try Rational(2), "A repair note is not new food")
        let beforeCook = try XCTUnwrap(pickup.journey)
        let cookText = PickupCookProjection.text(journey: beforeCook, allocation: pickup.allocation,
            result: pickup.result, language: "en-US", at: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(cookText.contains("set aside first"))
        XCTAssertTrue(cookText.contains("No sesame"))
        XCTAssertTrue(cookText.contains("Short or unverified amount. Review."))
        XCTAssertTrue(cookText.contains(repair.instruction))
        XCTAssertFalse(cookText.contains("Private budget included"))
        XCTAssertEqual(pickup.journey, beforeCook, "Preparing a cook copy cannot mutate food or send history")
        let note = PickupCookNote(id: UUID(), text: cookText, language: "en-US", createdAt: now, revision: beforeCook.revision)
        try requireSaved(await pickup.change { $0.notes.append(note) })
        try requireSaved(await pickup.change { $0.cookShareEvents.append(PickupCookShareEvent(id: UUID(), noteID: note.id, occurredAt: self.now, action: .shareCancelled, destination: nil)) })
        XCTAssertNil(pickup.journey?.notes.first?.sentAt)
        pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { self.now })
        await pickup.load()
        XCTAssertEqual(pickup.journey?.notes.first, note)
        XCTAssertEqual(pickup.journey?.repairs.first, repair)
        XCTAssertEqual(try totalShortfall(pickup), try Rational(2))

        let charge = SettlementEntry(id: UUID(), evidenceKey: "charge-net-440", kind: .postedCharge, amount: Money(minorUnits: 440), occurredAt: now)
        let pending = SettlementEntry(id: UUID(), evidenceKey: "credit-pending", kind: .pendingCredit, amount: Money(minorUnits: 200), occurredAt: now, creditID: "short-fill-credit", chargeEvidenceKey: charge.evidenceKey)
        try requireSaved(await pickup.settle(charge))
        try requireSaved(await pickup.settle(pending))
        XCTAssertEqual(try pickup.journey?.settlement.summary().paidSoFar, Money(minorUnits: 440))
        XCTAssertEqual(try pickup.journey?.settlement.summary().pendingCredits, Money(minorUnits: 200))
        let included = SettlementEntry(id: UUID(), evidenceKey: "credit-included", kind: .includedCredit, amount: Money(minorUnits: 200), occurredAt: now, creditID: "short-fill-credit", chargeEvidenceKey: charge.evidenceKey)
        try requireSaved(await pickup.settle(included))
        try requireSaved(await pickup.settle(included))
        XCTAssertEqual(try pickup.journey?.settlement.summary().paidSoFar, Money(minorUnits: 440))
        XCTAssertEqual(try pickup.journey?.settlement.summary().pendingCredits, .zero)
        XCTAssertEqual(try pickup.journey?.settlement.summary().includedCredits, Money(minorUnits: 200))
        XCTAssertEqual(try totalShortfall(pickup), try Rational(2), "Refunds cannot resolve food shortfalls")
        let deferredID = try XCTUnwrap(pickup.journey?.deferred.first?.id)
        try requireSaved(await pickup.change { value in
            value.deferred[0].status = "handled"; value.closedAt = self.now
        })
        let closed = try XCTUnwrap(pickup.journey)
        try requireSaved(await pickup.startNextShop(accept: [deferredID]))
        let next = try XCTUnwrap(pickup.journey)
        XCTAssertNotEqual(next.id, shopID)
        XCTAssertEqual(next.originShopID, shopID)
        XCTAssertTrue(next.basket?.current.lines.isEmpty == true, "Handled coffee must not become a purchase")
        XCTAssertEqual(next.carriedMeals.map(\.amount.amount), [try Rational(2)])
        XCTAssertTrue(next.stockLots.isEmpty)
        XCTAssertNil(next.quote); XCTAssertNil(next.pickup); XCTAssertNil(next.context)
        XCTAssertTrue(next.offers.isEmpty); XCTAssertTrue(next.settlement.entries.isEmpty)
        try requireSaved(await LedgerCheckoutAdapter.openNextShop(next, ledger: ledger))
        try requireSaved(await ledger.editShop(key: "choose-one-free-dinner", shopID: next.id) { _ = try $0.chooseMeal(reusable) })
        let nextMeal = try XCTUnwrap(ledger.shop?.mealOccurrences.first)
        XCTAssertEqual(nextMeal.templateID, reusable.id)
        XCTAssertFalse(mealIDs.contains(nextMeal.id))
        pickup.selectedID = shopID
        try requireSaved(await pickup.startNextShop(accept: [deferredID]))
        XCTAssertEqual(pickup.journey?.id, next.id)
        XCTAssertEqual(pickup.journeys.first { $0.id == shopID }, closed)
        ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { self.now })
        await ledger.open(); await pickup.load()
        XCTAssertEqual(ledger.shop?.id, next.id)
        XCTAssertEqual(ledger.shop?.mealOccurrences.first?.id, nextMeal.id)
        XCTAssertEqual(ledger.workspace.shops.first { $0.id == shopID }, savedShop)
        XCTAssertEqual(ledger.workspace.packSelections, selectedPacks)
        XCTAssertEqual(pickup.journeys.first { $0.id == shopID }?.ledgerPackSelections, selectedPacks)
        XCTAssertEqual(pickup.journeys.first { $0.id == shopID }, closed)
        XCTAssertEqual(pickup.journeys.first { $0.id == next.id }?.carriedMeals, next.carriedMeals)
        XCTAssertEqual(pickup.journeys.count, 2)
    }

    @MainActor func testWrongItemCannotFeedLunchAndLateSegmentRetryNeverDuplicatesFood() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var actualTime = now
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { actualTime })
        let shopID = UUID(), lineID = UUID(), lunchID = UUID(), dinnerID = UUID()
        let context = CheckoutContext(storeID: "Store", branchID: "Main", mode: .pickup, slot: "Tuesday", commitmentsID: shopID, observedAt: now, source: "Reviewed")
        try requireSaved(await pickup.start(from: [BasketLine(id: lineID, name: "Wraps", quantity: quantity(8), expectedCost: .exact(Money(minorUnits: 400)))], shopID: shopID, context: context,
            plannedNeeds: [AllocationNeed(id: dinnerID, orderLineID: lineID, name: "Dinner", amount: quantity(6), priority: .required), AllocationNeed(id: lunchID, orderLineID: lineID, name: "Lunch", amount: quantity(2), priority: .protected)]))
        try requireSaved(await pickup.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 400)))), cap: nil))
        try requireSaved(await pickup.freeze()); try requireSaved(await pickup.reportPlaced())
        let wrongKey = ReceiptKey(sourceEventID: "receipt", orderLineID: lineID, branchID: "Main", segmentID: "wrong")
        try requireSaved(await pickup.receive(ReceiptFragment(key: wrongKey, itemName: "Sesame wraps", received: quantity(8), disposition: .wrongItem, receivedAt: now), usable: UsableObservation(id: UUID(), receipt: wrongKey, usable: quantity(8), confirmedAt: now, confirmedMatchToOrderLine: false)))
        XCTAssertEqual(try totalShortfall(pickup), try Rational(8))
        let lateKey = ReceiptKey(sourceEventID: "receipt", orderLineID: lineID, branchID: "Main", segmentID: "actual-second-segment")
        let fragment = ReceiptFragment(key: lateKey, itemName: "Correct wraps", received: quantity(6), disposition: .late, receivedAt: now.addingTimeInterval(3600))
        let usable = UsableObservation(id: UUID(), receipt: lateKey, usable: quantity(6), confirmedAt: now.addingTimeInterval(3600), confirmedMatchToOrderLine: true)
        actualTime = now.addingTimeInterval(3600)
        try requireSaved(await pickup.receive(fragment, usable: usable))
        let reopened = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { actualTime })
        await reopened.load()
        try requireSaved(await reopened.receive(fragment, usable: usable))
        XCTAssertEqual(reopened.journey?.pickup?.receipts.count, 2)
        XCTAssertEqual(reopened.allocation?.demands.first { $0.id == lunchID }?.shortfall, .zero)
        XCTAssertEqual(try totalShortfall(reopened), try Rational(2))
        XCTAssertEqual(reopened.journey?.settlement.entries.count, 0)
    }

    func testInjectedPickupLocationNeverResolvesDefaultSupportOrHonorsResetFlags() throws {
        let injected = URL(fileURLWithPath: "/tmp/acceptance-injected/nested/pickup.sqlite")
        let location = try PickupPersistenceLocation.resolve(databaseURL: injected,
            arguments: ["--ui-testing", "--reset-test-workspace"]) {
                XCTFail("An injected test database must not touch the default application-support directory")
                throw CocoaError(.fileWriteNoPermission)
            }
        XCTAssertEqual(location.databaseURL, injected)
        XCTAssertFalse(location.resetTestDatabase)
        let support = URL(fileURLWithPath: "/tmp/default-support")
        let normal = PickupPersistenceLocation.resolve(databaseURL: nil, arguments: []) { support }
        let resetOnly = PickupPersistenceLocation.resolve(databaseURL: nil, arguments: ["--reset-test-workspace"]) { support }
        XCTAssertEqual(normal.databaseURL, support.appendingPathComponent("RoomInTheCart/pickup.sqlite"))
        XCTAssertEqual(resetOnly.databaseURL, normal.databaseURL)
        XCTAssertFalse(resetOnly.resetTestDatabase)
        #if DEBUG
        let isolated = PickupPersistenceLocation.resolve(databaseURL: nil, arguments: ["--ui-testing", "--reset-test-workspace"]) { support }
        XCTAssertEqual(isolated.databaseURL, support.appendingPathComponent("UITestWorkspace/pickup.sqlite"))
        XCTAssertTrue(isolated.resetTestDatabase)
        let restart = PickupPersistenceLocation.resolve(databaseURL: nil, arguments: ["--ui-testing"]) { support }
        XCTAssertEqual(restart.databaseURL, isolated.databaseURL)
        XCTAssertFalse(restart.resetTestDatabase)
        #endif
    }

    @MainActor func testInjectedNestedPickupCreatesItsOwnDirectoryAndSurvivesResetArguments() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("previously-missing/isolated/pickup.sqlite")
        let arguments = ["--ui-testing", "--reset-test-workspace"]
        let first = PickupModel(databaseURL: url, clock: { self.now }, launchArguments: arguments)
        try requireSaved(await first.addUrgent(UrgentMealNeed(id: UUID(), food: "Rice", meal: "Dinner", required: quantity(4), available: quantity(2), due: nil, confirmedAt: now)))
        let saved = try XCTUnwrap(first.journey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reopened = PickupModel(databaseURL: url, clock: { self.now }, launchArguments: arguments)
        await reopened.load()
        XCTAssertTrue(reopened.ready)
        XCTAssertEqual(reopened.journey, saved)
    }

    @MainActor func testHandledAndDismissedCarryoversUseSourceIdentityInsteadOfName() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pickup.sqlite")
        let pickup = PickupModel(databaseURL: url, clock: { self.now })
        try requireSaved(await pickup.addUrgent(UrgentMealNeed(id: UUID(), food: "Rice", meal: "Dinner", required: quantity(4), available: quantity(4), due: nil, confirmedAt: now)))
        let origin = try XCTUnwrap(pickup.journey?.id)
        let lines = (0..<3).map { _ in BasketLine(id: UUID(), name: "Coffee", quantity: quantity(1), expectedCost: .exact(Money(minorUnits: 460))) }
        let decisions = zip(lines, ["handled", "dismissed", "review"]).map { line, status in DeferredPickupNeed(id: UUID(), sourceShopID: origin, line: line, status: status) }
        let needs = lines.map { AllocationNeed(id: UUID(), orderLineID: $0.id, name: $0.name, amount: $0.quantity, priority: .required) }
        try requireSaved(await pickup.change { $0.deferred = decisions; $0.carriedMeals = needs })
        let before = try XCTUnwrap(pickup.journey)
        try requireSaved(await pickup.startNextShop(accept: []))
        let next = try XCTUnwrap(pickup.journey)
        XCTAssertEqual(next.carriedMeals, [needs[2]])
        XCTAssertEqual(next.deferred.map(\.id), [decisions[2].id])
        XCTAssertEqual(next.deferred.first?.line.quantity, decisions[2].line.quantity)
        guard case .unknown = next.deferred.first?.line.expectedCost else { return XCTFail("A new trip needs fresh pricing") }
        let reopened = PickupModel(databaseURL: url, clock: { self.now })
        await reopened.load()
        reopened.selectedID = origin
        try requireSaved(await reopened.startNextShop(accept: []))
        XCTAssertEqual(reopened.journey, next)
        XCTAssertEqual(reopened.journeys.first { $0.id == origin }, before)
        XCTAssertEqual(reopened.journeys.count, 2)
    }

    @MainActor func testFreshHandledAndDismissedChoicesDoNotReviveLinkedMealNeeds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pickup.sqlite")
        let pickup = PickupModel(databaseURL: url, clock: { self.now })
        try requireSaved(await pickup.addUrgent(UrgentMealNeed(id: UUID(), food: "Rice", meal: "Dinner", required: quantity(4), available: quantity(4), due: nil, confirmedAt: now)))
        let origin = try XCTUnwrap(pickup.journey?.id)
        let lines = (0..<3).map { _ in BasketLine(id: UUID(), name: "Coffee", quantity: quantity(1), expectedCost: .exact(Money(minorUnits: 460))) }
        let deferred = lines.map { DeferredPickupNeed(id: UUID(), sourceShopID: origin, line: $0, status: "review") }
        let needs = lines.map { AllocationNeed(id: UUID(), orderLineID: $0.id, name: $0.name, amount: $0.quantity, priority: .required) }
        try requireSaved(await pickup.change { $0.deferred = deferred; $0.carriedMeals = needs })
        let before = try XCTUnwrap(pickup.journey)
        let closing: [UUID: NextShopDisposition] = [deferred[0].id: .handled, deferred[1].id: .dismissed]
        try requireSaved(await pickup.startNextShop(accept: [], closing: closing, sourceID: origin, sourceRevision: before.revision))
        let next = try XCTUnwrap(pickup.journey)
        XCTAssertEqual(next.carriedMeals, [needs[2]], "Fresh closing choices must remove only their source-linked meal needs")
        XCTAssertEqual(next.deferred.map(\.status), ["handled", "dismissed", "review"])
        XCTAssertEqual(next.deferred.map(\.id), deferred.map(\.id))
        XCTAssertTrue(try XCTUnwrap(next.basket?.current.lines).isEmpty)
        let reopened = PickupModel(databaseURL: url, clock: { self.now })
        await reopened.load()
        XCTAssertEqual(reopened.journeys.first { $0.id == next.id }, next)
        reopened.selectedID = origin
        try requireSaved(await reopened.startNextShop(accept: [], closing: closing, sourceID: origin, sourceRevision: before.revision))
        XCTAssertEqual(reopened.journey, next)
        XCTAssertEqual(reopened.journeys.first { $0.id == origin }, before)
        XCTAssertEqual(reopened.journeys.count, 2)
    }

    @MainActor func testReviewedNextShopDispositionIsScopedAndNeverRewritesSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PickupModel(databaseURL: directory.appendingPathComponent("next.sqlite"), clock: { self.now })
        try requireSaved(await model.addUrgent(UrgentMealNeed(id: UUID(), food: "Coffee", meal: "Breakfast", required: quantity(1), available: quantity(0), due: nil, confirmedAt: now)))
        let sourceID = try XCTUnwrap(model.journey?.id), key = UUID()
        let line = BasketLine(id: UUID(), name: "Coffee", quantity: quantity(1), expectedCost: .exact(Money(minorUnits: 460)))
        try requireSaved(await model.change { $0.deferred = [DeferredPickupNeed(id: key, sourceShopID: sourceID, line: line, status: "review")] })
        let before = try XCTUnwrap(model.journey)
        let rejected = await model.startNextShop(accept: [], closing: [key: .handled], sourceID: sourceID, sourceRevision: before.revision - 1)
        XCTAssertFalse(rejected)
        XCTAssertEqual(model.journey, before)
        try requireSaved(await model.startNextShop(accept: [], closing: [key: .handled], sourceID: sourceID, sourceRevision: before.revision))
        XCTAssertTrue(try XCTUnwrap(model.journey?.basket?.current.lines).isEmpty)
        XCTAssertEqual(model.journey?.deferred.first?.status, "handled")
        XCTAssertFalse(model.reminderJourneys.contains(where: { $0.id == sourceID }))
        XCTAssertEqual(model.journeys.first { $0.id == sourceID }, before)
    }

    @MainActor func testConcurrentPickupChangesAndCompetingNextShopsRequireAFreshReview() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("shared-pickup.sqlite")
        let first = PickupModel(databaseURL: database, clock: { self.now }), second = PickupModel(databaseURL: database, clock: { self.now })
        try requireSaved(await first.addUrgent(UrgentMealNeed(id: UUID(), food: "Milk", meal: "Breakfast", required: quantity(2), available: quantity(0), due: nil, confirmedAt: now)))
        await second.load()
        let source = try XCTUnwrap(first.journey?.id)
        let deferred = DeferredPickupNeed(id: UUID(), sourceShopID: source,
                                         line: BasketLine(id: UUID(), name: "Coffee", quantity: quantity(1), expectedCost: .exact(.zero)),
                                         status: "review")
        try requireSaved(await first.change { $0.deferred.append(deferred) })
        let stale = await second.startNextShop(accept: [], sourceID: source, sourceRevision: try XCTUnwrap(second.journey?.revision))
        XCTAssertFalse(stale)
        XCTAssertFalse(second.hasPendingSave)
        XCTAssertEqual(second.journey?.deferred.first?.id, deferred.id)
        let revision = try XCTUnwrap(second.journey?.revision)
        try requireSaved(await first.startNextShop(accept: [], closing: [deferred.id: .handled], sourceID: source, sourceRevision: revision))
        let draft = try XCTUnwrap(first.journey?.id)
        let lostRace = await second.startNextShop(accept: [deferred.id], sourceID: source, sourceRevision: revision)
        XCTAssertFalse(lostRace)
        XCTAssertEqual(second.journeys.count, 2)
        let changedIntent = await second.startNextShop(accept: [deferred.id], sourceID: source, sourceRevision: revision)
        XCTAssertFalse(changedIntent)
        try requireSaved(await second.startNextShop(accept: [], closing: [deferred.id: .handled], sourceID: source, sourceRevision: revision))
        XCTAssertEqual(second.selectedID, draft)
        XCTAssertTrue(try XCTUnwrap(second.journey?.basket?.current.lines).isEmpty)
        try requireSaved(await first.change { $0.closedAt = self.now })
        let staleEdit = await second.change { $0.closedAt = self.now.addingTimeInterval(10) }
        XCTAssertFalse(staleEdit)
        XCTAssertEqual(second.journey?.closedAt, now)
    }

    @MainActor func testCurrentDinnerFeatureFreeReusableChoiceProjectsLunchAndSurvivesNewShopRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerURL = directory.appendingPathComponent("ledger.sqlite")
        var ledger = LedgerModel(databaseURL: ledgerURL)
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { self.now })
        await ledger.open(); await pickup.load()
        try requireSaved(await ledger.startShop(title: "First shop"))
        var feature = dinnerFeature(ledger: ledger, pickup: pickup)
        let acceptedID = UUID()
        let template = MealTemplate(title: "Wrap dinner", servings: try Rational(6),
            ingredients: [MealIngredient(name: "Wraps", quantity: quantity(6), exclusions: ["No sesame"])],
            sourceURL: "https://example.test/wrap-dinner",
            servingGroups: [ServingGroup(name: "Lunch", servings: try Rational(2), isProtected: true)])
        XCTAssertFalse(feature.paid)
        try requireSaved(await feature.accept(template, id: acceptedID, fallback: false))
        XCTAssertTrue(ledger.shop?.lines.isEmpty == true, "Accepting a library dinner does not add groceries")
        let accepted = try XCTUnwrap(feature.state.acceptedDinners.first)
        XCTAssertEqual(feature.state.freeReusableDinnerID, acceptedID)
        XCTAssertTrue(feature.choose(accepted, day: nil))
        XCTAssertTrue(ledger.shop?.lines.isEmpty == true, "Preview leaves the saved list intact")
        try requireSaved(await feature.applyPreview())
        let firstShop = try XCTUnwrap(ledger.shop)
        let firstOccurrence = try XCTUnwrap(firstShop.mealOccurrences.first)
        XCTAssertNil(firstOccurrence.scheduledDay)
        XCTAssertEqual(firstOccurrence.templateID, template.id)
        ledger = LedgerModel(databaseURL: ledgerURL)
        await ledger.open()
        feature = dinnerFeature(ledger: ledger, pickup: pickup)
        XCTAssertEqual(ledger.shop, firstShop)
        XCTAssertEqual(feature.state.acceptedDinners.first?.template.sourceURL, template.sourceURL)
        let review = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: nil)
        XCTAssertEqual(review.lines.count, 1)
        XCTAssertEqual(review.lines.first?.quantity.amount, try Rational(6))
        XCTAssertEqual(review.needs.first { $0.priority == .protected }?.amount.amount, try Rational(2))
        XCTAssertEqual(review.needs.first { $0.priority == .required }?.amount.amount, try Rational(4))
        XCTAssertEqual(Set(review.details.flatMap(\.exclusions)), ["No sesame"])
        try requireSaved(try await LedgerCheckoutAdapter.apply(review, ledger: ledger, pickup: pickup))
        try requireSaved(await pickup.startNextShop(accept: []))
        let next = try XCTUnwrap(pickup.journey)
        try requireSaved(await LedgerCheckoutAdapter.openNextShop(next, ledger: ledger))
        feature = dinnerFeature(ledger: ledger, pickup: pickup)
        XCTAssertTrue(feature.choose(accepted, day: nil))
        try requireSaved(await feature.applyPreview())
        let nextOccurrence = try XCTUnwrap(ledger.shop?.mealOccurrences.first)
        XCTAssertNotEqual(nextOccurrence.id, firstOccurrence.id)
        XCTAssertEqual(nextOccurrence.templateID, firstOccurrence.templateID)
        XCTAssertEqual(ledger.workspace.shops.first { $0.id == firstShop.id }, firstShop)
        let reopened = LedgerModel(databaseURL: ledgerURL)
        await reopened.open()
        XCTAssertEqual(reopened.shop?.mealOccurrences.first, nextOccurrence)
        XCTAssertEqual(reopened.workspace.dinnerPlanning.acceptedDinners.count, 1)
    }

    @MainActor private func dinnerFeature(ledger: LedgerModel, pickup: PickupModel) -> DinnerFeatureModel {
        DinnerFeatureModel(store: ledger, access: { shopID in
            guard ledger.ready, pickup.ready, let workspaceID = ledger.sourceWorkspaceID else { return nil }
            let current = Date()
            return DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: "local-free-adult",
                shopID: shopID, assignedShopperID: "local-free-adult", canPlan: true, canReadBudget: true,
                hasPaidTools: false, roleRevision: 0, verifiedAt: current, validUntil: current.addingTimeInterval(30), sharedCommitAuthorized: false)
        }, phase: { id in pickup.journeys.first { $0.id == id }?.basket?.phase ?? .draft })
    }

    @MainActor private func totalShortfall(_ pickup: PickupModel) throws -> Rational {
        try XCTUnwrap(pickup.allocation).demands.reduce(.zero) { try $0.adding(XCTUnwrap($1.shortfall)) }
    }
    private func requireSaved(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(value, "Shipping model operation must commit", file: file, line: line)
        if !value { throw CocoaError(.fileWriteUnknown) }
    }
    private func quantity(_ count: Int64) -> Quantity { Quantity(amount: try! Rational(count), unit: .count, originalLiteral: String(count)) }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
