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
}
