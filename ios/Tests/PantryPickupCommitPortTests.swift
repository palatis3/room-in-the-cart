import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor final class PantryPickupCommitPortTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ value: Int64) throws -> Quantity { .init(amount: try Rational(value), unit: .count, originalLiteral: String(value)) }
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let producer: PickupModel
        let store: ComparisonStore
        let ledger: LedgerStore
        let ledgerModel: LedgerModel
        let gate: PantryMutationGate
        let food: UUID
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let producer = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        let ledgerModel = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        await ledgerModel.open()
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        let store = try ComparisonStore(url: directory.appendingPathComponent("target.sqlite"), inventoryEnabled: true)
        cleanup.track(producer, store, ledger, ledgerModel)
        let food = UUID()
        let added = await producer.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: try q(6),
            available: try q(0), due: nil, confirmedAt: now)); XCTAssertTrue(added)
        let journeyID = try XCTUnwrap(producer.journey?.id)
        let stocked = await producer.saveStockLot(.init(id: UUID(), foodID: food, name: "Freezer wraps", usable: try q(8),
            confirmedAt: now, source: .freezer), in: journeyID); XCTAssertTrue(stocked)
        let saved = try await producer.archiveSnapshot()
        for head in saved.records { _ = try await store.save(id: head.id, title: head.title, payload: head.payload, savedAt: head.savedAt) }
        let source = try await store.inventoryCutoverSnapshot()
        let mapped = try PantryLegacyMigration.map(originID: store.workspaceID,
            heads: source.sources.map(PantryLegacyMigration.SourceHead.init),
            ledger: .available(originID: ledger.workspaceID, revision: ledgerModel.revision, workspace: ledgerModel.workspace), at: now)
        let package = try PantryMigrationPackage.build(mapped, migrationID: UUID(), sourceToken: source.token, inventoryRevision: 0, at: now)
        _ = try await store.beginInventoryMigration(package.plan)
        for chunk in package.chunks { _ = try await store.stageInventoryMigration(id: package.plan.migrationID, chunk: chunk) }
        _ = try await store.finishInventoryMigration(id: package.plan.migrationID, at: now)
        return Fixture(directory: directory, cleanup: cleanup, producer: producer, store: store,
            ledger: ledger, ledgerModel: ledgerModel, gate: PantryMutationGate(), food: food)
    }
    private func port(_ fixture: Fixture, store: ComparisonStore? = nil, limits: PantryRepository.ReadLimits = .standard) -> PantryPickupCommitPort {
        let instant = now
        return PantryPickupCommitPort(store: store ?? fixture.store, ledger: fixture.ledger, gate: fixture.gate,
            readLimits: limits, authorize: { _, _ in true }, clock: { instant })
    }
    private func changedHead(_ fixture: Fixture, store: ComparisonStore? = nil) async throws -> PantryLegacyMigration.SourceHead {
        let snapshot = try await fixture.producer.archiveSnapshot()
        let source = try XCTUnwrap(snapshot.records.first)
        let token = try await (store ?? fixture.store).inventorySourceToken()
        let current = try await (store ?? fixture.store).inventorySourcePage(token: token)
        let previous = try XCTUnwrap(current.first { $0.id == source.id })
        return .init(id: source.id, revision: previous.revision + 1, payload: source.payload, savedAt: source.savedAt)
    }
    private func note(_ text: String, in fixture: Fixture) async throws -> PantryLegacyMigration.SourceHead {
        let instant = now
        let changed = await fixture.producer.change {
            $0.notes.append(.init(id: UUID(), text: text, language: "en", createdAt: instant, revision: $0.revision))
        }
        XCTAssertTrue(changed)
        return try await changedHead(fixture)
    }
    private func canonicalEdit(_ change: InventoryChange, store: ComparisonStore) async throws -> PantryRepository.Snapshot {
        let repository = PantryRepository(store: store, authorize: { true })
        let current = try await repository.load(at: now), lot = try XCTUnwrap(current.lots.first)
        let command = InventoryCommand(id: UUID(), originID: store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: change)
        return try await repository.apply(command, reviewedInventoryRevision: current.state.revision, at: now).current
    }

    func testLegacyNoteCommitPreservesIndependentCanonicalCountAndMetadata() async throws {
        let f = try await fixture(), adapter = port(f)
        _ = try await canonicalEdit(.count(.someLeft, observationID: UUID()), store: f.store)
        let edited = try await canonicalEdit(.revise(.init(name: "My freezer wraps", useFirst: true, location: .fridge)), store: f.store)
        let head = try await note("Warm briefly", in: f)
        let review = try await adapter.prepare(operationID: UUID(), changedHeads: [head], preparedAt: now)
        let applied = try await adapter.apply(review.submission)
        XCTAssertFalse(applied.replayed)
        XCTAssertEqual(applied.current.lots, edited.lots)
        XCTAssertEqual(applied.current.reservations, edited.reservations)
        XCTAssertEqual(applied.sources.first?.payload, head.payload)
        XCTAssertEqual(applied.sources.first?.revision, head.revision)
        XCTAssertEqual(applied.receipt.committedAt, now)
        XCTAssertEqual(applied.current.state.revision, edited.state.revision + 1)
    }

    func testSerializedReopenedRetryReturnsCurrentPantryAndSourcesWithoutDuplicatingEffects() async throws {
        let f = try await fixture(), adapter = port(f)
        let firstHead = try await note("First note", in: f)
        let review = try await adapter.prepare(operationID: UUID(), changedHeads: [firstHead], preparedAt: now)
        let encoded = try JSONEncoder().encode(review.submission)
        let original = try await adapter.apply(review.submission)
        _ = try await canonicalEdit(.count(.exact(try q(3)), observationID: UUID()), store: f.store)
        let secondHead = try await note("Later note", in: f)
        let second = try await adapter.prepare(operationID: UUID(), changedHeads: [secondHead], preparedAt: now)
        let latest = try await adapter.apply(second.submission)
        let ledgerChanged = await f.ledgerModel.startShop(title: "Later ledger plan"); XCTAssertTrue(ledgerChanged)
        let observationsBefore = try await f.store.inventoryRecords(kind: .observation)
        try await f.store.close()
        let reopened = try ComparisonStore(url: f.directory.appendingPathComponent("target.sqlite"), inventoryEnabled: true)
        f.cleanup.track(reopened)
        let restored = try JSONDecoder().decode(PantryPickupCommitPort.Submission.self, from: encoded)
        let replay = try await port(f, store: reopened).apply(restored)
        XCTAssertTrue(replay.replayed); XCTAssertEqual(replay.receipt, original.receipt)
        XCTAssertEqual(replay.current.state, latest.current.state)
        XCTAssertEqual(replay.current.lots.first?.count.quantity, try q(3))
        XCTAssertEqual(replay.sources.first?.payload, secondHead.payload)
        XCTAssertNotEqual(replay.sources.first?.payload, firstHead.payload)
        let observationsAfter = try await reopened.inventoryRecords(kind: .observation)
        XCTAssertEqual(observationsAfter, observationsBefore)
        try await reopened.close()
    }

    func testChangedLedgerRejectsUncommittedSubmissionWithoutAnyInventoryWrite() async throws {
        let f = try await fixture(), adapter = port(f), head = try await note("Reviewed note", in: f)
        let review = try await adapter.prepare(operationID: UUID(), changedHeads: [head], preparedAt: now)
        let state = try await f.store.inventoryState(), token = try await f.store.inventorySourceToken()
        let before = try await f.store.inventorySourcePage(token: token)
        let changed = await f.ledgerModel.startShop(title: "New commitment"); XCTAssertTrue(changed)
        do { _ = try await adapter.apply(review.submission); XCTFail("stale ledger binding") }
        catch { XCTAssertEqual(error as? PantryPickupCommitPort.Failure, .staleLedger) }
        let afterState = try await f.store.inventoryState(), afterToken = try await f.store.inventorySourceToken()
        let after = try await f.store.inventorySourcePage(token: afterToken)
        XCTAssertEqual(afterState, state); XCTAssertEqual(afterToken, token); XCTAssertEqual(after, before)
    }

    func testChangedSubmittedBytesConflictEvenWhenOperationAlreadyCommitted() async throws {
        let f = try await fixture(), adapter = port(f), head = try await note("Original", in: f)
        let review = try await adapter.prepare(operationID: UUID(), changedHeads: [head], preparedAt: now)
        let first = try await adapter.apply(review.submission)
        // Still valid JSON and same decoded journey, but NOT the originally reviewed source bytes.
        let altered = PantryLegacyMigration.SourceHead(id: head.id, revision: head.revision,
            payload: head.payload + Data(" ".utf8), savedAt: head.savedAt)
        let substitution = PantryPickupCommitPort.Submission(version: 1, request: review.submission.request,
            changedHeads: [altered], preparedAt: now)
        do { _ = try await adapter.apply(substitution); XCTFail("same operation with changed source bytes") }
        catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
        let state = try await f.store.inventoryState(); XCTAssertEqual(state, first.current.state)
        let token = try await f.store.inventorySourceToken()
        let sources = try await f.store.inventorySourcePage(token: token)
        XCTAssertEqual(sources.first?.payload, head.payload)
    }

    func testCapacityAndGateRejectionsLeaveCanonicalAndSourceHeadsUntouched() async throws {
        let f = try await fixture()
        let current = try await PantryRepository(store: f.store, authorize: { true }).load(at: now)
        let journey = try XCTUnwrap(f.producer.journey?.id)
        let added = await f.producer.saveStockLot(.init(id: UUID(), foodID: f.food, name: "Extra wraps", usable: try q(4),
            confirmedAt: now, source: .freezer), in: journey); XCTAssertTrue(added)
        let head = try await changedHead(f)
        let adapter = port(f, limits: .init(payloadBytes: current.loadedPayloadBytes + 1, observations: 100_000))
        let token = try await f.store.inventorySourceToken(), before = try await f.store.inventorySourcePage(token: token)
        do { _ = try await adapter.prepare(operationID: UUID(), changedHeads: [head], preparedAt: now); XCTFail("new lot exceeds read budget") }
        catch { XCTAssertEqual(error as? InventoryError, .capacity) }
        let lease = try f.gate.beginWrite()
        do { _ = try await port(f).prepare(operationID: UUID(), changedHeads: [head], preparedAt: now); XCTFail("another paired writer is active") }
        catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        f.gate.endWrite(lease)
        let afterState = try await f.store.inventoryState(), after = try await f.store.inventorySourcePage(token: token)
        XCTAssertEqual(afterState, current.state); XCTAssertEqual(after, before)
    }
}
