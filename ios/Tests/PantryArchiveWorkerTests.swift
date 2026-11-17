import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

@MainActor final class PantryArchiveWorkerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let store: ComparisonStore
        let ledger: LedgerStore
        let pending: PantryPickupPendingStore
        let gate: PantryMutationGate
        let worker: PantryArchiveWorker
        let capture: PantryArchiveCapture
    }
    private func fixture(count: Int = 1) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(store, ledger)
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: store.workspaceID, ledgerWorkspaceID: ledger.workspaceID)
        var revision: Int64 = 0
        for start in stride(from: 0, to: count, by: 60) {
            let operation = UUID()
            var writes: [InventoryWrite] = []
            for index in start..<min(start + 60, count) {
                let command = InventoryCommand(id: operation, originID: store.workspaceID, lotID: UUID(), eventID: UUID(),
                    expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: UUID(), name: "Food \(index)",
                        source: .manual(originID: store.workspaceID, sourceID: UUID()), location: .freezer, unit: .count,
                        count: .exact(.init(amount: try Rational(8), unit: .count, originalLiteral: "8"))), observationID: UUID()))
                writes += try PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))
            }
            let token = revision == 0 ? try await store.inventorySourceToken() : nil
            _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: operation,
                expectedRevision: revision, request: Data(operation.uuidString.utf8), mode: revision == 0 ? .activate : .mutate,
                sourceToken: token, writes: writes), at: now)
            revision += 1
        }
        let gate = PantryMutationGate(), worker = try PantryArchiveWorker(root: directory.appendingPathComponent("archives"))
        return Fixture(directory: directory, cleanup: cleanup, store: store, ledger: ledger, pending: pending, gate: gate, worker: worker,
            capture: .init(inventory: store, ledger: ledger, pending: pending, gate: gate, authorize: { _, _ in true }))
    }
    private func firstLot(_ store: ComparisonStore) async throws -> InventoryLot {
        let rows = try await store.inventoryRecords(kind: .lot, limit: 1)
        return try PantryPersistenceCodec.lot(XCTUnwrap(rows.first))
    }
    private func append(_ command: InventoryCommand, current: InventoryLot, to store: ComparisonStore) async throws {
        let state = try await store.inventoryState()
        let prepared = try InventoryEngine.prepare(command, current: current, at: command.occurredAt)
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: command.id,
            expectedRevision: state.revision, request: PantryPersistenceCodec.request(command, inventoryRevision: state.revision),
            writes: PantryPersistenceCodec.writes(prepared)), at: command.occurredAt)
    }

    func testPagedCaptureReopensAllFactsWithoutMaterializedSnapshot() async throws {
        let f = try await fixture(count: 205)
        let handle = try await f.capture.captureHandle(worker: f.worker, at: now)
        XCTAssertEqual(handle.lotCount, 205); XCTAssertGreaterThan(handle.fileCount, 3)
        let restarted = try PantryArchiveWorker(root: f.directory.appendingPathComponent("archives"))
        let reopened = try await restarted.open(reference: handle.reference)
        XCTAssertEqual(reopened.reference, handle.reference); XCTAssertEqual(reopened.lotCount, 205)
        var cursor: PantryArchiveWorker.DependencyCursor?, lots: Set<UUID> = []
        repeat {
            let page = try await restarted.dependencies(reopened, after: cursor, limit: 200)
            XCTAssertLessThanOrEqual(page.values.count, 200)
            for dependency in page.values where dependency.kind == .lot { lots.insert(dependency.id) }
            cursor = page.next
        } while cursor != nil
        XCTAssertEqual(lots.count, 205)
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: handle.directory.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        #endif
    }

    func testLegacyPackageAndRestorationChunksMatchExistingPureConversion() async throws {
        let f = try await fixture(count: 90)
        let captured = try await f.capture.capture(at: now)
        let storage = try PantryArchiveStorage(root: f.directory.appendingPathComponent("archives"))
        let bundle = try storage.publish(captured)
        let handle = try await f.worker.open(reference: bundle.reference)
        let target = try ComparisonStore(url: f.directory.appendingPathComponent("restore.sqlite"), inventoryEnabled: true)
        f.cleanup.track(target)
        let context = PantryArchiveWorker.RestorationContext(version: 1, copyID: UUID(), reference: handle.reference,
            workspaceID: target.workspaceID, restorationID: UUID(), preparedAt: now)
        let token = try await target.inventorySourceToken()
        let prepared = try await f.worker.prepareRestoration(source: handle, context: context, sourceToken: token)
        XCTAssertGreaterThan(prepared.plan.expectedChunkCount, 1)
        _ = try await target.beginInventoryMigration(prepared.plan)
        for index in 0..<prepared.plan.expectedChunkCount {
            let chunk = try await f.worker.restorationChunk(prepared, index: index)
            _ = try await target.stageInventoryMigration(id: prepared.plan.migrationID, chunk: chunk)
        }
        _ = try await target.finishInventoryMigration(id: prepared.plan.migrationID, at: now)
        let expected = try PantryArchiveRestore.prepare(captured.snapshot, newOriginID: target.workspaceID,
            restorationID: context.restorationID, at: now)
        let rows = try await target.inventoryRecords(kind: .lot, limit: 200)
        XCTAssertEqual(Set(try rows.map { try PantryPersistenceCodec.lot($0).id }), Set(expected.lots.map(\.id)))
        let actual = try rows.map(PantryPersistenceCodec.lot).sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(actual, expected.lots.sorted { $0.id.uuidString < $1.id.uuidString })
        try await f.worker.discardRestoration(prepared)
        try await f.worker.discardRestoration(prepared)
    }

    func testIndependentEditReexportIsSelfContainedAndOldPendingStaysInert() async throws {
        let f = try await fixture(), originalLot = try await firstLot(f.store)
        let foodJournal = try f.pending.makeFoodPendingStore()
        _ = try foodJournal.save(command: .init(id: UUID(), originID: f.store.workspaceID, lotID: originalLot.id,
            eventID: UUID(), expectedRevision: 1, occurredAt: now, change: .count(.someLeft, observationID: UUID())), reviewedInventoryRevision: 1)
        let source = try await f.capture.captureHandle(worker: f.worker, at: now)
        let gate = PantryMutationGate()
        let coordinator = try PantryRecoveryCoordinator(root: f.directory.appendingPathComponent("copies"), worker: f.worker,
            gate: gate, protectedWorkspaceIDs: { [f.store.workspaceID, f.ledger.workspaceID] }, authorize: { _, _ in true })
        let opened = try await coordinator.create(copyID: UUID(), reference: source.reference, at: now)
        f.cleanup.track(opened.store)
        let baseline = try await firstLot(opened.store), later = now.addingTimeInterval(1)
        try await append(.init(id: UUID(), originID: opened.store.workspaceID, lotID: baseline.id, eventID: UUID(),
            expectedRevision: 1, occurredAt: later, change: .count(.someLeft, observationID: UUID())), current: baseline, to: opened.store)
        let changed = try await firstLot(opened.store)
        let exported = try await PantryArchiveCapture.captureIndependent(worker: f.worker, inventory: opened.store,
            original: source, identity: opened.identity, journalDirectory: f.directory.appendingPathComponent("copy-journal"),
            gate: gate, at: later, authorize: {})
        guard case .independent(let scope) = exported.scope else { return XCTFail("Independent scope required") }
        XCTAssertEqual(scope.originID, opened.store.workspaceID); XCTAssertNil(scope.foodPendingDigest)
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let package = try await f.worker.encryptedExport(exported, key: key)
        XCTAssertEqual(package.url.pathExtension, "ritcpantry")
        let independentWorker = try PantryArchiveWorker(root: f.directory.appendingPathComponent("portable"))
        let prepared = try await independentWorker.prepareImport(url: package.url, key: key)
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("portable-registry.json"))
        let review = try await registry.reviewPantry(prepared.reference)
        _ = try await independentWorker.applyImport(prepared, review: review, registry: registry, now: later)
        try await independentWorker.discardImport(prepared, registry: registry)
        let imported = try await independentWorker.open(reference: exported.reference)
        XCTAssertEqual(imported.reference, exported.reference)
        // The second worker has no original package or original databases.
        let secondCoordinator = try PantryRecoveryCoordinator(root: f.directory.appendingPathComponent("portable-copies"), worker: independentWorker,
            gate: PantryMutationGate(), protectedWorkspaceIDs: { [] }, authorize: { _, _ in true })
        let second = try await secondCoordinator.create(copyID: UUID(), reference: imported.reference, at: later)
        f.cleanup.track(second.store)
        let result = try await firstLot(second.store)
        XCTAssertEqual(result.count, changed.count); XCTAssertEqual(result.revision, 1)
        XCTAssertNotEqual(result.source.originID, opened.store.workspaceID)
        let oldIntents = try await second.store.inventoryRecords(kind: .intent)
        XCTAssertTrue(oldIntents.isEmpty)
        let sourcePending = try foodJournal.read()
        XCTAssertNotNil(sourcePending)
        try await f.worker.discardExport(package)
        try await f.worker.discardExport(package)
    }

    func testUnknownJournalAndRevocationFailWithoutPublishingPackage() async throws {
        let f = try await fixture()
        let directory = f.pending.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unknown = directory.appendingPathComponent("\(f.store.workspaceID.uuidString).\(UUID().uuidString).pack.json")
        try Data("{}".utf8).write(to: unknown)
        do { _ = try await f.capture.captureHandle(worker: f.worker, at: now); XCTFail("Unknown journal omitted") } catch { }
        try FileManager.default.removeItem(at: unknown)
        var accesses = 0
        let revoked = PantryArchiveCapture(inventory: f.store, ledger: f.ledger, pending: f.pending, gate: f.gate,
            authorize: { _, _ in accesses += 1; return accesses < 15 })
        do { _ = try await revoked.captureHandle(worker: f.worker, at: now); XCTFail("Revoked capture returned") }
        catch { XCTAssertEqual(error as? PantryArchiveCapture.Failure, .unauthorized) }
        let files = try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("archives").path)
        XCTAssertTrue(files.isEmpty)
        let lease = try f.gate.beginExclusiveWrite(); f.gate.endExclusiveWrite(lease)
    }

    func testEncryptedImportRejectsWrongKeyMissingPartAndChangedVerifiedBytes() async throws {
        let f = try await fixture(), handle = try await f.capture.captureHandle(worker: f.worker, at: now)
        let key = Data(repeating: 8, count: 32).base64EncodedString()
        let package = try await f.worker.encryptedExport(handle, key: key)
        let readerRoot = f.directory.appendingPathComponent("reader")
        let reader = try PantryArchiveWorker(root: readerRoot)
        do { _ = try await reader.prepareImport(url: package.url, key: Data(repeating: 9, count: 32).base64EncodedString()); XCTFail("Wrong key accepted") } catch { }
        let part = package.url.appendingPathComponent("pantry-0.json")
        let saved = try Data(contentsOf: part)
        try FileManager.default.removeItem(at: part)
        do { _ = try await reader.prepareImport(url: package.url, key: key); XCTFail("Partial package accepted") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: readerRoot.path).isEmpty)
        try saved.write(to: part)
        let prepared = try await reader.prepareImport(url: package.url, key: key)
        let imported = prepared.handle
        let localPart = imported.directory.appendingPathComponent("pantry-0.json")
        var corrupt = try Data(contentsOf: localPart); corrupt[corrupt.count / 2] ^= 1
        try corrupt.write(to: localPart)
        do { _ = try await reader.dependencies(imported); XCTFail("Changed handle bytes trusted") } catch { }
        do { _ = try await reader.encryptedExport(imported, key: key); XCTFail("Changed handle exported") } catch { }
        try await f.worker.discardExport(package)
    }

    func testConcurrentImportReviewsOwnSeparatePlaintextUntilExplicitRegistration() async throws {
        let f = try await fixture(), source = try await f.capture.captureHandle(worker: f.worker, at: now)
        let key = EncryptedArchive.generateKey()
        let package = try await f.worker.encryptedExport(source, key: key)
        let root = f.directory.appendingPathComponent("shared")
        let first = try PantryArchiveWorker(root: root), second = try PantryArchiveWorker(root: root)
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let a = try await first.prepareImport(url: package.url, key: key)
        let b = try await second.prepareImport(url: package.url, key: key)
        let destination = root.appendingPathComponent(source.reference.bundleID.uuidString)
        XCTAssertNotEqual(a.handle.directory, b.handle.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try await second.reconcilePreparedImports(registry: registry)
        do {
            try await second.reconcilePreparedImports(registry: registry, requireIdle: true)
            XCTFail("An active review cannot acknowledge a completed erasure drain")
        } catch { XCTAssertEqual(error as? PantryArchiveWorker.Failure, .conflict) }
        try await first.discardImport(a, registry: registry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.handle.directory.path))
        _ = try await second.revalidateImport(b)
        let reviewed = try await registry.reviewPantry(b.reference)
        let copy = try await second.applyImport(b, review: reviewed, registry: registry, now: now)
        try await second.discardImport(b, registry: registry)
        let reopened = try await first.open(reference: b.handle.reference)
        XCTAssertEqual(reopened.reference.manifestDigest, copy.reference.manifestDigest)
        let duplicate = try await first.prepareImport(url: package.url, key: key)
        try await first.discardImport(duplicate, registry: registry)
        _ = try await second.open(reference: source.reference)
        let registered = try await registry.listPantry()
        XCTAssertEqual(registered, [copy])
        try await second.reconcilePreparedImports(registry: registry, requireIdle: true)
    }

    func testRestartDropsAbandonedReviewsAndOnlyRepairsDurablyRegisteredPromotion() async throws {
        let f = try await fixture(), source = try await f.capture.captureHandle(worker: f.worker, at: now)
        let key = EncryptedArchive.generateKey()
        let package = try await f.worker.encryptedExport(source, key: key)
        let root = f.directory.appendingPathComponent("shared")
        let worker = try PantryArchiveWorker(root: root)
        let registryURL = f.directory.appendingPathComponent("registry.json")
        let registry = try RecoveryRegistry(url: registryURL)
        let destination = root.appendingPathComponent(source.reference.bundleID.uuidString)
        for phase in 0..<4 {
            var pending: PantryPreparedImport? = try await worker.prepareImport(url: package.url, key: key)
            let stage = try XCTUnwrap(pending?.handle.directory.deletingLastPathComponent())
            if phase > 0 {
                let prepared = try XCTUnwrap(pending)
                let review = try await registry.reviewPantry(prepared.reference)
                if phase == 3 {
                    _ = try await worker.applyImport(prepared, review: review, registry: registry, now: now)
                } else {
                    // Interrupt after the confirmation marker is durable, before
                    // the registry write. Phase 2 then persists only the registry
                    // side, as if the process exited before its rename callback.
                    do {
                        _ = try await worker.applyImport(prepared, review: review, registry: registry, now: now,
                            authorize: { false })
                        XCTFail("Revoked import applied")
                    } catch { XCTAssertEqual(error as? ArchiveError, .unavailable) }
                    if phase == 2 { _ = try await registry.applyPantry(review, now: now) }
                }
            }
            pending = nil // Simulates release of the process's directory lock.
            let restarted = try PantryArchiveWorker(root: root)
            let reopened = try RecoveryRegistry(url: registryURL)
            try await restarted.reconcilePreparedImports(registry: reopened, requireIdle: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), phase >= 2)
            if phase >= 2 { _ = try await restarted.open(reference: source.reference) }
        }
    }

    func testIncompleteGraphNeverProducesHandleAndCancelledJobIsRemoved() async throws {
        let f = try await fixture(), captured = try await f.capture.capture(at: now)
        let job = try await f.worker.begin(descriptor: captured.snapshot.descriptor)
        let rows = try await f.store.inventoryRecords(kind: .lot)
        try await f.worker.appendRecords(rows, to: job)
        do { _ = try await f.worker.finish(job, scope: .paired(captured.scope)); XCTFail("Orphan graph accepted") } catch { }
        let cancelled = try await f.worker.begin(descriptor: captured.snapshot.descriptor)
        try await f.worker.cancel(cancelled); try await f.worker.cancel(cancelled)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("archives").path).isEmpty)
    }
    func testHistoryBeyondFormerMaterializationCapIsCompleteOnReopen() async throws {
        let f = try await fixture(), captured = try await f.capture.capture(at: now)
        let job = try await f.worker.begin(descriptor: captured.snapshot.descriptor)
        for kind in [InventoryRecordKind.lot, .observation, .event, .sourceLink] {
            let rows = try await f.store.inventoryRecords(kind: kind)
            try await f.worker.appendRecords(rows, to: job)
        }
        // Legal source bytes retain original whitespace. One bounded source is
        // repeated at distinct historical revisions, exceeding 128 MiB in total.
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.urgent = [.init(id: UUID(), food: "Wraps", meal: "Dinner",
            required: .init(amount: try Rational(2), unit: .count, originalLiteral: "2"),
            available: .init(amount: try Rational(0), unit: .count, originalLiteral: "0"), due: nil, confirmedAt: now)]
        var payload = try ArchiveCodec.canonical(journey)
        payload.append(Data(repeating: 32, count: ComparisonStore.maximumPayloadBytes - payload.count))
        struct Head: Encodable { let id: UUID; let revision: Int64; let payload: Data; let savedAt: Date }
        for revision in 1...100 {
            let head = try JSONDecoder().decode(PantryLegacyMigration.SourceHead.self,
                from: ArchiveCodec.canonical(Head(id: journey.id, revision: Int64(revision), payload: payload, savedAt: now)))
            try await f.worker.append(ArchiveCodec.canonical(PantryArchiveCodec.Item.historical(.sourceHead(originID: f.store.workspaceID, head))), to: job)
        }
        let handle = try await f.worker.finish(job, scope: .paired(captured.scope))
        var size: Int64 = 0
        for file in try FileManager.default.contentsOfDirectory(at: handle.directory, includingPropertiesForKeys: nil) {
            size += (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        XCTAssertGreaterThan(size, 128 * 1_024 * 1_024)
        let reopened = try await f.worker.open(reference: handle.reference)
        XCTAssertEqual(reopened.reference, handle.reference); XCTAssertEqual(reopened.lotCount, 1)
        XCTAssertEqual(reopened.fileCount, handle.fileCount)
    }

    func testRedactionFloorRejectsOldHistoricalClaimButKeepsSanitizedHead() async throws {
        let f = try await fixture(), captured = try await f.capture.capture(at: now)
        let lot = try XCTUnwrap(captured.snapshot.lots.first), claimID = UUID()
        let claim = InventoryReservation(id: claimID, originID: f.store.workspaceID, revision: 2,
            foodID: lot.foodID, lotID: nil, name: "Unresolved", amount: nil, state: .unresolved)
        let marker = InventoryReservationRedaction(workspaceID: f.store.workspaceID, reservationID: claimID,
            throughRevision: 1, operationID: UUID(), previousLotID: lot.id)
        func stage(includeOld: Bool) async throws -> UUID {
            let job = try await f.worker.begin(descriptor: .init(originID: f.store.workspaceID, inventoryRevision: 2, capturedAt: now))
            for kind in [InventoryRecordKind.lot, .observation, .event, .sourceLink] {
                let rows = try await f.store.inventoryRecords(kind: kind)
                try await f.worker.appendRecords(rows, to: job)
            }
            try await f.worker.append(ArchiveCodec.canonical(PantryArchiveCodec.Item.reservation(claim)), to: job)
            try await f.worker.appendEvidence(.current(.reservationRedacted(marker)), to: job)
            if includeOld {
                let old = InventoryReservation(id: claimID, originID: f.store.workspaceID, revision: 1,
                    foodID: lot.foodID, lotID: lot.id, name: "Private former claim", amount: nil, state: .unresolved)
                try await f.worker.append(ArchiveCodec.canonical(PantryArchiveCodec.Item.historical(.originalReservation(old))), to: job)
            }
            return job
        }
        let old = captured.scope
        let scope = PantryArchiveCapture.Scope(version: 1, inventoryOriginID: old.inventoryOriginID, inventoryRevision: 2,
            sourceToken: old.sourceToken, ledgerOriginID: old.ledgerOriginID, ledgerRevision: old.ledgerRevision,
            ledgerOperationID: old.ledgerOperationID, ledgerPayloadDigest: old.ledgerPayloadDigest,
            pendingDigest: nil, foodPendingDigest: nil, packPendingDigest: old.packPendingDigest, capturedAt: now)
        let invalid = try await stage(includeOld: true)
        do { _ = try await f.worker.finish(invalid, scope: .paired(scope)); XCTFail("Redacted historical claim restored") } catch { }
        let valid = try await stage(includeOld: false)
        let handle = try await f.worker.finish(valid, scope: .paired(scope))
        XCTAssertEqual(handle.reservationCount, 1)
        let reopened = try await f.worker.open(reference: handle.reference)
        XCTAssertEqual(reopened.reservationCount, 1)
    }

    func testAuthenticatedContentPagesIncludeRetainedSQLClaimAndLotHistory() async throws {
        let f = try await fixture(), lot = try await firstLot(f.store)
        try await append(.init(id: UUID(), originID: f.store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: 1, occurredAt: now, change: .count(.someLeft, observationID: UUID())), current: lot, to: f.store)
        let claimID = UUID()
        for revision in 1...2 {
            let claim = InventoryReservation(id: claimID, originID: f.store.workspaceID, revision: Int64(revision),
                foodID: lot.foodID, lotID: revision == 1 ? lot.id : nil, name: "Dinner", amount: nil, state: .unresolved)
            let state = try await f.store.inventoryState()
            _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
                expectedRevision: state.revision, request: Data("claim-\(revision)".utf8),
                writes: [.init(record: .init(key: .init(.reservation, claimID), revision: Int64(revision),
                    payload: ArchiveCodec.canonical(claim), lotID: claim.lotID), expectedRevision: Int64(revision - 1))]), at: now)
        }
        let handle = try await f.capture.captureHandle(worker: f.worker, at: now)
        var cursor: PantryArchiveWorker.ContentCursor?, oldLot = false, oldClaim = false, currentClaim = false
        repeat {
            let page = try await f.worker.contentPage(handle, after: cursor, limit: 2)
            XCTAssertLessThanOrEqual(page.values.count, 2)
            var byteCount = 0
            for value in page.values {
                switch value {
                case .item(let bytes):
                    byteCount += bytes.count
                    let item = try JSONDecoder().decode(PantryArchiveCodec.Item.self, from: bytes)
                    if case .historical(.originalLot(let value)) = item, value.id == lot.id, value.revision == 1 { oldLot = true }
                    if case .historical(.originalReservation(let value)) = item, value.id == claimID, value.revision == 1 { oldClaim = true }
                    if case .reservation(let value) = item, value.id == claimID, value.revision == 2 { currentClaim = true }
                case .evidence(let bytes):
                    byteCount += bytes.count
                    _ = try JSONDecoder().decode(PantryArchiveWorker.Evidence.self, from: bytes)
                }
            }
            XCTAssertLessThanOrEqual(byteCount, PantryArchiveCodec.maximumChunkBytes)
            cursor = page.next
        } while cursor != nil
        XCTAssertTrue(oldLot); XCTAssertTrue(oldClaim); XCTAssertTrue(currentClaim)
    }

}

extension PantryArchiveWorkerTests {
    private func eraser(_ f: Fixture, _ registry: RecoveryRegistry, authorize: @escaping () -> Bool = { true },
                        cleanup: @escaping PantryErasureCoordinator.CleanupHandler = { _, _ in }) -> PantryErasureCoordinator {
        let instant = now
        return PantryErasureCoordinator(inventory: f.store, ledger: f.ledger, gate: f.gate,
            pendingDirectory: f.pending.fileURL.deletingLastPathComponent(), registry: registry, worker: f.worker,
            journalDirectory: f.directory.appendingPathComponent("erasure-journal"), cleanup: cleanup,
            authorize: authorize, clock: { instant })
    }

    func testReviewedFoodErasureRecoversCleanupFromReceiptAndKeepsIndependentPin() async throws {
        let f = try await fixture(count: 2)
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let repository = PantryRepository(store: f.store, authorize: { true }); f.cleanup.track(repository)
        let base = try await repository.load(at: now), selected = base.lots[0], kept = base.lots[1]
        let lost = InventoryReservation(id: UUID(), originID: f.store.workspaceID, revision: 1, foodID: selected.foodID,
            lotID: selected.id, name: "First meal", amount: selected.count.quantity)
        let pin = InventoryReservation(id: UUID(), originID: f.store.workspaceID, revision: 1, foodID: kept.foodID,
            lotID: kept.id, name: "Other meal", amount: kept.count.quantity)
        let writes = try [lost, pin].map { claim in
            InventoryWrite(record: .init(key: .init(.reservation, claim.id), revision: 1,
                payload: try ArchiveCodec.canonical(claim), lotID: claim.lotID), expectedRevision: 0)
        }
        _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
            expectedRevision: base.state.revision, request: Data("save two pins".utf8), writes: writes), at: now)
        let captured = try await f.capture.captureHandle(worker: f.worker, at: now)
        let reference = PantryRecoveryReference(bundleID: captured.reference.bundleID, manifestDigest: captured.reference.manifestDigest,
            originID: captured.descriptor.originID, inventoryRevision: captured.descriptor.inventoryRevision)
        let copy = try await registry.applyPantry(registry.reviewPantry(reference), now: now)
        let foodPending = try f.pending.makeFoodPendingStore()
        _ = try foodPending.save(command: .init(id: UUID(), originID: f.store.workspaceID, lotID: selected.id,
            eventID: UUID(), expectedRevision: selected.revision, occurredAt: now, change: .usedUp(observationID: UUID())),
            reviewedInventoryRevision: captured.descriptor.inventoryRevision)
        let coordinator = eraser(f, registry, cleanup: { cleanup, receipt in
            XCTAssertEqual(cleanup.copyIDs, [copy.id]); XCTAssertEqual(receipt.scope, .sourceGraph)
            throw ArchiveError.unavailable
        })
        let review = try await coordinator.prepare(.lot(selected.id, revision: selected.revision))
        XCTAssertTrue(review.canCommit); XCTAssertEqual(review.copyIDs, [copy.id])
        XCTAssertEqual(review.pendingFileCount, 1); XCTAssertEqual(review.affectedReservationNames, [lost.name])
        let result = try await coordinator.commit(review); XCTAssertEqual(result, .cleanupPending)
        let current = try await repository.load(at: now)
        XCTAssertEqual(current.lots, [kept])
        XCTAssertEqual(current.reservations.first { $0.id == pin.id }, pin)
        let uncertain = try XCTUnwrap(current.reservations.first { $0.id == lost.id })
        XCTAssertEqual(uncertain.state, .unresolved); XCTAssertNil(uncertain.amount); XCTAssertNil(uncertain.lotID)
        let copies = try await registry.listPantry(), retired = try await registry.permanentlyRetiredPantryBundleIDs()
        XCTAssertTrue(copies.isEmpty); XCTAssertEqual(retired, [reference.bundleID])
        XCTAssertNotNil(try foodPending.read())
        let restarted = eraser(f, registry, authorize: { false }, cleanup: { _, _ in
            try await f.worker.removePermanentlyRetiredBundles(retired)
        })
        let recovered = try await restarted.recoverCleanup(); XCTAssertEqual(recovered, .deleted)
        XCTAssertNil(try foodPending.read())
        let again = try await restarted.recoverCleanup(); XCTAssertNil(again)
        let after = try await repository.load(at: now); XCTAssertEqual(after.state, current.state)
    }

    func testHistoricalPinsRedactOldBodiesAndKeepPersonalDetailsAndIndependentReleasedHistory() async throws {
        let f = try await fixture(), registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let repository = PantryRepository(store: f.store, authorize: { true }); f.cleanup.track(repository)
        let snapshot = try await repository.load(at: now), first = try XCTUnwrap(snapshot.lots.first)
        let second = try InventoryEngine.prepare(.init(id: UUID(), originID: f.store.workspaceID, lotID: UUID(), eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: first.foodID, name: "Independent batch",
                source: .manual(originID: f.store.workspaceID, sourceID: UUID()), location: .freezer, unit: first.unit, count: first.count),
                observationID: UUID())), current: nil, at: now)
        let amount = Quantity(amount: .one, unit: first.unit, originalLiteral: "1"), day = try MealDay(date: now, timeZoneIdentifier: "America/New_York")
        let personal = InventoryPersonalReservation(day: day)
        func claim(_ id: UUID, revision: Int64, lot: UUID?, name: String, state: InventoryReservationState,
                   personal: InventoryPersonalReservation? = nil) -> InventoryReservation {
            .init(id: id, originID: f.store.workspaceID, revision: revision, foodID: first.foodID, lotID: lot,
                name: name, amount: amount, priority: .protected, state: state, personal: personal)
        }
        let initial = claim(UUID(), revision: 1, lot: first.id, name: "School lunch", state: .active, personal: personal)
        let releasedWithHistory = claim(UUID(), revision: 1, lot: first.id, name: "Earlier held meal", state: .active)
        let independent = claim(UUID(), revision: 1, lot: nil, name: "Independent release", state: .released)
        var writes = try PantryPersistenceCodec.writes(second)
        func write(_ claim: InventoryReservation) throws -> InventoryWrite {
            .init(record: .init(key: .init(.reservation, claim.id), revision: claim.revision,
                payload: try ArchiveCodec.canonical(claim), lotID: claim.lotID), expectedRevision: claim.revision - 1)
        }
        writes += try [initial, releasedWithHistory, independent].map(write)
        let one = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
            expectedRevision: snapshot.state.revision, request: Data("set historical pins".utf8), writes: writes), at: now)
        let repinned = claim(initial.id, revision: 2, lot: second.lot.id, name: initial.name, state: .active, personal: personal)
        let released = claim(releasedWithHistory.id, revision: 2, lot: nil, name: releasedWithHistory.name, state: .released)
        _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
            expectedRevision: one.revision, request: Data("save independent pins".utf8), writes: [write(repinned), write(released)]), at: now)

        let coordinator = eraser(f, registry)
        let review = try await coordinator.prepare(.lot(first.id, revision: first.revision))
        XCTAssertEqual(Set(review.affectedReservationNames), [repinned.name, released.name])
        let result = try await coordinator.commit(review); XCTAssertEqual(result, .deleted)
        let after = try await repository.load(at: now)
        XCTAssertEqual(after.lots, [second.lot])
        XCTAssertEqual(after.reservations.first { $0.id == initial.id },
            claim(initial.id, revision: 3, lot: second.lot.id, name: initial.name, state: .active, personal: personal))
        XCTAssertEqual(after.reservations.first { $0.id == released.id },
            claim(released.id, revision: 3, lot: nil, name: released.name, state: .released))
        XCTAssertEqual(after.reservations.first { $0.id == independent.id }, independent)
        let floors = try await f.store.inventoryReservationRedactions(expectedInventoryRevision: after.state.revision)
        XCTAssertEqual(Set(floors.map(\.reservationID)), [initial.id, released.id])
        XCTAssertTrue(floors.allSatisfy { $0.throughRevision == 2 })
        let history = try await f.store.inventoryRevisionPage(expectedRevision: after.state.revision, sourceToken: f.store.inventorySourceToken())
        XCTAssertEqual(history.filter { $0.key.kind == .reservation && $0.key.id == initial.id }.map(\.revision), [3])
        XCTAssertEqual(history.filter { $0.key.kind == .reservation && $0.key.id == released.id }.map(\.revision), [3])
        XCTAssertEqual(history.filter { $0.key.kind == .reservation && $0.key.id == independent.id }.map(\.revision), [1])
    }

    func testReviewedOriginRetirementRequiresCurrentLedgerBasisAndFencesUnseenPackages() async throws {
        let f = try await fixture(), registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let coordinator = eraser(f, registry)
        let futurePickup = UUID(), before = try await f.store.inventoryState()
        _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(), expectedRevision: before.revision,
            request: Data("retain newer-format pickup".utf8), comparisons: [.init(action: .save, id: futurePickup, expectedRevision: 0,
                title: "Future-format pickup", payload: Data(#"{"version":12,"future":true}"#.utf8))]), at: now)
        let review = try await coordinator.prepare(.wholeOrigin)
        XCTAssertEqual(review.pickupIDs, [futurePickup]); XCTAssertEqual(review.pickupTitles, ["Future-format pickup"])
        let original = try await f.store.inventoryState()
        struct Document: Encodable { let formatVersion = 1; let workspace: LedgerWorkspace }
        _ = try await f.ledger.save(payload: ArchiveCodec.canonical(Document(workspace: .init())), expectedRevision: 0,
            operationID: UUID(), savedAt: now)
        do { _ = try await coordinator.commit(review); XCTFail("Changed ledger requires a new review") }
        catch PantryErasureCoordinator.Failure.stale { }
        let retained = try await f.store.inventoryState(); XCTAssertEqual(retained, original)
        let revised = try await coordinator.prepare(.wholeOrigin)
        XCTAssertTrue(revised.canCommit)
        let result = try await coordinator.commit(revised); XCTAssertEqual(result, .deleted)
        let retirement = try await f.store.inventoryOriginRetirement(); XCTAssertEqual(retirement?.scope, .origin)
        let future = PantryRecoveryReference(bundleID: UUID(), manifestDigest: Data(repeating: 7, count: 32),
            originID: f.store.workspaceID, inventoryRevision: 123)
        let old = try await registry.reviewPantry(future); XCTAssertFalse(old.canApply)
        let ledger = try await f.ledger.load(); XCTAssertEqual(ledger?.revision, 1)
    }
}
