import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

final class PickupModelTests: XCTestCase {
    @MainActor func testFeedbackRequiresClosedPlacedPickupAndConsentAndSurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url)
        let id = UUID()
        let context = CheckoutContext(storeID: "Private store", branchID: "Branch", mode: .pickup,
            slot: "Evening", commitmentsID: id, observedAt: Date(), source: "Private note")
        let line = BasketLine(id: UUID(), name: "Secret grocery", quantity: quantity(2), expectedCost: .exact(.zero))
        _ = await model.start(from: [line], shopID: id, context: context)
        let feedback = PickupFeedback(decision: .unchanged, baseline: .list, comparison: .same)
        XCTAssertEqual(feedback.incrementalBenefit, 0)
        XCTAssertNil(PickupFeedback(decision: .acted, baseline: .retailer, comparison: .different).incrementalBenefit)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(feedback)) as? [String: String]
        XCTAssertEqual(encoded, ["decision": "unchanged", "baseline": "list", "comparison": "same"])
        XCTAssertEqual(PickupDecision.allCases.count, 6)
        var revision = try XCTUnwrap(model.journey?.revision)
        let early = await model.recordFeedback(feedback, shopID: id, revision: revision, consent: true)
        XCTAssertFalse(early)
        _ = await model.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(.zero))), cap: nil)
        _ = await model.freeze()
        _ = await model.reportPlaced()
        _ = await model.change { $0.closedAt = Date() }
        revision = try XCTUnwrap(model.journey?.revision)
        let declined = await model.recordFeedback(feedback, shopID: id, revision: revision, consent: false)
        let stale = await model.recordFeedback(feedback, shopID: id, revision: revision - 1, consent: true)
        let wrongShop = await model.recordFeedback(feedback, shopID: UUID(), revision: revision, consent: true)
        XCTAssertFalse(declined)
        XCTAssertFalse(stale)
        XCTAssertFalse(wrongShop)
        XCTAssertNil(model.journey?.feedback)
        let saved = await model.recordFeedback(feedback, shopID: id, revision: revision, consent: true)
        XCTAssertTrue(saved)
        let reopened = PickupModel(databaseURL: url)
        await reopened.load()
        XCTAssertEqual(reopened.journey?.feedback, feedback)
        let removed = await reopened.recordFeedback(nil, shopID: id, revision: try XCTUnwrap(reopened.journey?.revision), consent: false)
        XCTAssertTrue(removed)
        XCTAssertNil(reopened.journey?.feedback)
    }

    @MainActor func testKnownAndUnknownQuoteSurviveRestart() async throws {
        for unknown in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("pickup.sqlite")
            let store = try ComparisonStore(url: url)
            let model = PickupModel(store: store)
            let id = UUID(), lineID = UUID()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let context = CheckoutContext(storeID: "Market", branchID: "Main", mode: .pickup, slot: "Tuesday 5 PM", commitmentsID: id, observedAt: now, source: "Retailer preview")
            let line = BasketLine(id: lineID, name: "Wraps", quantity: quantity(12), expectedCost: .exact(Money(minorUnits: 3480)))
            let started = await model.start(from: [line], shopID: id, context: context)
            XCTAssertTrue(started)
            let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .components(lines: [CheckoutLine(id: lineID, name: "Wraps", cost: line.expectedCost)], lineSetComplete: true, fees: [CheckoutFee(id: "fee", rule: .fixed(unknown ? .unknown(reason: "Not confirmed") : .exact(Money(minorUnits: 240))))], discounts: [], tax: .exact(.zero), deposits: .exact(.zero)))
            let quoted = await model.setQuote(quote, cap: CheckoutCap(scope: .wholeCheckout, commitmentsID: id, amount: Money(minorUnits: 3800)))
            XCTAssertTrue(quoted)
            let before = try XCTUnwrap(model.result)
            XCTAssertEqual(before.total.exact == nil, unknown)
            try await store.close()
            let reopened = PickupModel(databaseURL: url)
            await reopened.load()
            XCTAssertEqual(reopened.result, before)
            XCTAssertEqual(reopened.journey?.id, id)
            XCTAssertNil(reopened.journey?.pickup)
            XCTAssertEqual(reopened.journey?.settlement.entries.count, 0)
        }
    }
    @MainActor func testUrgentOfflineHasNoOrderReceiptOrMoneyAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("urgent.sqlite")
        let store = try ComparisonStore(url: url)
        let model = PickupModel(store: store)
        let need = UrgentMealNeed(id: UUID(), food: "Wraps", meal: "Tacos", required: quantity(6), available: quantity(4), due: nil, confirmedAt: Date())
        let first = await model.addUrgent(need)
        let replay = await model.addUrgent(need)
        XCTAssertTrue(first); XCTAssertTrue(replay)
        XCTAssertEqual(model.journey?.urgent.count, 1)
        XCTAssertNil(model.journey?.basket)
        XCTAssertNil(model.journey?.pickup)
        XCTAssertEqual(model.journey?.settlement.entries.count, 0)
        XCTAssertEqual(model.stockAllocation?.demands.first?.shortfall, try Rational(2))
        let note = PickupCookNote(id: UUID(), text: "Use four wraps; two remain short", language: "en-US", createdAt: Date(), revision: 1)
        let saved = await model.change { $0.notes.append(note) }
        XCTAssertTrue(saved)
        try await store.close()
        let reopened = PickupModel(databaseURL: url)
        await reopened.load()
        XCTAssertNil(reopened.journey?.basket)
        XCTAssertNil(reopened.journey?.pickup)
        XCTAssertEqual(reopened.journey?.notes.first, note)
        XCTAssertNil(reopened.journey?.urgent.first?.due)
        XCTAssertEqual(reopened.journey?.settlement.entries.count, 0)
    }
    @MainActor func testFailedPersistenceNeverPublishesCandidateAndRetryKeepsIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComparisonStore(url: directory.appendingPathComponent("failure.sqlite"))
        let model = PickupModel(store: store)
        await model.load()
        try await store.close()
        let need = UrgentMealNeed(id: UUID(), food: "Rice", meal: "Dinner", required: quantity(2), available: quantity(1), due: nil, confirmedAt: Date())
        let saved = await model.addUrgent(need)
        XCTAssertFalse(saved)
        XCTAssertTrue(model.hasPendingSave)
        XCTAssertNil(model.journey)
        let retry = await model.retrySave()
        XCTAssertFalse(retry)
        XCTAssertNil(model.journey)
        XCTAssertNotNil(model.error)
    }
    @MainActor func testConfirmedFreezerLotCoversOrderNeedsAndNextShopCarriesOnlyShortfall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PickupModel(databaseURL: directory.appendingPathComponent("order.sqlite"))
        let shop = UUID(), lineID = UUID(), lunchID = UUID(), dinnerID = UUID()
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "5 PM", commitmentsID: shop, observedAt: Date(), source: "Manual")
        _ = await model.start(from: [BasketLine(id: lineID, name: "Wraps", quantity: quantity(8), expectedCost: .exact(.zero))], shopID: shop, context: context, plannedNeeds: [AllocationNeed(id: dinnerID, orderLineID: lineID, name: "Dinner", amount: quantity(6), priority: .required), AllocationNeed(id: lunchID, orderLineID: lineID, name: "Lunch", amount: quantity(2), priority: .protected)])
        _ = await model.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(.zero))), cap: nil)
        _ = await model.freeze()
        _ = await model.reportPlaced()
        let saved = await model.change { value in
            value.stockLots = [ConfirmedStockLot(id: UUID(), foodID: lineID, name: "Wraps from freezer", usable: quantity(6), confirmedAt: Date(), source: .freezer)]
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(model.allocation?.demands.first(where: { $0.id == lunchID })?.shortfall, .zero)
        XCTAssertEqual(model.allocation?.demands.first(where: { $0.id == dinnerID })?.shortfall, try Rational(2))
        let next = await model.startNextShop(accept: [])
        XCTAssertTrue(next)
        XCTAssertEqual(model.journey?.carriedMeals.count, 1)
        XCTAssertEqual(model.journey?.carriedMeals.first?.amount.amount, try Rational(2))
        XCTAssertNil(model.journey?.quote)
        XCTAssertNil(model.journey?.pickup)
        XCTAssertEqual(model.journey?.stockLots.count, 0)
    }
    @MainActor func testUrgentCarryRebuildsDemandWithoutAssumingOldStock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PickupModel(databaseURL: directory.appendingPathComponent("next.sqlite"))
        let need = UrgentMealNeed(id: UUID(), food: "Rice", meal: "Dinner", required: quantity(4), available: quantity(1), due: nil, confirmedAt: Date())
        _ = await model.addUrgent(need)
        _ = await model.startNextShop(accept: [])
        XCTAssertEqual(model.journey?.stockNeeds.first?.id, need.id)
        XCTAssertEqual(model.journey?.stockLots.count, 0)
        XCTAssertEqual(model.stockAllocation?.demands.first?.shortfall, try Rational(3))
    }
    @MainActor func testInvalidPersistedJourneyDoesNotReplaceReadableState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComparisonStore(url: directory.appendingPathComponent("corrupt.sqlite"))
        var invalid = PickupJourney(id: UUID(), savedAt: Date())
        invalid.revision = -1
        try await store.save(id: invalid.id, title: "Invalid", payload: JSONEncoder().encode(invalid), savedAt: Date())
        let model = PickupModel(store: store)
        await model.load()
        XCTAssertFalse(model.ready)
        XCTAssertTrue(model.journeys.isEmpty)
        XCTAssertNotNil(model.error)
    }
    @MainActor func testRevisionOverflowRejectsCandidateAndArchiveContainsDurableRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PickupModel(databaseURL: directory.appendingPathComponent("revision.sqlite"))
        let need = UrgentMealNeed(id: UUID(), food: "Rice", meal: "Dinner", required: quantity(2), available: quantity(1), due: nil, confirmedAt: Date())
        _ = await model.addUrgent(need)
        let original = try XCTUnwrap(model.journey)
        let changed = await model.change { $0.revision = Int64.max }
        XCTAssertFalse(changed)
        XCTAssertEqual(model.journey, original)
        let archive = try await model.archiveSnapshot()
        XCTAssertEqual(archive.records.count, 1)
        let durable = try JSONDecoder().decode(PickupJourney.self, from: archive.records[0].payload)
        XCTAssertEqual(durable, original)
    }
    @MainActor func testArchivedDeletionIsDurableAndExactRetrySafe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("delete.sqlite")
        let model = PickupModel(databaseURL: url)
        _ = await model.addUrgent(UrgentMealNeed(id: UUID(), food: "Rice", meal: "Dinner", required: quantity(2), available: quantity(1), due: nil, confirmedAt: Date()))
        let archive = try await model.archiveSnapshot()
        let record = try XCTUnwrap(archive.records.first)
        let operation = UUID()
        try await model.deleteArchived(id: record.id, expectedRevision: record.revision, operationID: operation)
        try await model.deleteArchived(id: record.id, expectedRevision: record.revision, operationID: operation)
        XCTAssertTrue(model.journeys.isEmpty)
        let reopened = PickupModel(databaseURL: url)
        await reopened.load()
        XCTAssertTrue(reopened.ready)
        XCTAssertTrue(reopened.journeys.isEmpty)
    }
    private func quantity(_ count: Int64) -> Quantity {
        Quantity(amount: try! Rational(count), unit: .count, originalLiteral: String(count))
    }
}
