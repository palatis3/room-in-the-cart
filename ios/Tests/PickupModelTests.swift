import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

final class PickupModelTests: XCTestCase {
    @MainActor func testLocalFeedbackConsentIsVersionedWorkspaceScopedAndCannotComeFromLegacyBoolean() throws {
        let suite = "measurement-consent-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PickupFeedbackSection.consentKey)
        let first = UUID(), second = UUID()
        let consent = LocalPickupFeedbackConsent(defaults: defaults, storageKey: "versioned")
        XCTAssertFalse(consent.enabled(for: first))
        consent.setEnabled(true, for: first)
        XCTAssertTrue(consent.enabled(for: first))
        XCTAssertFalse(consent.enabled(for: second))
        XCTAssertTrue(LocalPickupFeedbackConsent(defaults: defaults, storageKey: "versioned").enabled(for: first))
        defaults.set([first.uuidString.lowercased(): "old-notice"], forKey: "versioned")
        XCTAssertFalse(LocalPickupFeedbackConsent(defaults: defaults, storageKey: "versioned").enabled(for: first))
        consent.setEnabled(false, for: first)
        XCTAssertFalse(consent.enabled(for: first))
    }

    func testLegacyFeedbackDecodePreservesChoicesWithoutManufacturingConsent() throws {
        let data = Data(#"{"decision":"alreadyKnew","baseline":"list","comparison":"different"}"#.utf8)
        let answer = try JSONDecoder().decode(PickupFeedback.self, from: data)
        XCTAssertEqual(answer.decision, .alreadyKnew)
        XCTAssertEqual(answer.incrementalBenefit, 0)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(answer)) as? [String: String])
        XCTAssertEqual(Set(saved.keys), ["decision", "baseline", "comparison"])
        XCTAssertNil(saved["consentVersion"])
    }

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

extension PickupModelTests {
    @MainActor private func arrivalFixture(url: URL, clock: @escaping () -> Date) async throws -> (PickupModel, UUID, UUID, UUID) {
        let model = PickupModel(databaseURL: url, clock: clock)
        let shopID = UUID(), foodID = UUID(), lunchID = UUID(), dinnerID = UUID()
        let context = CheckoutContext(storeID: "Synthetic market", branchID: "Main", mode: .pickup,
            slot: "Evening", commitmentsID: shopID, observedAt: clock(), source: "Reviewed fixture")
        let started = await model.start(from: [BasketLine(id: foodID, name: "Wraps", quantity: quantity(6), expectedCost: .exact(.zero))],
            shopID: shopID, context: context, plannedNeeds: [
                AllocationNeed(id: lunchID, orderLineID: foodID, name: "Protected lunch", amount: quantity(2), priority: .protected),
                AllocationNeed(id: dinnerID, orderLineID: foodID, name: "Tacos", amount: quantity(4), priority: .required)
            ])
        let quoted = await model.setQuote(CheckoutQuote(scope: .wholeCheckout, context: context,
            pricing: .inclusiveTotal(.exact(.zero))), cap: nil)
        let frozen = await model.freeze(), placed = await model.reportPlaced()
        XCTAssertTrue(started && quoted && frozen && placed)
        return (model, foodID, lunchID, dinnerID)
    }

    @MainActor func testFutureArrivalAndUsableWritesLeaveProtectedFoodUnconfirmed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("arrival.sqlite")
        // Absolute instants cross a local calendar boundary; authorization does not
        // compare formatted dates, device time zones, or the host's current date.
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, food, lunch, dinner) = try await arrivalFixture(url: url, clock: { instant })
        let before = try XCTUnwrap(model.journey)
        let key = ReceiptKey(sourceEventID: "actual-delivery", orderLineID: food, branchID: "Main", segmentID: "one")
        let future = instant.addingTimeInterval(3600)
        let later = ReceiptFragment(key: key, itemName: "Wraps", received: quantity(6), disposition: .late, receivedAt: future)
        let laterUsable = UsableObservation(id: UUID(), receipt: key, usable: quantity(6), confirmedAt: future, confirmedMatchToOrderLine: true)
        let prematureReceipt = await model.receive(later, usable: nil)
        let prematureComplete = await model.receive(later, usable: laterUsable)
        XCTAssertFalse(prematureReceipt); XCTAssertFalse(prematureComplete)
        XCTAssertEqual(model.journey, before, "A future arrival must not persist even without a usable amount")
        XCTAssertFalse(model.hasPendingSave)
        XCTAssertEqual(model.allocation?.demands.first { $0.id == lunch }?.shortfall, try Rational(2))

        let actual = ReceiptFragment(key: key, itemName: "Wraps", received: quantity(6), disposition: .received, receivedAt: instant)
        let atomicReject = await model.receive(actual, usable: laterUsable)
        XCTAssertFalse(atomicReject)
        XCTAssertEqual(model.journey, before, "Rejecting usable evidence must not commit half the arrival")
        let savedReceipt = await model.receive(actual, usable: nil)
        XCTAssertTrue(savedReceipt)
        let receiptOnly = try XCTUnwrap(model.journey)
        let prematureConfirmation = await model.confirmUsable(laterUsable)
        XCTAssertFalse(prematureConfirmation)
        XCTAssertEqual(model.journey, receiptOnly)
        XCTAssertEqual(model.allocation?.demands.first { $0.id == dinner }?.shortfall, try Rational(4))

        instant = future
        let confirmed = await model.confirmUsable(laterUsable)
        let replay = await model.receive(actual, usable: laterUsable)
        XCTAssertTrue(confirmed && replay)
        XCTAssertEqual(model.journey?.pickup?.receipts.count, 1)
        XCTAssertEqual(model.journey?.pickup?.usableObservations.count, 1)
        XCTAssertEqual(model.allocation?.demands.first { $0.id == lunch }?.allocated, try Rational(2))
        XCTAssertEqual(model.allocation?.demands.first { $0.id == dinner }?.allocated, try Rational(4))
        let reopened = PickupModel(databaseURL: url, clock: { instant })
        await reopened.load()
        XCTAssertEqual(reopened.journey, model.journey)
        XCTAssertEqual(reopened.allocation, model.allocation)
        XCTAssertTrue(try XCTUnwrap(reopened.journey?.settlement.entries).isEmpty)
    }

    @MainActor func testImportedFutureEvidenceIsRetainedButExcludedFromCurrentFoodAndCookProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("historical.sqlite")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let future = instant.addingTimeInterval(86_400)
        let (model, food, lunch, dinner) = try await arrivalFixture(url: url, clock: { instant })
        var imported = try XCTUnwrap(model.journey)
        let key = ReceiptKey(sourceEventID: "old-import", orderLineID: food, branchID: "Main", segmentID: "one")
        let actual = ReceiptFragment(key: key, itemName: "Wraps", received: quantity(6), disposition: .partial, receivedAt: instant)
        let old = UsableObservation(id: UUID(), receipt: key, usable: quantity(4), confirmedAt: instant, confirmedMatchToOrderLine: true)
        let futureCorrection = UsableObservation(id: UUID(), receipt: key, usable: quantity(6), confirmedAt: future,
            supersedesID: old.id, confirmedMatchToOrderLine: true)
        try imported.pickup?.receive(actual)
        try imported.pickup?.confirmUsable(old)
        try imported.pickup?.confirmUsable(futureCorrection)
        let laterKey = ReceiptKey(sourceEventID: "old-import", orderLineID: food, branchID: "Main", segmentID: "two")
        let later = ReceiptFragment(key: laterKey, itemName: "Later wraps", received: quantity(2), disposition: .late, receivedAt: future)
        let laterObservation = UsableObservation(id: UUID(), receipt: laterKey, usable: quantity(2), confirmedAt: instant, confirmedMatchToOrderLine: true)
        try imported.pickup?.receive(later)
        try imported.pickup?.confirmUsable(laterObservation)
        imported.stockLots = [ConfirmedStockLot(id: UUID(), foodID: food, name: "Future freezer count", usable: quantity(3), confirmedAt: future, source: .freezer)]
        // Loading historical data validates its structure without inventing a
        // wall-clock-dependent decoding failure or rewriting its dated records.
        XCTAssertEqual(try JSONDecoder().decode(PickupJourney.self, from: JSONEncoder().encode(imported)), imported)
        let saved = await model.change { $0 = imported }
        XCTAssertTrue(saved)
        let retained = try XCTUnwrap(model.journey)
        let reopened = PickupModel(databaseURL: url, clock: { instant })
        await reopened.load()
        XCTAssertTrue(reopened.ready)
        XCTAssertEqual(reopened.journey, retained)
        XCTAssertEqual(reopened.journey?.pickup?.usableObservations.count, 3)
        XCTAssertEqual(reopened.journey?.stockLots.count, 1)
        XCTAssertTrue(PickupFallbackOptions.lots(retained, at: instant).isEmpty)
        XCTAssertEqual(reopened.allocation?.demands.first { $0.id == lunch }?.shortfall, try Rational(2))
        XCTAssertEqual(reopened.allocation?.demands.first { $0.id == dinner }?.shortfall, try Rational(4),
            "A future latest correction must not resurrect its superseded four-wrap observation")
        let text = PickupCookProjection.text(journey: retained, allocation: reopened.allocation, result: reopened.result,
            language: "en-US", at: instant, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertTrue(text.contains("Short or unverified amount. Review."))
        let receiptReplay = await reopened.receive(later, usable: laterObservation)
        let correctionReplay = await reopened.confirmUsable(futureCorrection)
        XCTAssertTrue(receiptReplay && correctionReplay, "Exact historical retries preserve evidence identities")
        XCTAssertEqual(reopened.journey?.pickup, retained.pickup)
        XCTAssertEqual(reopened.allocation?.demands.first { $0.id == lunch }?.shortfall, try Rational(2))
        let newEarlyConfirmation = UsableObservation(id: UUID(), receipt: laterKey, usable: quantity(2), confirmedAt: instant,
            supersedesID: laterObservation.id, confirmedMatchToOrderLine: true)
        let rejected = await reopened.confirmUsable(newEarlyConfirmation)
        XCTAssertFalse(rejected, "An imported future receipt does not authorize a new premature usable confirmation")
        XCTAssertEqual(reopened.journey?.pickup, retained.pickup)
        let laterView = PickupModel(databaseURL: url, clock: { future })
        await laterView.load()
        XCTAssertEqual(laterView.allocation?.demands.first { $0.id == dinner }?.shortfall, .zero)
        XCTAssertEqual(reopened.journey?.stockLots, retained.stockLots)
        XCTAssertEqual(reopened.journey?.settlement, retained.settlement)
    }
}

extension PickupModelTests {
    @MainActor func testStockReviewExpiresWhenRetainedFutureFoodBecomesCurrentWithoutRevisionChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var instant = Date(timeIntervalSince1970: 1_800_000_000)
        let future = instant.addingTimeInterval(3600)
        let (model, food, lunch, _) = try await arrivalFixture(url: directory.appendingPathComponent("review.sqlite"), clock: { instant })
        let imported = ConfirmedStockLot(id: UUID(), foodID: food, name: "Later freezer count", usable: quantity(2), confirmedAt: future, source: .freezer)
        let saved = await model.change { $0.stockLots.append(imported) }
        XCTAssertTrue(saved)
        let before = try XCTUnwrap(model.journey)
        let scope = PickupStockReviewScope(workspaceID: try XCTUnwrap(model.sourceWorkspaceID), localActorID: UUID(),
            accountSubject: nil, householdID: nil, memberID: nil, role: nil)
        let newLot = ConfirmedStockLot(id: UUID(), foodID: food, name: "New checked batch", usable: quantity(2), confirmedAt: instant, source: .freezer)
        let review = try model.previewStockLot(newLot, in: before.id, scope: scope)
        XCTAssertEqual(review.before.demands.first { $0.id == lunch }?.shortfall, try Rational(2))
        XCTAssertEqual(review.after.demands.first { $0.id == lunch }?.shortfall, .zero)
        XCTAssertTrue(model.isCurrentStockLotReview(review, scope: scope))
        instant = future
        XCTAssertEqual(model.journey?.revision, before.revision)
        XCTAssertFalse(model.isCurrentStockLotReview(review, scope: scope), "Food availability changed after this review even though no saved record changed")
        let applied = await model.applyStockLotReview(review, scope: scope, confirmed: true)
        XCTAssertFalse(applied)
        XCTAssertEqual(model.journey, before)
        XCTAssertFalse(model.hasPendingSave)
    }
}
