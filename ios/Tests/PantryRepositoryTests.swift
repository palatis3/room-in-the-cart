import XCTest
import CoreDomain
import LocalStore
@testable import RoomInTheCart

@MainActor
final class PantryRepositoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func database() throws -> (URL, ComparisonStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true))
    }

    private func activate(_ store: ComparisonStore) async throws {
        let token = try await store.inventorySourceToken()
        let state = try await store.inventoryState()
        _ = try await store.commitInventory(InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: state.revision, request: Data("empty reviewed workspace".utf8), mode: .activate, sourceToken: token), at: now)
    }

    private func quantity(_ value: Int64) throws -> Quantity {
        Quantity(amount: try Rational(value), unit: .count, originalLiteral: String(value))
    }

    private func creation(_ store: ComparisonStore) throws -> InventoryCommand {
        let lot = UUID()
        return InventoryCommand(id: UUID(), originID: store.workspaceID, lotID: lot, eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(InventoryLotSeed(foodID: UUID(), name: "Wraps",
                source: .manual(originID: store.workspaceID, sourceID: lot), location: .cupboard,
                unit: .count, count: .exact(try quantity(8))), observationID: UUID()))
    }

    private func change(_ source: InventoryCommand, revision: Int64, _ change: InventoryChange) -> InventoryCommand {
        InventoryCommand(id: UUID(), originID: source.originID, lotID: source.lotID, eventID: UUID(),
            expectedRevision: revision, occurredAt: now, change: change)
    }

    func testSplitReplaysAtomicallyWithOriginalDatesAndOneSourceAcquisition() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await activate(store)
        let repo = PantryRepository(store: store, authorize: { true })
        let command = try creation(store)
        let original = try await repo.apply(command, reviewedInventoryRevision: 1, at: now)
        let lot = try XCTUnwrap(original.current.lots.first)
        let amount = try quantity(2)
        let split = InventoryPortionAction.split(amount: amount, destination: .freezer, lotID: UUID(), eventID: UUID(), observationID: UUID())
        let reading = InventoryCountRevision(count: try split.remainder(of: lot), observationID: UUID(), observedAt: lot.confirmedAt)
        let edit = change(command, revision: lot.revision, .revise(.init(observation: reading, portion: split)))
        let reviewed = try await repo.review(edit, at: now)
        XCTAssertEqual(reviewed.splitLot?.count.quantity, amount)
        let saved = try await repo.apply(edit, reviewedInventoryRevision: reviewed.before.state.revision, at: now)
        let replay = try await repo.apply(edit, reviewedInventoryRevision: reviewed.before.state.revision, at: now)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(saved.current.lots.count, 2)
        XCTAssertEqual(replay.current.lots, saved.current.lots)
        let child = try XCTUnwrap(saved.current.lots.first { $0.id != lot.id })
        XCTAssertEqual(child.splitFromLotID, lot.id)
        XCTAssertEqual(child.confirmedAt, lot.confirmedAt)
        XCTAssertEqual(child.location, .freezer)
        XCTAssertEqual(saved.current.lots.first { $0.id == lot.id }?.count.quantity?.amount, try Rational(6))
        let acquisitionRows = try await store.acquisitionRows()
        XCTAssertTrue(acquisitionRows.isEmpty)
        let claim = InventoryReservation(id: UUID(), originID: store.workspaceID, revision: 1,
                                        foodID: lot.foodID, lotID: lot.id, name: "Lunch", amount: try quantity(5))
        _ = try await store.commitInventory(InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: saved.current.state.revision, request: Data("hold".utf8),
            writes: [try PantryPersistenceCodec.write(claim, expectedRevision: 0)]), at: now)
        let parent = try XCTUnwrap(saved.current.lots.first { $0.id == lot.id })
        let another = InventoryPortionAction.split(amount: amount, destination: .fridge, lotID: UUID(), eventID: UUID(), observationID: UUID())
        let remainder = InventoryCountRevision(count: try another.remainder(of: parent), observationID: UUID(), observedAt: lot.confirmedAt)
        do {
            _ = try await repo.review(change(command, revision: parent.revision, .revise(.init(observation: remainder, portion: another))), at: now)
            XCTFail("held quantity cannot move")
        } catch { XCTAssertEqual(error as? InventoryError, .invalid("reservationExceedsFree")) }
        try await store.close()
    }

    func testShelfMarksRequireSameRevisionAndMinimumUsesOnlyConfirmedAvailableStock() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await activate(store)
        let repo = PantryRepository(store: store, authorize: { true })
        let create = try creation(store)
        let result = try await repo.apply(create, reviewedInventoryRevision: 1, at: now)
        let lot = try XCTUnwrap(result.current.lots.first)
        let session = PantryShelfCount(id: UUID(), name: "Top", location: lot.location,
                                      batches: [.init(id: lot.id, revision: lot.revision, answer: .present)])
        let persisted = try JSONDecoder().decode(PantryShelfCount.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(persisted.answer(for: lot), .present)
        var other = PantryShelfCount(id: UUID(), name: "New count", location: lot.location, batches: [])
        XCTAssertFalse(other.markSaved(lot, from: session, adding: true))
        XCTAssertTrue(other.batches.isEmpty)
        let hold = InventoryReservation(id: UUID(), originID: store.workspaceID, revision: 1, foodID: lot.foodID,
                                       lotID: lot.id, name: "Dinner", amount: try quantity(7))
        let projection = try InventoryProjection.build(originID: store.workspaceID, lots: [lot], reservations: [hold], at: now)
        let minimum = PantryStapleMinimum(foodID: lot.foodID, anchorLotID: lot.id, target: try quantity(4), afterHolds: true)
        let need = try minimum.shortfall(lots: [lot], projection: projection)
        XCTAssertEqual(need?.amount, try Rational(3))
        XCTAssertEqual(minimum.proposal(shortfall: need, incoming: try quantity(4))?.amount, .zero)
        let qualitative = try await repo.apply(change(create, revision: lot.revision, .count(.someLeft, observationID: UUID())),
                                               reviewedInventoryRevision: result.current.state.revision, at: now)
        XCTAssertNil(persisted.answer(for: try XCTUnwrap(qualitative.current.lots.first)))
        XCTAssertNil(try minimum.shortfall(lots: qualitative.current.lots, projection: qualitative.current.availability))
        try await store.close()
    }

    func testReopenedRetryReturnsCurrentCountAndLocationWithoutRepeatingAcquisition() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await activate(store)
        let repository = PantryRepository(store: store, authorize: { true })
        let command = try creation(store)
        let review = try await repository.review(command, at: now)
        let first = try await repository.apply(command, reviewedInventoryRevision: review.before.state.revision, at: now)
        let recount = change(command, revision: 1, .count(.someLeft, observationID: UUID()))
        let second = try await repository.apply(recount, reviewedInventoryRevision: first.current.state.revision, at: now)
        let move = change(command, revision: 2, .move(.freezer))
        let moved = try await repository.apply(move, reviewedInventoryRevision: second.current.state.revision, at: now)
        try await store.close()
        let reopened = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let retry = try await PantryRepository(store: reopened, authorize: { true })
            .apply(command, reviewedInventoryRevision: review.before.state.revision, at: now)
        XCTAssertTrue(retry.replayed)
        XCTAssertEqual(retry.receipt, first.receipt)
        XCTAssertEqual(retry.current.state, moved.current.state)
        XCTAssertEqual(retry.current.lots.count, 1)
        XCTAssertEqual(retry.current.lots.first?.count, .someLeft)
        XCTAssertEqual(retry.current.lots.first?.location, .freezer)
        XCTAssertNil(retry.current.availability.lots.first?.free)
        let events = try await reopened.inventoryRecords(kind: .event)
        let observations = try await reopened.inventoryRecords(kind: .observation)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(observations.count, 2)
        let changedBody = InventoryCommand(id: command.id, originID: command.originID, lotID: command.lotID,
            eventID: command.eventID, expectedRevision: 3, occurredAt: now, change: .move(.fridge))
        do {
            _ = try await PantryRepository(store: reopened, authorize: { true })
                .apply(changedBody, reviewedInventoryRevision: review.before.state.revision, at: now)
            XCTFail("a reused operation identity must not accept a different command")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
        try await reopened.close()
    }

    func testAllShopClaimsSurviveQualitativeCountAndStaleReviewCannotIgnoreNewClaim() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await activate(store)
        let repository = PantryRepository(store: store, authorize: { true })
        let command = try creation(store)
        let created = try await repository.apply(command, reviewedInventoryRevision: 1, at: now)
        let lot = try XCTUnwrap(created.current.lots.first)
        let someLeft = change(command, revision: 1, .count(.someLeft, observationID: UUID()))
        let outdatedReview = try await repository.review(someLeft, at: now)
        let claim = InventoryReservation(id: UUID(), originID: store.workspaceID, revision: 1,
            foodID: lot.foodID, lotID: lot.id, name: "Tomorrow's lunch", amount: try quantity(2))
        let writer = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        _ = try await writer.commitInventory(InventoryBatch(workspaceID: writer.workspaceID, operationID: UUID(),
            expectedRevision: created.current.state.revision, request: Data("confirmed other-shop lunch".utf8),
            writes: [InventoryWrite(record: InventoryRecord(key: .init(.reservation, claim.id), revision: 1,
                payload: try JSONEncoder().encode(claim), lotID: lot.id), expectedRevision: 0)]), at: now)
        do {
            _ = try await repository.apply(someLeft, reviewedInventoryRevision: outdatedReview.before.state.revision, at: now)
            XCTFail("newly held food requires refreshed review")
        } catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
        let review = try await repository.review(someLeft, at: now)
        XCTAssertEqual(review.affectedReservations.map(\.id), [claim.id])
        let unknown = try await repository.apply(someLeft, reviewedInventoryRevision: review.before.state.revision, at: now)
        XCTAssertNil(unknown.current.availability.lots.first?.free)
        XCTAssertTrue(try XCTUnwrap(unknown.current.availability.reservations.first).unresolved)
        XCTAssertEqual(unknown.current.reservations, [claim])
        let recount = change(command, revision: 2, .count(.exact(try quantity(3)), observationID: UUID()))
        let counted = try await repository.apply(recount, reviewedInventoryRevision: unknown.current.state.revision, at: now)
        XCTAssertEqual(counted.current.availability.lots.first?.held?.amount, try Rational(2))
        XCTAssertEqual(counted.current.availability.lots.first?.free?.amount, try Rational(1))
        try await writer.close()
        try await store.close()
    }

    func testInactiveAndRevokedWorkspaceCannotReadWriteOrReplay() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let repository = PantryRepository(store: store, authorize: { allowed })
        let command = try creation(store)
        do {
            _ = try await repository.apply(command, reviewedInventoryRevision: 0, at: now)
            XCTFail("app mutations must not activate an unmigrated workspace")
        } catch { XCTAssertEqual(error as? PantryRepository.Failure, .inactive) }
        try await activate(store)
        let first = try await repository.apply(command, reviewedInventoryRevision: 1, at: now)
        allowed = false
        do { _ = try await repository.load(at: now); XCTFail("revoked read") }
        catch { XCTAssertEqual(error as? PantryRepository.Failure, .unauthorized) }
        do { _ = try await repository.apply(command, reviewedInventoryRevision: 1, at: now); XCTFail("revoked receipt replay") }
        catch { XCTAssertEqual(error as? PantryRepository.Failure, .unauthorized) }
        let unchanged = try await store.inventoryState()
        XCTAssertEqual(unchanged, first.current.state)
        allowed = true
        let otherOrigin = InventoryCommand(id: UUID(), originID: UUID(), lotID: command.lotID,
            eventID: UUID(), expectedRevision: 1, occurredAt: now, change: .move(.fridge))
        do { _ = try await repository.review(otherOrigin, at: now); XCTFail("cross-workspace command") }
        catch { XCTAssertEqual(error as? PantryRepository.Failure, .wrongWorkspace) }
        try await store.close()
    }

    func testRestoredHeadCannotReactivateAnOldValidButSupersededCount() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await activate(store)
        let repository = PantryRepository(store: store, authorize: { true })
        let command = try creation(store)
        let created = try await repository.apply(command, reviewedInventoryRevision: 1, at: now)
        let original = try XCTUnwrap(created.current.lots.first)
        let recount = change(command, revision: 1, .count(.exact(try quantity(3)), observationID: UUID()))
        let counted = try await repository.apply(recount, reviewedInventoryRevision: created.current.state.revision, at: now)
        let restoredOldCount = InventoryLot(id: original.id, foodID: original.foodID, name: original.name,
            source: original.source, revision: 3, location: original.location, unit: original.unit,
            count: original.count, observationID: original.observationID,
            confirmedAt: original.confirmedAt, updatedAt: now)
        _ = try await store.commitInventory(InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: counted.current.state.revision, request: Data("restore superseded eight-count".utf8),
            writes: [InventoryWrite(record: InventoryRecord(key: .init(.lot, original.id), revision: 3,
                payload: try JSONEncoder().encode(restoredOldCount)), expectedRevision: 2)]), at: now)
        try await store.close()
        let reopened = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        do {
            _ = try await PantryRepository(store: reopened, authorize: { true }).load(at: now)
            XCTFail("an old matching observation must not resurrect the previous eight-count")
        } catch { XCTAssertEqual(error as? PantryRepository.Failure, .invalidProvenance) }
        try await reopened.close()
    }

    func testReadCapacityIsCheckedBeforeCommitAndPreservesReadableCurrentState() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await activate(store)
        let normal = PantryRepository(store: store, authorize: { true })
        let command = try creation(store)
        let created = try await normal.apply(command, reviewedInventoryRevision: 1, at: now)
        let countLimited = PantryRepository(store: store,
            limits: .init(payloadBytes: PantryRepository.ReadLimits.standard.payloadBytes, observations: 1), authorize: { true })
        let moved = try await countLimited.apply(change(command, revision: 1, .move(.freezer)),
            reviewedInventoryRevision: created.current.state.revision, at: now)
        let recount = change(command, revision: 2, .count(.exact(try quantity(3)), observationID: UUID()))
        let byteLimited = PantryRepository(store: store,
            limits: .init(payloadBytes: moved.current.loadedPayloadBytes + 1, observations: 100_000), authorize: { true })
        for repository in [countLimited, byteLimited] {
            do {
                _ = try await repository.apply(recount, reviewedInventoryRevision: moved.current.state.revision, at: now)
                XCTFail("a command exceeding the read budget must fail before writing")
            } catch { XCTAssertEqual(error as? InventoryError, .capacity) }
            let readable = try await repository.load(at: now)
            XCTAssertEqual(readable.state, moved.current.state)
            XCTAssertEqual(readable.lots.first?.count, .exact(try quantity(8)))
        }
        let events = try await store.inventoryRecords(kind: .event)
        let observations = try await store.inventoryRecords(kind: .observation)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(observations.count, 1)
        let receipt = try await store.inventoryCommittedOperation(id: recount.id,
            request: PantryPersistenceCodec.request(recount, inventoryRevision: moved.current.state.revision))
        XCTAssertNil(receipt)
        try await store.close()
    }

    func testOpaqueValidJSONCannotPublishCountContradictingItsObservation() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await activate(store)
        let repository = PantryRepository(store: store, authorize: { true })
        let created = try await repository.apply(creation(store), reviewedInventoryRevision: 1, at: now)
        let lot = try XCTUnwrap(created.current.lots.first)
        let invalid = InventoryLot(id: lot.id, foodID: lot.foodID, name: lot.name, source: lot.source,
            revision: 2, location: lot.location, unit: lot.unit, count: .exact(try quantity(99)),
            observationID: lot.observationID, confirmedAt: lot.confirmedAt, updatedAt: now)
        _ = try await store.commitInventory(InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: created.current.state.revision, request: Data("opaque invalid app payload".utf8),
            writes: [InventoryWrite(record: InventoryRecord(key: .init(.lot, lot.id), revision: 2,
                payload: try JSONEncoder().encode(invalid)), expectedRevision: 1)]), at: now)
        do { _ = try await repository.load(at: now); XCTFail("missing observation evidence must not create 91 wraps") }
        catch { XCTAssertEqual(error as? PantryRepository.Failure, .invalidProvenance) }
        try await store.close()
    }

    func testDelayedCompoundRevisionSurvivesReopenWithoutReplacingNewerStorage() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await activate(store)
        let repository = PantryRepository(store: store, authorize: { true })
        let original = try creation(store)
        let created = try await repository.apply(original, reviewedInventoryRevision: 1, at: now)
        let movedAt = now.addingTimeInterval(20)
        let move = InventoryCommand(id: UUID(), originID: store.workspaceID, lotID: original.lotID,
            eventID: UUID(), expectedRevision: 1, occurredAt: movedAt, change: .move(.freezer))
        let moved = try await repository.apply(move, reviewedInventoryRevision: created.current.state.revision, at: movedAt)
        let savedAt = now.addingTimeInterval(30)
        let observedAt = now.addingTimeInterval(10)
        let revision = InventoryCommand(id: UUID(), originID: store.workspaceID, lotID: original.lotID,
            eventID: UUID(), expectedRevision: 2, occurredAt: savedAt,
            change: .revise(.init(observation: .init(count: .exact(try quantity(3)), observationID: UUID(),
                observedAt: observedAt), name: "Corn wraps", useFirst: true)))
        let revised = try await repository.apply(revision, reviewedInventoryRevision: moved.current.state.revision, at: savedAt)
        try await store.close()
        let reopened = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let retry = try await PantryRepository(store: reopened, authorize: { true })
            .apply(revision, reviewedInventoryRevision: moved.current.state.revision, at: savedAt)
        XCTAssertTrue(retry.replayed)
        XCTAssertEqual(retry.current.state, revised.current.state)
        let lot = try XCTUnwrap(retry.current.lots.first)
        XCTAssertEqual(lot.count, .exact(try quantity(3)))
        XCTAssertEqual(lot.location, .freezer)
        XCTAssertEqual(lot.name, "Corn wraps")
        XCTAssertEqual(lot.confirmedAt, observedAt)
        XCTAssertEqual(lot.updatedAt, savedAt)
        XCTAssertTrue(lot.useFirst)
        let observations = try await reopened.inventoryRecords(kind: .observation)
        XCTAssertEqual(observations.count, 2)
        try await reopened.close()
    }

    func testShoppingBatchCapacityCountsClaimReplacementAndEveryNewObservation() async throws {
        let (directory, store) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await activate(store)
        let repository = PantryRepository(store: store, authorize: { true })
        let original = try creation(store)
        let created = try await repository.apply(original, reviewedInventoryRevision: 1, at: now)
        let lot = try XCTUnwrap(created.current.lots.first)
        let claim = InventoryReservation(id: UUID(), originID: store.workspaceID, revision: 1,
            foodID: lot.foodID, lotID: lot.id, name: "Lunch", amount: try quantity(2))
        let firstWrite = InventoryWrite(record: InventoryRecord(key: .init(.reservation, claim.id), revision: 1,
            payload: try JSONEncoder().encode(claim), lotID: lot.id), expectedRevision: 0)
        _ = try await store.commitInventory(InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: created.current.state.revision, request: Data("lunch".utf8), writes: [firstWrite]), at: now)
        let snapshot = try await repository.load(at: now)
        let limited = PantryRepository(store: store,
            limits: .init(payloadBytes: snapshot.loadedPayloadBytes, observations: 2), authorize: { true })
        let replacement = InventoryReservation(id: claim.id, originID: claim.originID, revision: 2,
            foodID: claim.foodID, lotID: claim.lotID, name: claim.name, amount: claim.amount, state: .released)
        let replacementWrite = InventoryWrite(record: InventoryRecord(key: .init(.reservation, claim.id), revision: 2,
            payload: try JSONEncoder().encode(replacement), lotID: lot.id), expectedRevision: 1)
        // 'released' is two bytes longer than 'active'; only the difference counts.
        let exact = PantryRepository(store: store,
            limits: .init(payloadBytes: snapshot.loadedPayloadBytes + 2, observations: 2), authorize: { true })
        XCTAssertNoThrow(try exact.validateCapacity(of: [replacementWrite], replacing: snapshot))
        XCTAssertThrowsError(try limited.validateCapacity(of: [replacementWrite], replacing: snapshot)) {
            XCTAssertEqual($0 as? InventoryError, .capacity)
        }
        let countLimited = PantryRepository(store: store,
            limits: .init(payloadBytes: PantryRepository.ReadLimits.standard.payloadBytes, observations: 2), authorize: { true })
        let newObservations = try (1...2).map { index -> InventoryWrite in
            let observation = InventoryObservation(id: UUID(), lotID: lot.id, operationID: UUID(), revision: Int64(index + 1),
                supersedesID: lot.observationID, observedAt: now, count: .unknown)
            return InventoryWrite(record: InventoryRecord(key: .init(.observation, observation.id), revision: 1,
                payload: try JSONEncoder().encode(observation), lotID: lot.id), expectedRevision: 0)
        }
        XCTAssertThrowsError(try countLimited.validateCapacity(of: newObservations, replacing: snapshot)) {
            XCTAssertEqual($0 as? InventoryError, .capacity)
        }
        try await store.close()
        let reopened = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let unchanged = try await PantryRepository(store: reopened, authorize: { true }).load(at: now)
        XCTAssertEqual(unchanged.state, snapshot.state)
        XCTAssertEqual(unchanged.reservations, [claim])
        XCTAssertEqual(unchanged.lots, snapshot.lots)
        try await reopened.close()
    }
}
