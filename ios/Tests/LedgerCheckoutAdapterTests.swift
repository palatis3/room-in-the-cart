import XCTest
import CoreDomain
@testable import RoomInTheCart

final class LedgerCheckoutAdapterTests: XCTestCase {
    func testGuestCheckoutReviewRequiresSameLedgerBasketAndBranch() throws {
        let shop = try wrapShop()
        let source = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        let context = source.context
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(.init(minorUnits: 500))))
        let basket = try BasketPlan(id: shop.id, revisionID: UUID(), lines: source.lines, createdAt: Date())
        var journey = PickupJourney(id: shop.id, savedAt: Date())
        journey.basket = basket; journey.ledgerSourceRevisionID = shop.revisionID; journey.ledgerBasis = shop.basis
        journey.quotedRevisionID = basket.current.id; journey.quote = quote; journey.context = context
        XCTAssertEqual(journey.reviewedGuestQuote(for: shop, selections: []), quote)
        journey.quotedRevisionID = UUID()
        XCTAssertNil(journey.reviewedGuestQuote(for: shop, selections: []))
        journey.quotedRevisionID = basket.current.id; journey.ledgerSourceRevisionID = UUID()
        XCTAssertNil(journey.reviewedGuestQuote(for: shop, selections: []))
        journey.ledgerSourceRevisionID = shop.revisionID
        let other = CheckoutContext(storeID: "Other", branchID: "Other", mode: context.mode, slot: context.slot, commitmentsID: shop.id, observedAt: Date(), source: "Quote")
        journey.context = other; journey.quote = .init(scope: quote.scope, context: other, pricing: quote.pricing)
        XCTAssertNil(journey.reviewedGuestQuote(for: shop, selections: []))
    }

    @MainActor func testGuestApplyCarriesFiveBoundPeppersThroughPackAndCheckoutWithoutChangingReportedPurchase() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        await ledger.open(); await pickup.load()
        let workspaceID = try XCTUnwrap(ledger.sourceWorkspaceID)
        let now = Date()
        var shop = ShoppingLedger(title: "Pickup", basis: basis())
        let family = ServingGroup(name: "Dinner", servings: try Rational(3))
        let lunch = ServingGroup(name: "Lunch", servings: .one, isProtected: true)
        let occurrence = try shop.chooseMeal(.init(title: "Rice", servings: try Rational(4),
            ingredients: [.init(name: "Peppers", quantity: quantity(8))], servingGroups: [family, lunch]))
        let source = try XCTUnwrap(shop.contributions.first)
        let auth = DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: "adult", shopID: shop.id, assignedShopperID: "adult",
            canPlan: true, canReadBudget: true, hasPaidTools: true, roleRevision: 1,
            verifiedAt: now.addingTimeInterval(-1), validUntil: now.addingTimeInterval(3600))
        let conversion = UnitBasis(sourceUnit: .gram, targetUnit: .count, targetAmountPerSourceUnit: try Rational(1,100), sourceNote: "100 g per pepper")
        let boundLunch = DinnerPortionBinding(occurrenceID: occurrence, contributionID: source.id, groupID: lunch.id,
            quantity: Quantity(amount: try Rational(500), unit: .gram, originalLiteral: "500g", confirmedConversion: conversion), servings: .one)
        var planning = DinnerPlanningState()
        try planning.setPortionBindings([.init(occurrenceID: occurrence, contributionID: source.id, groupID: family.id, quantity: quantity(3), servings: family.servings),
            boundLunch], for: occurrence, ledger: shop, access: auth, at: now)
        _ = await ledger.change(key: "seed-portions") { $0.shops = [shop]; $0.selectedShopID = shop.id; $0.dinnerPlanning = planning }
        let model = DinnerFeatureModel(store: ledger, access: { _ in auth }, phase: { _ in pickup.journey?.basket?.phase ?? .draft })
        let pack = PackOffer(id: "eight", label: "8 peppers", usableQuantity: quantity(8), price: .init(minorUnits: 240))
        let other = PackOffer(id: "single", label: "1 pepper", usableQuantity: quantity(1), price: .init(minorUnits: 60))
        let before = try LedgerPackReview.prepare(ledger: ledger, shopID: shop.id, lineID: source.lineID, offerA: pack, offerB: other, itemCap: nil, at: now, source: "Package")
        XCTAssertEqual(before.requirement.protectedQuantity.amount, try Rational(5))
        let saved = try await before.save(offerID: pack.id, ledger: ledger)
        XCTAssertTrue(saved)
        XCTAssertTrue(model.previewGuests(occurrenceID: occurrence, servings: [family.id: try Rational(4)]))
        model.cancelPreview()
        XCTAssertEqual(ledger.shop?.revisionID, shop.revisionID)
        XCTAssertTrue(model.previewGuests(occurrenceID: occurrence, servings: [family.id: try Rational(4)]))
        let applied = await model.applyPreview()
        XCTAssertTrue(applied)
        XCTAssertEqual(ledger.workspace.dinnerPlanning.portionBindings.first(where: { $0.id == boundLunch.id }), boundLunch)
        XCTAssertNil(try ledger.workspace.currentPackSelection(shopID: shop.id, lineID: source.lineID, workspaceID: workspaceID))
        let after = try LedgerPackReview.prepare(ledger: ledger, shopID: shop.id, lineID: source.lineID, offerA: pack, offerB: other, itemCap: nil, at: now, source: "Package")
        XCTAssertEqual(after.requirement.quantity.amount, try Rational(9)); XCTAssertEqual(after.requirement.protectedQuantity.amount, try Rational(5))
        XCTAssertEqual(after.result.offerA.packsToBuy, 2)
        let resaved = try await after.save(offerID: pack.id, ledger: ledger)
        XCTAssertTrue(resaved)
        func review() throws -> LedgerCheckoutReview {
            try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: pickup.journey,
                packSelections: ledger.workspace.packSelections, workspaceID: workspaceID, bindings: ledger.workspace.dinnerPlanning.portionBindings)
        }
        let reviewed = try review()
        XCTAssertEqual(reviewed.lines.first?.quantity.amount, try Rational(16))
        XCTAssertEqual(reviewed.needs.first(where: { $0.priority == .protected })?.amount.amount, try Rational(5))
        XCTAssertEqual(reviewed.needs.first(where: { $0.priority == .required })?.amount.amount, try Rational(4))
        let staged = try await LedgerCheckoutAdapter.apply(reviewed, ledger: ledger, pickup: pickup); XCTAssertTrue(staged)
        let quoted = await pickup.setQuote(.init(scope: .wholeCheckout, context: reviewed.context, pricing: .inclusiveTotal(.exact(.init(minorUnits: 480)))), cap: nil)
        XCTAssertTrue(quoted)
        let frozen = await pickup.freeze(); XCTAssertTrue(frozen)
        let placed = await pickup.reportPlaced(); XCTAssertTrue(placed)
        let reported = try XCTUnwrap(pickup.journey)
        XCTAssertTrue(model.previewGuests(occurrenceID: occurrence, servings: [family.id: try Rational(5)]))
        XCTAssertTrue(model.preview?.needsPurchaseAmendment == true); XCTAssertFalse(model.canApply)
        do { _ = try await LedgerCheckoutAdapter.apply(review(), ledger: ledger, pickup: pickup); XCTFail("Reported purchase was editable") }
        catch { XCTAssertEqual(error as? LedgerCheckoutError, .placedOrder) }
        XCTAssertEqual(pickup.journey, reported)
        // A later quantity without a compatible unit must never fall back to a ration of servings.
        var stale = try XCTUnwrap(ledger.shop)
        try stale.updateContribution(contributionID: source.id, quantity: Quantity(amount: .one, unit: .liter, originalLiteral: "1 L"), notes: "")
        XCTAssertThrowsError(try LedgerPackRequirement.review(shop: stale, lineID: source.lineID, bindings: ledger.workspace.dinnerPlanning.portionBindings))
        XCTAssertThrowsError(try LedgerCheckoutAdapter.review(shop: stale, workspaceRevision: ledger.revision, previous: reported, bindings: ledger.workspace.dinnerPlanning.portionBindings))
        XCTAssertEqual(pickup.journey, reported)
    }

    @MainActor func testTwelveExistingWrapsProjectSixFourTwoExactlyOnce() async throws {
        let shop = try wrapShop()
        let review = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(review.lines.count, 1)
        XCTAssertEqual(review.lines[0].quantity.amount, try Rational(12))
        XCTAssertEqual(review.needs.count, 3)
        XCTAssertEqual(review.needs.first(where: { $0.name == "Tacos" })?.amount.amount, try Rational(6))
        XCTAssertEqual(review.needs.first(where: { $0.name == "Quesadillas" })?.amount.amount, try Rational(4))
        let protected = try XCTUnwrap(review.needs.first(where: { $0.priority == .protected }))
        XCTAssertEqual(protected.name, "Lunch")
        XCTAssertEqual(protected.amount.amount, try Rational(2))
        XCTAssertEqual(Set(review.needs.map(\.orderLineID)), Set(review.lines.map(\.id)))
        let repeated = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(review.needs, repeated.needs)

        // Use the ingredient screen's actual pack-review path with the same
        // six/four/two partition, rather than a separate twelve-item fixture.
        let directory = try temporaryDirectory()
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        cleanup.track(ledger, pickup)
        await ledger.open(); await pickup.load()
        let seeded = await ledger.change(key: "six-four-two-pack-review") {
            $0.shops = [shop]; $0.selectedShopID = shop.id
        }
        XCTAssertTrue(seeded)
        XCTAssertTrue(pickup.journeys.isEmpty, "No pantry, freezer or receipt stock was supplied")
        let lineID = review.lines[0].id
        let before = ledger.workspace
        let beforeRevision = ledger.revision
        let packs = try LedgerPackReview.prepare(ledger: ledger, shopID: shop.id, lineID: lineID,
            offerA: PackOffer(id: "eight", label: "Eight wraps", usableQuantity: quantity(8), price: Money(minorUnits: 300)),
            offerB: PackOffer(id: "six", label: "Six wraps", usableQuantity: quantity(6), price: Money(minorUnits: 250)),
            itemCap: nil, at: Date(timeIntervalSince1970: 1_800_000_000), source: "Reviewed shelf", pickup: pickup)
        XCTAssertEqual(packs.requirement.quantity.amount, try Rational(12))
        XCTAssertEqual(packs.requirement.protectedQuantity.amount, try Rational(2))
        XCTAssertNil(packs.stockEvidence)
        XCTAssertNil(packs.request.confirmedAtHome)
        XCTAssertEqual(packs.result.offerA.packsToBuy, 2)
        XCTAssertEqual(packs.result.offerA.purchasedAmount, try Rational(16))
        XCTAssertEqual(packs.result.offerA.leftover, try Rational(4))
        XCTAssertEqual(packs.result.offerA.totalCost, Money(minorUnits: 600))
        XCTAssertEqual(ledger.workspace, before, "Preparing packs must not change dinner or lunch demand")
        XCTAssertEqual(ledger.revision, beforeRevision)
        let saved = try await packs.save(offerID: "eight", ledger: ledger, pickup: pickup)
        XCTAssertTrue(saved)
        XCTAssertEqual(ledger.shop, shop)
        XCTAssertTrue(pickup.journeys.isEmpty, "Choosing packs must not silently apply or place a checkout")
        let checkout = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision,
            previous: nil, packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        XCTAssertEqual(checkout.lines.count, 1)
        XCTAssertEqual(checkout.lines[0].quantity.amount, try Rational(16))
        XCTAssertEqual(checkout.lines[0].expectedCost, .exact(Money(minorUnits: 600)))
        XCTAssertEqual(checkout.needs, review.needs, "Whole packs supply twelve needed wraps without inventing four more meal portions")

        let reopened = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        cleanup.track(reopened)
        await reopened.open()
        XCTAssertEqual(reopened.shop, shop)
        XCTAssertEqual(reopened.workspace.packSelections, ledger.workspace.packSelections)
        let restored = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(reopened.shop), workspaceRevision: reopened.revision,
            previous: nil, packSelections: reopened.workspace.packSelections, workspaceID: reopened.sourceWorkspaceID)
        XCTAssertEqual(restored.lines, checkout.lines)
        XCTAssertEqual(restored.needs, review.needs)
    }

    @MainActor func testCalendarMoveUpdatesCookCorrectionWithoutChangingPlacedPickup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        await ledger.open(); await pickup.load()
        pickup.bindCookLedger(ledger)
        var shop = ShoppingLedger(title: "Family pickup", basis: basis())
        let original = try MealDay(year: 2026, month: 11, day: 4, timeZoneIdentifier: shop.basis.timeZoneIdentifier)
        let moved = try MealDay(year: 2026, month: 11, day: 12, timeZoneIdentifier: original.timeZoneIdentifier)
        let occurrence = try shop.chooseMeal(.init(title: "Tacos", ingredients: [.init(name: "Wraps", quantity: quantity(6))]), on: original.date)
        _ = try shop.addProtectedNeed(name: "Lunch wraps", quantity: quantity(2), purpose: "School lunch")
        let seeded = await ledger.change(key: "seed-calendar-move") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        XCTAssertTrue(seeded)
        let review = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: nil)
        let staged = try await LedgerCheckoutAdapter.apply(review, ledger: ledger, pickup: pickup)
        XCTAssertTrue(staged)
        let quoted = await pickup.setQuote(.init(scope: .wholeCheckout, context: review.context, pricing: .inclusiveTotal(.exact(.init(minorUnits: 600)))), cap: nil)
        XCTAssertTrue(quoted)
        let frozen = await pickup.freeze(); XCTAssertTrue(frozen)
        let placed = await pickup.reportPlaced(); XCTAssertTrue(placed)
        let initial = try XCTUnwrap(pickup.cookJourney)
        let now = Date(), zone = TimeZone.current
        let oldText = PickupCookProjection.text(journey: initial, allocation: pickup.allocation, result: nil, language: "en-US", at: now, timeZone: zone)
        XCTAssertTrue(oldText.contains(original.iso8601))
        let oldReview = CookHandoffReview(pieces: PickupCookProjection.pieces(journey: initial, allocation: pickup.allocation, language: "en-US", timeZone: zone),
                                         timeZoneID: zone.identifier, includesBudget: false, customWording: false, budget: nil)
        let note = PickupCookNote(id: UUID(), text: oldText, language: "en-US", createdAt: now, revision: initial.revision, reviewedHandoff: oldReview)
        let saved = await pickup.change { $0.notes.append(note) }; XCTAssertTrue(saved)
        let copy = try XCTUnwrap(pickup.handoffCopy(channel: .cook, versionID: note.id, language: "en-US"))
        let sent = await pickup.markRecipient(copy, recipient: "Cook", acknowledge: false, reviewedRevision: try XCTUnwrap(pickup.journey?.revision))
        XCTAssertTrue(sent)
        let checkout = try XCTUnwrap(pickup.journey)
        let workspaceID = try XCTUnwrap(ledger.sourceWorkspaceID)
        let model = DinnerFeatureModel(store: ledger, access: { id in
            .init(scope: .local(workspaceID: workspaceID), actorID: "local", shopID: id, assignedShopperID: "local",
                  canPlan: true, canReadBudget: true, hasPaidTools: false, roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(60))
        }, phase: { _ in pickup.journey?.basket?.phase ?? .draft }, clock: { now })
        XCTAssertTrue(model.prepare([.move(occurrenceID: occurrence, day: moved)]))
        let applied = await model.applyPreview(); XCTAssertTrue(applied)
        XCTAssertEqual(pickup.journey, checkout)
        XCTAssertFalse(pickup.isCurrent(copy))
        XCTAssertEqual(ledger.shop?.contributions, shop.contributions)
        let current = try XCTUnwrap(pickup.cookJourney)
        XCTAssertEqual(current.needs, checkout.needs)
        let newText = PickupCookProjection.text(journey: current, allocation: pickup.allocation, result: nil, language: "en-US", at: now, timeZone: zone)
        XCTAssertTrue(newText.contains(moved.iso8601))
        XCTAssertFalse(newText.contains(original.iso8601))
        XCTAssertEqual(pickup.handoffCopy(channel: .cook, versionID: note.id, language: "en-US")?.fullText, oldText)

        let correctionReview = CookHandoffReview(pieces: PickupCookProjection.pieces(journey: current, allocation: pickup.allocation, language: "en-US", timeZone: zone),
                                                timeZoneID: zone.identifier, includesBudget: false, customWording: false, budget: nil)
        let correctionNote = PickupCookNote(id: UUID(), text: newText, language: "en-US", createdAt: now, revision: current.revision, reviewedHandoff: correctionReview)
        let savedCorrection = await pickup.change { $0.notes.append(correctionNote) }; XCTAssertTrue(savedCorrection)
        let currentCopy = try XCTUnwrap(pickup.handoffCopy(channel: .cook, versionID: correctionNote.id, language: "en-US"))
        let correction = pickup.reviewedCorrection(currentCopy, recipient: "Cook", destinationConfirmed: true,
                                                   privateWordingConfirmed: false, paid: true, reviewedRevision: pickup.journey?.revision)
        guard case let .changes(added, removed, _) = correction else { return XCTFail("Expected the reviewed recipient correction") }
        XCTAssertEqual(added, ["Tacos: \(moved.iso8601) · \(moved.timeZoneIdentifier)"])
        XCTAssertEqual(removed, ["Tacos: \(original.iso8601) · \(original.timeZoneIdentifier)"])
        XCTAssertEqual(pickup.journey?.basket, checkout.basket)
        XCTAssertEqual(pickup.journey?.needs, checkout.needs)
        XCTAssertEqual(pickup.journey?.recipientSends, checkout.recipientSends)
    }

    func testNamedServingGroupsPartitionOneMealAndKeepStableNeedIdentities() throws {
        var shop = ShoppingLedger(basis: basis())
        let meal = MealTemplate(title: "Soup", servings: try Rational(6), ingredients: [MealIngredient(name: "Soup portions", quantity: quantity(6))], servingGroups: [ServingGroup(name: "Lunch", servings: try Rational(2), isProtected: true)])
        try shop.chooseMeal(meal)
        let first = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        let second = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(first.needs, second.needs)
        XCTAssertEqual(first.needs.first(where: { $0.priority == .protected })?.amount.amount, try Rational(2))
        XCTAssertEqual(first.needs.first(where: { $0.priority == .required })?.amount.amount, try Rational(4))
    }

    func testUnknownAmountsBlockProjectionAndMissingContextStaysMissing() throws {
        var unknown = ShoppingLedger()
        try unknown.addManualLine(name: "Milk", quantity: nil)
        XCTAssertThrowsError(try LedgerCheckoutAdapter.review(shop: unknown, workspaceRevision: 1, previous: nil)) { error in
            XCTAssertEqual(error as? LedgerCheckoutError, .missingQuantity)
        }
        var knownQuantity = ShoppingLedger()
        try knownQuantity.addManualLine(name: "Milk", quantity: quantity(1))
        let review = try LedgerCheckoutAdapter.review(shop: knownQuantity, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(review.context.branchID, "")
        XCTAssertEqual(review.context.slot, "")
        XCTAssertNil(review.cap)
        XCTAssertFalse(review.lines.isEmpty)
    }

    @MainActor func testBasisOnlyChangeRequiresReviewClearsQuoteAndLeavesOldSnapshotImmutable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        await ledger.open(); await pickup.load()
        let shop = try wrapShop()
        _ = await ledger.change(key: "seed") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        let originalReview = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: nil)
        let started = try await LedgerCheckoutAdapter.apply(originalReview, ledger: ledger, pickup: pickup)
        XCTAssertTrue(started)
        _ = await pickup.setQuote(CheckoutQuote(scope: .wholeCheckout, context: originalReview.context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 3720)))), cap: originalReview.cap)
        _ = await pickup.freeze()
        let original = try XCTUnwrap(pickup.journey)
        let frozen = try XCTUnwrap(pickup.frozenSnapshot)
        let updated = await ledger.editShop(key: "cap", shopID: shop.id) { current in
            var changed = current.basis; changed.cap = Money(minorUnits: 3000); changed.knownFees = Money(minorUnits: 495)
            try current.updateBasis(changed)
        }
        XCTAssertTrue(updated)
        let changedShop = try XCTUnwrap(ledger.shop)
        let review = try LedgerCheckoutAdapter.review(shop: changedShop, workspaceRevision: ledger.revision, previous: original)
        XCTAssertTrue(review.needsApplication)
        XCTAssertNotNil(review.proposal)
        XCTAssertEqual(review.lines.map(\.quantity), originalReview.lines.map(\.quantity))
        let saved = try await LedgerCheckoutAdapter.apply(review, ledger: ledger, pickup: pickup)
        XCTAssertTrue(saved)
        XCTAssertNil(pickup.journey?.quote)
        XCTAssertNil(pickup.journey?.quotedRevisionID)
        XCTAssertEqual(pickup.journey?.basket?.phase, .draft)
        XCTAssertEqual(pickup.journey?.basket?.snapshots.first, frozen)
        XCTAssertEqual(pickup.journey?.cap?.amount, Money(minorUnits: 3000))
        XCTAssertEqual(pickup.journey?.plannedNeeds.filter { $0.priority == .protected }.count, 1)
    }

    @MainActor func testSourceChangesAfterPreviewAreRejectedEvenWhenQuantitiesStayTheSame() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        await ledger.open(); await pickup.load()
        let shop = try wrapShop()
        _ = await ledger.change(key: "seed") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        let stale = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: nil)
        _ = await ledger.editShop(key: "rename-purpose", shopID: shop.id) { current in
            try current.updateMeal(occurrenceID: current.mealOccurrences[0].id, title: "Tuesday tacos", notes: "Keep lunch protected")
        }
        do {
            _ = try await LedgerCheckoutAdapter.apply(stale, ledger: ledger, pickup: pickup)
            XCTFail("A stale source review must not create a checkout")
        } catch { XCTAssertEqual(error as? LedgerCheckoutError, .staleSource) }
        XCTAssertNil(pickup.journey)
        let changed = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: nil)
        XCTAssertEqual(changed.lines, stale.lines)
        XCTAssertNotEqual(changed.needs, stale.needs)
    }

    @MainActor func testSameLinesStillReviewRetailerSourceAndZoneChanges() async throws {
        let shop = try wrapShop()
        let first = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        var previous = PickupJourney(id: shop.id, savedAt: Date())
        previous.basket = try BasketPlan(id: shop.id, revisionID: UUID(), lines: first.lines, createdAt: Date())
        previous.context = first.context; previous.cap = first.cap; previous.plannedNeeds = first.needs
        previous.needDetails = first.details; previous.ledgerBasis = shop.basis; previous.ledgerSourceRevisionID = shop.revisionID
        let unchanged = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: previous)
        XCTAssertFalse(unchanged.needsApplication)
        var changed = shop
        var revisedBasis = changed.basis
        revisedBasis.timeZoneIdentifier = "America/Chicago"
        revisedBasis.retailerPreview = LedgerRetailerPreview(total: Money(minorUnits: 3720), source: "New retailer preview", capturedAt: Date(), includedCharges: ["tax"])
        try changed.updateBasis(revisedBasis)
        let review = try LedgerCheckoutAdapter.review(shop: changed, workspaceRevision: 2, previous: previous)
        XCTAssertTrue(review.needsApplication)
        XCTAssertEqual(review.lines.map(\.id), unchanged.lines.map(\.id))
        XCTAssertEqual(review.context.source, "New retailer preview")
        XCTAssertTrue(review.context.slot.contains("America/Chicago"))
    }

    @MainActor func testNextShopBridgeAndRepeatedOriginActionCreateOneEditableShop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        let urgent = UrgentMealNeed(id: UUID(), food: "Wraps", meal: "Dinner", required: quantity(6), available: quantity(4), due: nil, confirmedAt: Date())
        _ = await pickup.addUrgent(urgent)
        let origin = try XCTUnwrap(pickup.journey?.id)
        let deferred = DeferredPickupNeed(id: UUID(), sourceShopID: origin, line: BasketLine(id: UUID(), name: "Coffee", quantity: quantity(1), expectedCost: .exact(Money(minorUnits: 460))))
        _ = await pickup.change { $0.deferred = [deferred] }
        _ = await pickup.startNextShop(accept: [deferred.id])
        let next = try XCTUnwrap(pickup.journey)
        let first = await LedgerCheckoutAdapter.openNextShop(next, ledger: ledger)
        XCTAssertTrue(first)
        let firstLineIDs = ledger.shop?.lines.map(\.id)
        let second = await LedgerCheckoutAdapter.openNextShop(next, ledger: ledger)
        XCTAssertTrue(second)
        XCTAssertEqual(ledger.workspace.shops.count, 1)
        XCTAssertEqual(ledger.shop?.id, next.id)
        XCTAssertEqual(ledger.shop?.lines.map(\.id), firstLineIDs)
        XCTAssertNil(ledger.shop?.basis.retailerPreview)
        XCTAssertNil(ledger.shop?.basis.slot)
        XCTAssertEqual(ledger.shop?.basis.branch, "")
        pickup.selectedID = origin
        _ = await pickup.startNextShop(accept: [deferred.id])
        XCTAssertEqual(pickup.journey?.id, next.id)
        XCTAssertEqual(pickup.journeys.count, 2)
    }

    @MainActor func testMonthOldMarketCoffeeBoughtByAnotherPersonDropsFromReviewedCheckoutAndOtherDeferralSurvivesRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerURL = directory.appendingPathComponent("ledger.sqlite"), pickupURL = directory.appendingPathComponent("pickup.sqlite")
        let now = Date(), prior = now.addingTimeInterval(-32 * 86400)
        let ledger = LedgerModel(databaseURL: ledgerURL), pickup = PickupModel(databaseURL: pickupURL)
        await ledger.open(); await pickup.load()
        var old = ShoppingLedger(title: "Previous market", basis: .init(branch: "South market", slot: prior, timeZoneIdentifier: "America/New_York"))
        let coffee = try old.addManualLine(name: "Coffee", quantity: quantity(1), at: prior)
        try old.approveStaple(lineID: coffee, purpose: "After lunch", at: prior)
        try old.setChecked(lineID: coffee, checked: true, at: prior)
        let tea = try old.addManualLine(name: "Tea", quantity: quantity(8), at: prior)
        try old.approveStaple(lineID: tea, purpose: "Breakfast", at: prior)
        let seeded = await ledger.change(key: "prior-market") { workspace in
            workspace.shops = [old]; workspace.selectedShopID = old.id
        }
        XCTAssertTrue(seeded)
        let initial = try LedgerCheckoutAdapter.review(shop: old, workspaceRevision: ledger.revision, previous: nil)
        let started = try await LedgerCheckoutAdapter.apply(initial, ledger: ledger, pickup: pickup)
        XCTAssertTrue(started)
        let oldQuote = CheckoutQuote(scope: .wholeCheckout, context: initial.context, pricing: .inclusiveTotal(.exact(.init(minorUnits: 2750))))
        let quoted = await pickup.setQuote(oldQuote, cap: nil)
        XCTAssertTrue(quoted)
        let oldCoffee = BasketLine(id: coffee, name: "Coffee", quantity: quantity(1), expectedCost: .exact(.init(minorUnits: 460)))
        let oldRice = BasketLine(id: UUID(), name: "Rice", quantity: quantity(2), expectedCost: .exact(.init(minorUnits: 330)))
        let deferrals = [oldCoffee,oldRice].map { DeferredPickupNeed(id: UUID(), sourceShopID: old.id, line: $0, status: "review") }
        let deferred = await pickup.change { $0.deferred = deferrals }
        XCTAssertTrue(deferred)
        let source = try XCTUnwrap(pickup.journey)
        let accepted = await pickup.startNextShop(accept: [deferrals[0].id], sourceID: old.id, sourceRevision: source.revision)
        XCTAssertTrue(accepted)
        let target = try XCTUnwrap(pickup.journey)
        let opened = await LedgerCheckoutAdapter.openNextShop(target, ledger: ledger)
        XCTAssertTrue(opened)
        let reviewed = try XCTUnwrap(ledger.workspace.priorStaples(for: target.id).first { $0.line.id == coffee })
        XCTAssertEqual(reviewed.approval.branch, "South market"); XCTAssertEqual(reviewed.approval.purpose, "After lunch")
        XCTAssertEqual(reviewed.line.checkedAt, prior)
        let current = try XCTUnwrap(ledger.shop?.openStapleMatches(named: "Coffee").first)
        let mark = HandledStapleLine(lineID: current.id, boughtBy: "Ana")
        let saved = await ledger.change(key: "bought-by-ana") { try $0.applyStaple(reviewed, choice: .alreadyHandled, quantity: nil, handledLine: mark, at: now) }
        XCTAssertTrue(saved)
        XCTAssertEqual(pickup.journey?.basket?.current.lines.map(\.name), ["Coffee"])
        let prices = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision, previous: target)
        XCTAssertTrue(prices.lines.isEmpty)
        let applied = try await LedgerCheckoutAdapter.apply(prices, ledger: ledger, pickup: pickup)
        XCTAssertTrue(applied)
        let reopenedLedger = LedgerModel(databaseURL: ledgerURL), reopenedPickup = PickupModel(databaseURL: pickupURL)
        await reopenedLedger.open(); await reopenedPickup.load()
        XCTAssertEqual(reopenedLedger.workspace.shops.first, old)
        XCTAssertEqual(reopenedLedger.shop?.stapleReviews?.first?.handledLine, mark)
        XCTAssertEqual(reopenedLedger.shop?.handled.first?.handledBy, "Ana")
        XCTAssertEqual(reopenedLedger.workspace.priorStaples(for: target.id).map(\.line.id), [tea])
        let savedTrip = try XCTUnwrap(reopenedPickup.journeys.first { $0.id == target.id })
        XCTAssertEqual(savedTrip.basket?.current.lines.count, 0)
        XCTAssertNil(savedTrip.quote)
        XCTAssertEqual(savedTrip.deferred.map(\.id), [deferrals[1].id])
        XCTAssertEqual(savedTrip.deferred.first?.status, "review")
        XCTAssertEqual(reopenedPickup.journeys.first { $0.id == old.id }, source)
        XCTAssertEqual(reopenedLedger.shop?.basis.branch, "")
        XCTAssertNil(reopenedLedger.shop?.basis.slot)
        let enteredBasis = await reopenedLedger.editShop(key: "review-this-branch-and-slot", shopID: target.id) {
            try $0.updateBasis(.init(branch: "East market", slot: now, timeZoneIdentifier: "America/Chicago"))
        }
        XCTAssertTrue(enteredBasis)
        let selectedTea = try XCTUnwrap(reopenedLedger.workspace.priorStaples(for: target.id).first)
        let added = await reopenedLedger.change(key: "three-teas") {
            try $0.applyStaple(selectedTea, choice: .needed, quantity: self.quantity(3), at: now)
        }
        XCTAssertTrue(added)
        let newReview = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(reopenedLedger.shop), workspaceRevision: reopenedLedger.revision, previous: savedTrip)
        XCTAssertEqual(newReview.lines.map(\.name), ["Tea"])
        XCTAssertEqual(newReview.lines.first?.quantity.amount, try Rational(3))
        guard case .unknown = try XCTUnwrap(newReview.lines.first?.expectedCost) else { return XCTFail("The new tea needs a fresh price") }
        let copied = try await LedgerCheckoutAdapter.apply(newReview, ledger: reopenedLedger, pickup: reopenedPickup)
        XCTAssertTrue(copied)
        XCTAssertNil(reopenedPickup.journey?.quote)
        let newQuote = CheckoutQuote(scope: .wholeCheckout, context: newReview.context, pricing: .inclusiveTotal(.exact(.init(minorUnits: 310))))
        let priced = await reopenedPickup.setQuote(newQuote, cap: nil)
        XCTAssertTrue(priced)
        XCTAssertEqual(reopenedPickup.journey?.quote, newQuote)
        XCTAssertEqual(reopenedPickup.journey?.deferred.map(\.id), [deferrals[1].id])
        XCTAssertEqual(reopenedPickup.journeys.first { $0.id == old.id }?.quote, oldQuote)
        let reopened = await reopenedLedger.editShop(key: "reopen-old-coffee", shopID: old.id) { try $0.reopen(lineID: coffee) }
        XCTAssertTrue(reopened)
        XCTAssertEqual(reopenedLedger.workspace.shops.first?.recentlyChecked.count, 0)
    }

    private func wrapShop() throws -> ShoppingLedger {
        var shop = ShoppingLedger(title: "Tuesday pickup", basis: basis())
        let line = try shop.addManualLine(name: "Wraps", quantity: quantity(12))
        let supply = try XCTUnwrap(shop.contributions(forLineID: line).first?.id)
        for (title, count) in [("Tacos", Int64(6)), ("Quesadillas", Int64(4))] {
            let occurrence = try shop.chooseMeal(MealTemplate(title: title, ingredients: [MealIngredient(name: "Wraps", quantity: quantity(count))]))
            let demand = try XCTUnwrap(shop.mealOccurrences.first { $0.id == occurrence }?.ingredientContributionIDs.first)
            try shop.linkContribution(contributionID: demand, within: supply, quantity: quantity(count))
        }
        try shop.addProtectedNeed(name: "Wraps", quantity: quantity(2), purpose: "Lunch", within: supply)
        return shop
    }

    @MainActor func testCheckoutMealProvenanceDistinguishesSameNamedOccurrencesAndSurvivesLegacyAndSQLiteRoundTrips() async throws {
        var shop = ShoppingLedger(basis: basis())
        let lunch = ServingGroup(name: "Lunch", servings: try Rational(2), isProtected: true)
        let recipe = MealTemplate(title: "Soup", servings: try Rational(6),
            ingredients: [MealIngredient(name: "Soup portions", quantity: quantity(6))], servingGroups: [lunch])
        let first = try shop.chooseMeal(recipe)
        let second = try shop.chooseMeal(recipe)
        XCTAssertNotEqual(first, second)
        let review = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: 1, previous: nil)
        XCTAssertEqual(review.details.count, 4)
        for occurrenceID in [first, second] {
            let occurrence = try XCTUnwrap(shop.mealOccurrences.first { $0.id == occurrenceID })
            let details = review.details.filter { $0.sourceOccurrenceID == occurrenceID }
            XCTAssertEqual(details.count, 2)
            XCTAssertEqual(Set(details.compactMap(\.sourceContributionID)), Set(occurrence.ingredientContributionIDs))
            XCTAssertTrue(details.allSatisfy { $0.sourceLedgerRevisionID == shop.revisionID })
            for detail in details {
                let need = try XCTUnwrap(review.needs.first { $0.id == detail.id })
                if need.priority == .protected {
                    XCTAssertEqual(detail.sourceGroupID, lunch.id)
                    XCTAssertEqual(need.amount.amount, try Rational(2))
                } else {
                    XCTAssertNil(detail.sourceGroupID)
                    XCTAssertEqual(need.amount.amount, try Rational(4))
                }
            }
        }
        let encoded = try JSONEncoder().encode(review.details)
        XCTAssertEqual(try JSONDecoder().decode([PickupNeedDetail].self, from: encoded), review.details)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let legacyObjects = objects.map { object -> [String: Any] in
            var old = object
            for key in ["sourceOccurrenceID", "sourceGroupID", "sourceLedgerRevisionID"] { old.removeValue(forKey: key) }
            return old
        }
        let legacy = try JSONDecoder().decode([PickupNeedDetail].self, from: JSONSerialization.data(withJSONObject: legacyObjects))
        var expectedLegacy = review.details
        for index in expectedLegacy.indices {
            expectedLegacy[index].sourceOccurrenceID = nil
            expectedLegacy[index].sourceGroupID = nil
            expectedLegacy[index].sourceLedgerRevisionID = nil
        }
        XCTAssertEqual(legacy, expectedLegacy, "Old details remain intact without inventing occurrence/group provenance")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pickup.sqlite")
        let pickup = PickupModel(databaseURL: url)
        let started = await pickup.start(from: review.lines, shopID: shop.id, context: review.context,
            plannedNeeds: review.needs, ledgerBasis: shop.basis, ledgerSourceRevisionID: shop.revisionID,
            needDetails: review.details)
        XCTAssertTrue(started)
        let stored = try XCTUnwrap(pickup.journey)
        let reopened = PickupModel(databaseURL: url)
        await reopened.load()
        XCTAssertEqual(reopened.journey, stored)
        XCTAssertEqual(reopened.journey?.needDetails, review.details)
        let partial = await reopened.change { $0.needDetails[0].sourceOccurrenceID = nil }
        XCTAssertFalse(partial, "A partially populated new provenance tuple is not a valid saved snapshot")
        XCTAssertEqual(reopened.journey, stored)
    }

    private func basis() -> ShopBasis {
        ShopBasis(branch: "Main branch", mode: .pickup, slot: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "America/New_York", cap: Money(minorUnits: 3800))
    }
    private func quantity(_ count: Int64) -> Quantity { Quantity(amount: try! Rational(count), unit: .count, originalLiteral: String(count)) }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
