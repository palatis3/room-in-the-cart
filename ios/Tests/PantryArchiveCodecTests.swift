import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

@MainActor final class PantryArchiveCodecTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func quantity(_ value: Int64) throws -> Quantity { .init(amount: try Rational(value), unit: .count, originalLiteral: String(value)) }
    private func snapshot(count: Int = 1, longNames: Bool = false) throws -> PantryArchiveCodec.Snapshot {
        let origin = UUID()
        var lots: [InventoryLot] = [], observations: [InventoryObservation] = [], events: [InventoryEvent] = []
        for index in 0..<count {
            let command = InventoryCommand(id: UUID(), originID: origin, lotID: UUID(), eventID: UUID(), expectedRevision: nil,
                occurredAt: now, change: .create(.init(foodID: UUID(), name: longNames ? String(repeating: "x", count: 480) + String(index) : "Wraps",
                    source: .manual(originID: origin, sourceID: UUID()), location: .freezer, unit: .count,
                    count: .exact(try quantity(8))), observationID: UUID()))
            let prepared = try InventoryEngine.prepare(command, current: nil, at: now)
            lots.append(prepared.lot); observations.append(try XCTUnwrap(prepared.observation)); events.append(prepared.event)
        }
        return .init(descriptor: .init(originID: origin, inventoryRevision: 1, capturedAt: now), lots: lots,
            observations: observations, events: events, reservations: [], sourceLinks: lots.map { .init(lotID: $0.id, source: $0.source) }, history: [])
    }
    private func replacing(_ source: PantryArchiveCodec.Snapshot, lots: [InventoryLot]? = nil,
                           observations: [InventoryObservation]? = nil, events: [InventoryEvent]? = nil,
                           reservations: [InventoryReservation]? = nil, history: [PantryArchiveCodec.History]? = nil) -> PantryArchiveCodec.Snapshot {
        .init(descriptor: .init(originID: source.descriptor.originID,
            inventoryRevision: max(source.descriptor.inventoryRevision,
                max((lots ?? source.lots).map(\.revision).max() ?? 0, (reservations ?? source.reservations).map(\.revision).max() ?? 0)),
            capturedAt: source.descriptor.capturedAt), lots: lots ?? source.lots, observations: observations ?? source.observations,
            events: events ?? source.events, reservations: reservations ?? source.reservations,
            sourceLinks: source.sourceLinks, history: history ?? source.history)
    }

    func testIndependentPantryHistoryKeepsReceiptCurrencyAndRejectsMixedReceiptLines() throws {
        let snapshot = try snapshot(count: 0), archivedOrigin = UUID(), receipt = UUID()
        func acquisition(_ id: UUID, _ line: Int, _ currency: Currency, paid: Int64?) throws -> PantryArchiveCodec.History {
            let quantity = try quantity(1)
            let row = ReceiptAcquisition(receiptID: id, ordinal: line, lotID: UUID(), foodID: UUID(),
                merchant: "Mercado", purchaseDate: now, transactionReference: nil, imageDigest: nil,
                originalLine: "Frijol", name: "Frijol", received: quantity, usable: quantity,
                paidLineTotal: paid.map { Money(minorUnits: $0, currency: currency) }, stock: .added(location: .freezer),
                currency: currency)
            return .acquisition(originID: archivedOrigin, row)
        }
        let paid = try acquisition(receipt, 0, .mxn, paid: 3201), unknown = try acquisition(receipt, 1, .mxn, paid: nil)
        let dollars = try acquisition(UUID(), 0, .usd, paid: 0)
        let valid = replacing(snapshot, history: [paid, unknown, dollars])
        let package = try PantryArchiveCodec.encode(valid)
        let decoded = try PantryArchiveCodec.decode(package)
        let restored = try PantryArchiveRestore.prepare(decoded, newOriginID: UUID(), restorationID: UUID(), at: now)
        for fact in valid.history { XCTAssertTrue(restored.history.contains(fact)) }

        let foreignLine = try acquisition(receipt, 2, .usd, paid: 3201)
        XCTAssertThrowsError(try PantryArchiveCodec.encode(replacing(valid, history: valid.history + [foreignLine])))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let index = try PantryArchiveIndex(url: url)
        for (ordinal, fact) in valid.history.enumerated() {
            try index.append(.historical(fact), ordinal: ordinal, at: now)
        }
        XCTAssertThrowsError(try index.append(.historical(foreignLine), ordinal: valid.history.count, at: now))
        try index.validate(descriptor: decoded.descriptor)
        try index.close()
        XCTAssertEqual(try PantryArchiveCodec.decode(package).history, valid.history)
    }

    func testQualitativeUseRoundTripKeepsWordingAndHistoryAcrossIndependentRestore() throws {
        let original = try snapshot(), before = try XCTUnwrap(original.lots.first)
        let wording = "menos de media botella"
        let read = InventoryCountRevision(count: .someLeft, observationID: UUID(), observedAt: now, countWording: wording)
        let action = InventoryUsage(id: UUID(), kind: .some)
        let command = InventoryCommand(id: UUID(), originID: original.descriptor.originID, lotID: before.id, eventID: UUID(),
            expectedRevision: before.revision, occurredAt: now, change: .revise(.init(observation: read, usage: [action])))
        let change = try InventoryEngine.prepare(command, current: before, at: now)
        let saved = replacing(original, lots: [change.lot], observations: original.observations + [try XCTUnwrap(change.observation)],
                              events: original.events + [change.event])
        let restored = try PantryArchiveRestore.prepare(PantryArchiveCodec.decode(PantryArchiveCodec.encode(saved)),
            newOriginID: UUID(), restorationID: UUID(), at: now)
        XCTAssertEqual(restored.lots.first?.countWording, wording)
        XCTAssertEqual(restored.observations.first?.countWording, wording)
        XCTAssertTrue(restored.history.contains(.originalEvent(change.event)))
        XCTAssertNil(restored.lots.first?.count.quantity)
    }

    func testDatedPersonalLunchSurvivesArchiveAndIndependentRestoreKeepsItsHoldUnresolved() throws {
        let source = try snapshot(), lot = try XCTUnwrap(source.lots.first)
        let day = try MealDay(year: 2026, month: 11, day: 18, timeZoneIdentifier: "America/New_York")
        let claim = InventoryReservation(id: UUID(), originID: source.descriptor.originID, revision: 1, foodID: lot.foodID,
            lotID: lot.id, name: "Packed lunch", amount: try quantity(2), priority: .protected, personal: .init(day: day))
        let saved = replacing(source, reservations: [claim])
        let decoded = try PantryArchiveCodec.decode(PantryArchiveCodec.encode(saved))
        XCTAssertEqual(decoded.reservations, [claim])
        let restored = try PantryArchiveRestore.prepare(decoded, newOriginID: UUID(), restorationID: UUID(), at: now)
        XCTAssertEqual(restored.reservations.first?.personal?.day, day)
        XCTAssertEqual(restored.reservations.first?.state, .unresolved)
        let projection = try InventoryProjection.build(originID: restored.descriptor.originID, lots: restored.lots,
            reservations: restored.reservations, at: now)
        XCTAssertNil(projection.lots.first?.free)
    }

    func testCompleteGraphRoundTripPreservesObservationHistoryAndPhysicalSource() throws {
        let original = try snapshot(), lot = try XCTUnwrap(original.lots.first)
        let command = InventoryCommand(id: UUID(), originID: original.descriptor.originID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(.someLeft, observationID: UUID()))
        let changed = try InventoryEngine.prepare(command, current: lot, at: now)
        let state = replacing(original, lots: [changed.lot], observations: original.observations + [try XCTUnwrap(changed.observation)],
            events: original.events + [changed.event])
        let package = try PantryArchiveCodec.encode(state)
        let decoded = try PantryArchiveCodec.decode(package)
        XCTAssertEqual(decoded.lots, state.lots)
        XCTAssertEqual(Set(decoded.observations.map(\.id)), Set(state.observations.map(\.id)))
        XCTAssertEqual(decoded.sourceLinks, state.sourceLinks)
        XCTAssertEqual(decoded.lots.first?.count, .someLeft)
        let manifest = try PantryArchiveCodec.decodeManifest(ArchiveCodec.canonical(package.manifest))
        XCTAssertEqual(manifest, package.manifest)
    }

    func testLargeValidGraphUsesBoundedChunksWithoutDroppingRecords() throws {
        let source = try snapshot(count: 3_000, longNames: true)
        let package = try PantryArchiveCodec.encode(source)
        XCTAssertGreaterThan(package.chunks.count, 1)
        XCTAssertGreaterThan(package.chunks.reduce(0) { $0 + $1.count }, ArchiveCodec.maximumNativeBytes)
        XCTAssertTrue(package.chunks.allSatisfy { $0.count <= ArchiveCodec.maximumNativeBytes })
        let restored = try PantryArchiveCodec.decode(package)
        XCTAssertEqual(restored.lots.count, 3_000); XCTAssertEqual(restored.observations.count, 3_000)
        XCTAssertEqual(restored.events.count, 3_000); XCTAssertEqual(restored.sourceLinks.count, 3_000)
        XCTAssertEqual(Set(restored.lots.map(\.id)), Set(source.lots.map(\.id)))
    }

    func testMissingDuplicateReorderedMixedAndAlteredChunksCannotBecomeSnapshot() throws {
        let source = try snapshot(count: 80), package = try PantryArchiveCodec.encode(source)
        XCTAssertGreaterThan(package.chunks.count, 1)
        XCTAssertThrowsError(try PantryArchiveCodec.decode(.init(manifest: package.manifest, chunks: Array(package.chunks.dropLast()))))
        var duplicated = package.chunks; duplicated[1] = duplicated[0]
        XCTAssertThrowsError(try PantryArchiveCodec.decode(.init(manifest: package.manifest, chunks: duplicated)))
        XCTAssertThrowsError(try PantryArchiveCodec.decode(.init(manifest: package.manifest, chunks: Array(package.chunks.reversed()))))
        let other = try PantryArchiveCodec.encode(source)
        var mixed = package.chunks; mixed[0] = other.chunks[0]
        XCTAssertThrowsError(try PantryArchiveCodec.decode(.init(manifest: package.manifest, chunks: mixed)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: package.chunks[0]) as? [String: Any])
        object["unexpectedPrivateData"] = "unsupported"
        let unexpected = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try PantryArchiveCodec.decodeChunk(unexpected))
    }

    func testInvalidGraphAndEventContradictionsAreRejectedBeforeEncoding() throws {
        let source = try snapshot(), lot = try XCTUnwrap(source.lots.first)
        XCTAssertThrowsError(try PantryArchiveCodec.encode(replacing(source, observations: [])))
        XCTAssertThrowsError(try PantryArchiveCodec.encode(replacing(source, lots: source.lots + source.lots)))
        let foreign = InventoryReservation(id: UUID(), originID: UUID(), revision: 1, foodID: lot.foodID,
            lotID: lot.id, name: "Other origin", amount: try quantity(1))
        XCTAssertThrowsError(try PantryArchiveCodec.encode(replacing(source, reservations: [foreign])))
        let missing = InventoryReservation(id: UUID(), originID: source.descriptor.originID, revision: 1, foodID: lot.foodID,
            lotID: UUID(), name: "Missing physical lot", amount: try quantity(1))
        XCTAssertThrowsError(try PantryArchiveCodec.encode(replacing(source, reservations: [missing])))
        let contradictory = InventoryLot(id: lot.id, foodID: lot.foodID, name: lot.name, source: lot.source, revision: lot.revision,
            location: .fridge, unit: lot.unit, count: lot.count, observationID: lot.observationID,
            confirmedAt: lot.confirmedAt, updatedAt: lot.updatedAt)
        XCTAssertThrowsError(try PantryArchiveCodec.encode(replacing(source, lots: [contradictory])))
    }

    func testIndependentRestoreKeepsTimesAndConservativeClaimsWithoutOldReplayState() throws {
        let source = try snapshot(), lot = try XCTUnwrap(source.lots.first)
        let claim = InventoryReservation(id: UUID(), originID: source.descriptor.originID, revision: 3, foodID: lot.foodID,
            lotID: lot.id, name: "Dinner", amount: try quantity(2), priority: .protected)
        let original = replacing(source, reservations: [claim]), newOrigin = UUID(), restorationID = UUID()
        let restored = try PantryArchiveRestore.prepare(original, newOriginID: newOrigin, restorationID: restorationID, at: now)
        XCTAssertEqual(restored.lots.first?.revision, 1); XCTAssertEqual(restored.lots.first?.source.originID, newOrigin)
        XCTAssertEqual(restored.lots.first?.confirmedAt, lot.confirmedAt); XCTAssertEqual(restored.lots.first?.updatedAt, lot.updatedAt)
        XCTAssertEqual(restored.reservations.first?.originID, newOrigin); XCTAssertEqual(restored.reservations.first?.state, .unresolved)
        XCTAssertEqual(restored.reservations.first?.lotID, lot.id); XCTAssertEqual(restored.reservations.first?.amount, claim.amount)
        XCTAssertTrue(restored.events.isEmpty)
        XCTAssertTrue(restored.history.contains(.originalLot(lot)))
        let projection = try InventoryProjection.build(originID: newOrigin, lots: restored.lots, reservations: restored.reservations, at: now)
        XCTAssertNil(projection.lots.first?.free)
        XCTAssertEqual(try PantryArchiveRestore.prepare(original, newOriginID: newOrigin, restorationID: restorationID, at: now), restored)
        XCTAssertThrowsError(try PantryArchiveRestore.prepare(restored, newOriginID: source.descriptor.originID, restorationID: UUID(), at: now))
        let baseline = try XCTUnwrap(restored.lots.first)
        let move = try InventoryEngine.prepare(.init(id: UUID(), originID: newOrigin, lotID: baseline.id, eventID: UUID(),
            expectedRevision: 1, occurredAt: now, change: .move(.cupboard)), current: baseline, at: now)
        try PantryArchiveCodec.validate(replacing(restored, lots: [move.lot], events: [move.event]))
    }

    func testProjectionReaderRejectsUnknownScopeAndArchiveRestoreKeepsBindingInert() async throws {
        let source = try snapshot()
        struct Document: Codable { let formatVersion: Int; let workspace: LedgerWorkspace }
        let payload = try ArchiveCodec.canonical(Document(formatVersion: 1, workspace: LedgerWorkspace()))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(ledger)
        let ledgerOrigin = ledger.workspaceID
        let binding = LedgerInventoryProjectionBinding(ledgerWorkspaceID: ledgerOrigin, projectionID: UUID(),
            inventoryWorkspaceID: source.descriptor.originID, inventoryOperationID: UUID(), kind: "test.archive", targetID: UUID())
        let record = try PantryLedgerProjectionPort.intentRecord(id: UUID(), binding: binding, canonicalRequest: Data("reviewed".utf8),
            payload: payload, expectedRevision: 0, savedAt: now)
        let typed = try PantryLedgerProjectionPort.archiveBinding(record)
        let wrongKind = InventoryRecord(key: .init(.lot, record.key.id), revision: 1, payload: record.payload)
        XCTAssertThrowsError(try PantryLedgerProjectionPort.archiveBinding(wrongKind))
        let wrongVersion = InventoryRecord(key: record.key, revision: 2, payload: record.payload)
        XCTAssertThrowsError(try PantryLedgerProjectionPort.archiveBinding(wrongVersion))
        let invented = PantryLedgerProjectionPort.ReviewDisposition(version: 1, sourceIntentID: record.key.id,
            bindingDigest: Data(repeating: 0, count: 32), decision: "needsReview", ledgerRevision: 0)
        XCTAssertThrowsError(try PantryLedgerProjectionPort.archiveDisposition(.init(key: .init(.intent, UUID()), revision: 1,
            payload: ArchiveCodec.canonical(invented)), bindingRecord: record))
        let receipt = try await ledger.applyInventoryProjection(binding: binding, request: typed.canonicalRequest,
            payload: payload, expectedRevision: 0, savedAt: now)
        let application = PantryArchiveCodec.ProjectionApplication(receipt)
        let evidence = PantryArchiveCodec.History.projection(.init(sourceIntentID: record.key.id, binding: typed,
            needsReview: nil, application: application))
        var invalidObject = try XCTUnwrap(JSONSerialization.jsonObject(with: ArchiveCodec.canonical(application)) as? [String: Any])
        invalidObject["revision"] = 2
        let invalidApplication = try JSONDecoder().decode(PantryArchiveCodec.ProjectionApplication.self,
            from: JSONSerialization.data(withJSONObject: invalidObject))
        XCTAssertThrowsError(try PantryArchiveCodec.encode(replacing(source, history: [.projection(.init(
            sourceIntentID: record.key.id, binding: typed, needsReview: nil, application: invalidApplication))])))
        let package = try PantryArchiveCodec.encode(replacing(source, history: [evidence]))
        let restored = try PantryArchiveRestore.prepare(PantryArchiveCodec.decode(package), newOriginID: UUID(), restorationID: UUID(), at: now)
        XCTAssertTrue(restored.history.contains(evidence)); XCTAssertTrue(restored.events.isEmpty)
        XCTAssertNotEqual(restored.descriptor.originID, binding.inventoryWorkspaceID)
    }

    func testMigratedSQLiteBaselineAndLaterCountAndMoveRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let pickup = PickupModel(store: store, clock: { instant }); cleanup.track(pickup, store)
        let food = UUID()
        let added = await pickup.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: try quantity(2),
            available: try quantity(0), due: nil, confirmedAt: now))
        XCTAssertTrue(added)
        let journeyID = try XCTUnwrap(pickup.journey?.id)
        let stocked = await pickup.saveStockLot(.init(id: UUID(), foodID: food, name: "Freezer wraps",
            usable: try quantity(8), confirmedAt: now, source: .freezer), in: journeyID)
        XCTAssertTrue(stocked)
        let cutover = try await store.inventoryCutoverSnapshot()
        let mapped = try PantryLegacyMigration.map(originID: cutover.token.workspaceID,
            heads: cutover.sources.map(PantryLegacyMigration.SourceHead.init), ledger: .unavailable, at: now)
        let migration = try PantryMigrationPackage.build(mapped, migrationID: UUID(), sourceToken: cutover.token,
            inventoryRevision: 0, at: now)
        _ = try await store.beginInventoryMigration(migration.plan)
        for chunk in migration.chunks { _ = try await store.stageInventoryMigration(id: migration.plan.migrationID, chunk: chunk) }
        _ = try await store.finishInventoryMigration(id: migration.plan.migrationID, at: now)
        let repository = PantryRepository(store: store, authorize: { true })
        var current = try await repository.load(at: now)
        let initial = try XCTUnwrap(current.lots.first)
        XCTAssertEqual(initial.revision, 1)
        let count = InventoryCommand(id: UUID(), originID: mapped.originID, lotID: initial.id, eventID: UUID(),
            expectedRevision: initial.revision, occurredAt: now, change: .count(.someLeft, observationID: UUID()))
        _ = try await repository.apply(count, reviewedInventoryRevision: current.state.revision, at: now)
        current = try await repository.load(at: now)
        let counted = try XCTUnwrap(current.lots.first)
        let move = InventoryCommand(id: UUID(), originID: mapped.originID, lotID: counted.id, eventID: UUID(),
            expectedRevision: counted.revision, occurredAt: now, change: .move(.fridge))
        _ = try await repository.apply(move, reviewedInventoryRevision: current.state.revision, at: now)
        current = try await repository.load(at: now)
        let observations = try await store.inventoryRecords(kind: .observation).map(PantryPersistenceCodec.observation)
        let links = try await store.inventoryRecords(kind: .sourceLink).map(PantryPersistenceCodec.sourceLink)
        let events = try await store.inventoryRecords(kind: .event).map { try JSONDecoder().decode(InventoryEvent.self, from: $0.payload) }
        let history = try await store.inventoryRecords(kind: .intent).map {
            PantryArchiveCodec.History.migration(try PantryMigrationPackage.provenance($0,
                migrationID: migration.plan.migrationID, originID: mapped.originID))
        }
        let snapshot = PantryArchiveCodec.Snapshot(descriptor: .init(originID: mapped.originID,
            inventoryRevision: current.state.revision, capturedAt: now), lots: current.lots,
            observations: observations, events: events, reservations: current.reservations, sourceLinks: links, history: history)
        let decoded = try PantryArchiveCodec.decode(PantryArchiveCodec.encode(snapshot))
        XCTAssertEqual(decoded.lots, current.lots)
        XCTAssertEqual(decoded.lots.first?.count, .someLeft); XCTAssertEqual(decoded.lots.first?.location, .fridge)
        XCTAssertEqual(decoded.events.count, 2)
        XCTAssertEqual(Set(decoded.observations.map(\.id)), Set(observations.map(\.id)))
        XCTAssertEqual(decoded.history, history)
        XCTAssertThrowsError(try PantryArchiveCodec.encode(replacing(snapshot, history: [])),
            "An imported baseline cannot be invented from the final lot after later changes.")
        let after = try await pickup.archiveSnapshot()
        XCTAssertEqual(after.records.map(\.payload), cutover.sources.map(\.payload))
    }

    func testPendingEvidenceValidatorDoesNotOpenJournalOrAuthorizeRestoredAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let producer = PickupModel(databaseURL: directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        cleanup.track(producer)
        let added = await producer.addUrgent(.init(id: UUID(), food: "Wraps", meal: "Dinner", required: try quantity(4), available: try quantity(0), due: nil, confirmedAt: now))
        XCTAssertTrue(added)
        let saved = try await producer.archiveSnapshot(), head = try XCTUnwrap(saved.records.first), source = try snapshot()
        let request = PantryPickupDelta.Request(version: 1, operationID: UUID(), originID: source.descriptor.originID,
            inventoryRevision: 1, priorDigest: Data(repeating: 1, count: 32), proposedDigest: Data(repeating: 2, count: 32),
            ledgerOriginID: UUID(), ledgerRevision: 0, ledgerDigest: Data(repeating: 3, count: 32))
        let entry = PantryPickupPendingStore.Entry(submission: .init(version: 1, request: request,
            changedHeads: [.init(id: head.id, revision: 1, payload: head.payload, savedAt: now)], preparedAt: now),
            selection: .preserve, recoveryOperationID: UUID(), requiresActionAuthorization: true)
        try PantryPickupPendingStore.validateArchiveEntry(entry, inventoryWorkspaceID: request.originID, ledgerWorkspaceID: try XCTUnwrap(request.ledgerOriginID))
        XCTAssertThrowsError(try PantryPickupPendingStore.validateArchiveEntry(entry, inventoryWorkspaceID: UUID(), ledgerWorkspaceID: try XCTUnwrap(request.ledgerOriginID)))
        let evidence = PantryArchiveCodec.History.pickupPending(entry)
        let restored = try PantryArchiveRestore.prepare(replacing(source, history: [evidence]), newOriginID: UUID(), restorationID: UUID(), at: now)
        XCTAssertTrue(restored.history.contains(evidence))
        XCTAssertTrue(entry.requiresActionAuthorization)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending").path))
    }
}
