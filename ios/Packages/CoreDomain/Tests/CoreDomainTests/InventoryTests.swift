import XCTest
@testable import CoreDomain

final class InventoryTests: XCTestCase {
    private let origin = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let food = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func q(_ amount: Int64, _ unit: UnitOfMeasure = .count) -> Quantity {
        Quantity(amount: try! Rational(amount), unit: unit, originalLiteral: String(amount))
    }
    private func lot(_ count: InventoryCount = .exact(Quantity(amount: try! Rational(8), unit: .count, originalLiteral: "8")),
                     id: UUID = UUID(), source: InventorySource? = nil, useFirst: Bool = false) throws -> InventoryLot {
        let seed = InventoryLotSeed(foodID: food, name: "Wraps", source: source ?? .manual(originID: origin, sourceID: id),
            location: .cupboard, unit: count.quantity?.unit ?? .count, count: count, useFirst: useFirst)
        return try InventoryEngine.prepare(InventoryCommand(id: UUID(), originID: origin, lotID: id, eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(seed, observationID: UUID())), current: nil, at: now).lot
    }
    private func change(_ lot: InventoryLot, _ change: InventoryChange, id: UUID = UUID()) throws -> InventoryPreparedChange {
        try InventoryEngine.prepare(InventoryCommand(id: id, originID: origin, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: change), current: lot, at: now)
    }
    private func claim(_ lot: InventoryLot?, amount: Quantity? = nil, priority: AllocationPriority = .required,
                       state: InventoryReservationState = .active) -> InventoryReservation {
        InventoryReservation(id: UUID(), originID: origin, revision: 1, foodID: food, lotID: lot?.id,
            name: "Lunch", amount: amount ?? (state == .active ? q(2) : nil), priority: priority, state: state)
    }
    private func project(_ lots: [InventoryLot], _ reservations: [InventoryReservation]) throws -> InventoryProjection {
        try InventoryProjection.build(originID: origin, lots: lots, reservations: reservations, at: now)
    }

    private func applyReservation(_ edit: InventoryReservationEdit, to lot: InventoryLot, lots: [InventoryLot],
                                  claims: [InventoryReservation]) throws -> (InventoryReservation, InventoryProjection) {
        let command = InventoryCommand(id: UUID(), originID: origin, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .reservation(edit))
        return try edit.prepare(command: command, lots: lots, reservations: claims, before: project(lots, claims), at: now)
    }

    func testDirectReservationConservesExactPinAcrossPartialAndWholeRelease() throws {
        let a = try lot(.exact(q(4))), b = try lot(.exact(q(4)))
        let linked = claim(b, amount: q(4), priority: .protected)
        let day = try MealDay(year: 2026, month: 11, day: 18, timeZoneIdentifier: "America/New_York")
        let edit = InventoryReservationEdit.reserve(id: UUID(), purpose: "Packed lunch", amount: q(2), day: day)
        let (held, projection) = try applyReservation(edit, to: a, lots: [a,b], claims: [linked])
        XCTAssertEqual(held.personal?.day, day)
        XCTAssertEqual(projection.lots.first { $0.id == a.id }?.free?.amount, q(2).amount)
        XCTAssertEqual(projection.lots.first { $0.id == b.id }?.free?.amount, .zero)
        let (one, partiallyFree) = try applyReservation(.release(id: held.id, expectedRevision: 1, amount: q(1)), to: a,
                                                        lots: [a,b], claims: [linked,held])
        XCTAssertEqual(one.id, held.id)
        XCTAssertEqual(one.amount?.amount, .one)
        XCTAssertEqual(partiallyFree.lots.first { $0.id == a.id }?.free?.amount, q(3).amount)
        XCTAssertThrowsError(try applyReservation(.release(id: one.id, expectedRevision: 1, amount: nil), to: a,
                                                 lots: [a,b], claims: [linked,one]))
        let (released, allFree) = try applyReservation(.release(id: one.id, expectedRevision: 2, amount: nil), to: a,
                                                       lots: [a,b], claims: [linked,one])
        XCTAssertEqual(released.state, .released)
        XCTAssertEqual(allFree.lots.first { $0.id == a.id }?.free?.amount, q(4).amount)
        XCTAssertEqual(allFree.allocations.map(\.lotID), [b.id])
        XCTAssertThrowsError(try applyReservation(.release(id: linked.id, expectedRevision: 1, amount: nil), to: b,
                                                 lots: [a,b], claims: [linked,released]))
    }

    func testDirectReserveRejectsUnknownInsufficientAndReservedFood() throws {
        let a = try lot(.exact(q(4))), unknown = try lot(.someLeft)
        let linked = claim(a, amount: q(3), priority: .protected)
        let edit = InventoryReservationEdit.reserve(id: UUID(), purpose: "Lunch", amount: q(2), day: nil)
        XCTAssertThrowsError(try applyReservation(edit, to: a, lots: [a,unknown], claims: [linked]))
        XCTAssertThrowsError(try applyReservation(edit, to: unknown, lots: [a,unknown], claims: []))
        XCTAssertThrowsError(try applyReservation(.reserve(id: UUID(), purpose: "Lunch", amount: q(1,.gram), day: nil),
                                                 to: a, lots: [a], claims: []))
        XCTAssertThrowsError(try change(a, .reservation(edit)))
    }

    func testQualitativeObservationSupersedesCountAndRecountRestoresOnlyNewQuantity() throws {
        let eight = try lot(), lunch = claim(nil)
        let initial = try project([eight], [lunch])
        XCTAssertEqual(initial.lots[0].remaining?.amount, try Rational(8))
        XCTAssertEqual(initial.lots[0].held?.amount, try Rational(2))
        XCTAssertEqual(initial.lots[0].free?.amount, try Rational(6))
        let some = try change(eight, .count(.someLeft, observationID: UUID()))
        XCTAssertEqual(some.observation?.supersedesID, eight.observationID)
        XCTAssertEqual(some.lot.id, eight.id)
        XCTAssertEqual(some.lot.source, eight.source)
        XCTAssertEqual(some.lot.revision, 2)
        let unknown = try project([some.lot], [lunch])
        XCTAssertNil(unknown.lots[0].remaining); XCTAssertNil(unknown.lots[0].free)
        XCTAssertNil(unknown.lots[0].held)
        XCTAssertTrue(unknown.reservations[0].unresolved)
        XCTAssertNil(unknown.reservations[0].shortfall)
        let enough = try change(some.lot, .count(.haveEnough, observationID: UUID()))
        XCTAssertTrue(enough.lot.count.suppressesStaplePrompt)
        XCTAssertNil(try project([enough.lot], [lunch]).lots[0].free)
        let three = try change(enough.lot, .count(.exact(q(3)), observationID: UUID()))
        let recounted = try project([three.lot], [lunch])
        XCTAssertEqual(recounted.lots[0].remaining?.amount, try Rational(3))
        XCTAssertEqual(recounted.lots[0].held?.amount, try Rational(2))
        XCTAssertEqual(recounted.lots[0].free?.amount, .one)
        XCTAssertEqual(recounted.reservations[0].shortfall?.amount, .zero)
        XCTAssertEqual(lunch.state, .active)
    }

    func testStorageAndOpenedPreserveCountObservationAndPhysicalSource() throws {
        let original = try lot()
        let moved = try change(original, .move(.freezer))
        XCTAssertEqual(moved.lot.location, .freezer)
        XCTAssertEqual(moved.lot.count, original.count)
        XCTAssertEqual(moved.lot.observationID, original.observationID)
        XCTAssertEqual(moved.lot.confirmedAt, original.confirmedAt)
        XCTAssertNil(moved.observation)
        let opened = try change(moved.lot, .opened(now.addingTimeInterval(-3_600)))
        XCTAssertEqual(opened.lot.openedAt, now.addingTimeInterval(-3_600))
        XCTAssertEqual(opened.lot.count, original.count)
        XCTAssertEqual(opened.lot.source, original.source)
        XCTAssertEqual(opened.lot.id, original.id)
        XCTAssertEqual(opened.lot.revision, 3)
        XCTAssertNil(opened.observation)
    }

    func testUsedUpIsConfirmedZeroAndLeavesKnownReservationShortfall() throws {
        let original = try lot(), lunch = claim(nil)
        let lower = try change(original, .count(.exact(q(1)), observationID: UUID()))
        let one = try project([lower.lot], [lunch])
        XCTAssertEqual(one.lots[0].held?.amount, .one)
        XCTAssertEqual(one.lots[0].free?.amount, .zero)
        XCTAssertEqual(one.reservations[0].shortfall?.amount, .one)
        let empty = try change(lower.lot, .usedUp(observationID: UUID()))
        XCTAssertEqual(empty.observation?.count, .exact(q(0)))
        let result = try project([empty.lot], [lunch])
        XCTAssertEqual(result.lots[0].remaining?.amount, .zero)
        XCTAssertEqual(result.lots[0].free?.amount, .zero)
        XCTAssertEqual(result.reservations[0].shortfall?.amount, try Rational(2))
        XCTAssertFalse(result.reservations[0].unresolved)
        XCTAssertEqual(lunch.state, .active)
    }

    func testMetadataRevisionPreservesQualitativeObservationAndStorage() throws {
        let original = try lot(.someLeft, useFirst: true)
        let frozen = try change(original, .move(.freezer)).lot
        let opened = try change(frozen, .opened(now.addingTimeInterval(-30))).lot
        let correctedFood = UUID()
        let renamed = try change(opened, .revise(.init(foodID: correctedFood, name: "Corn wraps", useFirst: false)))
        XCTAssertEqual(renamed.lot.foodID, correctedFood)
        XCTAssertEqual(renamed.lot.name, "Corn wraps")
        XCTAssertFalse(renamed.lot.useFirst)
        XCTAssertEqual(renamed.lot.revision, opened.revision + 1)
        XCTAssertEqual(renamed.lot.count, .someLeft)
        XCTAssertEqual(renamed.lot.observationID, original.observationID)
        XCTAssertEqual(renamed.lot.confirmedAt, original.confirmedAt)
        XCTAssertEqual(renamed.lot.location, .freezer)
        XCTAssertEqual(renamed.lot.openedAt, opened.openedAt)
        XCTAssertEqual(renamed.lot.source, original.source)
        XCTAssertNil(renamed.observation)
    }

    func testDelayedObservationAfterStorageMoveKeepsActualTimeAndUsesOneRevision() throws {
        let original = try lot()
        let movedAt = now.addingTimeInterval(20)
        let moved = try InventoryEngine.prepare(InventoryCommand(id: UUID(), originID: origin, lotID: original.id,
            eventID: UUID(), expectedRevision: original.revision, occurredAt: movedAt, change: .move(.freezer)),
            current: original, at: movedAt).lot
        let savedAt = now.addingTimeInterval(30)
        let countedAt = now.addingTimeInterval(10)
        let observationID = UUID()
        let command = InventoryCommand(id: UUID(), originID: origin, lotID: original.id, eventID: UUID(),
            expectedRevision: moved.revision, occurredAt: savedAt,
            change: .revise(.init(observation: .init(count: .exact(q(3)), observationID: observationID,
                observedAt: countedAt), name: "Wraps remaining", useFirst: true)))
        let result = try InventoryEngine.prepare(command, current: moved, at: savedAt)
        XCTAssertEqual(result.lot.revision, 3)
        XCTAssertEqual(result.lot.location, .freezer)
        XCTAssertEqual(result.lot.count, .exact(q(3)))
        XCTAssertEqual(result.lot.confirmedAt, countedAt)
        XCTAssertEqual(result.lot.updatedAt, savedAt)
        XCTAssertEqual(result.observation?.observedAt, countedAt)
        XCTAssertEqual(result.observation?.supersedesID, original.observationID)
        XCTAssertEqual(result.lot.name, "Wraps remaining")
        XCTAssertTrue(result.lot.useFirst)
        XCTAssertEqual(try JSONDecoder().decode(InventoryCommand.self, from: JSONEncoder().encode(command)), command)
    }

    func testRevisionCannotReviveOlderObservationOrIntroduceFutureOrDuplicateCount() throws {
        let original = try lot()
        for observedAt in [now.addingTimeInterval(-1), now.addingTimeInterval(1)] {
            XCTAssertThrowsError(try change(original, .revise(.init(observation: .init(
                count: .exact(q(99)), observationID: UUID(), observedAt: observedAt))))) {
                XCTAssertEqual($0 as? InventoryError, .invalid("observationChronology"))
            }
        }
        XCTAssertThrowsError(try change(original, .revise(.init(observation: .init(
            count: .unknown, observationID: original.observationID, observedAt: now))))) {
            XCTAssertEqual($0 as? InventoryError, .duplicateIdentity)
        }
        XCTAssertThrowsError(try change(original, .revise(.init())))
        XCTAssertThrowsError(try change(original, .revise(.init(name: " "))))
    }

    func testNewReceiptPreservesObservationDateAndLegacySeedDecoding() throws {
        let observedAt = now.addingTimeInterval(-3_600)
        let seed = InventoryLotSeed(foodID: food, name: "Wraps",
            source: .receipt(originID: origin, key: ReceiptKey(sourceEventID: "arrival", orderLineID: food,
                branchID: "store", segmentID: "one")), location: .fridge, unit: .count,
            count: .exact(q(4)), observedAt: observedAt)
        let result = try InventoryEngine.prepare(InventoryCommand(id: UUID(), originID: origin, lotID: UUID(),
            eventID: UUID(), expectedRevision: nil, occurredAt: now, change: .create(seed, observationID: UUID())),
            current: nil, at: now)
        XCTAssertEqual(result.lot.confirmedAt, observedAt)
        XCTAssertEqual(result.observation?.observedAt, observedAt)
        XCTAssertEqual(result.lot.updatedAt, now)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as? [String: Any])
        legacyJSON.removeValue(forKey: "observedAt")
        let legacySeed = try JSONDecoder().decode(InventoryLotSeed.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(legacySeed.observedAt)
        let legacy = try InventoryEngine.prepare(InventoryCommand(id: UUID(), originID: origin, lotID: UUID(),
            eventID: UUID(), expectedRevision: nil, occurredAt: now, change: .create(legacySeed, observationID: UUID())),
            current: nil, at: now)
        XCTAssertEqual(legacy.lot.confirmedAt, now)
        let futureSeed = InventoryLotSeed(foodID: food, name: "Wraps", source: seed.source,
            location: .fridge, unit: .count, count: .exact(q(4)), observedAt: now.addingTimeInterval(1))
        XCTAssertThrowsError(try InventoryEngine.prepare(InventoryCommand(id: UUID(), originID: origin, lotID: UUID(),
            eventID: UUID(), expectedRevision: nil, occurredAt: now, change: .create(futureSeed, observationID: UUID())),
            current: nil, at: now))
    }

    func testBatchDetailShowsExactMealAllocationAndWholeLunchShortfallWithoutDuplicatingHolds() throws {
        let first = try lot(.exact(q(2)), useFirst: true)
        let second = try lot(.exact(q(1)))
        let lunch = claim(nil, amount: q(4), priority: .protected)
        let projection = try project([second, first], [lunch])
        for (batch, amount) in [(first, 2), (second, 1)] {
            let rows = projection.reservations(for: batch, among: [lunch])
            XCTAssertEqual(rows.map(\.id), [lunch.id])
            XCTAssertEqual(rows.first?.allocation?.lotID, batch.id)
            XCTAssertEqual(rows.first?.allocation?.amount, q(Int64(amount)).amount)
            XCTAssertEqual(rows.first?.coverage.requested?.amount, q(4).amount)
            XCTAssertEqual(rows.first?.coverage.shortfall?.amount, .one)
        }
        let pinned = claim(second, amount: q(2), priority: .protected)
        let pinnedProjection = try project([first, second], [pinned])
        XCTAssertTrue(pinnedProjection.reservations(for: first, among: [pinned]).isEmpty)
        let rows = pinnedProjection.reservations(for: second, among: [pinned])
        XCTAssertEqual(rows.first?.coverage.shortfall?.amount, .one)
        XCTAssertEqual(rows.first?.allocation?.amount, .one)
    }

    func testBatchDetailSeparatesUnconfirmedBackingFromAnotherBatchsActualMealAllocation() throws {
        let unknown = try lot(.unknown), known = try lot(.exact(q(1)))
        let lunch = claim(nil, amount: q(2), priority: .protected)
        let retired = claim(nil, amount: q(1), state: .released)
        let rows = [lunch, retired]
        let projection = try project([unknown, known], rows)
        let waiting = projection.reservations(for: unknown, among: rows)
        XCTAssertEqual(waiting.map(\.id), [lunch.id])
        XCTAssertNil(waiting.first?.allocation)
        XCTAssertTrue(waiting.first?.coverage.unresolved == true)
        XCTAssertNil(waiting.first?.coverage.shortfall)
        let backed = projection.reservations(for: known, among: rows)
        XCTAssertEqual(backed.first?.allocation?.amount, .one)
        XCTAssertEqual(backed.first?.id, lunch.id)
        let pinned = claim(unknown, amount: q(2), priority: .protected)
        let pinnedProjection = try project([unknown, known], [pinned])
        XCTAssertEqual(pinnedProjection.reservations(for: unknown, among: [pinned]).first?.coverage.issues, [.reservationUnresolved])
        XCTAssertTrue(pinnedProjection.reservations(for: known, among: [pinned]).isEmpty)
    }

    func testPinKeepsBReservedDespiteAUseFirst() throws {
        let a = try lot(.exact(q(4)), useFirst: true), b = try lot(.exact(q(4)))
        let result = try project([a, b], [claim(b, amount: q(4))])
        XCTAssertEqual(result.lots[0].free?.amount, try Rational(4))
        XCTAssertEqual(result.lots[1].held?.amount, try Rational(4))
        XCTAssertEqual(result.lots[1].free?.amount, .zero)
    }

    func testProtectedPinPrecedesUnpinnedProtectedDemand() throws {
        let a = try lot(.exact(q(4))), b = try lot(.exact(q(4)), useFirst: true)
        let pinnedLunch = claim(b, amount: q(4), priority: .protected)
        let otherLunch = claim(nil, amount: q(4), priority: .protected)
        let result = try project([b, a], [otherLunch, pinnedLunch])
        XCTAssertTrue(result.reservations.allSatisfy { $0.shortfall?.amount == .zero && !$0.unresolved })
        XCTAssertTrue(result.lots.allSatisfy { $0.held?.amount == (try? Rational(4)) && $0.free?.amount == .zero })
        XCTAssertEqual(pinnedLunch.priority, .protected)
        XCTAssertEqual(result.allocations.filter { $0.needID == pinnedLunch.id }.map(\.lotID), [b.id])
        XCTAssertEqual(result.allocations.filter { $0.needID == otherLunch.id }.map(\.lotID), [a.id])
    }

    func testUnknownOrMissingPinnedSourceNeverBorrowsAnotherLot() throws {
        let a = try lot(.exact(q(4)), useFirst: true), b = try lot(.unknown)
        let pin = claim(b, amount: q(4))
        let result = try project([a, b], [pin])
        XCTAssertEqual(result.lots[0].free?.amount, try Rational(4))
        XCTAssertNil(result.lots[1].free)
        XCTAssertTrue(result.reservations[0].unresolved)
        XCTAssertNil(result.reservations[0].shortfall)
        let missing = try project([a], [pin])
        XCTAssertEqual(missing.lots[0].free?.amount, try Rational(4))
        XCTAssertTrue(missing.reservations[0].issues.contains(.sourceUnavailable))
        XCTAssertNil(missing.reservations[0].shortfall)
    }

    func testUnresolvedMigrationHoldBlocksItsScopeAndReleaseDoesNotDuplicateSupply() throws {
        let a = try lot(.exact(q(4))), b = try lot(.exact(q(4)))
        let pin = claim(b, state: .unresolved)
        let pinned = try project([a, b], [pin])
        XCTAssertEqual(pinned.lots[0].free?.amount, try Rational(4))
        XCTAssertNil(pinned.lots[1].free)
        XCTAssertTrue(pinned.reservations[0].unresolved)
        XCTAssertTrue(try project([a, b], [claim(nil, state: .unresolved)]).lots.allSatisfy { $0.free == nil })
        let released = InventoryReservation(id: pin.id, originID: origin, revision: 2, foodID: food, lotID: b.id,
            name: pin.name, amount: pin.amount, priority: pin.priority, state: .released)
        let free = try project([a, b], [released])
        XCTAssertTrue(free.reservations.isEmpty)
        XCTAssertEqual(free.lots.map { $0.free?.amount }, [try Rational(4), try Rational(4)])
        XCTAssertEqual(try project([a, b], [released]), free)
    }

    func testUnknownConversionKeepsQuantityButWithholdsFreeAndCoverage() throws {
        let stock = try lot(.exact(q(8)))
        let result = try project([stock], [claim(stock, amount: q(100, .gram))])
        XCTAssertEqual(result.lots[0].remaining?.amount, try Rational(8))
        XCTAssertNil(result.lots[0].held); XCTAssertNil(result.lots[0].free)
        XCTAssertTrue(result.lots[0].issues.contains(.conversionUnknown))
        XCTAssertTrue(result.reservations[0].unresolved)
        XCTAssertNil(result.reservations[0].shortfall)
    }

    func testExactConversionsConservePerLotUnitsWithoutRounding() throws {
        let stock = try lot(.exact(q(1, .kilogram)))
        let result = try project([stock], [claim(stock, amount: q(250, .gram), priority: .protected), claim(nil, amount: q(250, .gram))])
        XCTAssertEqual(result.lots[0].held?.amount, try Rational(1, 2))
        XCTAssertEqual(result.lots[0].free?.amount, try Rational(1, 2))
        XCTAssertEqual(result.lots[0].free?.unit, .kilogram)
        XCTAssertTrue(result.reservations.allSatisfy { $0.shortfall?.amount == .zero })
        let noClaims = try project([try lot(.exact(q(2))), try lot(.exact(q(50, .gram)))], [])
        XCTAssertEqual(noClaims.lots.map { $0.free?.amount }, [try Rational(2), try Rational(50)])
    }

    func testReceiptIdentitySurvivesCorrectionAndPartialDeliveryStaysDistinct() throws {
        let key = ReceiptKey(sourceEventID: "arrival", orderLineID: food, branchID: "Branch", segmentID: "one")
        let source = InventorySource.receipt(originID: origin, key: key)
        let first = try lot(.exact(q(8)), source: source)
        let corrected = try change(first, .count(.exact(q(6)), observationID: UUID()))
        XCTAssertEqual(corrected.lot.id, first.id); XCTAssertEqual(corrected.lot.source, source)
        XCTAssertNotEqual(corrected.lot.observationID, first.observationID)
        let second = try lot(.exact(q(2)), source: .receipt(originID: origin,
            key: ReceiptKey(sourceEventID: "arrival", orderLineID: food, branchID: "Branch", segmentID: "two")))
        XCTAssertEqual(try project([corrected.lot, second], []).lots.map { $0.free?.amount }, [try Rational(6), try Rational(2)])
        XCTAssertThrowsError(try project([first, try lot(.exact(q(8)), source: source)], [])) { XCTAssertEqual($0 as? InventoryError, .duplicateIdentity) }
    }

    func testCommandEncodingRetainsReplayIdentityAndNewPrepareRejectsOldBase() throws {
        let original = try lot()
        let request = InventoryCommand(id: UUID(), originID: origin, lotID: original.id, eventID: UUID(),
            expectedRevision: original.revision, occurredAt: now, change: .count(.exact(q(3)), observationID: UUID()))
        let bytes = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(InventoryCommand.self, from: bytes), request)
        let prepared = try InventoryEngine.prepare(request, current: original, at: now)
        XCTAssertEqual(prepared.receipt.id, request.id)
        XCTAssertEqual(prepared.event.operationID, request.id)
        XCTAssertEqual(prepared.observation?.operationID, request.id)
        XCTAssertEqual(prepared.receipt.previousRevision, 1)
        XCTAssertEqual(prepared.receipt.revision, 2)
        XCTAssertEqual(try InventoryEngine.prepare(request, current: original, at: now), prepared)
        XCTAssertThrowsError(try InventoryEngine.prepare(request, current: prepared.lot, at: now)) { XCTAssertEqual($0 as? InventoryError, .stale) }
        XCTAssertEqual(try JSONDecoder().decode(InventoryLot.self, from: JSONEncoder().encode(prepared.lot)), prepared.lot)
    }

    func testInvalidOriginFutureObservationAndReusedObservationAreRejected() throws {
        let original = try lot()
        let wrong = InventoryCommand(id: UUID(), originID: UUID(), lotID: original.id, eventID: UUID(),
            expectedRevision: 1, occurredAt: now, change: .move(.fridge))
        XCTAssertThrowsError(try InventoryEngine.prepare(wrong, current: original, at: now)) { XCTAssertEqual($0 as? InventoryError, .wrongOrigin) }
        XCTAssertThrowsError(try change(original, .count(.unknown, observationID: original.observationID)))
        XCTAssertThrowsError(try change(original, .opened(now.addingTimeInterval(1))))
        let future = InventoryCommand(id: UUID(), originID: origin, lotID: original.id, eventID: UUID(),
            expectedRevision: 1, occurredAt: now.addingTimeInterval(1), change: .usedUp(observationID: UUID()))
        XCTAssertThrowsError(try InventoryEngine.prepare(future, current: original, at: now))
        XCTAssertThrowsError(try InventoryProjection.build(originID: UUID(), lots: [original], reservations: [], at: now))
    }

    func testProjectionRejectsDuplicateClaimsAndBoundedOversizedInput() throws {
        let stock = try lot(), pin = claim(nil)
        XCTAssertThrowsError(try project([stock], [pin, pin])) { XCTAssertEqual($0 as? InventoryError, .duplicateIdentity) }
        XCTAssertThrowsError(try project(Array(repeating: stock, count: InventoryProjection.maximumLots + 1), [])) {
            XCTAssertEqual($0 as? InventoryError, .capacity)
        }
    }
}
