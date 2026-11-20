import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryPackStockReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    private final class Authority { var allowed = true }
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let ledger: LedgerModel
        let producer: PickupModel
        let store: ComparisonStore
        let repository: PantryRepository
        let mapping: PantryLegacyMigration.Plan
        let shop: ShoppingLedger
        let food: UUID
    }
    private func fixture(otherShop: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let producer = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        let store = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        cleanup.track(ledger, producer, store)
        await ledger.open(); await producer.load()
        var shop = ShoppingLedger(title: "Canonical packs", basis: .init(branch: "Main", mode: .pickup,
            slot: now, timeZoneIdentifier: "America/New_York"))
        let food = try shop.addManualLine(name: "Wraps", quantity: q(12))
        let contribution = try XCTUnwrap(shop.contributions(forLineID: food).first)
        try shop.addProtectedNeed(name: "Wraps", quantity: q(4), purpose: "Lunch", within: contribution.id)
        let saved = await ledger.change(key: "fixture") { $0.shops = [shop]; $0.selectedShopID = shop.id }; XCTAssertTrue(saved)
        let checkout = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: nil)
        let started = try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: producer); XCTAssertTrue(started)
        let stocked = await producer.saveStockLot(.init(id: food, foodID: food, name: "Wraps at home", usable: q(12),
            confirmedAt: now, source: .freezer), in: shop.id); XCTAssertTrue(stocked)
        if otherShop {
            let id = UUID(), need = UUID()
            let second = await producer.start(from: [.init(id: food, name: "Wraps", quantity: q(8), expectedCost: .unknown(reason: "Review"))],
                shopID: id, context: .init(storeID: "Main", branchID: "Main", mode: .pickup, slot: "Later", commitmentsID: id,
                    observedAt: now, source: "Fixture"), plannedNeeds: [.init(id: need, orderLineID: food, name: "Other protected lunch", amount: q(8), priority: .protected)])
            XCTAssertTrue(second)
        }
        for head in try await producer.archiveSnapshot().records {
            _ = try await store.save(id: head.id, title: head.title, payload: head.payload, savedAt: head.savedAt)
        }
        let heads = try await store.list().map(PantryLegacyMigration.SourceHead.init)
        let mapping = try PantryLegacyMigration.map(originID: store.workspaceID, heads: heads, ledger: .unavailable, at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: await store.inventorySourceToken(),
            inventoryRevision: await store.inventoryState().revision, at: now)
        _ = try await store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await store.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let repository = PantryRepository(store: store, authorize: { true }); cleanup.track(repository)
        return .init(directory: directory, cleanup: cleanup, ledger: ledger, producer: producer, store: store, repository: repository, mapping: mapping, shop: shop, food: food)
    }
    private func context(_ f: Fixture, mapping: PantryLegacyMigration.Plan? = nil) async throws -> PantryPackStockReview.Context {
        .init(snapshot: try await f.repository.load(at: now), mapping: mapping ?? f.mapping, asOf: now)
    }
    private func proof(_ f: Fixture, context: PantryPackStockReview.Context) throws -> LedgerCanonicalPackStockEvidence {
        try PantryPackStockReview.evidence(shop: f.shop, lineID: f.food,
            requirement: LedgerPackRequirement.review(shop: f.shop, lineID: f.food), bindings: [], context: context)
    }
    private func selection(_ f: Fixture, proof: LedgerCanonicalPackStockEvidence) throws -> LedgerPackSelection {
        let requirement = try LedgerPackRequirement.review(shop: f.shop, lineID: f.food)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity,
            confirmedAtHome: try proof.confirmedQuantity(for: requirement), protectedAmount: requirement.protectedQuantity,
            offerA: .init(id: "a", label: "Eight", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "b", label: "Six", usableQuantity: q(6), price: .init(minorUnits: 250)))
        return try .init(id: UUID(), workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID), shop: f.shop, lineID: f.food,
            request: request, selectedOfferID: "a", at: now, source: "Fixture", canonicalStockEvidence: proof)
    }
    private func recount(_ f: Fixture, count: InventoryCount) async throws {
        let before = try await f.repository.load(at: now), lot = try XCTUnwrap(before.lots.first)
        _ = try await f.repository.apply(.init(id: UUID(), originID: f.store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(count, observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
    }

    func testCompleteOtherShopProtectionAndIndependentRecountReplaceLegacyTwelve() async throws {
        let f = try await fixture(otherShop: true), initial = try await context(f)
        let old = try proof(f, context: initial), choice = try selection(f, proof: old)
        XCTAssertEqual(choice.request.confirmedAtHome?.amount, try Rational(4))
        XCTAssertEqual(choice.selectedResult.packsToBuy, 1)
        XCTAssertEqual(old.basis.sourceHeads.count, 2)
        try await recount(f, count: .exact(q(8)))
        let current = try proof(f, context: await context(f))
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(try old.hasSameMaterial(as: current))
        XCTAssertFalse(try choice.isCurrent(in: f.shop, workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID), currentCanonicalEvidence: current))
        XCTAssertEqual(f.producer.journeys.first(where: { $0.id == f.shop.id })?.stockLots.first?.usable.amount, try Rational(12))
    }

    func testUnknownCountKeepsGrossPurchaseAndActivePantryCannotUseLegacyEvidence() async throws {
        let f = try await fixture()
        try await recount(f, count: .someLeft)
        let current = try proof(f, context: await context(f)), choice = try selection(f, proof: current)
        XCTAssertNil(choice.request.confirmedAtHome); XCTAssertFalse(choice.isNoPurchase)
        XCTAssertEqual(choice.selectedResult.packsToBuy, 2)
        XCTAssertFalse(try LedgerPackStockReview.isCurrent(choice, shop: f.shop, workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID),
            journey: f.producer.journey, pickupWorkspaceID: f.store.workspaceID, bindings: []))
        XCTAssertTrue(try LedgerPackStockReview.isCurrent(choice, shop: f.shop, workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID),
            journey: f.producer.journey, pickupWorkspaceID: f.store.workspaceID, bindings: [], currentCanonicalEvidence: current, pantryIsActive: true))
        let legacyReview = try LedgerPackReview.prepare(ledger: f.ledger, shopID: f.shop.id, lineID: f.food,
            offerA: choice.request.offerA, offerB: choice.request.offerB, itemCap: nil, at: now, source: "Old", pickup: f.producer)
        let legacy = try LedgerPackSelection(id: UUID(), workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID), shop: f.shop,
            lineID: f.food, request: legacyReview.request, selectedOfferID: "a", at: now, source: "Old", stockEvidence: legacyReview.stockEvidence)
        XCTAssertFalse(try LedgerPackStockReview.isCurrent(legacy, shop: f.shop, workspaceID: XCTUnwrap(f.ledger.sourceWorkspaceID),
            journey: f.producer.journey, pickupWorkspaceID: f.store.workspaceID, bindings: [], pantryIsActive: true))
    }

    func testAppliedBasketMayAdvanceNotesButAnyRecountInvalidatesMaterial() async throws {
        let f = try await fixture(), original = try proof(f, context: await context(f)), choice = try selection(f, proof: original)
        XCTAssertTrue(choice.isNoPurchase)
        let updated = await f.producer.change { journey in
            var basket = try XCTUnwrap(journey.basket)
            try basket.apply(.init(id: UUID(), baseRevisionID: basket.current.id, revisionID: UUID(), changes: [.remove(f.food)]), at: self.now)
            journey.basket = basket; journey.ledgerPackSelections = [choice]
        }; XCTAssertTrue(updated)
        let noted = await f.producer.change { journey in
            journey.notes.append(.init(id: UUID(), text: "Take bags", language: "en", createdAt: self.now, revision: journey.revision))
        }; XCTAssertTrue(noted)
        let heads = try await f.producer.archiveSnapshot().records.map(PantryLegacyMigration.SourceHead.init)
        let mapping = try PantryLegacyMigration.map(originID: f.store.workspaceID, heads: heads, ledger: .unavailable, at: now)
        let live = try await context(f, mapping: mapping), journey = try XCTUnwrap(f.producer.journey)
        XCTAssertNotEqual(try proof(f, context: live), original)
        XCTAssertTrue(PantryPackStockReview.basketBasisIsCurrent(journey, shop: f.shop,
            workspaceID: try XCTUnwrap(f.ledger.sourceWorkspaceID), bindings: [], context: live))
        XCTAssertFalse(LedgerPackStockReview.basketBasisIsCurrent(journey, pickupWorkspaceID: f.store.workspaceID), "An unadapted caller cannot treat version three as no-stock evidence.")
        try await recount(f, count: .exact(q(12)))
        let changed = try await context(f, mapping: mapping)
        XCTAssertFalse(PantryPackStockReview.basketBasisIsCurrent(journey, shop: f.shop,
            workspaceID: try XCTUnwrap(f.ledger.sourceWorkspaceID), bindings: [], context: changed))
    }

    func testMissingReceiptProvenanceDoesNotGrantCoverageOrNoPurchase() async throws {
        let f = try await fixture()
        try await recount(f, count: .exact(q(0)))
        let before = try await f.repository.load(at: now)
        let key = ReceiptKey(sourceEventID: "unlinked", orderLineID: f.food, branchID: "Main", segmentID: "one")
        _ = try await f.repository.apply(.init(id: UUID(), originID: f.store.workspaceID, lotID: UUID(), eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: f.food, name: "Unlinked arrival",
                source: .receipt(originID: f.store.workspaceID, key: key), location: .cupboard, unit: .count,
                count: .exact(q(12))), observationID: UUID())), reviewedInventoryRevision: before.state.revision, at: now)
        let current = try proof(f, context: await context(f)), choice = try selection(f, proof: current)
        XCTAssertFalse(current.allocations.isEmpty, "The global allocator retains provisional physical backing.")
        XCTAssertTrue(current.lots.contains { $0.eligibility.receiptEvidenceDigest?.count == 32 })
        XCTAssertNil(choice.request.confirmedAtHome); XCTAssertFalse(choice.isNoPurchase)
    }

    func testReopenedDraftRejectsOldPriceForDifferentPacksOfEqualWeight() async throws {
        let f = try await fixture()
        var shop = ShoppingLedger(title: "Beans", basis: f.shop.basis)
        try shop.commitImport(shop.stageImport(text: "2 × 15 oz beans"))
        let lineID = try XCTUnwrap(shop.lines.first?.id)
        try shop.pickPart(lineID: lineID, amount: Rational(30), expectedRevision: shop.revisionID)
        // Legacy trip picks encoded just the amount and time; packaging evidence lived on the source line.
        let encoded = try JSONEncoder().encode(shop)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var rows = try XCTUnwrap(document["lines"] as? [[String: Any]])
        let pick = try XCTUnwrap(rows[0]["tripPick"] as? [String: Any])
        rows[0]["tripPick"] = pick.filter { ["amount", "at"].contains($0.key) }
        document["lines"] = rows
        shop = try JSONDecoder().decode(ShoppingLedger.self, from: JSONSerialization.data(withJSONObject: document))
        let added = await f.ledger.change(key: "beans") { $0.shops.append(shop); $0.selectedShopID = shop.id }
        XCTAssertTrue(added)
        let workspace = try XCTUnwrap(f.ledger.sourceWorkspaceID)
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: lineID)
        let large = Quantity(amount: try Rational(30), unit: .ounce, originalLiteral: "30")
        let small = Quantity(amount: try Rational(15), unit: .ounce, originalLiteral: "15")
        let price = Money(minorUnits: 450)
        let request = ComparisonRequest(itemName: requirement.name, needed: requirement.quantity, protectedAmount: requirement.protectedQuantity,
            offerA: .init(id: "large", label: "One 30 oz can", usableQuantity: large, price: price),
            offerB: .init(id: "small", label: "15 oz cans", usableQuantity: small, price: Money(minorUnits: 300)))
        let offer = try LedgerPackSelection(workspaceID: workspace, shop: shop, lineID: lineID, request: request,
                                            selectedOfferID: "large", at: now, source: "Shelf label")
        let fresh = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: f.ledger.revision, previous: nil,
                                                     packSelections: [offer], workspaceID: workspace, pantryIsActive: true)
        let picked = try XCTUnwrap(fresh.lines.first)
        XCTAssertEqual(picked.packages, [.init(count: 2, amountPerPack: small.amount, unit: .ounce)])
        XCTAssertEqual(fresh.unreviewedPackLineIDs, [lineID])
        guard case .unknown = picked.expectedCost else { return XCTFail("Two 15 oz cans cannot use the single-can price") }

        let gross = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: f.ledger.revision, previous: nil)
        let opened = try await LedgerCheckoutAdapter.apply(gross, ledger: f.ledger, pickup: f.producer)
        XCTAssertTrue(opened)
        // Earlier versions saved the offered packaging and price for a fully checked line.
        let oldLine = BasketLine(id: lineID, name: picked.name, quantity: try XCTUnwrap(offer.purchasedQuantity),
                                 expectedCost: .exact(price), packages: [.init(count: 1, amountPerPack: large.amount, unit: .ounce)])
        func saveAndReopen(_ line: BasketLine, _ selection: LedgerPackSelection) async throws -> (PickupJourney, PantryPackStockReview.Context) {
            let saved = await f.producer.change { journey in
                var basket = try XCTUnwrap(journey.basket)
                try basket.apply(.init(id: UUID(), baseRevisionID: basket.current.id, revisionID: UUID(), changes: [.upsert(line)]), at: self.now)
                journey.basket = basket
                journey.ledgerPackSelections = [selection]
            }
            XCTAssertTrue(saved)
            let heads = try await f.producer.archiveSnapshot().records.map(PantryLegacyMigration.SourceHead.init)
            let head = try XCTUnwrap(heads.first { $0.id == shop.id })
            let reopened = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
            XCTAssertEqual(reopened.basket?.current.lines, [line])
            XCTAssertEqual(reopened.mealSource?.shop, shop)
            let mapping = try PantryLegacyMigration.map(originID: f.store.workspaceID, heads: heads, ledger: .unavailable, at: now)
            return (reopened, try await context(f, mapping: mapping))
        }
        XCTAssertTrue(try offer.isCurrent(in: shop, workspaceID: workspace))
        let (reopened, live) = try await saveAndReopen(oldLine, offer)
        XCTAssertFalse(PantryPackStockReview.basketBasisIsCurrent(reopened, shop: shop, workspaceID: workspace, bindings: [], context: live))
        XCTAssertFalse(LedgerPackStockReview.basketBasisIsCurrent(reopened, pickupWorkspaceID: f.store.workspaceID))

        var history = reopened
        var basket = try XCTUnwrap(history.basket)
        let frozen = try basket.freeze(snapshotID: UUID(), expectedRevision: basket.current.id, at: now)
        try basket.reportPlaced(.init(id: UUID(), intentID: UUID(), snapshotID: frozen.id, reportedAt: now))
        history.basket = basket
        XCTAssertTrue(PantryPackStockReview.basketBasisIsCurrent(history, shop: shop, workspaceID: workspace, bindings: [], context: live))
        XCTAssertTrue(LedgerPackStockReview.basketBasisIsCurrent(history, pickupWorkspaceID: f.store.workspaceID))
        XCTAssertEqual(frozen.revision.lines, [oldLine])

        let matching = try LedgerPackSelection(workspaceID: workspace, shop: shop, lineID: lineID, request: request,
                                               selectedOfferID: "small", at: now, source: "Shelf label")
        let corrected = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: f.ledger.revision, previous: reopened,
                                                         packSelections: [matching], workspaceID: workspace, pantryIsActive: true)
        let matchedLine = try XCTUnwrap(corrected.lines.first)
        XCTAssertEqual(matchedLine.packages, picked.packages)
        XCTAssertEqual(matchedLine.expectedCost, .exact(Money(minorUnits: 600)))
        XCTAssertEqual(corrected.packSelections, [matching])
        let (matched, matchedContext) = try await saveAndReopen(matchedLine, matching)
        XCTAssertTrue(PantryPackStockReview.basketBasisIsCurrent(matched, shop: shop, workspaceID: workspace, bindings: [], context: matchedContext))
        XCTAssertTrue(LedgerPackStockReview.basketBasisIsCurrent(matched, pickupWorkspaceID: f.store.workspaceID))
    }

    func testActiveModelPrepareUsesCanonicalReadAndRevokedAccessCannotFallBack() async throws {
        let f = try await fixture(), instant = now, authority = Authority()
        try await recount(f, count: .exact(q(4)))
        let ledgerStore = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        let pending = try PantryPickupPendingStore(directory: f.directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: f.store.workspaceID, ledgerWorkspaceID: ledgerStore.workspaceID)
        let model = PickupModel(store: f.store, clock: { instant }, pantry: .init(ledger: ledgerStore,
            pendingStore: pending, gate: PantryMutationGate(), authorize: { authority.allowed }))
        f.cleanup.track(ledgerStore, model)
        await model.load(); XCTAssertTrue(model.ready, model.error ?? "")
        let makeReview = {
            try LedgerPackReview.prepare(ledger: f.ledger, shopID: f.shop.id, lineID: f.food,
                offerA: .init(id: "a", label: "Eight", usableQuantity: self.q(8), price: .init(minorUnits: 300)),
                offerB: .init(id: "b", label: "Six", usableQuantity: self.q(6), price: .init(minorUnits: 250)),
                itemCap: nil, at: instant, source: "Shelf", pickup: model)
        }
        let review = try makeReview()
        XCTAssertNil(review.stockEvidence); XCTAssertNotNil(review.canonicalStockEvidence)
        XCTAssertEqual(review.request.confirmedAtHome?.amount, try Rational(4))
        XCTAssertEqual(review.result.offerA.packsToBuy, 1)
        authority.allowed = false
        XCTAssertThrowsError(try makeReview())
        XCTAssertTrue(model.pantryIsActive)
    }

    func testCommittedLegacyReplaySurvivesChangedStockButDifferentOfferConflicts() async throws {
        let f = try await fixture()
        let review = try LedgerPackReview.prepare(ledger: f.ledger, shopID: f.shop.id, lineID: f.food,
            offerA: .init(id: "a", label: "Eight", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "b", label: "Six", usableQuantity: q(6), price: .init(minorUnits: 250)),
            itemCap: nil, at: now, source: "Shelf", pickup: f.producer)
        let saved = try await review.save(offerID: "a", ledger: f.ledger, pickup: f.producer); XCTAssertTrue(saved)
        let revision = f.ledger.revision
        let changed = await f.producer.change { $0.stockLots = [] }; XCTAssertTrue(changed)
        let replayed = try await review.save(offerID: "a", ledger: f.ledger, pickup: f.producer); XCTAssertTrue(replayed)
        XCTAssertEqual(f.ledger.revision, revision)
        do { _ = try await review.save(offerID: "b", ledger: f.ledger, pickup: f.producer); XCTFail("Changed operation body") }
        catch { XCTAssertEqual(error as? LedgerPackError, .operationConflict) }
    }
}
