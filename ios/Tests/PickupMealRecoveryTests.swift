import XCTest
import CoreDomain
import SQLite3
@testable import RoomInTheCart

@MainActor final class PickupMealRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_312_000)
    private func q(_ value: Int64) -> Quantity { .init(amount: try! Rational(value), unit: .count, originalLiteral: String(value)) }
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let ledger: LedgerModel
        let model: PickupModel
        let beans: UUID
        let tuesday: UUID
        let wednesday: UUID
        let lunch: UUID
        let authority: PickupRecoveryAuthority
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let instant = now
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let model = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"), clock: { instant })
        cleanup.track(ledger, model)
        await ledger.open(); await model.load(); model.bindCookLedger(ledger)
        var shop = ShoppingLedger(title: "Recovery", basis: .init(branch: "Main", mode: .pickup, slot: now,
            timeZoneIdentifier: "America/New_York", cap: .init(minorUnits: 3800)))
        let line = try shop.addManualLine(name: "Wraps", quantity: q(12))
        let supply = try XCTUnwrap(shop.contributions(forLineID: line).first?.id)
        var occurrences: [UUID] = []
        for (title, count, day) in [("Tuesday tacos", Int64(6), 10), ("Wednesday quesadillas", Int64(4), 11)] {
            let date = try MealDay(year: 2026, month: 11, day: day, timeZoneIdentifier: "America/New_York")
            let occurrence = try shop.chooseMeal(.init(title: title, servings: try Rational(count),
                ingredients: [.init(name: "Wraps", quantity: q(count), notes: "Keep separate", exclusions: ["garlic"])],
                notes: "Original instructions", exclusions: ["garlic"],
                leadTimeMinutes: day == 10 ? 45 : nil, completedSteps: day == 10 ? ["Marinade prepared"] : []), on: date.date)
            let ingredient = try XCTUnwrap(shop.mealOccurrences.first { $0.id == occurrence }?.ingredientContributionIDs.first)
            try shop.linkContribution(contributionID: ingredient, within: supply, quantity: q(count))
            occurrences.append(occurrence)
        }
        try shop.addProtectedNeed(name: "Wraps", quantity: q(2), purpose: "Lunch", within: supply)
        let seeded = await ledger.change(key: "recovery-fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        XCTAssertTrue(seeded)
        let packs = try LedgerPackReview.prepare(ledger: ledger, shopID: shop.id, lineID: line,
            offerA: .init(id: "eight", label: "Eight wraps", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "six", label: "Six wraps", usableQuantity: q(6), price: .init(minorUnits: 250)),
            itemCap: nil, at: now, source: "Package")
        let packed = try await packs.save(offerID: "eight", ledger: ledger); XCTAssertTrue(packed)
        let checkout = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision,
            previous: nil, packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        XCTAssertEqual(checkout.lines.first?.quantity, q(16))
        let applied = try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: model); XCTAssertTrue(applied)
        let quoted = await model.setQuote(.init(scope: .wholeCheckout, context: checkout.context,
            pricing: .inclusiveTotal(.exact(.init(minorUnits: 600)))), cap: nil); XCTAssertTrue(quoted)
        let frozen = await model.freeze(); XCTAssertTrue(frozen)
        let placed = await model.reportPlaced(); XCTAssertTrue(placed)
        let key = ReceiptKey(sourceEventID: "wrap-delivery", orderLineID: line, branchID: "Main", segmentID: "one")
        let received = await model.receive(.init(key: key, itemName: "Wraps", received: q(8), disposition: .partial, receivedAt: now),
            usable: .init(id: UUID(), receipt: key, usable: q(6), confirmedAt: now, confirmedMatchToOrderLine: true))
        XCTAssertTrue(received)
        let beans = UUID()
        let stocked = await model.change { $0.stockLots.append(.init(id: UUID(), foodID: beans, name: "Beans", usable: q(4), confirmedAt: now)) }
        XCTAssertTrue(stocked)
        let journey = try XCTUnwrap(model.journey)
        let authority = PickupRecoveryAuthority(presentation: .init(workspaceID: model.sourceWorkspaceID,
            localActorID: UUID(), workspaceUnlocked: true, sceneActive: true, childPresented: false,
            guardianChildOnly: false, accountSubject: nil, householdLocked: false, projection: nil),
            ledgerWorkspaceID: try XCTUnwrap(ledger.sourceWorkspaceID), ledgerRevisionID: try XCTUnwrap(ledger.shop?.revisionID),
            selectedPickupID: journey.id, leaseID: UUID())
        return Fixture(directory: directory, cleanup: cleanup, ledger: ledger, model: model, beans: beans,
            tuesday: occurrences[0], wednesday: occurrences[1], lunch: try XCTUnwrap(journey.needs.first { $0.priority == .protected }?.id), authority: authority)
    }
    private func review(_ fixture: Fixture, amount: Int64 = 4) throws -> PickupMealRecoveryReview {
        let old = try XCTUnwrap(fixture.model.recoveryDefinitions().first { $0.meal.id == fixture.wednesday })
        let need = StockNeed(id: UUID(), foodID: fixture.beans, name: "Wednesday beans", amount: q(amount), priority: .required)
        let due = now.addingTimeInterval(2700)
        let replacement = RecoveryMeal(id: old.meal.id, revisionID: UUID(), templateID: nil, templateVersion: nil,
            title: "Wednesday beans", servings: old.meal.servings,
            ingredients: [.init(ingredientID: UUID(), groupID: nil, foodName: "Beans", need: need)],
            scheduledDay: old.meal.scheduledDay, due: due, timeZoneID: old.meal.timeZoneID,
            exclusions: old.meal.exclusions, remainingElapsedMinutes: 15, requiredLeadMinutes: old.meal.requiredLeadMinutes,
            advanceStepsCompleted: false)
        return try fixture.model.prepareMealRecovery(definition: .init(meal: replacement, groups: old.groups,
            notes: "Warm the beans", sourceURL: "https://example.invalid/beans",
            ingredientRules: [.init(needID: need.id, notes: "Use the checked freezer portion", exclusions: ["garlic"])], acceptedTemplate: nil),
            operationID: UUID(), confirmedUnknownDeadline: old.meal.due == nil ? due : nil,
            agreesToRepeat: false, proposesExtraTrip: false, agreesToExtraTrip: false, acceptsUnresolved: true, authority: fixture.authority)
    }
    func testReplacementCancelApplyReplayAndRestartPreserveWholeOrderAndTuesdayShortage() async throws {
        let f = try await fixture(), before = try XCTUnwrap(f.model.journey), ledgerBefore = f.ledger.workspace
        let reviewed = try review(f)
        XCTAssertTrue(reviewed.domain.feasible)
        XCTAssertEqual(f.model.journey, before, "Preview/cancel must preserve the whole saved journey")
        XCTAssertEqual(f.ledger.workspace, ledgerBefore)
        let applied = await f.model.applyMealRecovery(reviewed, currentAuthority: { f.authority }); XCTAssertTrue(applied)
        let after = try XCTUnwrap(f.model.journey)
        var expected = before
        expected.mealRecovery = after.mealRecovery; expected.savedAt = after.savedAt; expected.revision += 1
        XCTAssertEqual(after, expected, "Only recovery history and save envelope may change; receipts, money, original demands and order stay exact")
        XCTAssertEqual(f.ledger.workspace, ledgerBefore)
        XCTAssertEqual(after.mealRecovery?.domain.events.map(\.id), [reviewed.id])
        XCTAssertEqual(after.mealRecovery?.definitions.first?.definition, reviewed.definition)
        let tuesdayNeed = try XCTUnwrap(before.needDetails.first { $0.sourceOccurrenceID == f.tuesday }?.id)
        XCTAssertEqual(f.model.allocation?.demands.first { $0.id == tuesdayNeed }?.shortfall, try Rational(2))
        XCTAssertEqual(f.model.allocation?.demands.first { $0.id == f.lunch }?.allocated, try Rational(2))
        XCTAssertEqual(f.model.allocation?.demands.first { $0.id == reviewed.definition.meal.needs[0].id }?.allocated, try Rational(4))
        XCTAssertTrue(Set(after.physicalStockNeeds.map(\.id)).isDisjoint(with: reviewed.domain.request.target.needs.map(\.id)))
        let text = PickupCookProjection.text(journey: try XCTUnwrap(f.model.cookJourney), allocation: f.model.allocation,
            result: nil, language: "en-US", at: now, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertTrue(text.contains("Wednesday beans")); XCTAssertTrue(text.contains("Warm the beans"))
        XCTAssertTrue(text.contains("Tuesday tacos")); XCTAssertFalse(text.contains("Wednesday quesadillas"))
        XCTAssertEqual(after.recoveryCurrentDetails.first { $0.id == reviewed.definition.meal.needs[0].id }?.due, reviewed.definition.meal.due)
        let replayed = await f.model.applyMealRecovery(reviewed, currentAuthority: { f.authority }); XCTAssertTrue(replayed)
        XCTAssertEqual(f.model.journey, after)
        let instant = now
        let reopened = PickupModel(databaseURL: f.directory.appendingPathComponent("pickup.sqlite"), clock: { instant })
        f.cleanup.track(reopened); await reopened.load(); reopened.bindCookLedger(f.ledger)
        XCTAssertEqual(reopened.journey, after)
        XCTAssertEqual(try reopened.recoveryDefinitions(), try f.model.recoveryDefinitions())
    }
    func testCookInstructionsAndManualRepairTargetsFollowTheCurrentDinner() async throws {
        let f = try await fixture()
        let previousNeed = try XCTUnwrap(f.model.journey?.needDetails.first { $0.sourceOccurrenceID == f.wednesday }?.id)
        func instruction(_ text: String, for id: UUID) -> PickupRepair {
            PickupRepair(id: UUID(), needID: id, instruction: text, createdAt: now, extraTripAgreed: false,
                         repeatMealAgreed: false, elapsedMinutes: nil, due: nil)
        }
        let superseded = instruction("Toast the quesadillas", for: previousNeed)
        let firstSaved = await f.model.change { try $0.recordRepair(superseded) }
        XCTAssertTrue(firstSaved)
        let reviewed = try review(f)
        let replaced = await f.model.applyMealRecovery(reviewed, currentAuthority: { f.authority })
        XCTAssertTrue(replaced)
        let after = try XCTUnwrap(f.model.journey)
        let currentNeed = try XCTUnwrap(reviewed.definition.meal.needs.first?.id)
        XCTAssertEqual(after.savedMealDeadline(for: currentNeed), reviewed.definition.meal.due)
        XCTAssertNil(after.savedMealDeadline(for: previousNeed))
        XCTAssertTrue(after.repairs.contains(superseded))
        XCTAssertFalse(after.currentRepairNeeds.contains { $0.id == previousNeed })
        XCTAssertTrue(after.currentRepairNeeds.contains { $0.id == currentNeed })
        let stale = await f.model.change { try $0.recordRepair(instruction("Old dinner", for: previousNeed)) }
        XCTAssertFalse(stale)
        XCTAssertEqual(f.model.journey, after)
        let current = instruction("Heat the bean portions separately", for: currentNeed)
        let saved = await f.model.change { try $0.recordRepair(current) }
        XCTAssertTrue(saved)
        let cook = try XCTUnwrap(f.model.cookJourney)
        XCTAssertEqual(cook.currentRepairInstructions, [current])
        let pieces = PickupCookProjection.pieces(journey: cook, allocation: f.model.allocation, language: "en-US", timeZone: .current)
        XCTAssertTrue(pieces.contains { $0.text.contains(current.instruction) })
        XCTAssertFalse(pieces.contains { $0.text.contains(superseded.instruction) })
    }

    func testWednesdayReplacementPreservesEntireTuesdayPreparationDetail() async throws {
        let f = try await fixture()
        let original = try XCTUnwrap(f.model.journey?.needDetails.first { $0.sourceOccurrenceID == f.tuesday })
        XCTAssertEqual(original.leadTimeMinutes, 45)
        XCTAssertEqual(original.completedSteps, ["Marinade prepared"])
        let reviewed = try review(f)
        let applied = await f.model.applyMealRecovery(reviewed, currentAuthority: { f.authority }); XCTAssertTrue(applied)
        XCTAssertEqual(f.model.journey?.recoveryCurrentDetails.first { $0.id == original.id }, original,
            "Replacing Wednesday must preserve all of Tuesday's saved prep, completed steps, date, restrictions and source identity")
        let replacement = try XCTUnwrap(f.model.journey?.recoveryCurrentDetails.first { $0.id == reviewed.definition.meal.needs[0].id })
        XCTAssertEqual(replacement.leadTimeMinutes, 15)
        XCTAssertEqual(replacement.completedSteps, [])
        XCTAssertEqual(replacement.preparationNotes, ["Warm the beans", "Use the checked freezer portion"])
        let pieces = PickupCookProjection.pieces(journey: try XCTUnwrap(f.model.cookJourney), allocation: f.model.allocation,
            language: "en-US", timeZone: TimeZone(identifier: "America/New_York")!)
        let tuesday = try XCTUnwrap(pieces.first { $0.key == "detail/\(original.id)" })
        XCTAssertTrue(tuesday.text.contains("45")); XCTAssertTrue(tuesday.text.contains("Marinade prepared"))
    }

    func testChangedLeaseAndStaleReviewCannotCommitThenFreshReviewSucceeds() async throws {
        let f = try await fixture(), reviewed = try review(f), before = try XCTUnwrap(f.model.journey)
        let changed = PickupRecoveryAuthority(presentation: f.authority.presentation, ledgerWorkspaceID: f.authority.ledgerWorkspaceID,
            ledgerRevisionID: f.authority.ledgerRevisionID, selectedPickupID: f.authority.selectedPickupID, leaseID: UUID())
        let denied = await f.model.applyMealRecovery(reviewed, currentAuthority: { changed }); XCTAssertFalse(denied)
        XCTAssertEqual(f.model.journey, before); XCTAssertFalse(f.model.hasPendingSave)
        let altered = await f.model.change { $0.stockLots.removeAll { $0.foodID == f.beans } }; XCTAssertTrue(altered)
        let current = f.model.journey
        let stale = await f.model.applyMealRecovery(reviewed, currentAuthority: { f.authority }); XCTAssertFalse(stale)
        XCTAssertEqual(f.model.journey, current)
        let fresh = try review(f); XCTAssertFalse(fresh.domain.foodConfirmed)
        let applied = await f.model.applyMealRecovery(fresh, currentAuthority: { f.authority }); XCTAssertTrue(applied)
        XCTAssertEqual(f.model.allocation?.demands.first { $0.id == fresh.definition.meal.needs[0].id }?.shortfall, try Rational(4))
    }
    func testOutsideAdditionCorrectionMoveAndNextShopUseCurrentNeedsWithSavedDeadline() async throws {
        let f = try await fixture(), reviewed = try review(f, amount: 5)
        XCTAssertFalse(reviewed.domain.foodConfirmed)
        let applied = await f.model.applyMealRecovery(reviewed, currentAuthority: { f.authority }); XCTAssertTrue(applied)
        let originalHistory = try XCTUnwrap(f.model.journey?.mealRecovery)
        let outside = StockNeed(id: UUID(), foodID: UUID(), name: "Friday rice", amount: q(3), priority: .required)
        let appended = await f.model.change { $0.stockNeeds.append(outside) }; XCTAssertTrue(appended)
        let expanded = try XCTUnwrap(f.model.journey?.mealRecovery)
        XCTAssertEqual(expanded.domain.originalMeals, originalHistory.domain.originalMeals)
        XCTAssertEqual(expanded.domain.outsideDemands, originalHistory.domain.outsideDemands)
        XCTAssertEqual(expanded.domain.events, originalHistory.domain.events)
        XCTAssertEqual(try MealRecoveryEngine.project(expanded.domain).outsideDemands.last, outside)
        let sourceBeforeMove = f.ledger.workspace
        let day = try MealDay(year: 2026, month: 11, day: 12, timeZoneIdentifier: "America/New_York")
        let move = try f.model.prepareRecoveryMove(occurrenceID: f.wednesday, to: day, operationID: UUID(), authority: f.authority)
        let moved = await f.model.applyRecoveryMove(move, currentAuthority: { f.authority }); XCTAssertTrue(moved)
        XCTAssertEqual(f.ledger.workspace, sourceBeforeMove)
        XCTAssertEqual(try f.model.recoveryDefinitions().first { $0.meal.id == f.wednesday }?.meal.scheduledDay, day)
        XCTAssertEqual(try f.model.recoveryDefinitions().first { $0.meal.id == f.wednesday }?.meal.due, reviewed.definition.meal.due)
        let beforeCorrection = try XCTUnwrap(f.model.journey)
        let receipt = try XCTUnwrap(beforeCorrection.pickup?.receipts.first)
        let unlinked = await f.model.confirmUsable(.init(id: UUID(), receipt: receipt.key, usable: q(4),
            confirmedAt: now, confirmedMatchToOrderLine: true))
        XCTAssertFalse(unlinked)
        XCTAssertEqual(f.model.journey, beforeCorrection)
        let prior = try XCTUnwrap(beforeCorrection.pickup?.usableObservations.last { $0.receipt == receipt.key })
        let corrected = await f.model.confirmUsable(.init(id: UUID(), receipt: receipt.key, usable: q(4),
            confirmedAt: now, supersedesID: prior.id, confirmedMatchToOrderLine: true))
        XCTAssertTrue(corrected)
        XCTAssertEqual(f.model.journey?.mealRecovery, beforeCorrection.mealRecovery)
        let tuesdayNeed = try XCTUnwrap(beforeCorrection.needDetails.first { $0.sourceOccurrenceID == f.tuesday }?.id)
        XCTAssertEqual(f.model.allocation?.demands.first { $0.id == tuesdayNeed }?.shortfall, try Rational(4))
        let previous = try XCTUnwrap(f.model.journey)
        let next = await f.model.startNextShop(accept: []); XCTAssertTrue(next)
        let draft = try XCTUnwrap(f.model.journey)
        XCTAssertEqual(f.model.journeys.first { $0.id == previous.id }, previous)
        XCTAssertEqual(draft.carriedMeals.first { $0.id == reviewed.definition.meal.needs[0].id }?.amount.amount, .one)
        XCTAssertFalse(draft.carriedMeals.contains { reviewed.domain.request.target.needs.map(\.id).contains($0.id) })
        XCTAssertEqual(draft.needDetails.first { $0.id == reviewed.definition.meal.needs[0].id }?.due, reviewed.definition.meal.due)
        XCTAssertEqual(Set(draft.carriedMeals.map(\.id)).count, draft.carriedMeals.count)
    }

    func testIndependentWriterWinsCASAndImportedFutureStockNeverCoversReview() async throws {
        let f = try await fixture(), reviewed = try review(f)
        let instant = now
        let other = PickupModel(databaseURL: f.directory.appendingPathComponent("pickup.sqlite"), clock: { instant })
        f.cleanup.track(other); await other.load(); other.bindCookLedger(f.ledger)
        let inserted = await other.change { value in
            value.stockLots.removeAll { $0.foodID == f.beans }
            value.stockLots.append(.init(id: UUID(), foodID: f.beans, name: "Beans", usable: q(4), confirmedAt: now.addingTimeInterval(3600)))
        }
        XCTAssertTrue(inserted)
        let otherSaved = try XCTUnwrap(other.journey)
        let stale = await f.model.applyMealRecovery(reviewed, currentAuthority: { f.authority })
        XCTAssertFalse(stale, "SQLite source CAS must reject a stale in-memory preview")
        XCTAssertFalse(f.model.hasPendingSave)
        XCTAssertEqual(f.model.journey, otherSaved, "The winning writer must be reloaded without losing future evidence")
        let current = try review(f)
        XCTAssertFalse(current.domain.foodConfirmed)
        XCTAssertEqual(current.domain.afterAllocation.demands.first { $0.id == current.definition.meal.needs[0].id }?.shortfall, try Rational(4))
        XCTAssertEqual(current.domain.stockEvidence.filter { $0.lot.foodID == f.beans }.count, 1)
        let applied = await f.model.applyMealRecovery(current, currentAuthority: { f.authority }); XCTAssertTrue(applied)
        XCTAssertEqual(f.model.journey?.stockLots, otherSaved.stockLots)
        XCTAssertEqual(f.model.allocation?.demands.first { $0.id == current.definition.meal.needs[0].id }?.shortfall, try Rational(4))
    }

    func testLockedStoreRetryKeepsExactCandidateAndRechecksLiveAuthority() async throws {
        let f = try await fixture(), reviewed = try review(f), before = try XCTUnwrap(f.model.journey)
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.directory.appendingPathComponent("pickup.sqlite").path, &lock), SQLITE_OK)
        defer { sqlite3_exec(lock, "ROLLBACK", nil, nil, nil); sqlite3_close(lock); f.model.discardPending() }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        var live: PickupRecoveryAuthority? = f.authority
        let saved = await f.model.applyMealRecovery(reviewed, currentAuthority: { live })
        XCTAssertFalse(saved); XCTAssertTrue(f.model.hasPendingSave)
        XCTAssertEqual(f.model.journey, before)
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        live = nil
        let denied = await f.model.retrySave()
        XCTAssertFalse(denied); XCTAssertTrue(f.model.hasPendingSave)
        XCTAssertEqual(f.model.journey, before, "Generic pending retry must also recheck the retained live authority")
        live = f.authority
        let retried = await f.model.applyMealRecovery(reviewed, currentAuthority: { live })
        XCTAssertTrue(retried); XCTAssertFalse(f.model.hasPendingSave)
        XCTAssertEqual(f.model.journey?.revision, before.revision + 1)
        XCTAssertEqual(f.model.journey?.mealRecovery?.domain.events.map(\.id), [reviewed.id])
        XCTAssertEqual(f.model.journey?.mealRecovery?.definitions.first?.definition, reviewed.definition)
        let persisted = f.model.journey
        let replayed = await f.model.applyMealRecovery(reviewed, currentAuthority: { live })
        XCTAssertTrue(replayed); XCTAssertEqual(f.model.journey, persisted)
    }

    private func dinnerModel(_ fixture: Fixture) -> DinnerFeatureModel {
        let instant = now, workspace = fixture.authority.ledgerWorkspaceID
        return DinnerFeatureModel(store: fixture.ledger, access: { shopID in
            .init(scope: .local(workspaceID: workspace), actorID: "local", shopID: shopID,
                assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: false,
                roleRevision: 0, verifiedAt: instant.addingTimeInterval(-1), validUntil: instant.addingTimeInterval(3600))
        }, phase: { _ in .reportedPlaced }, clock: { instant })
    }

    func testDinnersAllChosenAndWeekShareCurrentIdentityMetadataAndDate() async throws {
        let f = try await fixture(), dinners = dinnerModel(f)
        let originalShop = try XCTUnwrap(f.ledger.shop)
        let originalTuesday = try XCTUnwrap(originalShop.mealOccurrences.first { $0.id == f.tuesday })
        let originalWednesday = try XCTUnwrap(originalShop.mealOccurrences.first { $0.id == f.wednesday })
        let initial = try dinners.currentMeals(pickup: f.model)
        XCTAssertEqual(initial.all, originalShop.mealOccurrences.map(DinnerCurrentMeal.original))
        XCTAssertEqual(try dinners.currentMealDestination(f.wednesday, pickup: f.model), .original(originalWednesday))
        let replacement = try review(f)
        let applied = await f.model.applyMealRecovery(replacement, currentAuthority: { f.authority }); XCTAssertTrue(applied)
        let current = try dinners.currentMeals(pickup: f.model)
        XCTAssertEqual(current.all.map(\.id), initial.all.map(\.id))
        XCTAssertEqual(try current.occurrence(f.tuesday), .original(originalTuesday))
        XCTAssertEqual(try current.occurrence(f.wednesday), .recovered(original: originalWednesday, current: replacement.definition))
        XCTAssertFalse(current.all.map(\.title).contains(originalWednesday.title))
        XCTAssertEqual(try dinners.currentMealDestination(f.wednesday, pickup: f.model), .recovered(shopID: originalShop.id, occurrenceID: f.wednesday))
        XCTAssertEqual(current.on(try XCTUnwrap(originalWednesday.scheduledDay)).map(\.id), [f.wednesday])
        let beforeMove = try XCTUnwrap(f.model.journey), ledgerBefore = f.ledger.workspace
        let day = try MealDay(year: 2026, month: 11, day: 12, timeZoneIdentifier: "America/New_York")
        let preview = try f.model.prepareRecoveryMove(occurrenceID: f.wednesday, to: day, operationID: UUID(), authority: f.authority)
        XCTAssertEqual(f.model.journey, beforeMove, "Canceling a calendar preview preserves the whole pickup")
        XCTAssertEqual(f.ledger.workspace, ledgerBefore)
        XCTAssertEqual(try dinners.currentMeals(pickup: f.model), current)
        let moved = await f.model.applyRecoveryMove(preview, currentAuthority: { f.authority }); XCTAssertTrue(moved)
        let after = try dinners.currentMeals(pickup: f.model)
        XCTAssertTrue(after.on(try XCTUnwrap(originalWednesday.scheduledDay)).isEmpty)
        XCTAssertEqual(after.on(day).map(\.id), [f.wednesday])
        guard case .recovered(_, let definition) = try after.occurrence(f.wednesday) else { return XCTFail("Calendar route resurrected the original meal") }
        XCTAssertEqual(definition, replacement.definition.withMeal(try XCTUnwrap(preview.domain.after.meals.first { $0.id == f.wednesday })))
        XCTAssertEqual(definition.meal.due, replacement.definition.meal.due)
        XCTAssertEqual(f.ledger.workspace, ledgerBefore)
        var expected = beforeMove; expected.mealRecovery = f.model.journey?.mealRecovery
        expected.savedAt = try XCTUnwrap(f.model.journey?.savedAt); expected.revision += 1
        XCTAssertEqual(f.model.journey, expected)
    }

    func testCurrentRoutesRejectWrongPickupAndConflictingRecoveredSourceWithoutOriginalFallback() async throws {
        let f = try await fixture(), dinners = dinnerModel(f), replacement = try review(f)
        let applied = await f.model.applyMealRecovery(replacement, currentAuthority: { f.authority }); XCTAssertTrue(applied)
        let current = try dinners.currentMeals(pickup: f.model), saved = f.model.journey
        f.model.selectedID = UUID()
        XCTAssertThrowsError(try dinners.currentMeals(pickup: f.model))
        XCTAssertThrowsError(try dinners.currentMealDestination(f.wednesday, pickup: f.model))
        f.model.selectedID = f.authority.selectedPickupID
        XCTAssertEqual(try dinners.currentMeals(pickup: f.model), current)
        let conflictDay = try MealDay(year: 2026, month: 11, day: 13, timeZoneIdentifier: "America/New_York")
        let changed = await f.ledger.change(key: "simulate-original-calendar-conflict") { workspace in
            try workspace.shops[0].scheduleMeal(occurrenceID: f.wednesday, day: conflictDay, at: now)
        }
        XCTAssertTrue(changed)
        XCTAssertThrowsError(try dinners.currentMeals(pickup: f.model), "Conflicting source must be shown as unavailable, never old Wednesday")
        XCTAssertEqual(f.model.journey, saved)
        let missing = try XCTUnwrap(saved?.mealRecovery)
        XCTAssertThrowsError(try DinnerCurrentMeals.project(shop: missing.source.shop, definitions: [], recovered: [f.wednesday]))
    }

    func testRecoveredDestinationSurvivesPendingCalendarRetryWithoutGrantingWriteAuthority() async throws {
        let f = try await fixture(), dinners = dinnerModel(f), replacement = try review(f)
        let applied = await f.model.applyMealRecovery(replacement, currentAuthority: { f.authority }); XCTAssertTrue(applied)
        let old = try XCTUnwrap(f.model.journey), route = try dinners.currentMealDestination(f.wednesday, pickup: f.model)
        let day = try MealDay(year: 2026, month: 11, day: 12, timeZoneIdentifier: "America/New_York")
        let reviewed = try f.model.prepareRecoveryMove(occurrenceID: f.wednesday, to: day, operationID: UUID(), authority: f.authority)
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.directory.appendingPathComponent("pickup.sqlite").path, &lock), SQLITE_OK)
        defer { sqlite3_exec(lock, "ROLLBACK", nil, nil, nil); sqlite3_close(lock); f.model.discardPending() }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        var live: PickupRecoveryAuthority? = f.authority
        let failed = await f.model.applyRecoveryMove(reviewed, currentAuthority: { live })
        XCTAssertFalse(failed); XCTAssertTrue(f.model.hasPendingSave); XCTAssertEqual(f.model.journey, old)
        XCTAssertEqual(try dinners.currentMealDestination(f.wednesday, pickup: f.model), route,
            "The recovery destination must stay mounted so its live lease and exact retry are retained")
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        live = nil
        let denied = await f.model.retrySave(); XCTAssertFalse(denied); XCTAssertEqual(f.model.journey, old)
        live = f.authority
        let saved = await f.model.applyRecoveryMove(reviewed, currentAuthority: { live }); XCTAssertTrue(saved)
        XCTAssertEqual(try dinners.currentMeals(pickup: f.model).on(day).map(\.id), [f.wednesday])
        XCTAssertEqual(f.model.journey?.revision, old.revision + 1)
    }

    func testLegacyJourneyWithoutRecoveryFieldsStillDecodesWithoutInventingMealAuthority() async throws {
        let f = try await fixture(), original = try XCTUnwrap(f.model.journey)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        object.removeValue(forKey: "mealSource"); object.removeValue(forKey: "mealRecovery")
        let decoded = try decoder.decode(PickupJourney.self, from: JSONSerialization.data(withJSONObject: object))
        var expected = original; expected.mealSource = nil; expected.mealRecovery = nil
        XCTAssertEqual(decoded, expected)
        XCTAssertThrowsError(try decoded.initialMealRecoveryHistory())
        XCTAssertEqual(decoded.physicalStockNeeds, original.rawPhysicalStockNeeds)
    }
}
