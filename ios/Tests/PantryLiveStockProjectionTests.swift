import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryLiveStockProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64) -> Quantity { .init(amount: try! Rational(amount), unit: .count, originalLiteral: String(amount)) }
    private struct Fixture {
        let cleanup: SQLiteFixtureDirectory
        let store: ComparisonStore
        let repository: PantryRepository
        let mapping: PantryLegacyMigration.Plan
        let journeys: [PickupJourney]
    }

    private func activate(_ journeys: [PickupJourney]) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        for journey in journeys {
            try PickupModel.validate(journey)
            _ = try await store.save(id: journey.id, title: "Projection fixture", payload: JSONEncoder().encode(journey), savedAt: journey.savedAt)
        }
        let mapping = try PantryLegacyMigration.map(originID: store.workspaceID,
            heads: try await store.list().map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let package = try PantryMigrationPackage.build(mapping, migrationID: UUID(), sourceToken: await store.inventorySourceToken(),
            inventoryRevision: await store.inventoryState().revision, at: now)
        _ = try await store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await store.finishInventoryMigration(id: package.plan.migrationID, at: now)
        let repository = PantryRepository(store: store, authorize: { true })
        cleanup.track(repository)
        return Fixture(cleanup: cleanup, store: store, repository: repository, mapping: mapping, journeys: journeys)
    }

    private func manualJourneys(twoLots: Bool = false) -> (PickupJourney, PickupJourney, UUID, UUID) {
        let food = UUID(), secondLot = UUID()
        let stock = ConfirmedStockLot(id: food, foodID: food, name: "Wraps A", usable: q(twoLots ? 4 : 8),
            confirmedAt: now, source: .pantry, useFirst: true)
        var first = PickupJourney(id: UUID(), savedAt: now)
        first.stockLots = [stock]
        if twoLots {
            first.stockLots.append(.init(id: secondLot, foodID: food, name: "Wraps B", usable: q(4), confirmedAt: now, source: .freezer))
        } else {
            first.stockNeeds = [.init(id: UUID(), foodID: food, name: "Dinner", amount: q(3), priority: .required)]
        }
        var second = PickupJourney(id: UUID(), savedAt: now)
        second.originShopID = first.id
        second.stockLots = first.stockLots
        second.stockNeeds = [.init(id: UUID(), foodID: food, name: "Tomorrow's lunch", amount: q(twoLots ? 4 : 2), priority: .protected)]
        return (first, second, food, secondLot)
    }

    @discardableResult private func change(_ lotID: UUID, _ change: InventoryChange, fixture: Fixture) async throws -> PantryRepository.Snapshot {
        let before = try await fixture.repository.load(at: now)
        let lot = try XCTUnwrap(before.lots.first { $0.id == lotID })
        let result = try await fixture.repository.apply(.init(id: UUID(), originID: fixture.store.workspaceID, lotID: lotID,
            eventID: UUID(), expectedRevision: lot.revision, occurredAt: now, change: change),
            reviewedInventoryRevision: before.state.revision, at: now)
        return result.current
    }

    func testIndependentPantryCountAndOtherShopClaimReplaceCopiedEightCount() async throws {
        let (first, second, food, _) = manualJourneys()
        let fixture = try await activate([first, second])
        let initial = try await fixture.repository.load(at: now)
        let lot = try XCTUnwrap(initial.lots.first)
        let old = try PantryLiveStockProjection.build(snapshot: initial, mapping: fixture.mapping, journeyID: first.id, at: now)
        XCTAssertEqual(old.confirmedQuantity(for: first.stockNeeds[0].id), q(3))
        XCTAssertEqual(old.globallyFreeLots.first?.usable, q(3))
        let updated = try await change(lot.id, .count(.exact(q(4)), observationID: UUID()), fixture: fixture)
        let dinner = try PantryLiveStockProjection.build(snapshot: updated, mapping: fixture.mapping, journeyID: first.id, at: now)
        let lunch = try PantryLiveStockProjection.build(snapshot: updated, mapping: fixture.mapping, journeyID: second.id, at: now)
        XCTAssertEqual(dinner.confirmedQuantity(for: first.stockNeeds[0].id), q(2))
        XCTAssertEqual(dinner.demands.first?.shortfall, q(1))
        let bridged = try dinner.legacyAllocation()
        XCTAssertEqual(bridged.demands.first?.id, first.stockNeeds[0].id)
        XCTAssertEqual(bridged.demands.first?.allocated, try Rational(2))
        XCTAssertEqual(bridged.demands.first?.shortfall, .one)
        XCTAssertEqual(bridged.allocations.first?.lotID, food)
        XCTAssertEqual(bridged.remainingLots.first?.remainingUnallocated, .zero)
        XCTAssertFalse(bridged.confirmedCoverageComplete)
        XCTAssertEqual(lunch.confirmedQuantity(for: second.stockNeeds[0].id), q(2))
        XCTAssertTrue(dinner.globallyFreeLots.isEmpty)
        XCTAssertTrue(lunch.globallyFreeLots.isEmpty)
        XCTAssertEqual(dinner.allocations.map(\.legacyNeedID), [first.stockNeeds[0].id])
        XCTAssertEqual(dinner.allocations.first?.readerLotID, food)
        XCTAssertEqual(dinner.lots.first?.scopedLegacyLotIDs, [food])
        XCTAssertNotEqual(dinner.lots.first?.currentObservationID, old.lots.first?.currentObservationID)
        XCTAssertNotEqual(dinner.basis, old.basis)
        XCTAssertEqual(first.stockLots.first?.usable, q(8), "Historical source bytes remain unchanged.")
        let all = dinner.allocations + lunch.allocations
        XCTAssertEqual(try all.reduce(Rational.zero) { try $0.adding($1.quantity.amount) }, try Rational(4))
    }

    func testCanonicalExactPinWinsOverUseFirstAndUnknownHoldNeverBecomesFree() async throws {
        let (first, second, _, secondLot) = manualJourneys(twoLots: true)
        let fixture = try await activate([first, second])
        let initial = try await fixture.repository.load(at: now)
        let target = try XCTUnwrap(initial.lots.first { $0.source == .manual(originID: fixture.store.workspaceID, sourceID: secondLot) })
        let original = try XCTUnwrap(initial.reservations.first)
        let pinned = InventoryReservation(id: original.id, originID: original.originID, revision: original.revision + 1,
            foodID: original.foodID, lotID: target.id, name: original.name, amount: original.amount, priority: .protected)
        _ = try await fixture.store.commitInventory(.init(workspaceID: fixture.store.workspaceID, operationID: UUID(),
            expectedRevision: initial.state.revision, request: Data("review exact physical lunch pin".utf8),
            writes: [.init(record: .init(key: .init(.reservation, pinned.id), revision: pinned.revision,
                payload: JSONEncoder().encode(pinned), lotID: target.id), expectedRevision: original.revision)]), at: now)
        let snapshot = try await fixture.repository.load(at: now)
        let scope = try PantryLiveStockProjection.build(snapshot: snapshot, mapping: fixture.mapping, journeyID: second.id, at: now)
        XCTAssertEqual(scope.demands.first?.pinnedCanonicalLotID, target.id)
        XCTAssertEqual(scope.allocations.first?.canonicalLotID, target.id)
        XCTAssertEqual(scope.allocations.first?.readerLotID, secondLot)
        XCTAssertEqual(scope.globallyFreeLots.map(\.name), ["Wraps A"])
        XCTAssertEqual(scope.globallyFreeLots.first?.usable, q(4))
        let unknown = try await change(target.id, .count(.someLeft, observationID: UUID()), fixture: fixture)
        let held = try PantryLiveStockProjection.build(snapshot: unknown, mapping: fixture.mapping, journeyID: second.id, at: now)
        XCTAssertNil(held.confirmedQuantity(for: second.stockNeeds[0].id))
        XCTAssertNil(held.lot(canonicalID: target.id)?.free)
        XCTAssertEqual(held.lot(canonicalID: target.id)?.current.count, .someLeft)
        XCTAssertFalse(held.globallyFreeLots.contains { $0.id == secondLot })
        XCTAssertEqual(unknown.reservations.first?.lotID, target.id)
        let bridged = try held.legacyAllocation()
        XCTAssertNil(bridged.demands.first?.allocated)
        XCTAssertNil(bridged.demands.first?.shortfall)
        XCTAssertFalse(bridged.confirmedCoverageComplete)
        XCTAssertTrue(bridged.allocations.isEmpty)
        let blocked = try XCTUnwrap(bridged.remainingLots.first { $0.lotID == secondLot })
        XCTAssertEqual(blocked.remainingUnallocated, .zero)
        XCTAssertFalse(blocked.issues.isEmpty, "Zero is only allocatable credit; the amount is unresolved.")
    }

    func testZeroNeedsBridgeWithoutInventingClaimsWhileUnknownPositiveNeedStaysUnresolved() async throws {
        var first = manualJourneys().0
        let zero = StockNeed(id: UUID(), foodID: first.stockNeeds[0].foodID, name: "Nothing else needed", amount: q(0), priority: .required)
        first.stockNeeds.append(zero)
        let fixture = try await activate([first])
        let before = try await fixture.repository.load(at: now)
        XCTAssertEqual(before.reservations.count, 1)
        let lot = try XCTUnwrap(before.lots.first)
        let unknown = try await change(lot.id, .count(.unknown, observationID: UUID()), fixture: fixture)
        let scope = try PantryLiveStockProjection.build(snapshot: unknown, mapping: fixture.mapping, journeyID: first.id, at: now)
        let result = try scope.legacyAllocation()
        let zeroRow = try XCTUnwrap(result.demands.first { $0.id == zero.id })
        XCTAssertEqual(zeroRow.needed, .zero)
        XCTAssertEqual(zeroRow.allocated, .zero)
        XCTAssertEqual(zeroRow.shortfall, .zero)
        XCTAssertTrue(zeroRow.issues.isEmpty)
        let positive = try XCTUnwrap(result.demands.first { $0.id == first.stockNeeds[0].id })
        XCTAssertEqual(positive.needed, try Rational(3))
        XCTAssertNil(positive.allocated)
        XCTAssertNil(positive.shortfall)
        XCTAssertTrue(positive.issues.contains(.usableUnverified))
        XCTAssertFalse(result.confirmedCoverageComplete)
        XCTAssertEqual(scope.confirmedQuantity(for: zero.id), q(0))
        XCTAssertEqual(scope.lots.first?.current.count, .unknown)
        XCTAssertTrue(scope.globallyFreeLots.isEmpty)
        XCTAssertEqual(unknown.reservations.count, 1)
    }

    /// Build actual posted receipt evidence through the existing checkout commands,
    /// then activate a separate temporary inventory database from those saved bytes.
    private func receiptFixture() async throws -> (Fixture, [ReceiptKey], [UUID]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        let producer = try ComparisonStore(url: directory.appendingPathComponent("producer.sqlite"))
        let pickup = PickupModel(store: producer, clock: { instant })
        cleanup.track(ledger, producer, pickup)
        await ledger.open(); await pickup.load(); pickup.bindCookLedger(ledger)
        var shop = ShoppingLedger(title: "Receipts", basis: .init(branch: "Main", mode: .pickup, slot: now,
            timeZoneIdentifier: "America/New_York", cap: .init(minorUnits: 3800)))
        let food = try shop.addManualLine(name: "Wraps", quantity: q(6))
        let saved = await ledger.change(key: "projection-receipts") { $0.shops = [shop]; $0.selectedShopID = shop.id }
        XCTAssertTrue(saved)
        let packs = try LedgerPackReview.prepare(ledger: ledger, shopID: shop.id, lineID: food,
            offerA: .init(id: "eight", label: "Eight wraps", usableQuantity: q(8), price: .init(minorUnits: 300)),
            offerB: .init(id: "six", label: "Six wraps", usableQuantity: q(6), price: .init(minorUnits: 250)), itemCap: nil, at: now, source: "Package")
        let packed = try await packs.save(offerID: "eight", ledger: ledger); XCTAssertTrue(packed)
        let checkout = try LedgerCheckoutAdapter.review(shop: XCTUnwrap(ledger.shop), workspaceRevision: ledger.revision,
            previous: nil, packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
        let applied = try await LedgerCheckoutAdapter.apply(checkout, ledger: ledger, pickup: pickup); XCTAssertTrue(applied)
        let quoted = await pickup.setQuote(.init(scope: .wholeCheckout, context: checkout.context,
            pricing: .inclusiveTotal(.exact(.init(minorUnits: 300)))), cap: nil); XCTAssertTrue(quoted)
        let frozen = await pickup.freeze(); XCTAssertTrue(frozen)
        let placed = await pickup.reportPlaced(); XCTAssertTrue(placed)
        let keys = [ReceiptKey(sourceEventID: "delivery-a", orderLineID: food, branchID: "Main", segmentID: "one"),
                    ReceiptKey(sourceEventID: "delivery-a", orderLineID: food, branchID: "Main", segmentID: "two"),
                    ReceiptKey(sourceEventID: "delivery-b", orderLineID: food, branchID: "Main", segmentID: "one")]
        var observationIDs: [UUID] = []
        for key in keys {
            let observation = UsableObservation(id: UUID(), receipt: key, usable: q(8), confirmedAt: now, confirmedMatchToOrderLine: true)
            let received = await pickup.receive(.init(key: key, itemName: "Wraps", received: q(8), disposition: .received, receivedAt: now), usable: observation)
            XCTAssertTrue(received); observationIDs.append(observation.id)
        }
        return (try await activate([XCTUnwrap(pickup.journey)]), keys, observationIDs)
    }

    private func receiptPickup(_ fixture: Fixture) async throws -> PickupModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(root, test: self)
        let ledger = try LedgerStore(url: root.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        let pending = try PantryPickupPendingStore(directory: root.appendingPathComponent("pending"),
            inventoryWorkspaceID: fixture.store.workspaceID, ledgerWorkspaceID: ledger.workspaceID)
        let instant = now
        let pickup = PickupModel(store: fixture.store, clock: { instant }, pantry: .init(ledger: ledger, pendingStore: pending,
            gate: PantryMutationGate(), authorize: { true }))
        cleanup.track(ledger, pickup)
        await pickup.load()
        return pickup
    }

    func testProductBatchLinksReviewedDeliveryAndAddsOnlySeparateStock() async throws {
        let (fixture, keys, _) = try await receiptFixture()
        let pickup = try await receiptPickup(fixture)
        let editor = try XCTUnwrap(pickup.makePantryModel())
        await editor.load()
        let target = try XCTUnwrap(editor.productDeliveries.first { $0.purchase?.receiptKey == keys[1] })
        let originalLots = try XCTUnwrap(editor.snapshot).lots
        var batch = PantryProductBatch(workspaceID: fixture.store.workspaceID)
        XCTAssertTrue(try batch.addManual(name: "Wraps", code: "LOCAL-WRAPS"))
        XCTAssertTrue(try batch.addManual(name: "Oats", code: "LOCAL-OATS"))
        batch.candidates[0].perPack = "8"
        batch.candidates[0].packages = "1"
        batch.candidates[1].perPack = "1"
        batch.candidates[1].packages = "2"
        do {
            _ = try await editor.reviewProducts(batch, merchant: "Main", purchaseDate: now, confirmed: true)
            XCTFail("Unreviewed actions must not create new stock when delivery fragments exist")
        } catch ProductBatchError.chooseStockAction {}
        batch.candidates[0].stockAction = .link(target)
        batch.candidates[1].stockAction = .separate
        let oldReview = try await editor.reviewProducts(batch, merchant: "Main", purchaseDate: now, confirmed: true)
        XCTAssertEqual(oldReview.facts.first?.stock, .linked(fragment: keys[1]))

        // A count changes after the picker and confirmation review. The entire
        // mixed batch must remain unapplied, including the otherwise valid oats.
        _ = try await change(target.id, .count(.exact(q(6)), observationID: UUID()), fixture: fixture)
        do {
            try await editor.saveProducts(batch, review: oldReview)
            XCTFail("A changed pantry must invalidate the pending acquisition")
        } catch ComparisonStoreError.staleInventory {}
        _ = await pickup.refreshPantryStock()
        await editor.load()
        do {
            _ = try await editor.reviewProducts(batch, merchant: "Main", purchaseDate: now, confirmed: true)
            XCTFail("A stale selected delivery must require a new choice")
        } catch ProductBatchError.changedDelivery {}
        let historyAfterConflict = try await editor.receiptHistory()
        XCTAssertTrue(historyAfterConflict.isEmpty)
        XCTAssertEqual(editor.snapshot?.lots.count, originalLots.count)
        let current = try XCTUnwrap(editor.productDeliveries.first { $0.id == target.id })
        XCTAssertEqual(current.purchase?.receiptKey, keys[1])
        batch.candidates[0].stockAction = .link(current)
        batch.candidates[0].usable = "6"
        let fresh = try await editor.reviewProducts(batch, merchant: "Main", purchaseDate: now, confirmed: true)
        try await editor.saveProducts(batch, review: fresh)

        let reopened = try XCTUnwrap(pickup.makePantryModel())
        await reopened.load()
        let after = try XCTUnwrap(reopened.snapshot)
        XCTAssertEqual(after.lots.count, originalLots.count + 1)
        XCTAssertEqual(after.lots.first { $0.id == target.id }, current.lot)
        XCTAssertEqual(after.lots.first { $0.name == "Oats" }?.count, .exact(q(2)))
        let history = try await reopened.receiptHistory()
        XCTAssertEqual(history.count, 2)
        let linked = try XCTUnwrap(history.first { $0.lotID == target.id })
        XCTAssertEqual(linked.stock, .linked(fragment: keys[1]))
        XCTAssertEqual(linked.received, q(8))
        XCTAssertEqual(linked.usable, q(6))

        // Choosing the previous receipt immediately excludes this row even if the shopper closes its editor.
        var repeatScan = PantryProductBatch(workspaceID: fixture.store.workspaceID)
        XCTAssertTrue(try repeatScan.addManual(name: "Oats", code: "LOCAL-OATS"))
        let prior = try XCTUnwrap(history.first { $0.name == "Oats" })
        repeatScan.candidates[0].selectExistingReceipt(prior)
        XCTAssertFalse(repeatScan.candidates[0].included)
        XCTAssertFalse(repeatScan.candidates[0].receiptLinkSaved)
        XCTAssertThrowsError(try repeatScan.draft(merchant: "Main", purchaseDate: now, confirmed: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = PantryDigestScope(origin: fixture.store.workspaceID, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let memory = PantryPackMemory(folder: directory)
        let link = RecordedPackReceiptLink(id: repeatScan.candidates[0].id, receiptID: prior.receiptID, lineID: prior.lineID,
            lotID: prior.lotID, code: try XCTUnwrap(repeatScan.candidates[0].barcode))
        try memory.link(link, scope: scope) { true }
        try memory.link(link, scope: scope) { true }
        XCTAssertTrue(try memory.recent(scope).isEmpty, "Linking purchase evidence must not implicitly remember the pack")
        XCTAssertEqual(try PantryPackMemory(folder: directory).receiptLinks(lotID: prior.lotID, scope: scope), [link])
        XCTAssertEqual(reopened.snapshot?.lots.count, after.lots.count)

        // The same barcode on a genuinely different purchase remains available.
        var another = PantryProductBatch(workspaceID: fixture.store.workspaceID)
        XCTAssertTrue(try another.addManual(name: "Wraps", code: "LOCAL-WRAPS"))
        another.candidates[0].perPack = "8"
        another.candidates[0].packages = "1"
        another.candidates[0].stockAction = .separate
        let distinct = try await reopened.reviewProducts(another, merchant: "Main", purchaseDate: now, confirmed: true)
        try await reopened.saveProducts(another, review: distinct)
        XCTAssertEqual(reopened.snapshot?.lots.count, after.lots.count + 1)
        XCTAssertEqual(reopened.snapshot?.lots.first { $0.id == target.id }, current.lot)
    }

    func testRecentPurchaseOpensOneCanonicalLotAndSavesCountAndLocationInOneRevision() async throws {
        let (fixture, keys, _) = try await receiptFixture()
        let pickup = try await receiptPickup(fixture)
        let instant = now
        let editor = try XCTUnwrap(pickup.makePantryModel())
        await editor.load()
        let snapshot = try XCTUnwrap(editor.snapshot)
        let options = editor.recentPurchases
        XCTAssertEqual(Set(options.map(\.receiptKey)), Set(keys))
        let selected = try XCTUnwrap(options.first { $0.receiptKey == keys[0] })
        let before = try XCTUnwrap(snapshot.lots.first { $0.id == selected.id })
        let duplicates = PantryLiveStockProjection.recentPurchases(snapshot: snapshot, mapping: fixture.mapping,
            journeys: fixture.journeys + fixture.journeys)
        XCTAssertEqual(options, duplicates)
        var orderOnly = try XCTUnwrap(fixture.journeys.first)
        let arrival = try XCTUnwrap(orderOnly.pickup)
        orderOnly.pickup = try PickupLedger(orderID: arrival.orderID, orderLines: arrival.orderLines)
        XCTAssertTrue(PantryLiveStockProjection.recentPurchases(snapshot: snapshot, mapping: fixture.mapping, journeys: [orderOnly]).isEmpty)
        for fragment in arrival.receipts { try orderOnly.pickup?.receive(fragment) }
        XCTAssertTrue(PantryLiveStockProjection.recentPurchases(snapshot: snapshot, mapping: fixture.mapping, journeys: [orderOnly]).isEmpty)

        await editor.prepareRecentPurchase(selected, amount: "3", location: .freezer)
        let review = try XCTUnwrap(editor.review)
        XCTAssertEqual(review.command.lotID, before.id)
        guard case .revise = review.command.change else { return XCTFail("Receipt review must update its original lot") }
        XCTAssertEqual(review.proposedLot.count, .exact(q(3)))
        XCTAssertEqual(review.proposedLot.location, .freezer)
        await editor.confirmReview(acknowledgingReservations: true)
        let after = try XCTUnwrap(editor.snapshot)
        XCTAssertEqual(after.state.revision, snapshot.state.revision + 1)
        XCTAssertEqual(Set(after.lots.map(\.id)), Set(snapshot.lots.map(\.id)))
        XCTAssertEqual(after.lots.first { $0.id == selected.id }, review.proposedLot)
        XCTAssertEqual(after.lots.filter { $0.id != selected.id }, snapshot.lots.filter { $0.id != selected.id })
        await editor.prepareRecentPurchase(selected, amount: "8", location: .cupboard)
        XCTAssertNil(editor.review)
        XCTAssertEqual(editor.notice, .stale)

        let independent = PantryModel(repository: fixture.repository, clock: { instant })
        await independent.load()
        XCTAssertTrue(independent.recentPurchases.isEmpty)
    }

    func testFullReceiptKeysRemainDistinctAndNewPantryObservationDoesNotRevertToLegacyCount() async throws {
        let (fixture, keys, observationIDs) = try await receiptFixture()
        let original = try await fixture.repository.load(at: now)
        XCTAssertEqual(original.lots.count, 3)
        let target = try XCTUnwrap(original.lots.first { $0.source == .receipt(originID: fixture.store.workspaceID, key: keys[1]) })
        let latestObservation = UUID()
        let updated = try await change(target.id, .count(.exact(q(1)), observationID: latestObservation), fixture: fixture)
        let scope = try PantryLiveStockProjection.build(snapshot: updated, mapping: fixture.mapping, journeyID: fixture.journeys[0].id, at: now)
        XCTAssertEqual(Set(scope.lots.compactMap(\.receiptKey)), Set(keys))
        let row = try XCTUnwrap(scope.lot(canonicalID: target.id))
        XCTAssertEqual(row.readerID, observationIDs[1])
        XCTAssertEqual(row.currentObservationID, latestObservation)
        XCTAssertEqual(row.current.count, .exact(q(1)))
        XCTAssertEqual(row.scopedLegacyObservationIDs, [observationIDs[1]])
        XCTAssertEqual(Set(scope.allocations.compactMap(\.receiptKey)).subtracting(Set(keys)), [])
        let free = try scope.globallyFreeLots.reduce(Rational.zero) { try $0.adding($1.usable.amount) }
        XCTAssertEqual(free, try Rational(11), "Seventeen current wraps minus six allocated, not twenty-four old wraps.")
    }

    func testSplitOfUnresolvedReceiptCannotBecomeEligibleManualStock() async throws {
        let fixture = try await activate([])
        let initial = try await fixture.repository.load(at: now)
        let source = UUID(), child = UUID(), food = UUID()
        let key = ReceiptKey(sourceEventID: "unverified", orderLineID: food, branchID: "store", segmentID: "one")
        _ = try await fixture.repository.apply(.init(id: UUID(), originID: fixture.store.workspaceID, lotID: source,
            eventID: UUID(), expectedRevision: nil, occurredAt: now,
            change: .create(.init(foodID: food, name: "Rolls", source: .receipt(originID: fixture.store.workspaceID, key: key),
                                  location: .cupboard, unit: .count, count: .exact(q(6))), observationID: UUID())),
            reviewedInventoryRevision: initial.state.revision, at: now)
        let portion = InventoryPortionAction.split(amount: q(2), destination: .freezer, lotID: child, eventID: UUID(), observationID: UUID())
        let reading = InventoryCountRevision(count: .exact(q(4)), observationID: UUID(), observedAt: now)
        let split = try await change(source, .revise(.init(observation: reading, portion: portion)), fixture: fixture)
        let live = try PantryLiveStockProjection.buildGlobal(snapshot: split, mapping: fixture.mapping, at: now)
        XCTAssertEqual(live.lots.count, 2)
        XCTAssertTrue(live.globallyFreeLots.isEmpty)
        XCTAssertTrue(try XCTUnwrap(live.lot(canonicalID: child)).issues.contains(.receiptEvidenceUnresolved))
        let context = try PantryErasureDependencies.Context(snapshot: split, mapping: fixture.mapping,
                                                            sourceToken: await fixture.store.inventorySourceToken(), at: now)
        let impact = try await PantryErasureDependencies.scan(store: fixture.store, selection: .lot(child, revision: 1),
                                                              context: context, authorize: { true })
        XCTAssertEqual(impact.explicitlySelectedLotIDs, [source, child])
    }

    func testOtherShopIneligibleReceiptBackingHoldsFreeFoodButUnknownUnallocatedReceiptDoesNot() async throws {
        let pair = manualJourneys()
        var first = pair.0
        first.stockNeeds = []
        let second = pair.1, food = pair.2
        let fixture = try await activate([first, second])
        let initial = try await fixture.repository.load(at: now)
        let manual = try XCTUnwrap(initial.lots.first)
        let before = try await change(manual.id, .revise(.init(useFirst: false)), fixture: fixture)
        let lotID = UUID()
        let key = ReceiptKey(sourceEventID: "not-linked-to-an-arrival", orderLineID: food, branchID: "Other branch", segmentID: "one")
        let created = try await fixture.repository.apply(.init(id: UUID(), originID: fixture.store.workspaceID, lotID: lotID,
            eventID: UUID(), expectedRevision: nil, occurredAt: now,
            change: .create(.init(foodID: food, name: "Unlinked receipt", source: .receipt(originID: fixture.store.workspaceID, key: key),
                location: .cupboard, unit: .count, count: .unknown, useFirst: true), observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
        let unknown = try PantryLiveStockProjection.build(snapshot: created.current, mapping: fixture.mapping, journeyID: first.id, at: now)
        XCTAssertEqual(unknown.globallyFreeLots.first?.usable, q(6), "Unallocated unknown food must not hide independently confirmed free stock.")
        XCTAssertFalse(created.current.availability.allocations.contains { $0.lotID == lotID })
        let counted = try await change(lotID, .count(.exact(q(20)), observationID: UUID()), fixture: fixture)
        XCTAssertEqual(Set(counted.availability.allocations.map(\.lotID)), [lotID], "Use-first makes the other shop's invalid backing deterministic.")
        let scope = try PantryLiveStockProjection.build(snapshot: counted, mapping: fixture.mapping, journeyID: first.id, at: now)
        let row = try XCTUnwrap(scope.lot(canonicalID: lotID))
        XCTAssertEqual(row.receiptKey, key)
        XCTAssertTrue(row.issues.contains(.receiptEvidenceUnresolved))
        XCTAssertNil(row.free)
        XCTAssertTrue(scope.demands.isEmpty)
        XCTAssertTrue(scope.allocations.isEmpty, "The offending commitment belongs only to another shop.")
        XCTAssertTrue(scope.globallyFreeLots.isEmpty, "That other shop's still-owed promise prevents spending the manual stock.")
        XCTAssertNil(scope.lot(canonicalID: manual.id)?.free)
        XCTAssertEqual(scope.lot(canonicalID: manual.id)?.current.count, .exact(q(8)), "Physical counts stay intact.")
        let other = try PantryLiveStockProjection.build(snapshot: counted, mapping: fixture.mapping, journeyID: second.id, at: now)
        XCTAssertNil(other.confirmedQuantity(for: second.stockNeeds[0].id))
        XCTAssertFalse(try other.legacyAllocation().confirmedCoverageComplete)
    }
}

extension PantryLiveStockProjectionTests {
    func testOnePhysicalPackageWithUnknownContentsReplaysWithoutMakingAPurchaseOrConfirmingDate() async throws {
        let (fixture, _, _) = try await receiptFixture()
        let pickup = try await receiptPickup(fixture)
        let editor = try XCTUnwrap(pickup.makePantryModel())
        await editor.load()
        let before = try XCTUnwrap(editor.snapshot).lots
        var intake = PantryProductBatch(workspaceID: fixture.store.workspaceID)
        XCTAssertTrue(try intake.addManual(name: "Butter beans", code: "LOCAL-BEANS"))
        intake.candidates[0].onePackageUnknown = true
        intake.candidates[0].dateWordingDraft = "BEST BEFORE DEC 2026"
        let row = intake.candidates[0]
        XCTAssertEqual(try row.homeCount(), .unknown)
        XCTAssertThrowsError(try row.usableQuantity())
        XCTAssertThrowsError(try intake.draft(merchant: "Market", purchaseDate: now, confirmed: true))
        var several = row
        several.packages = "2"
        XCTAssertThrowsError(try several.homeCount())
        let review = try await editor.reviewHomePacks(intake)
        XCTAssertEqual(editor.snapshot?.lots, before)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scope = PantryDigestScope(origin: fixture.store.workspaceID, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let journal = PantryPackMemory(folder: folder)
        let staged = try XCTUnwrap(ReviewedPackSave(review: review, intake: intake, scope: scope, atHome: true))
        XCTAssertEqual(staged.rows.first?.reviewedDateWording, "BEST BEFORE DEC 2026")
        try journal.stage(staged, scope: scope) { true }
        let lookup = CapturedBarcode(symbology: "manual", value: "012345678905")
        let access = PantryDigestAccess(scope: scope) { true }
        XCTAssertThrowsError(try journal.reviewUnmatched(lookup, retailer: "", productName: "Cereal", typed: true,
            access: access, canEdit: true)) { error in
            guard case ProductBatchError.pendingPackSave = error else { return XCTFail("Expected the pending pack save") }
        }
        XCTAssertEqual(try journal.pending(scope), staged)
        try await editor.saveReceipt(review)
        XCTAssertTrue(try XCTUnwrap(editor.snapshot).singlePackageIntakes.contains(row.id))
        let retry = try XCTUnwrap(PantryPackMemory(folder: folder).pending(scope))
        try await editor.saveReceipt(retry.review)
        try journal.clear(retry, scope: scope) { true }
        let reopened = try XCTUnwrap(pickup.makePantryModel())
        await reopened.load()
        let after = try XCTUnwrap(reopened.snapshot).lots
        XCTAssertEqual(after.count, before.count + 1)
        let lot = try XCTUnwrap(after.first { $0.id == row.id })
        XCTAssertEqual(lot.name, "Butter beans")
        XCTAssertEqual(lot.count, .unknown)
        XCTAssertTrue(try XCTUnwrap(reopened.snapshot).singlePackageIntakes.contains(lot.id))
        XCTAssertNil(lot.openedAt)
        XCTAssertEqual(lot.location, .cupboard)
        XCTAssertEqual(lot.packageCode?.value, "LOCAL-BEANS")
        guard case .manual = lot.source else { return XCTFail("Expected at-home stock") }
        let history = try await reopened.receiptHistory()
        XCTAssertTrue(history.isEmpty)
        let labels = PantryPackageDateStore(folder: folder.appendingPathComponent("labels"))
        XCTAssertNil(try labels.load(scope, lot: lot.id))
        try intake.separate(row.id)
        XCTAssertNil(intake.candidates.last?.reviewedDateWording)
    }

    func testUnknownUsableAmountAloneDoesNotEstablishOneOuterPackage() async throws {
        let fixture = try await activate([])
        let origin = fixture.store.workspaceID
        let at = now
        let genericID = UUID()
        let initial = try await fixture.repository.load(at: at)
        // Older ordinary manual lots have no package-intake evidence.
        let ordinary = InventoryLotSeed(foodID: genericID, name: "Beans", source: .manual(originID: origin, sourceID: genericID),
                                        location: .cupboard, unit: .count, count: .unknown)
        let generic = try await fixture.repository.apply(.init(id: UUID(), originID: origin, lotID: genericID, eventID: UUID(),
            expectedRevision: nil, occurredAt: at, change: .create(ordinary, observationID: UUID())),
            reviewedInventoryRevision: initial.state.revision, at: at)
        XCTAssertFalse(generic.current.singlePackageIntakes.contains(genericID))

        var measured = PantryProductBatch(workspaceID: origin)
        XCTAssertTrue(try measured.addManual(name: "Flour", code: nil))
        measured.candidates[0].packages = "2"
        measured.candidates[0].perPack = "100"
        measured.candidates[0].unit = .gram
        let review = try await fixture.repository.reviewHomePacks(measured, basis: generic.current.state, at: at)
        try await fixture.repository.applyReceipt(review, at: at)
        let id = measured.candidates[0].id
        let current = try await change(id, .count(.unknown, observationID: UUID()), fixture: fixture)
        XCTAssertEqual(current.lots.first(where: { $0.id == id })?.count, .unknown)
        XCTAssertTrue(current.singlePackageIntakes.isEmpty)
    }

    func testReviewedAtHomePacksSaveTwoPhysicalLotsWithNoPurchaseAndReplayOnce() async throws {
        let (fixture, _, _) = try await receiptFixture()
        let pickup = try await receiptPickup(fixture)
        let editor = try XCTUnwrap(pickup.makePantryModel())
        await editor.load()
        let previous = try XCTUnwrap(editor.snapshot).lots.count
        let code = CapturedBarcode(symbology: "UPC-A", value: "012345000058")
        let pack = ConfirmedPantryPack(id: UUID(), barcode: code, retailer: "", name: "Canned beans",
            size: Quantity(amount: try Rational(375), unit: .gram, originalLiteral: "375"), attribution: nil, confirmedAt: now)
        var intake = PantryProductBatch(workspaceID: fixture.store.workspaceID)
        XCTAssertTrue(try intake.addScan(code))
        intake.candidates[0].use(pack)
        intake.candidates[0].packages = "2"
        try intake.separate(intake.candidates[0].id)
        intake.candidates[1].location = .fridge
        let review = try await editor.reviewHomePacks(intake)
        XCTAssertEqual(editor.snapshot?.lots.count, previous)
        XCTAssertTrue(review.facts.isEmpty)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scope = PantryDigestScope(origin: fixture.store.workspaceID, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let journal = PantryPackMemory(folder: folder)
        let staged = try XCTUnwrap(ReviewedPackSave(review: review, intake: intake, scope: scope, atHome: true))
        try journal.stage(staged, scope: scope) { true }
        try await editor.saveReceipt(review)
        let afterInterruption = try XCTUnwrap(PantryPackMemory(folder: folder).pending(scope))
        let appliedBeforeRetry = try await editor.packSaveAlreadyApplied(afterInterruption)
        XCTAssertTrue(appliedBeforeRetry)
        try await editor.saveReceipt(afterInterruption.review)
        try journal.clear(afterInterruption, scope: scope) { true }
        XCTAssertNil(try journal.pending(scope))
        let reopened = try XCTUnwrap(pickup.makePantryModel())
        await reopened.load()
        let lots = try XCTUnwrap(reopened.snapshot).lots.filter { $0.foodID == pack.id }
        XCTAssertEqual(lots.count, 2)
        XCTAssertEqual(Set(lots.map(\.location)), [.fridge, .cupboard])
        XCTAssertEqual(Set(lots.map(\.id)), Set(intake.candidates.map(\.id)))
        for lot in lots {
            XCTAssertFalse(try XCTUnwrap(reopened.snapshot).singlePackageIntakes.contains(lot.id))
            guard case .manual = lot.source else { return XCTFail("A home count cannot create purchase evidence") }
            XCTAssertEqual(lot.count.quantity?.amount, try Rational(375))
            XCTAssertEqual(lot.packageCode?.canonicalGTIN, code.canonicalGTIN)
            XCTAssertNotNil(lot.intakeOrdinal)
        }
        let history = try await reopened.receiptHistory()
        XCTAssertTrue(history.isEmpty)
    }
}
