import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryPendingRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Fixture {
        let directory: URL
        let store: ComparisonStore
        let gate: PantryMutationGate
        let journal: PantryPendingStore
        let cleanup: SQLiteFixtureDirectory
    }
    private func fixture(removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data("reviewed empty pantry".utf8), mode: .activate, sourceToken: token), at: now)
        let journal = try PantryPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: store.workspaceID, removeFile: removeFile)
        return .init(directory: directory, store: store, gate: PantryMutationGate(), journal: journal, cleanup: cleanup)
    }
    private func repository(_ f: Fixture, authorize: @escaping () -> Bool = { true }) -> PantryRepository {
        PantryRepository(store: f.store, mutationGate: f.gate, pendingStore: f.journal, authorize: authorize)
    }
    private func editor(_ f: Fixture, at date: Date? = nil, authorize: @escaping () -> Bool = { true }) -> PantryModel {
        let instant = date ?? now
        return PantryModel(repository: repository(f, authorize: authorize), clock: { instant })
    }
    private func stagedAdd(_ f: Fixture) async throws -> PantryPendingStore.Entry {
        let model = editor(f)
        await model.load()
        await model.prepareNewFood(name: "Milk", location: .fridge, amount: "1,5", unit: .liter)
        let review = try XCTUnwrap(model.review)
        return try repository(f).stagePending(review.command, reviewedInventoryRevision: review.before.state.revision)
    }
    private func rawApply(_ f: Fixture, _ entry: PantryPendingStore.Entry, at date: Date? = nil) async throws -> PantryRepository.Result {
        // Simulates a process that reached SQLite commit but died before model
        // adoption/acknowledgment. The original journal stays on disk.
        try await PantryRepository(store: f.store, mutationGate: f.gate, authorize: { true })
            .apply(entry.command, reviewedInventoryRevision: entry.reviewedInventoryRevision, at: date ?? now)
    }
    private func change(_ f: Fixture, from result: PantryRepository.Result, to change: InventoryChange, at date: Date? = nil) async throws -> PantryRepository.Result {
        let lot = try XCTUnwrap(result.current.lots.first)
        return try await PantryRepository(store: f.store, mutationGate: f.gate, authorize: { true }).apply(
            .init(id: UUID(), originID: f.store.workspaceID, lotID: lot.id, eventID: UUID(),
                  expectedRevision: lot.revision, occurredAt: date ?? now, change: change),
            reviewedInventoryRevision: result.current.state.revision, at: date ?? now)
    }

    func testConsumptionAtomicallyRecoversEveryBatchAndQualitativeReadingAfterLostReply() async throws {
        let f = try await fixture(), model = editor(f)
        await model.load()
        for (name, amount) in [("Eggs", "6"), ("Ketchup", "1"), ("Milk", "1")] {
            await model.prepareNewFood(name: name, location: .fridge, amount: amount, unit: .count)
            await model.confirmReview(acknowledgingReservations: false)
        }
        let snapshot = try XCTUnwrap(model.snapshot)
        let eggs = try XCTUnwrap(snapshot.lots.first { $0.name == "Eggs" })
        let ketchup = try XCTUnwrap(snapshot.lots.first { $0.name == "Ketchup" })
        let milk = try XCTUnwrap(snapshot.lots.first { $0.name == "Milk" })
        let one = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        let wording = "less than half a bottle left"
        let review = try await model.reviewConsumption([
            .init(lotID: eggs.id, use: .amount(one)), .init(lotID: ketchup.id, use: .low(wording)),
            .init(lotID: milk.id, use: .all), .init(lotID: eggs.id, use: .amount(one))
        ], basis: snapshot.state)
        XCTAssertEqual(review.lines.map { $0.after.quantity?.amount }, [try Rational(5), nil, .zero, try Rational(4)])
        XCTAssertEqual(review.lines.last?.before.quantity?.amount, try Rational(5))
        XCTAssertEqual(model.snapshot?.lots, snapshot.lots)
        let repo = repository(f)
        let original = try repo.stagePending(review.entry)
        let reopenedBefore = editor(f)
        await reopenedBefore.load()
        XCTAssertEqual(reopenedBefore.pending, original)
        XCTAssertFalse(reopenedBefore.canEdit)
        guard case .committed(_, let committed) = try await repo.recoverPending(original, at: now, commitIfUnapplied: true) else {
            return XCTFail("Expected atomic SQLite commit")
        }
        XCTAssertEqual(committed.receipt.revision, snapshot.state.revision + 1)
        XCTAssertEqual(committed.receipt.heads.count, 9)
        // Simulate a lost reply and a fresh database handle. Adoption must never spend a second time.
        let fresh = try ComparisonStore(url: f.directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        f.cleanup.track(fresh)
        let reopened = PantryModel(repository: PantryRepository(store: fresh, mutationGate: f.gate, pendingStore: f.journal,
                                                                 authorize: { true }), clock: { self.now })
        await reopened.load()
        XCTAssertTrue(reopened.canEdit)
        XCTAssertNil(try f.journal.read())
        let after = try XCTUnwrap(reopened.snapshot)
        XCTAssertEqual(after.state.revision, committed.receipt.revision)
        XCTAssertEqual(after.lots.first { $0.id == eggs.id }?.count.quantity?.amount, try Rational(4))
        XCTAssertEqual(after.lots.first { $0.id == milk.id }?.count.quantity?.amount, .zero)
        let low = try XCTUnwrap(after.lots.first { $0.id == ketchup.id })
        XCTAssertEqual(low.count, .someLeft)
        XCTAssertEqual(low.countWording, wording)
        XCTAssertNil(after.availability.lots.first { $0.id == low.id }?.free)
        let history = try await fresh.inventoryRecords(kind: .observation)
        let latest = try XCTUnwrap(history.first { $0.key.id == low.observationID })
        XCTAssertEqual(try PantryPersistenceCodec.observation(latest).countWording, wording)
        let events = try await fresh.inventoryRecords(kind: .event)
        XCTAssertEqual(events.count, 6)
        let replayed = try await repo.apply(original, at: now)
        XCTAssertTrue(replayed.replayed)
        await reopened.prepare(lotID: low.id, action: .move(.cupboard))
        await reopened.confirmReview(acknowledgingReservations: false)
        XCTAssertEqual(reopened.snapshot?.lots.first { $0.id == low.id }?.countWording, wording)
        await reopened.prepare(lotID: low.id, action: .recount("1", .count))
        await reopened.confirmReview(acknowledgingReservations: false)
        XCTAssertNil(reopened.snapshot?.lots.first { $0.id == low.id }?.countWording)
    }

    func testConsumptionUnmeasuredUseHistorySurvivesRecountAndReopenButObservationAloneIsNotAUse() async throws {
        let f = try await fixture(), model = editor(f)
        await model.load()
        await model.prepareNewFood(name: "Ketchup", location: .fridge, amount: "1", unit: .count)
        await model.confirmReview(acknowledgingReservations: false)
        let start = try XCTUnwrap(model.snapshot)
        let id = try XCTUnwrap(start.lots.first?.id)
        func submit(_ use: PantryConsumptionSelection.Use) async throws {
            let basis = try XCTUnwrap(model.snapshot?.state)
            let review = try await model.reviewConsumption([.init(lotID: id, use: use)], basis: basis)
            try await model.saveConsumption(review)
        }
        try await submit(.usedSome(remainingWording: nil))
        let unknown = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(unknown.lots.first?.count, .unknown)
        XCTAssertNil(unknown.availability.lots.first?.free)
        try await submit(.usedSome(remainingWording: "less than half a bottle"))
        let estimated = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(estimated.lots.first?.countWording, "less than half a bottle")
        XCTAssertEqual(estimated.lots.first?.count, .someLeft)
        let original = try await model.usageHistory(lotID: id, basis: estimated.state)
        XCTAssertEqual(original.count, 2)
        XCTAssertEqual(Set(original.map(\.id)).count, 2)
        XCTAssertTrue(original.allSatisfy { $0.kind == .some && $0.occurredAt == now })
        XCTAssertEqual(original.compactMap(\.remainingWording), ["less than half a bottle"])
        try await submit(.low("nearly empty"))
        try await submit(.unknown)
        try await submit(.empty)
        let empty = try XCTUnwrap(model.snapshot)
        for use in [PantryConsumptionSelection.Use.usedSome(remainingWording: nil), .usedSome(remainingWording: "a little left"), .all] {
            do { _ = try await model.reviewConsumption([.init(lotID: id, use: use)], basis: empty.state); XCTFail("Empty batch accepted a use") }
            catch { XCTAssertEqual(error as? PantryConsumptionFailure, .emptyBatch) }
        }
        XCTAssertEqual(model.snapshot?.state, empty.state)
        XCTAssertNil(try f.journal.read())
        await model.prepare(lotID: id, action: .recount("2", .count))
        await model.confirmReview(acknowledgingReservations: false)
        let final = try XCTUnwrap(model.snapshot)
        let fresh = try ComparisonStore(url: f.directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        f.cleanup.track(fresh)
        let reopened = PantryRepository(store: fresh, authorize: { true })
        let history = try await reopened.usageHistory(lotID: id, basis: final.state)
        XCTAssertEqual(history, original)
        XCTAssertEqual(final.lots.first?.count.quantity?.amount, try Rational(2))
        XCTAssertNil(final.lots.first?.countWording)
        let token = try await fresh.inventorySourceToken()
        _ = try await fresh.eraseInventoryOrigin(expectedRevision: final.state.revision, sourceToken: token, operationID: UUID(), at: now)
        do { _ = try await reopened.usageHistory(lotID: id, basis: final.state); XCTFail("Retired inventory exposed use history") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    }

    func testConsumptionRequiresExactLotFreeQuantityAndCurrentAuthorizedBasis() async throws {
        let f = try await fixture(), model = editor(f)
        await model.load()
        for name in ["Eggs", "Eggs"] {
            await model.prepareNewFood(name: name, location: .fridge, amount: "5", unit: .count)
            await model.confirmReview(acknowledgingReservations: false)
        }
        let before = try XCTUnwrap(model.snapshot)
        let lot = try XCTUnwrap(before.lots.first)
        let spare = try XCTUnwrap(before.lots.last)
        XCTAssertNotEqual(lot.id, spare.id)
        let basis = PantryReviewedFood(id: lot.foodID, name: lot.name, inventoryWorkspaceID: before.state.workspaceID,
                                      inventoryRevision: before.state.revision)
        await model.prepareReservation(.reserve(purpose: "Lunch", amount: "3", day: nil), lotID: lot.id, basis: basis)
        await model.confirmReview(acknowledgingReservations: false)
        let held = try XCTUnwrap(model.snapshot)
        let one = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        let three = Quantity(amount: try Rational(3), unit: .count, originalLiteral: "3")
        let volume = Quantity(amount: .one, unit: .cup, originalLiteral: "1")
        for (use, expected) in [(PantryConsumptionSelection.Use.all, PantryConsumptionFailure.reserved),
                                (.low("nearly empty"), .reserved), (.usedSome(remainingWording: nil), .reserved), (.unknown, .reserved),
                                (.amount(three), .insufficientFree), (.amount(volume), .incompatibleUnit)] {
            do {
                _ = try await model.reviewConsumption([.init(lotID: lot.id, use: use)], basis: held.state)
                XCTFail("Invalid consumption was offered")
            } catch { XCTAssertEqual(error as? PantryConsumptionFailure, expected) }
        }
        let valid = try await model.reviewConsumption([.init(lotID: lot.id, use: .amount(one))], basis: held.state)
        let other = editor(f)
        await other.load()
        await other.prepare(lotID: spare.id, action: .move(.freezer))
        await other.confirmReview(acknowledgingReservations: false)
        do {
            try await model.saveConsumption(valid)
            XCTFail("Stale review committed")
        } catch { XCTAssertEqual(error as? PantryConsumptionFailure, .stale) }
        XCTAssertTrue(model.requiresFreshReview)
        await model.discardStaleReview()
        let current = try XCTUnwrap(model.snapshot)
        let retried = try await model.reviewConsumption([.init(lotID: lot.id, use: .amount(one))], basis: current.state)
        try await model.saveConsumption(retried)
        let result = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(result.lots.first { $0.id == lot.id }?.count.quantity?.amount, try Rational(4))
        XCTAssertEqual(result.lots.first { $0.id == spare.id }?.count.quantity?.amount, try Rational(5))
        XCTAssertEqual(result.availability.lots.first { $0.id == lot.id }?.held?.amount, try Rational(3))
        XCTAssertEqual(result.reservations, held.reservations)
        var allowed = true
        let guarded = editor(f, authorize: { allowed })
        await guarded.load()
        let final = try await guarded.reviewConsumption([.init(lotID: spare.id, use: .all)], basis: result.state)
        allowed = false
        do { try await guarded.saveConsumption(final); XCTFail("Revoked writer changed pantry") } catch {}
        XCTAssertNil(guarded.snapshot)
        XCTAssertEqual(guarded.phase, .accessDenied)
        let verified = try await repository(f).load(at: now)
        XCTAssertEqual(verified.state, result.state)
        XCTAssertNil(try f.journal.read())
    }

    func testDirectLunchReservationAndPartialReleaseRecoverExactClaimAfterSQLiteReopen() async throws {
        let f = try await fixture()
        let a = editor(f)
        await a.load()
        await a.prepareNewFood(name: "Cooked portions", location: .fridge, amount: "4", unit: .count)
        await a.confirmReview(acknowledgingReservations: false)
        let before = try XCTUnwrap(a.snapshot), lot = try XCTUnwrap(before.lots.first)
        func basis(_ snapshot: PantryRepository.Snapshot) -> PantryReviewedFood {
            .init(id: lot.foodID, name: lot.name, inventoryWorkspaceID: snapshot.state.workspaceID, inventoryRevision: snapshot.state.revision)
        }
        let day = try MealDay(year: 2026, month: 11, day: 18, timeZoneIdentifier: "America/New_York")
        await a.prepareReservation(.reserve(purpose: "School lunch", amount: "2", day: day), lotID: lot.id, basis: basis(before))
        let review = try XCTUnwrap(a.review)
        let pending = try repository(f).stagePending(review.command, reviewedInventoryRevision: review.before.state.revision)
        let committed = try await rawApply(f, pending)
        XCTAssertEqual(committed.receipt.heads.map(\.key.kind), [.reservation])
        let fresh = try ComparisonStore(url: f.directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        f.cleanup.track(fresh)
        let recovered = PantryModel(repository: PantryRepository(store: fresh, mutationGate: f.gate, pendingStore: f.journal,
                                                                 authorize: { true }), clock: { self.now })
        await recovered.load()
        XCTAssertNil(try f.journal.read())
        let held = try XCTUnwrap(recovered.snapshot)
        let claim = try XCTUnwrap(held.reservations.first)
        XCTAssertEqual(claim.name, "School lunch")
        XCTAssertEqual(claim.personal?.day, day)
        XCTAssertEqual(held.availability.lots.first?.free?.amount, try Rational(2))
        await recovered.prepareReservation(.release(claim, amount: "1"), lotID: lot.id, basis: basis(held))
        await recovered.confirmReview(acknowledgingReservations: true)
        let partial = try XCTUnwrap(recovered.snapshot)
        let remaining = try XCTUnwrap(partial.reservations.first)
        XCTAssertEqual(remaining.amount?.amount, .one)
        XCTAssertEqual(partial.availability.lots.first?.free?.amount, try Rational(3))
        await recovered.prepareReservation(.release(remaining, amount: nil), lotID: lot.id, basis: basis(partial))
        await recovered.confirmReview(acknowledgingReservations: true)
        let replay = try await rawApply(f, pending)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.current.reservations.map(\.state), [.released])
        XCTAssertEqual(replay.current.availability.lots.first?.free?.amount, try Rational(4))
        XCTAssertEqual(replay.current.lots, before.lots)
    }

    func testRestartRestoresExactAddBeforeEditableStateAndNeverInventsOldReview() async throws {
        let f = try await fixture(), original = try await stagedAdd(f)
        let reopened = editor(f, at: now.addingTimeInterval(3600))
        await reopened.load()
        XCTAssertEqual(reopened.pending, original)
        XCTAssertNil(reopened.review)
        XCTAssertFalse(reopened.canEdit)
        XCTAssertEqual(reopened.snapshot?.lots.count, 0)
        await reopened.retryPending()
        XCTAssertNil(reopened.pending)
        XCTAssertNil(try f.journal.read())
        XCTAssertEqual(reopened.savedLotID, original.command.lotID)
        XCTAssertEqual(reopened.snapshot?.lots.first?.confirmedAt, original.command.occurredAt)
        XCTAssertEqual(reopened.snapshot?.lots.first?.count.quantity?.amount, try Rational(3, 2))
        let events = try await f.store.inventoryRecords(kind: .event)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.key.id, original.command.eventID)
    }

    func testReceiptFirstRestartAdoptsInterveningCountInsteadOfReapplyingAcquisition() async throws {
        let f = try await fixture(), original = try await stagedAdd(f)
        let first = try await rawApply(f, original)
        let changed = try await change(f, from: first, to: .count(.someLeft, observationID: UUID()))
        let reopened = editor(f, at: now.addingTimeInterval(3600))
        await reopened.load()
        XCTAssertNil(reopened.pending)
        XCTAssertEqual(reopened.notice, .saved)
        XCTAssertEqual(reopened.snapshot?.state.revision, changed.current.state.revision)
        XCTAssertEqual(reopened.snapshot?.lots.count, 1)
        XCTAssertEqual(reopened.snapshot?.lots.first?.count, .someLeft)
        XCTAssertNil(try f.journal.read())
        let events = try await f.store.inventoryRecords(kind: .event)
        XCTAssertEqual(events.count, 2)
    }

    func testOpenedTimestampSurvivesRestartBeforeCommit() async throws {
        let f = try await fixture(), add = try await stagedAdd(f)
        let model = editor(f)
        await model.load(); await model.retryPending()
        await model.prepare(lotID: add.command.lotID, action: .opened)
        let review = try XCTUnwrap(model.review)
        let entry = try repository(f).stagePending(review.command, reviewedInventoryRevision: review.before.state.revision)
        let reopened = editor(f, at: now.addingTimeInterval(7200))
        await reopened.load()
        XCTAssertEqual(reopened.pending?.command, entry.command)
        await reopened.retryPending()
        XCTAssertEqual(reopened.snapshot?.lots.first?.openedAt, now)
        let events = try await f.store.inventoryRecords(kind: .event)
        XCTAssertEqual(events.count, 2)
    }

    func testCommittedReceiptCannotClearJournalUntilCompleteReadbackSucceeds() async throws {
        let f = try await fixture(), original = try await stagedAdd(f)
        let committed = try await rawApply(f, original)
        _ = try await change(f, from: committed, to: .count(.someLeft, observationID: UUID()))
        let instant = now
        let restricted = PantryModel(repository: PantryRepository(store: f.store,
            limits: .init(payloadBytes: PantryRepository.ReadLimits.standard.payloadBytes, observations: 1),
            mutationGate: f.gate, pendingStore: f.journal, authorize: { true }), clock: { instant })
        await restricted.load() // Exact receipt exists; today's complete read exceeds this adapter's limit.
        XCTAssertFalse(restricted.canEdit)
        XCTAssertNil(restricted.snapshot)
        XCTAssertEqual(restricted.pending?.command, original.command)
        XCTAssertNil(try f.journal.read()?.acknowledgment)
        let reopened = editor(f)
        await reopened.load()
        XCTAssertEqual(reopened.notice, .saved)
        XCTAssertEqual(reopened.snapshot?.lots.first?.count, .someLeft)
        XCTAssertNil(try f.journal.read())
        let events = try await f.store.inventoryRecords(kind: .event)
        XCTAssertEqual(events.count, 2)
    }

    func testAcknowledgedCleanupFailureRetainsExactIntentAndCachedMissingReceiptReconciles() async throws {
        var failRemoval = true
        let f = try await fixture { url in
            if failRemoval { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let original = try await stagedAdd(f)
        let first = editor(f)
        await first.load(); await first.retryPending()
        XCTAssertTrue(first.pendingWasCommitted)
        XCTAssertFalse(first.canEdit)
        let acknowledged = try XCTUnwrap(f.journal.read())
        XCTAssertNotNil(acknowledged.acknowledgment)
        XCTAssertEqual(acknowledged.command, original.command)
        let second = editor(f)
        await second.load() // Recognizes receipt; cleanup still fails.
        XCTAssertNotNil(second.pending)
        failRemoval = false
        await first.retryPending()
        XCTAssertNil(try f.journal.read())
        await second.retryPending() // Journal absent, exact receipt present.
        XCTAssertNil(second.pending)
        XCTAssertEqual(second.notice, .saved)
        XCTAssertNil(try f.journal.read())
        let events = try await f.store.inventoryRecords(kind: .event)
        XCTAssertEqual(events.count, 1)
    }

    func testStaleDiscardProvesNoReceiptAndAnotherCachedEditorNeverRestagesIt() async throws {
        let f = try await fixture(), add = try await stagedAdd(f)
        let first = editor(f)
        await first.load(); await first.retryPending()
        await first.prepare(lotID: add.command.lotID, action: .usedUp)
        let review = try XCTUnwrap(first.review)
        let pending = try repository(f).stagePending(review.command, reviewedInventoryRevision: review.before.state.revision)
        let second = editor(f)
        await second.load()
        let current = try await repository(f).load(at: now)
        let raw = PantryRepository(store: f.store, mutationGate: f.gate, authorize: { true })
        let lot = try XCTUnwrap(current.lots.first)
        _ = try await raw.apply(.init(id: UUID(), originID: f.store.workspaceID, lotID: lot.id,
            eventID: UUID(), expectedRevision: lot.revision, occurredAt: now, change: .move(.freezer)),
            reviewedInventoryRevision: current.state.revision, at: now)
        await first.load()
        XCTAssertTrue(first.requiresFreshReview)
        await first.discardStaleReview()
        XCTAssertNil(try f.journal.read())
        await second.retryPending() // Journal absent AND exact receipt absent.
        XCTAssertNil(second.pending)
        XCTAssertNil(second.savedLotID)
        XCTAssertTrue(second.canEdit)
        XCTAssertNil(try f.journal.read())
        XCTAssertEqual(second.snapshot?.lots.first?.count.quantity?.amount, try Rational(3, 2))
        let receipt = try await f.store.inventoryCommittedOperation(id: pending.operationID,
            request: PantryPersistenceCodec.request(pending.command, inventoryRevision: pending.reviewedInventoryRevision))
        XCTAssertNil(receipt)
    }

    func testDiscardRecognizesCommittedReceiptAndCannotUndoLaterCount() async throws {
        let f = try await fixture(), original = try await stagedAdd(f)
        let committed = try await rawApply(f, original)
        _ = try await change(f, from: committed, to: .count(.haveEnough, observationID: UUID()))
        let recovery = try await repository(f).recoverPending(original, at: now, discardIfUnapplied: true)
        guard case .committed(let entry, let result) = recovery else { return XCTFail("Committed work must be adopted, never discarded") }
        XCTAssertNotNil(entry)
        XCTAssertEqual(result.current.lots.first?.count, .haveEnough)
        XCTAssertNotNil(try f.journal.read())
    }

    func testAccessRevocationRedactsMemoryButRetainsDurableOperationForAuthorizedRecovery() async throws {
        let f = try await fixture(), original = try await stagedAdd(f)
        _ = try await rawApply(f, original)
        var authorized = false
        let model = editor(f, authorize: { authorized })
        await model.load()
        XCTAssertEqual(model.phase, .accessDenied)
        XCTAssertNil(model.pending)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(try f.journal.read()?.command, original.command)
        authorized = true
        await model.load()
        XCTAssertEqual(model.notice, .saved)
        XCTAssertEqual(model.snapshot?.lots.count, 1)
        XCTAssertNil(try f.journal.read())
        model.accessLost()
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.savedLotID)
        XCTAssertFalse(model.pendingWasCommitted)
    }

    func testProtectedJournalRejectsReplacementAndCorruptionBlocksEditableState() async throws {
        let f = try await fixture(), original = try await stagedAdd(f)
        let changed = InventoryCommand(id: original.command.id, originID: original.command.originID,
            lotID: original.command.lotID, eventID: original.command.eventID,
            expectedRevision: original.command.expectedRevision, occurredAt: now.addingTimeInterval(1), change: original.command.change)
        XCTAssertThrowsError(try f.journal.save(command: changed, reviewedInventoryRevision: original.reviewedInventoryRevision)) {
            XCTAssertEqual($0 as? PantryPendingStore.Failure, .operationConflict)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: f.journal.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(try f.journal.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #if os(iOS) && !targetEnvironment(simulator)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        #endif
        try Data("corrupt".utf8).write(to: f.journal.fileURL)
        let model = editor(f)
        await model.load()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertFalse(model.canEdit)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(try Data(contentsOf: f.journal.fileURL), Data("corrupt".utf8))
        let lots = try await f.store.inventoryRecords(kind: .lot)
        XCTAssertTrue(lots.isEmpty)
    }
}
