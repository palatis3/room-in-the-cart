import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

@MainActor final class PantryArchiveCaptureStorageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let inventory: ComparisonStore
        let ledger: LedgerStore
        let pending: PantryPickupPendingStore
        let gate: PantryMutationGate
        let capture: PantryArchiveCapture
    }
    private func fixture(lots count: Int = 1) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(inventory, ledger)
        let gate = PantryMutationGate()
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: ledger.workspaceID)
        var revision: Int64 = 0
        for start in stride(from: 0, to: count, by: 60) {
            let operation = UUID()
            var writes: [InventoryWrite] = []
            for index in start..<min(start + 60, count) {
                let command = InventoryCommand(id: operation, originID: inventory.workspaceID, lotID: UUID(), eventID: UUID(),
                    expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: UUID(), name: "Food \(index)",
                        source: .manual(originID: inventory.workspaceID, sourceID: UUID()), location: .freezer, unit: .count,
                        count: .exact(.init(amount: try Rational(8), unit: .count, originalLiteral: "8"))), observationID: UUID()))
                writes += try PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))
            }
            let token = revision == 0 ? try await inventory.inventorySourceToken() : nil
            _ = try await inventory.commitInventory(.init(workspaceID: inventory.workspaceID, operationID: operation,
                expectedRevision: revision, request: Data(operation.uuidString.utf8), mode: revision == 0 ? .activate : .mutate,
                sourceToken: token, writes: writes), at: now)
            revision += 1
        }
        return Fixture(directory: directory, cleanup: cleanup, inventory: inventory, ledger: ledger, pending: pending, gate: gate,
            capture: PantryArchiveCapture(inventory: inventory, ledger: ledger, pending: pending, gate: gate, authorize: { _, _ in true }))
    }
    private func append(_ row: InventoryRecord, to fixture: Fixture) async throws {
        let state = try await fixture.inventory.inventoryState(), operation = UUID()
        _ = try await fixture.inventory.commitInventory(.init(workspaceID: state.workspaceID, operationID: operation,
            expectedRevision: state.revision, request: Data(operation.uuidString.utf8),
            writes: [.init(record: row, expectedRevision: 0)]), at: now)
    }

    func testAllSQLitePagesPublishProtectedFilesAndReopenCompleteGraph() async throws {
        let f = try await fixture(lots: 205)
        let captured = try await f.capture.capture(at: now)
        XCTAssertEqual(captured.snapshot.lots.count, 205); XCTAssertEqual(captured.snapshot.observations.count, 205)
        XCTAssertEqual(captured.snapshot.events.count, 205); XCTAssertEqual(captured.snapshot.sourceLinks.count, 205)
        let root = f.directory.appendingPathComponent("archives")
        let storage = try PantryArchiveStorage(root: root)
        let bundle = try await f.capture.publish(captured, to: storage)
        XCTAssertGreaterThan(bundle.files.count, 2)
        XCTAssertLessThan(try ArchiveCodec.canonical(bundle.reference).count, 256)
        let reopened = try PantryArchiveStorage(root: root).open(bundle.reference)
        XCTAssertEqual(reopened.captured.scope, captured.scope)
        XCTAssertEqual(Set(reopened.captured.snapshot.lots.map(\.id)), Set(captured.snapshot.lots.map(\.id)))
        for file in reopened.files {
            XCTAssertLessThanOrEqual(file.byteCount, PantryArchiveCodec.maximumChunkBytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            // This simulator returns no protection attribute. Keep the real
            // device assertion; locked-phone protection remains a device gate.
            #if os(iOS) && !targetEnvironment(simulator)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
            #endif
            XCTAssertEqual(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            XCTAssertEqual(try storage.read(file, from: reopened).count, file.byteCount)
        }
    }

    func testUnknownIntentAndCorruptPendingPreventCompleteCapture() async throws {
        let f = try await fixture()
        let captured = try await f.capture.capture(at: now)
        XCTAssertEqual(captured.snapshot.lots.count, 1)
        let row = InventoryRecord(key: .init(.intent, UUID()), revision: 1,
            payload: Data("{\"namespace\":\"future-private-history/v2\",\"value\":1}".utf8))
        try await append(row, to: f)
        do { _ = try await f.capture.capture(at: now); XCTFail("Unknown durable history must not be omitted") }
        catch { XCTAssertEqual(error as? PantryArchiveCapture.Failure, .unknownHistory) }
        let clean = try await fixture()
        _ = try clean.pending.read() // Creates only the protected journal directory/lock.
        try Data("corrupt".utf8).write(to: clean.pending.fileURL)
        do { _ = try await clean.capture.capture(at: now); XCTFail("Corrupt pending evidence must stop export") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .corrupt) }
    }

    func testRevocationMemoryBudgetAndExclusiveGateFailClosed() async throws {
        let f = try await fixture()
        var checks = 0
        let revoked = PantryArchiveCapture(inventory: f.inventory, ledger: f.ledger, pending: f.pending, gate: f.gate) { _, _ in
            checks += 1; return checks < 4
        }
        do { _ = try await revoked.capture(at: now); XCTFail("Revocation after await must stop capture") }
        catch { XCTAssertEqual(error as? PantryArchiveCapture.Failure, .unauthorized) }
        let limited = PantryArchiveCapture(inventory: f.inventory, ledger: f.ledger, pending: f.pending, gate: f.gate,
            limits: .init(materializedBytes: 1), authorize: { _, _ in true })
        do { _ = try await limited.capture(at: now); XCTFail("No truncation on budget exhaustion") }
        catch { XCTAssertEqual(error as? PantryArchiveCapture.Failure, .tooLarge) }
        let lease = try f.gate.beginWrite()
        do { _ = try await f.capture.capture(at: now); XCTFail("Capture must exclude writers") }
        catch { XCTAssertEqual(error as? PantryMutationGate.Failure, .busy) }
        f.gate.endWrite(lease)
        _ = try await f.capture.capture(at: now)
    }

    func testPublicationRejectsChangedInventoryAndChangedPending() async throws {
        let f = try await fixture(), storage = try PantryArchiveStorage(root: f.directory.appendingPathComponent("archives"))
        let captured = try await f.capture.capture(at: now), lot = try XCTUnwrap(captured.snapshot.lots.first)
        let command = InventoryCommand(id: UUID(), originID: f.inventory.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(.someLeft, observationID: UUID()))
        _ = try await PantryRepository(store: f.inventory, authorize: { true }).apply(command,
            reviewedInventoryRevision: captured.scope.inventoryRevision, at: now)
        do { _ = try await f.capture.publish(captured, to: storage); XCTFail("A reviewed capture must not be published as current after mutation") }
        catch { XCTAssertEqual(error as? PantryArchiveCapture.Failure, .stale) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("archives").path), [])
        let current = try await f.capture.capture(at: now)
        try Data("corrupt".utf8).write(to: f.pending.fileURL)
        do { _ = try await f.capture.publish(current, to: storage); XCTFail("Changed pending state must be revalidated") }
        catch { XCTAssertEqual(error as? PantryPickupPendingStore.Failure, .corrupt) }
    }

    func testExactLedgerReceiptAndRetiredOriginRemainDistinctHistoricalEvidence() async throws {
        let f = try await fixture()
        struct Document: Codable { let formatVersion: Int; let workspace: LedgerWorkspace }
        let payload = try ArchiveCodec.canonical(Document(formatVersion: 1, workspace: LedgerWorkspace()))
        let binding = LedgerInventoryProjectionBinding(ledgerWorkspaceID: f.ledger.workspaceID, projectionID: UUID(),
            inventoryWorkspaceID: f.inventory.workspaceID, inventoryOperationID: UUID(), kind: "test.archive", targetID: UUID())
        let row = try PantryLedgerProjectionPort.intentRecord(id: UUID(), binding: binding, canonicalRequest: Data("review".utf8),
            payload: payload, expectedRevision: 0, savedAt: now)
        try await append(row, to: f)
        let before = try await f.capture.capture(at: now)
        XCTAssertTrue(before.evidence.contains(.projection(sourceIntentID: row.key.id, status: .unappliedAtCapture)))
        _ = try await f.ledger.applyInventoryProjection(binding: binding, request: Data("review".utf8), payload: payload,
            expectedRevision: 0, savedAt: now)
        let applied = try await f.capture.capture(at: now)
        XCTAssertTrue(applied.evidence.contains(.projection(sourceIntentID: row.key.id, status: .applied)))
        XCTAssertTrue(applied.snapshot.history.contains { if case .projection(let evidence) = $0 { return evidence.application != nil }; return false })
        _ = try await f.ledger.eraseWorkspace(workspaceID: f.ledger.workspaceID, expectedRevision: 1, operationID: UUID(), at: now)
        let reopened = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(reopened)
        let capture = PantryArchiveCapture(inventory: f.inventory, ledger: reopened, pending: f.pending, gate: f.gate, authorize: { _, _ in true })
        let retired = try await capture.capture(at: now)
        XCTAssertTrue(retired.evidence.contains(.projection(sourceIntentID: row.key.id, status: .retiredLedgerOrigin)))
        XCTAssertTrue(retired.evidence.contains { if case .ledgerRetired(let origin, _, _, _, _) = $0 { return origin == f.ledger.workspaceID }; return false })
        let storage = try PantryArchiveStorage(root: f.directory.appendingPathComponent("archives"))
        let bundle = try await capture.publish(retired, to: storage)
        XCTAssertEqual(try storage.open(bundle.reference).captured.evidence, retired.evidence)
    }

    func testMultipartImportRequiresEveryExactFileAndRechecksTampering() async throws {
        let f = try await fixture(lots: 70), source = try PantryArchiveStorage(root: f.directory.appendingPathComponent("source"))
        let captured = try await f.capture.capture(at: now)
        let bundle = try await f.capture.publish(captured, to: source)
        var files: [String: Data] = [:]
        for part in bundle.files { files[part.name] = try source.read(part, from: bundle) }
        let manifest = try XCTUnwrap(files["manifest.json"]), names = Set(files.keys)
        let destination = try PantryArchiveStorage(root: f.directory.appendingPathComponent("destination"))
        XCTAssertThrowsError(try destination.importFiles(manifest: manifest, names: names.subtracting(["pantry-0.json"])) { name, _ in try XCTUnwrap(files[name]) })
        let imported = try destination.importFiles(manifest: manifest, names: names) { name, maximum in
            let data = try XCTUnwrap(files[name]); XCTAssertLessThanOrEqual(data.count, maximum); return data
        }
        XCTAssertEqual(imported.reference, bundle.reference)
        XCTAssertEqual(imported.captured.scope, bundle.captured.scope)
        let part = try XCTUnwrap(imported.files.first { $0.name == "pantry-0.json" })
        try Data("{}".utf8).write(to: part.url)
        XCTAssertThrowsError(try destination.open(imported.reference))
        XCTAssertThrowsError(try destination.read(part, from: imported))
        XCTAssertThrowsError(try destination.open(.init(bundleID: bundle.reference.bundleID, manifestDigest: Data(repeating: 0, count: 32))))
    }

    func testPendingSubmissionAndAllRetirementPagesRemainExternalEvidence() async throws {
        let f = try await fixture(), instant = now
        let producer = PickupModel(databaseURL: f.directory.appendingPathComponent("producer.sqlite"), clock: { instant })
        f.cleanup.track(producer)
        let amount = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2")
        let added = await producer.addUrgent(.init(id: UUID(), food: "Wraps", meal: "Dinner", required: amount,
            available: .init(amount: .zero, unit: .count, originalLiteral: "0"), due: nil, confirmedAt: now))
        XCTAssertTrue(added)
        let saved = try await producer.archiveSnapshot(), head = try XCTUnwrap(saved.records.first)
        let state = try await f.inventory.inventoryState()
        let request = PantryPickupDelta.Request(version: 1, operationID: UUID(), originID: f.inventory.workspaceID,
            inventoryRevision: state.revision, priorDigest: Data(repeating: 1, count: 32), proposedDigest: Data(repeating: 2, count: 32),
            ledgerOriginID: f.ledger.workspaceID, ledgerRevision: 0, ledgerDigest: Data(repeating: 3, count: 32))
        let entry = try f.pending.save(submission: .init(version: 1, request: request,
            changedHeads: [.init(id: head.id, revision: 1, payload: head.payload, savedAt: now)], preparedAt: now),
            selection: .select(head.id), recoveryOperationID: UUID(), requiresActionAuthorization: true)
        let captured = try await f.capture.capture(at: now)
        XCTAssertTrue(captured.snapshot.history.contains(.pickupPending(entry)))
        XCTAssertEqual(captured.scope.pendingDigest, PantryArchiveCapture.digest(try ArchiveCodec.canonical(entry)))
        let records = (0..<205).map { _ in InventoryRecord(key: .init(.intent, UUID()), revision: 1, payload: Data("{}".utf8)) }
        _ = try await f.inventory.commitInventory(.init(workspaceID: f.inventory.workspaceID, operationID: UUID(),
            expectedRevision: state.revision, request: Data("insert retired fixtures".utf8),
            writes: records.map { .init(record: $0, expectedRevision: 0) }), at: now)
        _ = try await f.inventory.commitInventory(.init(workspaceID: f.inventory.workspaceID, operationID: UUID(),
            expectedRevision: state.revision + 1, request: Data("erase retired fixtures".utf8),
            erasures: records.map { .init(key: $0.key, expectedRevision: 1) }), at: now)
        let retired = try await f.capture.capture(at: now)
        let keys = retired.evidence.compactMap { item -> InventoryRecordKey? in
            if case .inventoryRetired(let key, _, _, _) = item { return key }; return nil
        }
        XCTAssertEqual(Set(keys), Set(records.map(\.key)))
        let storage = try PantryArchiveStorage(root: f.directory.appendingPathComponent("archives"))
        let bundle = try await f.capture.publish(retired, to: storage)
        XCTAssertTrue(bundle.files.contains { $0.name == "scope-0.json" })
        XCTAssertEqual(try storage.open(bundle.reference).captured.evidence, retired.evidence)
        XCTAssertEqual(try f.pending.read(), entry, "Export cannot execute or discard durable pending work.")
    }

    func testMissingOrSymbolicChunkAndFailedImportNeverPublishReadyBundle() async throws {
        let f = try await fixture(), source = try PantryArchiveStorage(root: f.directory.appendingPathComponent("source"))
        let captured = try await f.capture.capture(at: now), bundle = try source.publish(captured)
        let chunk = try XCTUnwrap(bundle.files.first { $0.name == "pantry-0.json" })
        let manifestPart = try XCTUnwrap(bundle.files.first { $0.name == "manifest.json" })
        let manifest = try source.read(manifestPart, from: bundle), bytes = try source.read(chunk, from: bundle)
        let external = f.directory.appendingPathComponent("external.json"); try bytes.write(to: external)
        try FileManager.default.removeItem(at: chunk.url)
        XCTAssertThrowsError(try source.open(bundle.reference))
        try FileManager.default.createSymbolicLink(at: chunk.url, withDestinationURL: external)
        XCTAssertThrowsError(try source.open(bundle.reference))
        let root = f.directory.appendingPathComponent("failed"), destination = try PantryArchiveStorage(root: root)
        XCTAssertThrowsError(try destination.importFiles(manifest: manifest, names: Set(bundle.files.map(\.name))) { _, _ in throw PantryArchiveStorage.Failure.io })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
