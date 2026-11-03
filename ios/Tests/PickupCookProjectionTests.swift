import XCTest
import CoreDomain
@testable import RoomInTheCart

final class PickupCookProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let actor = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private func quantity(_ count: Int64) -> Quantity { Quantity(amount: try! Rational(count), unit: .count, originalLiteral: "\(count) wraps") }
    private func fixture() throws -> (PickupJourney, StockAllocationResult) {
        let food = UUID(), dinner = UUID(), lunch = UUID()
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.revision = 4
        journey.needs = [AllocationNeed(id: dinner, orderLineID: food, name: "Tacos", amount: quantity(6), priority: .required),
                         AllocationNeed(id: lunch, orderLineID: food, name: "Lunch", amount: quantity(2), priority: .protected)]
        journey.plannedNeeds = journey.needs
        journey.needDetails = [.init(id: dinner, mealName: "Tacos", exclusions: ["sin ajo", "Original Wraps™"], scheduledDay: nil,
                                    leadTimeMinutes: 25, completedSteps: ["Beans already soaked"])]
        journey.repairs = [.init(id: UUID(), needID: dinner, instruction: "Use the confirmed beans; keep lunch separate.", createdAt: now,
                                extraTripAgreed: false, repeatMealAgreed: false, elapsedMinutes: nil, due: nil)]
        let allocation = try ConfirmedStockAllocator.allocate(lots: [.init(id: UUID(), foodID: food, name: "Original Wraps™", usable: quantity(6), confirmedAt: now)],
            needs: journey.needs.map { .init(id: $0.id, foodID: $0.orderLineID, name: $0.name, amount: $0.amount, priority: $0.priority) })
        return (journey, allocation)
    }
    private func context(subject: String? = nil, household: String? = nil, member: String? = nil, role: String? = nil,
                         unlocked: Bool = true, locked: Bool = false, saving: Bool = false, pending: Bool = false) -> PickupCookReadbackContext {
        .init(scope: .init(localActorID: actor, accountSubject: subject, householdID: household, memberID: member, role: role),
              workspaceUnlocked: unlocked, householdLocked: locked, saving: saving, pendingSave: pending)
    }
    private func text(_ journey: PickupJourney, _ allocation: StockAllocationResult?, language: String = "en-US", result: CheckoutResult? = nil, budget: Bool = false) -> String {
        PickupCookProjection.text(journey: journey, allocation: allocation, result: result, language: language, includeBudget: budget, at: now, timeZone: utc)
    }
    private func binding(_ journey: PickupJourney, _ allocation: StockAllocationResult?, context: PickupCookReadbackContext? = nil) throws -> PickupCookReadbackBinding {
        try XCTUnwrap(PickupCookReadbackBinding(journey: journey, allocation: allocation, result: nil, language: "en-US", includeBudget: false,
            text: text(journey, allocation), context: context ?? self.context(), at: now, timeZone: utc))
    }
    private func result(_ journey: PickupJourney) throws -> CheckoutResult {
        let scope = CheckoutContext(storeID: "Private store", branchID: "Main", mode: .pickup, slot: "Evening", commitmentsID: journey.id, observedAt: now, source: "Reviewed")
        return try CheckoutEngine.evaluate(CheckoutQuote(scope: .wholeCheckout, context: scope, pricing: .inclusiveTotal(.exact(Money(minorUnits: 4069)))), cap: nil)
    }
    func testSplitServingsRepeatQuantitiesButShareOneSetOfIngredientInstructions() throws {
        let (fixtureJourney, allocation) = try fixture()
        var journey = fixtureJourney
        let source = UUID()
        journey.needDetails = journey.needs.map { need in
            PickupNeedDetail(id: need.id, mealName: "Tacos", exclusions: ["no sesame"],
                             scheduledDay: nil, leadTimeMinutes: nil, completedSteps: [], sourceContributionID: source)
        }
        let pieces = PickupCookProjection.pieces(journey: journey, allocation: allocation, language: "en", timeZone: utc)
        XCTAssertEqual(pieces.filter { $0.text.contains("no sesame") }.count, 1)
        XCTAssertEqual(pieces.filter { $0.key.hasPrefix("need/") }.count, 2)
        journey.needDetails[1].sourceContributionID = UUID()
        XCTAssertEqual(PickupCookProjection.pieces(journey: journey, allocation: allocation, language: "en").filter { $0.text.contains("no sesame") }.count, 2)
    }
    func testFormatterPreservesProtectedPortionsConfirmedSupplyAndUnresolvedNeed() throws {
        let (journey, allocation) = try fixture()
        let value = text(journey, allocation)
        XCTAssertTrue(value.contains("Lunch: 2 units — set aside first"), "Protected quantity must use the real English unit catalog: \(value)")
        XCTAssertTrue(value.contains("Allocated: 4 units"), "Dinner allocation must remain exact and localized: \(value)")
        XCTAssertTrue(value.contains("Allocated: 2 units"), "Protected allocation must remain exact and localized: \(value)")
        XCTAssertTrue(value.contains("Short or unverified amount. Review."))
        XCTAssertTrue(value.contains("Timing conditional or deadline missed · review before cooking"))
        XCTAssertTrue(value.contains("sin ajo, Original Wraps™"))
        XCTAssertTrue(value.contains("Saved elapsed preparation minutes: 25"))
        XCTAssertTrue(value.contains("Beans already soaked"))
    }
    func testFormatterUsesSuppliedTimeAndLanguagePreservesOriginalFields() throws {
        let (journey, allocation) = try fixture()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "es-US"); formatter.timeZone = utc
        formatter.dateStyle = .full; formatter.timeStyle = .short
        let spanish = text(journey, allocation, language: "es-US")
        XCTAssertTrue(spanish.contains(formatter.string(from: now)))
        XCTAssertTrue(spanish.contains("sin ajo, Original Wraps™"))
        XCTAssertTrue(spanish.contains("Use the confirmed beans; keep lunch separate."))
        XCTAssertTrue(spanish.contains("4 unidades"), "Allocation must use the Spanish unit catalog: \(spanish)")
        XCTAssertTrue(spanish.contains("Lunch: 2 unidades"), "Original meal name stays unchanged while units localize: \(spanish)")
        XCTAssertFalse(spanish.contains(" count"), "No raw unit enum should appear in recipient copy")
        XCTAssertEqual(spanish, text(journey, allocation, language: "es-US"))
        XCTAssertNotEqual(spanish, text(journey, allocation, language: "en-US"))
    }
    func testFractionalAllocatedAmountRemainsExactInBothLanguages() throws {
        let food = UUID(), need = UUID()
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.needs = [.init(id: need, orderLineID: food, name: "Original lunch", amount: quantity(2), priority: .protected)]
        journey.plannedNeeds = journey.needs
        let usable = Quantity(amount: try Rational(3, 2), unit: .count, originalLiteral: "one and a half wraps")
        let allocation = try ConfirmedStockAllocator.allocate(lots: [.init(id: UUID(), foodID: food, name: "Wraps", usable: usable, confirmedAt: now)],
            needs: [.init(id: need, foodID: food, name: "Original lunch", amount: quantity(2), priority: .protected)])
        for (language, unit) in [("en-US", "units"), ("es-US", "unidades")] {
            let value = text(journey, allocation, language: language)
            XCTAssertTrue(value.contains("3/2 \(unit)"), "Exact fractional allocation must survive localization: \(value)")
            XCTAssertTrue(value.contains("Original lunch"), "Original meal wording must remain untouched")
        }
    }
    func testBudgetIsOmittedUnlessExplicitlyIncludedAndDoesNotEnterBinding() throws {
        let (journey, allocation) = try fixture(); let money = try result(journey)
        let safe = text(journey, allocation, result: money)
        XCTAssertFalse(safe.contains("Private budget included")); XCTAssertFalse(safe.contains(pMoney(Money(minorUnits: 4069))))
        let privateCopy = text(journey, allocation, result: money, budget: true)
        XCTAssertTrue(privateCopy.contains("Private budget included")); XCTAssertTrue(privateCopy.contains(pMoney(Money(minorUnits: 4069))))
        XCTAssertNil(PickupCookReadbackBinding(journey: journey, allocation: allocation, result: money, language: "en-US", includeBudget: true,
            text: privateCopy, context: context(), at: now, timeZone: utc))
        XCTAssertNil(PickupCookReadbackBinding(journey: journey, allocation: allocation, result: money, language: "en-US", includeBudget: false,
            text: privateCopy, context: context(), at: now, timeZone: utc))
    }
    func testUnresolvedPrivateBudgetUsesRecipientLanguage() throws {
        let (journey, allocation) = try fixture()
        let scope = CheckoutContext(storeID: "Private store", branchID: "Main", mode: .pickup,
            slot: "Evening", commitmentsID: journey.id, observedAt: now, source: "Reviewed")
        let unresolved = try CheckoutEngine.evaluate(CheckoutQuote(scope: .wholeCheckout,
            context: scope, pricing: .inclusiveTotal(.unknown(reason: "Unreviewed amount"))), cap: nil)
        let spanish = text(journey, allocation, language: "es-US", result: unresolved, budget: true)
        XCTAssertTrue(spanish.contains("Como mínimo"), spanish)
        XCTAssertTrue(spanish.contains("total sin resolver"), spanish)
        XCTAssertFalse(spanish.contains("At least"), spanish)
        let english = text(journey, allocation, language: "en-US", result: unresolved, budget: true)
        XCTAssertTrue(english.contains("At least"), english)
        XCTAssertTrue(english.contains("total unresolved"), english)
        XCTAssertFalse(english.contains("Como mínimo"), english)
        XCTAssertFalse(text(journey, allocation, language: "es-US", result: unresolved).contains("total sin resolver"))
    }
    func testCarriedStockRemainsUnconfirmedAndSavedNotesDoNotSupplyInstruction() throws {
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.urgent = [.init(id: UUID(), food: "Wraps", meal: "Tacos", required: quantity(6), available: quantity(99), due: nil,
                               confirmedAt: now, carriedFromID: UUID())]
        journey.notes = [.init(id: UUID(), text: "Archived private text", language: "en-US", createdAt: now, revision: 0, sentTo: "Sam", sentAt: now)]
        let value = text(journey, nil)
        XCTAssertTrue(value.contains("Reconfirmation required")); XCTAssertTrue(value.contains("Deadline unknown"))
        XCTAssertFalse(value.contains("99 units"), "Carried stock must not be certified without reconfirmation: \(value)"); XCTAssertFalse(value.contains("Archived private text")); XCTAssertFalse(value.contains("Sam"))
        XCTAssertFalse(value.localizedCaseInsensitiveContains("acknowledg"))
        XCTAssertNil(PickupCookReadbackBinding(journey: journey, allocation: nil, result: nil, language: "en-US", includeBudget: false,
            text: journey.notes[0].text, context: context(), at: now, timeZone: utc))
    }
    func testCurrentDemandSetIncludesPreplacementPlanAndStockOnlyProtectedCommitmentsOnce() throws {
        let food = UUID(), dinner = UUID(), lunch = UUID()
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.plannedNeeds = [.init(id: dinner, orderLineID: food, name: "Planned dinner", amount: quantity(4), priority: .required)]
        journey.urgent = [.init(id: food, food: "Wraps", meal: "Urgent dinner", required: quantity(2),
            available: quantity(0), due: nil, confirmedAt: now)]
        journey.stockNeeds = [.init(id: food, foodID: food, name: "Urgent dinner", amount: quantity(2), priority: .required),
            .init(id: lunch, foodID: food, name: "Stock-only lunch", amount: quantity(1), priority: .protected)]
        journey.stockLots = [.init(id: UUID(), foodID: food, name: "Counted wraps", usable: quantity(3), confirmedAt: now)]
        journey.needDetails = [.init(id: dinner, mealName: "Planned dinner", exclusions: ["no sesame"], scheduledDay: nil,
                                    leadTimeMinutes: nil, completedSteps: [])]
        let allocation = try journey.carryoverAllocation()
        let pieces = PickupCookProjection.pieces(journey: journey, allocation: allocation, language: "en-US", timeZone: utc)
        XCTAssertEqual(pieces.filter { $0.key.hasPrefix("need/") || $0.key.hasPrefix("urgent/") }.count, 3)
        let planned = try XCTUnwrap(pieces.first { $0.key == "need/\(dinner)" })
        XCTAssertTrue(planned.text.contains("Planned dinner: 4 units"), planned.text)
        XCTAssertTrue(planned.text.contains("Allocated: 2 units"), planned.text)
        XCTAssertTrue(planned.text.contains("Still short: 2 units"), planned.text)
        let urgent = try XCTUnwrap(pieces.first { $0.key == "urgent/\(food)" })
        XCTAssertTrue(urgent.text.contains("Allocated: 0 units"), urgent.text)
        XCTAssertTrue(urgent.text.contains("Still short: 2 units"), urgent.text)
        XCTAssertFalse(pieces.contains { $0.key == "need/\(food)" })
        let protected = try XCTUnwrap(pieces.first { $0.key == "need/\(lunch)" })
        XCTAssertTrue(protected.text.contains("Stock-only lunch: 1 unit — set aside first"), protected.text)
        XCTAssertTrue(protected.text.contains("Allocated: 1 unit"), protected.text)
        XCTAssertTrue(protected.text.contains("Still short: 0 units"), protected.text)
        XCTAssertTrue(pieces.contains { $0.text.contains("no sesame") })
    }
    func testUnknownCurrentAllocationNeverTreatsInitialObservationAsCurrentSupply() throws {
        let food = UUID()
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.urgent = [.init(id: food, food: "Wraps", meal: "Dinner", required: quantity(4), available: quantity(3), due: nil, confirmedAt: now)]
        let value = text(journey, nil)
        XCTAssertTrue(value.contains("Allocated: Unresolved"), value)
        XCTAssertTrue(value.contains("Still short: Unresolved"), value)
        XCTAssertTrue(value.contains("Initially observed available: 3 units"), value)
        XCTAssertFalse(value.contains("Confirmed available: 3"), value)
        XCTAssertTrue(value.contains("Open need: review before cooking."), value)
    }
    func testStockOnlyCarryoverUsesPinnedCoverageWithoutBorrowingAnotherBatch() throws {
        let food = UUID(), carryover = UUID(), pinnedBatch = UUID(), otherBatch = UUID()
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.stockNeeds = [.init(id: carryover, foodID: food, name: "Confirmed carryover dinner", amount: quantity(3), priority: .required)]
        journey.stockLots = [.init(id: pinnedBatch, foodID: food, name: "Reserved batch", usable: quantity(1), confirmedAt: now),
                             .init(id: otherBatch, foodID: food, name: "Other batch", usable: quantity(10), confirmedAt: now)]
        let allocation = try ConfirmedCarryoverAllocator.allocate(lots: journey.stockLots, needs: journey.stockNeeds,
            reservations: [.init(needID: carryover, lotID: pinnedBatch)])
        let value = text(journey, allocation)
        XCTAssertTrue(value.contains("Confirmed carryover dinner: 3 units"), value)
        XCTAssertTrue(value.contains("Allocated: 1 unit"), value)
        XCTAssertTrue(value.contains("Still short: 2 units"), value)
        XCTAssertTrue(value.contains("Short or unverified amount. Review."), value)
        XCTAssertFalse(value.contains("Allocated: 3 units"), value)
    }
    func testPlacedInstructionUsesCurrentNeedsRatherThanOutdatedPreplacementPlan() throws {
        let food = UUID(), current = UUID(), obsolete = UUID()
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.pickup = try PickupLedger(orderID: UUID(), orderLines: [.init(id: food, branchID: "Branch", name: "Wraps", ordered: quantity(4))])
        journey.plannedNeeds = [.init(id: obsolete, orderLineID: food, name: "Old planned dinner", amount: quantity(4), priority: .required)]
        journey.needs = [.init(id: current, orderLineID: food, name: "Current dinner", amount: quantity(2), priority: .required)]
        journey.stockLots = [.init(id: UUID(), foodID: food, name: "Counted batch", usable: quantity(1), confirmedAt: now)]
        let value = text(journey, try journey.carryoverAllocation())
        XCTAssertTrue(value.contains("Current dinner: 2 units"), value)
        XCTAssertTrue(value.contains("Allocated: 1 unit"), value)
        XCTAssertTrue(value.contains("Still short: 1 unit"), value)
        XCTAssertFalse(value.contains("Old planned dinner"), value)
    }
    func testBindingRequiresUnlockedPermittedRuntimeScopeAndCleanSaveState() throws {
        let (journey, allocation) = try fixture()
        let denied = [context(unlocked: false), context(locked: true), context(saving: true), context(pending: true),
            context(subject: "adult", household: "h", member: "m", role: "contributor"),
            context(subject: "adult", household: "h", member: "m", role: "helper"),
            context(subject: "adult", household: "h", member: "m", role: "editor"),
            context(subject: "adult", household: "h", member: "m", role: "unknown"),
            context(household: "h", member: "m", role: "shopper"), context(subject: "adult", household: "h")]
        for invalid in denied {
            XCTAssertNil(PickupCookReadbackBinding(journey: journey, allocation: allocation, result: nil, language: "en-US", includeBudget: false,
                text: text(journey, allocation), context: invalid, at: now, timeZone: utc))
        }
        for allowed in [context(), context(subject: "adult"), context(subject: "adult", household: "h", member: "m", role: "shopper"),
                        context(subject: "adult", household: "h", member: "m", role: "organizer")] {
            XCTAssertNotNil(try binding(journey, allocation, context: allowed))
        }
    }
    func testBindingRechecksIdentityHouseholdMemberRoleAndLocalActor() throws {
        let (journey, allocation) = try fixture()
        let original = context(subject: "adult", household: "household", member: "member", role: "shopper")
        let value = try binding(journey, allocation, context: original)
        let changed = [context(subject: "other", household: "household", member: "member", role: "shopper"),
            context(subject: "adult", household: "other", member: "member", role: "shopper"),
            context(subject: "adult", household: "household", member: "other", role: "shopper"),
            context(subject: "adult", household: "household", member: "member", role: "organizer"), context(),
            .init(scope: .init(localActorID: UUID(), accountSubject: "adult", householdID: "household", memberID: "member", role: "shopper"),
                  workspaceUnlocked: true, householdLocked: false, saving: false, pendingSave: false)]
        for current in changed {
            XCTAssertFalse(value.isCurrent(journey: journey, allocation: allocation, result: nil, language: "en-US", includeBudget: false,
                text: value.text, context: current, at: now))
        }
    }
    func testBindingLeaseIsLocalBoundedAndNeverRestoredFromSameText() throws {
        let (journey, allocation) = try fixture(); let value = try binding(journey, allocation)
        for (offset, expected) in [(-1.0, false), (0, true), (59, true), (60, false), (600, false)] {
            XCTAssertEqual(value.isCurrent(journey: journey, allocation: allocation, result: nil, language: "en-US", includeBudget: false,
                text: value.text, context: context(), at: now.addingTimeInterval(offset)), expected)
        }
        let fresh = try binding(journey, allocation)
        XCTAssertNotEqual(value.authorityBindingID, fresh.authorityBindingID)
        XCTAssertEqual(value.text, fresh.text)
    }
    func testSourceRevisionTextLocaleBudgetAndSaveChangesInvalidateBinding() throws {
        let (journey, allocation) = try fixture(); let value = try binding(journey, allocation)
        var saved = journey; saved.notes.append(.init(id: UUID(), text: value.text, language: "en-US", createdAt: now, revision: journey.revision)); saved.revision += 1
        var edited = journey; edited.repairs = []
        let other = PickupJourney(id: UUID(), savedAt: now)
        for current in [nil, saved, edited, other] {
            XCTAssertFalse(value.isCurrent(journey: current, allocation: allocation, result: nil, language: "en-US", includeBudget: false,
                text: value.text, context: context(), at: now))
        }
        for current in [context(unlocked: false), context(locked: true), context(saving: true), context(pending: true)] {
            XCTAssertFalse(value.isCurrent(journey: journey, allocation: allocation, result: nil, language: "en-US", includeBudget: false,
                text: value.text, context: current, at: now))
        }
        XCTAssertFalse(value.isCurrent(journey: journey, allocation: allocation, result: nil, language: "es-US", includeBudget: false, text: value.text, context: context(), at: now))
        XCTAssertFalse(value.isCurrent(journey: journey, allocation: allocation, result: nil, language: "en-US", includeBudget: true, text: value.text, context: context(), at: now))
        XCTAssertFalse(value.isCurrent(journey: journey, allocation: allocation, result: nil, language: "en-US", includeBudget: false, text: value.text + "Edited", context: context(), at: now))
    }
}
