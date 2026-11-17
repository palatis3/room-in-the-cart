import XCTest
import CoreDomain
import LocalStore
import SQLite3
@testable import RoomInTheCart

@MainActor
final class PantryModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func database(active: Bool = true) async throws -> (URL, ComparisonStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        if active {
            let token = try await store.inventorySourceToken()
            let state = try await store.inventoryState()
            _ = try await store.commitInventory(InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
                expectedRevision: state.revision, request: Data("reviewed empty pantry".utf8), mode: .activate, sourceToken: token), at: now)
        }
        return (directory, store)
    }

    private func model(_ store: ComparisonStore) -> PantryModel {
        PantryModel(repository: PantryRepository(store: store, authorize: { true }), clock: { self.now })
    }

    private func add(_ model: PantryModel, name: String = "Wraps", amount: String = "8", foodID: UUID? = nil) async throws -> InventoryLot {
        await model.prepareNewFood(name: name, existingFoodID: foodID, location: .cupboard, amount: amount, unit: .count)
        _ = try XCTUnwrap(model.review)
        await model.confirmReview(acknowledgingReservations: true)
        return try XCTUnwrap(model.snapshot?.lots.first { $0.id == model.savedLotID })
    }

    private func reserve(_ lot: InventoryLot, store: ComparisonStore) async throws -> InventoryReservation {
        let state = try await store.inventoryState()
        let claim = InventoryReservation(id: UUID(), originID: store.workspaceID, revision: 1,
            foodID: lot.foodID, lotID: lot.id, name: "Tomorrow's lunch",
            amount: Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2"), priority: .protected)
        _ = try await store.commitInventory(InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: state.revision, request: Data("lunch reservation".utf8),
            writes: [InventoryWrite(record: InventoryRecord(key: .init(.reservation, claim.id), revision: 1,
                payload: try JSONEncoder().encode(claim), lotID: lot.id), expectedRevision: 0)]), at: now)
        return claim
    }

    func testReviewCancelAndExplicitFoodIdentityNeverMergeNames() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(store)
        await model.load()
        await model.prepareNewFood(name: "Wraps", location: .cupboard, amount: "8", unit: .count)
        let uncommitted = try XCTUnwrap(model.review)
        XCTAssertEqual(uncommitted.proposedLot.count.quantity?.amount, try Rational(8))
        XCTAssertEqual(model.snapshot?.lots.count, 0)
        model.cancelReview()
        XCTAssertNil(model.review)
        let first = try await add(model)
        model.cancelReview() // The dismissed review sheet calls this after a successful save.
        XCTAssertEqual(model.notice, .saved)
        XCTAssertEqual(model.savedLotID, first.id)
        let second = try await add(model)
        XCTAssertNotEqual(first.foodID, second.foodID)
        let third = try await add(model, foodID: first.foodID)
        XCTAssertEqual(third.foodID, first.foodID)
        XCTAssertNotEqual(third.id, first.id)
        XCTAssertEqual(model.snapshot?.lots.count, 3)
        try await store.close()
        let reopened = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let reopenedModel = self.model(reopened)
        await reopenedModel.load()
        XCTAssertEqual(Set(reopenedModel.snapshot?.lots.map(\.id) ?? []), Set([first.id, second.id, third.id]))
        try await reopened.close()
    }

    func testOversizedReviewDoesNotTrapPendingSaveAndSmallerEditStillWorks() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PantryModel(repository: PantryRepository(store: store,
            limits: .init(payloadBytes: PantryRepository.ReadLimits.standard.payloadBytes, observations: 1), authorize: { true }),
            clock: { self.now })
        await model.load()
        let lot = try await add(model)
        await model.prepare(lotID: lot.id, action: .someLeft)
        XCTAssertNil(model.review)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.notice, .changeTooLarge)
        XCTAssertTrue(model.canEdit)
        XCTAssertEqual(model.snapshot?.lots.first?.count, lot.count)
        await model.prepare(lotID: lot.id, action: .move(.freezer))
        XCTAssertNotNil(model.review)
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.notice, .saved)
        XCTAssertEqual(model.snapshot?.lots.first?.location, .freezer)
        XCTAssertEqual(model.snapshot?.lots.first?.count, lot.count)
        try await store.close()
    }

    func testReservationImpactRequiresAcknowledgmentAndQualitativeCountDoesNotFreeFood() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(store)
        await model.load()
        let lot = try await add(model)
        let claim = try await reserve(lot, store: store)
        await model.load()
        await model.prepare(lotID: lot.id, action: .someLeft)
        XCTAssertEqual(model.review?.affectedReservations.map(\.id), [claim.id])
        await model.confirmReview(acknowledgingReservations: false)
        XCTAssertEqual(model.notice, .reservationReviewRequired)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(8))
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.snapshot?.lots.first?.count, .someLeft)
        XCTAssertNil(model.snapshot?.availability.lots.first?.free)
        XCTAssertEqual(model.snapshot?.reservations, [claim])
        await model.prepare(lotID: lot.id, action: .recount("3", .count))
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.snapshot?.availability.lots.first?.held?.amount, try Rational(2))
        XCTAssertEqual(model.snapshot?.availability.lots.first?.free?.amount, .one)
        await model.prepare(lotID: lot.id, action: .move(.freezer))
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.snapshot?.lots.first?.id, lot.id)
        XCTAssertEqual(model.snapshot?.lots.first?.location, .freezer)
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(3))
        try await store.close()
    }

    func testNewReservationMakesReviewedSaveStaleAndRequiresExplicitFreshReview() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(store)
        await model.load()
        let lot = try await add(model)
        await model.prepare(lotID: lot.id, action: .usedUp)
        let original = try XCTUnwrap(model.review)
        _ = try await reserve(lot, store: store)
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.pending?.command, original.command)
        XCTAssertEqual(model.pending?.reviewedInventoryRevision, original.before.state.revision)
        XCTAssertTrue(model.requiresFreshReview)
        XCTAssertFalse(model.canEdit)
        await model.load()
        XCTAssertEqual(model.pending?.command, original.command)
        XCTAssertEqual(model.pending?.reviewedInventoryRevision, original.before.state.revision)
        await model.retryPending()
        XCTAssertEqual(model.notice, .stale)
        await model.discardStaleReview()
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.canEdit)
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(8))
        await model.prepare(lotID: lot.id, action: .usedUp)
        XCTAssertNotEqual(model.review?.command.id, original.command.id)
        XCTAssertEqual(model.review?.affectedReservations.count, 1)
        try await store.close()
    }

    func testLockedDatabaseKeepsExactPendingInputAcrossRefreshAndRetry() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(store)
        await model.load()
        await model.prepareNewFood(name: "Milk", location: .fridge, amount: "1,5", unit: .liter)
        let review = try XCTUnwrap(model.review)
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("pickup.sqlite").path, &lock), SQLITE_OK)
        defer { sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.notice, .saveFailed)
        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending.command, review.command)
        XCTAssertEqual(pending.reviewedInventoryRevision, review.before.state.revision)
        XCTAssertFalse(model.requiresFreshReview)
        model.cancelReview()
        XCTAssertEqual(model.pending, pending)
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        await model.load()
        XCTAssertEqual(model.pending, pending)
        await model.retryPending()
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.snapshot?.lots.count, 1)
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(3, 2))
        await model.retryPending()
        let events = try await store.inventoryRecords(kind: .event)
        XCTAssertEqual(events.count, 1)
        try await store.close()
    }

    func testInactiveDoesNotActivateAndRevocationClearsAllPrivateState() async throws {
        let (inactiveDirectory, inactive) = try await database(active: false)
        defer { try? FileManager.default.removeItem(at: inactiveDirectory) }
        let unavailable = model(inactive)
        await unavailable.load()
        XCTAssertEqual(unavailable.phase, .migrationRequired)
        XCTAssertNil(unavailable.snapshot)
        let inactiveState = try await inactive.inventoryState()
        XCTAssertFalse(inactiveState.active)
        try await inactive.close()

        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        var authorized = true
        let model = PantryModel(repository: PantryRepository(store: store, authorize: { authorized }), clock: { self.now })
        await model.load()
        let lot = try await add(model)
        await model.prepare(lotID: lot.id, action: .usedUp)
        authorized = false
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.phase, .accessDenied)
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.review)
        XCTAssertNil(model.pending)
        XCTAssertNil(model.savedLotID)
        XCTAssertFalse(model.busy)
        authorized = true
        await model.load()
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(8))
        model.accessLost()
        XCTAssertNil(model.snapshot)
        try await store.close()
    }
}

@MainActor private final class DigestSchedulerSpy: PantryDigestScheduling {
    var granted = false
    var requests = 0
    var replacementCount = 0
    var onRequest: (() -> Void)?
    var deliveries: [PantryDigestDelivery] = []
    var removed = Set<UUID>()
    func permission(request: Bool) async throws -> Bool {
        if request { requests += 1; onRequest?() }
        return granted
    }
    func replace(_ deliveries: [PantryDigestDelivery], keepingDelivered: Set<UUID>) async throws {
        replacementCount += 1
        self.deliveries = deliveries
    }
    func remove(_ handles: Set<UUID>) async {
        removed.formUnion(handles)
        deliveries.removeAll { handles.contains($0.handle) }
    }
}

extension PantryModelTests {
    func testDigestDenialKeepsManualDatesAndConfirmedDailyGroupSurvivesReopen() async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(db)
        await model.load()
        let first = try await add(model), second = try await add(model, name: "Lentils")
        let scope = PantryDigestScope(origin: db.workspaceID, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let day = try MealDay(year: 2027, month: 3, day: 14, timeZoneIdentifier: "America/New_York")
        let spy = DigestSchedulerSpy(), folder = dir.appendingPathComponent("digest")
        let digest = PantryDigestStore(folder: folder, scheduler: spy, now: { self.now })
        try await digest.saveDay(scope, lot: first, day: day, authorized: { true })
        let travelDay = try MealDay(year: day.year, month: day.month, day: day.day, timeZoneIdentifier: "Europe/Madrid")
        try await digest.saveDay(scope, lot: second, day: travelDay, authorized: { true })
        XCTAssertEqual(spy.requests, 0)
        XCTAssertEqual(spy.replacementCount, 0)
        XCTAssertTrue(spy.deliveries.isEmpty)
        do {
            try await digest.setAlerts(scope, enabled: true, minute: 570, timeZone: try XCTUnwrap(TimeZone(identifier: day.timeZoneIdentifier)), authorized: { true })
            XCTFail("Denied permission enabled this digest")
        } catch PantryDigestFailure.denied {}
        XCTAssertFalse(try digest.document(scope).enabled)
        XCTAssertEqual(try digest.document(scope).rules.count, 2)
        spy.granted = true
        try await digest.setAlerts(scope, enabled: true, minute: 570, timeZone: try XCTUnwrap(TimeZone(identifier: day.timeZoneIdentifier)), authorized: { true })
        XCTAssertEqual(spy.deliveries.count, 1)
        let fire = try XCTUnwrap(spy.deliveries.first)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = try XCTUnwrap(TimeZone(identifier: day.timeZoneIdentifier))
        XCTAssertEqual(cal.component(.hour, from: fire.date), 9)
        XCTAssertEqual(cal.component(.minute, from: fire.date), 30)
        let reopened = PantryDigestStore(folder: folder, scheduler: spy, now: { self.now })
        try await reopened.reconcile(scope, lots: try XCTUnwrap(model.snapshot).lots)
        XCTAssertEqual(spy.deliveries, [fire])
        XCTAssertEqual(spy.requests, 2)
        await model.prepare(lotID: first.id, action: .usedUp)
        await model.confirmReview(acknowledgingReservations: true)
        try await reopened.reconcile(scope, lots: try XCTUnwrap(model.snapshot).lots)
        XCTAssertEqual(try reopened.document(scope).rules.map(\.lotID), [second.id])
        XCTAssertEqual(spy.deliveries, [fire])
        try await reopened.saveDay(scope, lot: second, day: nil, authorized: { true })
        XCTAssertTrue(spy.deliveries.isEmpty)
        try await db.close()
    }

    func testDigestPermissionScopeAndDateChangesReplaceAlertsWhileKeepingInAppChoices() async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(db); await model.load()
        let lot = try await add(model)
        let owner = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryDigestScope(origin: db.workspaceID, identity: owner)
        let scheduler = DigestSchedulerSpy(); scheduler.granted = true
        let digest = PantryDigestStore(folder: dir.appendingPathComponent("digest"), scheduler: scheduler, now: { self.now })
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let first = try MealDay(year: 2027, month: 12, day: 11, timeZoneIdentifier: zone.identifier)
        let later = try MealDay(year: 2027, month: 12, day: 12, timeZoneIdentifier: zone.identifier)
        try await digest.saveDay(scope, lot: lot, day: first, authorized: { true })
        var allowed = true
        scheduler.onRequest = { allowed = false }
        do {
            try await digest.setAlerts(scope, enabled: true, minute: 600, timeZone: zone, authorized: { allowed })
            XCTFail("A late system grant cannot enable another session")
        } catch PantryDigestFailure.changed {}
        XCTAssertFalse(try digest.document(scope).enabled)
        XCTAssertTrue(scheduler.deliveries.isEmpty)
        scheduler.onRequest = nil
        try await digest.setAlerts(scope, enabled: true, minute: 600, timeZone: zone, authorized: { true })
        let before = try XCTUnwrap(scheduler.deliveries.first)
        try await digest.saveDay(scope, lot: lot, day: later, authorized: { true })
        let replacement = try XCTUnwrap(scheduler.deliveries.first)
        XCTAssertEqual(scheduler.deliveries.count, 1)
        XCTAssertNotEqual(before.handle, replacement.handle)
        XCTAssertEqual(replacement.date.timeIntervalSince(before.date), 86_400)
        scheduler.granted = false
        try await digest.reconcile(scope, lots: [lot])
        XCTAssertTrue(scheduler.deliveries.isEmpty)
        XCTAssertTrue(digest.notificationsUnavailable)
        XCTAssertEqual(try digest.document(scope).rules.first?.day, later)
        try await digest.setAlerts(scope, enabled: false, minute: 600, timeZone: zone, authorized: { true })
        XCTAssertFalse(try digest.document(scope).enabled)
        XCTAssertEqual(try digest.document(scope).rules.first?.day, later)
        try await db.close()
    }

    func testDigestErasureRemovesOnlyAffectedHandlesAndWholeOriginRevokesSavedConsent() async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(db); await model.load()
        let first = try await add(model), second = try await add(model, name: "Rice")
        let owner = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryDigestScope(origin: db.workspaceID, identity: owner)
        let spy = DigestSchedulerSpy(); spy.granted = true
        let digest = PantryDigestStore(folder: dir.appendingPathComponent("digest"), scheduler: spy, now: { self.now })
        let day = try MealDay(year: 2027, month: 5, day: 3, timeZoneIdentifier: "America/New_York")
        let next = try MealDay(year: 2027, month: 5, day: 4, timeZoneIdentifier: "America/New_York")
        try await digest.saveDay(scope, lot: first, day: day, authorized: { true })
        try await digest.saveDay(scope, lot: second, day: next, authorized: { true })
        try await digest.setAlerts(scope, enabled: true, minute: 600, authorized: { true })
        let handles = try digest.document(scope).rules.map(\.handle)
        await model.prepare(lotID: first.id, action: .move(.freezer))
        await model.confirmReview(acknowledgingReservations: true)
        try await digest.erase(origin: db.workspaceID, whole: false, inventory: db)
        XCTAssertEqual(spy.removed, [handles[0]])
        XCTAssertEqual(spy.deliveries.map(\.handle), [handles[1]])
        XCTAssertEqual(try digest.document(scope).rules.map(\.lotID), [second.id])
        try await digest.erase(origin: db.workspaceID, whole: true, inventory: db)
        XCTAssertEqual(spy.removed, Set(handles))
        XCTAssertFalse(try digest.document(scope).enabled)
        XCTAssertTrue(try digest.document(scope).rules.isEmpty)
        try await db.close()
    }
}
