import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

@MainActor final class PantryRecoveryCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let archives: PantryArchiveStorage
        let bundle: PantryArchiveStorage.VerifiedBundle
        let root: URL
        let gate: PantryMutationGate
        let originalStore: ComparisonStore
    }
    private func fixture(count: Int = 1, pendingAndClaim: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let inventory = try ComparisonStore(url: directory.appendingPathComponent("source.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(inventory, ledger)
        let gate = PantryMutationGate(), origin = inventory.workspaceID
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"), inventoryWorkspaceID: origin,
            ledgerWorkspaceID: ledger.workspaceID)
        var revision: Int64 = 0, first: InventoryLot?
        for start in stride(from: 0, to: count, by: 60) {
            let id = UUID()
            var writes: [InventoryWrite] = []
            for index in start..<min(count, start + 60) {
                let command = InventoryCommand(id: id, originID: origin, lotID: UUID(), eventID: UUID(), expectedRevision: nil,
                    occurredAt: now, change: .create(.init(foodID: UUID(), name: "Food \(index)",
                        source: .manual(originID: origin, sourceID: UUID()), location: .freezer, unit: .count,
                        count: .exact(.init(amount: try Rational(8), unit: .count, originalLiteral: "8"))), observationID: UUID()))
                let prepared = try InventoryEngine.prepare(command, current: nil, at: now)
                if first == nil { first = prepared.lot }
                writes += try PantryPersistenceCodec.writes(prepared)
            }
            let token = revision == 0 ? try await inventory.inventorySourceToken() : nil
            _ = try await inventory.commitInventory(.init(workspaceID: origin, operationID: id, expectedRevision: revision,
                request: Data(id.uuidString.utf8), mode: revision == 0 ? .activate : .mutate, sourceToken: token, writes: writes), at: now)
            revision += 1
        }
        if pendingAndClaim {
            let lot = try XCTUnwrap(first)
            let claim = InventoryReservation(id: UUID(), originID: origin, revision: 1, foodID: lot.foodID, lotID: lot.id,
                name: "Dinner", amount: .init(amount: try Rational(2), unit: .count, originalLiteral: "2"))
            _ = try await inventory.commitInventory(.init(workspaceID: origin, operationID: UUID(), expectedRevision: revision,
                request: Data("reviewed claim".utf8), writes: [.init(record: .init(key: .init(.reservation, claim.id), revision: 1,
                    payload: try ArchiveCodec.canonical(claim), lotID: lot.id), expectedRevision: 0)]), at: now)
            revision += 1
            let foodJournal = try pending.makeFoodPendingStore()
            _ = try foodJournal.save(command: .init(id: UUID(), originID: origin, lotID: lot.id, eventID: UUID(), expectedRevision: 1,
                occurredAt: now, change: .count(.someLeft, observationID: UUID())), reviewedInventoryRevision: revision)
        }
        let archives = try PantryArchiveStorage(root: directory.appendingPathComponent("archives"))
        let capture = PantryArchiveCapture(inventory: inventory, ledger: ledger, pending: pending, gate: gate, authorize: { _, _ in true })
        let captured = try await capture.capture(at: now), bundle = try await capture.publish(captured, to: archives)
        return Fixture(directory: directory, cleanup: cleanup, archives: archives, bundle: bundle,
            root: directory.appendingPathComponent("Recoveries"), gate: gate, originalStore: inventory)
    }
    private func coordinator(_ f: Fixture, authorize: @escaping PantryRecoveryCoordinator.Authorization = { _, _ in true }) throws -> PantryRecoveryCoordinator {
        try .init(root: f.root, archives: f.archives, gate: f.gate,
            protectedWorkspaceIDs: { [f.originalStore.workspaceID] }, authorize: authorize)
    }

    func testIndependentRestorePreservesEvidenceButNeverCreatesExecutablePendingOrLedger() async throws {
        let f = try await fixture(pendingAndClaim: true), copyID = UUID(), coordinator = try coordinator(f)
        let opened = try await coordinator.create(copyID: copyID, reference: f.bundle.reference, at: now)
        f.cleanup.track(opened.store)
        XCTAssertNotEqual(opened.identity.workspaceID, f.originalStore.workspaceID)
        XCTAssertEqual(opened.current.lots.first?.count, f.bundle.captured.snapshot.lots.first?.count)
        XCTAssertEqual(opened.current.lots.first?.confirmedAt, now)
        XCTAssertEqual(opened.current.reservations.first?.state, .unresolved)
        XCTAssertNil(opened.current.availability.lots.first?.free)
        XCTAssertTrue(opened.baseline.history.contains { if case .foodPending = $0 { return true }; return false })
        let intents = try await opened.store.inventoryRecords(kind: .intent)
        let events = try await opened.store.inventoryRecords(kind: .event)
        XCTAssertTrue(intents.isEmpty); XCTAssertTrue(events.isEmpty)
        let folder = f.root.appendingPathComponent(copyID.uuidString)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains("ledger.sqlite")); XCTAssertFalse(files.contains("pending"))
        for name in [PantryRecoveryCoordinator.manifestFilename, PantryRecoveryCoordinator.activationFilename, PantryRecoveryCoordinator.databaseFilename] {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            // The simulator omits this attribute; locked-device protection is
            // verified on a physical iPhone. POSIX permissions still apply here.
            #if os(iOS) && !targetEnvironment(simulator)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
            #endif
        }
        try await opened.store.close()
    }

    func testLargeStagingInterruptionResumesSameOriginIdentityAndTime() async throws {
        let f = try await fixture(count: 100), copyID = UUID()
        var didInterrupt = false
        let interrupting = try coordinator(f) { _, _ in
            let url = f.root.appendingPathComponent(copyID.uuidString).appendingPathComponent(PantryRecoveryCoordinator.databaseFilename)
            guard FileManager.default.fileExists(atPath: url.path), !didInterrupt else { return !didInterrupt }
            let probe = try ComparisonStore(url: url, inventoryEnabled: true)
            let progress = try await probe.inventoryPendingMigration()
            try await probe.close()
            if (progress?.nextChunk ?? 0) > 0 { didInterrupt = true; return false }
            return true
        }
        do { _ = try await interrupting.create(copyID: copyID, reference: f.bundle.reference, at: now); XCTFail("Expected staged interruption") }
        catch { XCTAssertEqual(error as? PantryRecoveryCoordinator.Failure, .unauthorized) }
        XCTAssertTrue(didInterrupt)
        let folder = f.root.appendingPathComponent(copyID.uuidString)
        let identityBytes = try Data(contentsOf: folder.appendingPathComponent(PantryRecoveryCoordinator.manifestFilename))
        let probe = try ComparisonStore(url: folder.appendingPathComponent(PantryRecoveryCoordinator.databaseFilename), inventoryEnabled: true)
        let priorOrigin = probe.workspaceID, progress = try await probe.inventoryPendingMigration()
        XCTAssertEqual(progress?.nextChunk, 1)
        let inactive = try await probe.inventoryState(); XCTAssertFalse(inactive.active)
        try await probe.close()
        let resumed = try await coordinator(f).open(copyID: copyID, reference: f.bundle.reference, at: now.addingTimeInterval(600))
        f.cleanup.track(resumed.store)
        XCTAssertEqual(resumed.identity.workspaceID, priorOrigin); XCTAssertEqual(resumed.identity.preparedAt, now)
        XCTAssertEqual(resumed.current.lots.count, 100)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(PantryRecoveryCoordinator.manifestFilename)), identityBytes)
        try await resumed.store.close()
    }

    func testLostActivationAcknowledgmentRecoversExactReceiptThenReopenKeepsEdits() async throws {
        let f = try await fixture(), copyID = UUID()
        var interrupted = false
        let interrupting = try coordinator(f) { _, _ in
            let url = f.root.appendingPathComponent(copyID.uuidString).appendingPathComponent(PantryRecoveryCoordinator.databaseFilename)
            guard FileManager.default.fileExists(atPath: url.path), !interrupted else { return !interrupted }
            let probe = try ComparisonStore(url: url, inventoryEnabled: true)
            let state = try await probe.inventoryState(); try await probe.close()
            if state.active { interrupted = true; return false }
            return true
        }
        do { _ = try await interrupting.create(copyID: copyID, reference: f.bundle.reference, at: now); XCTFail("Expected lost activation acknowledgment") }
        catch { XCTAssertEqual(error as? PantryRecoveryCoordinator.Failure, .unauthorized) }
        let folder = f.root.appendingPathComponent(copyID.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PantryRecoveryCoordinator.activationFilename).path))
        let recovered = try await coordinator(f).open(copyID: copyID, reference: f.bundle.reference, at: now.addingTimeInterval(10))
        f.cleanup.track(recovered.store)
        let lot = try XCTUnwrap(recovered.current.lots.first)
        let repository = PantryRepository(store: recovered.store, mutationGate: f.gate, authorize: { true })
        _ = try await repository.apply(.init(id: UUID(), originID: recovered.identity.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now.addingTimeInterval(20), change: .move(.fridge)),
            reviewedInventoryRevision: recovered.current.state.revision, at: now.addingTimeInterval(20))
        try await recovered.store.close()
        let reopened = try await coordinator(f).open(copyID: copyID, reference: f.bundle.reference, at: now.addingTimeInterval(30))
        f.cleanup.track(reopened.store)
        XCTAssertEqual(reopened.identity, recovered.identity)
        XCTAssertEqual(reopened.current.lots.first?.location, .fridge)
        XCTAssertEqual(reopened.current.lots.first?.revision, 2)
        XCTAssertEqual(reopened.baseline.lots.first?.location, .freezer)
        try await reopened.store.close()
    }

    func testAcknowledgedCopyReopensCurrentEmptyStateAfterImportedGraphErasure() async throws {
        let f = try await fixture(), copyID = UUID()
        let opened = try await coordinator(f).create(copyID: copyID, reference: f.bundle.reference, at: now)
        var rows: [InventoryRecord] = []
        for kind in [InventoryRecordKind.lot, .observation, .sourceLink] {
            rows += try await opened.store.inventoryRecords(kind: kind)
        }
        _ = try await opened.store.commitInventory(.init(workspaceID: opened.identity.workspaceID, operationID: UUID(),
            expectedRevision: opened.current.state.revision, request: Data("reviewed physical graph erasure".utf8),
            erasures: rows.map { .init(key: $0.key, expectedRevision: $0.revision) }), at: now)
        try await opened.store.close()
        let current = try await coordinator(f).open(copyID: copyID, reference: f.bundle.reference, at: now)
        f.cleanup.track(current.store)
        XCTAssertTrue(current.current.lots.isEmpty)
        XCTAssertEqual(current.current.state.revision, 2)
        try await current.store.close()
    }

    func testMissingManifestOrSQLiteAndForeignBundleCannotRecreateCopy() async throws {
        let f = try await fixture(), copyID = UUID()
        let opened = try await coordinator(f).create(copyID: copyID, reference: f.bundle.reference, at: now)
        try await opened.store.close()
        let other = try f.archives.publish(f.bundle.captured)
        do { _ = try await coordinator(f).open(copyID: copyID, reference: other.reference, at: now); XCTFail("A copy cannot adopt a different bundle") }
        catch { XCTAssertEqual(error as? PantryRecoveryCoordinator.Failure, .invalidIdentity) }
        let folder = f.root.appendingPathComponent(copyID.uuidString), manifest = folder.appendingPathComponent(PantryRecoveryCoordinator.manifestFilename)
        let bytes = try Data(contentsOf: manifest)
        try Data("{}".utf8).write(to: manifest)
        do { _ = try await coordinator(f).open(copyID: copyID, reference: f.bundle.reference, at: now); XCTFail("Corrupt identity cannot be reconstructed") }
        catch { XCTAssertEqual(try Data(contentsOf: manifest), Data("{}".utf8)) }
        try FileManager.default.removeItem(at: manifest)
        do { _ = try await coordinator(f).open(copyID: copyID, reference: f.bundle.reference, at: now); XCTFail("Missing manifest cannot be minted anew") }
        catch { XCTAssertEqual(error as? PantryRecoveryCoordinator.Failure, .missingIdentity) }
        try bytes.write(to: manifest)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(PantryRecoveryCoordinator.databaseFilename))
        do { _ = try await coordinator(f).open(copyID: copyID, reference: f.bundle.reference, at: now); XCTFail("Missing database cannot be recreated") }
        catch { XCTAssertEqual(error as? PantryRecoveryCoordinator.Failure, .missingIdentity) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PantryRecoveryCoordinator.databaseFilename).path))
        try FileManager.default.removeItem(at: folder)
        do { _ = try await coordinator(f).open(copyID: copyID, reference: f.bundle.reference, at: now); XCTFail("A lost materialized directory is not a first open") }
        catch { XCTAssertEqual(error as? PantryRecoveryCoordinator.Failure, .missingIdentity) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testForeignDatabaseProtectedOriginAndCorruptExternalHistoryRejectOpen() async throws {
        let f = try await fixture(), copyID = UUID()
        let opened = try await coordinator(f).create(copyID: copyID, reference: f.bundle.reference, at: now)
        let origin = opened.identity.workspaceID; try await opened.store.close()
        let protected = try PantryRecoveryCoordinator(root: f.root, archives: f.archives, gate: f.gate,
            protectedWorkspaceIDs: { [origin] }, authorize: { _, _ in true })
        do { _ = try await protected.open(copyID: copyID, reference: f.bundle.reference, at: now); XCTFail("Root namespaces cannot become recovered copies") }
        catch { XCTAssertEqual(error as? PantryRecoveryCoordinator.Failure, .invalidIdentity) }
        let database = f.root.appendingPathComponent(copyID.uuidString).appendingPathComponent(PantryRecoveryCoordinator.databaseFilename)
        try FileManager.default.removeItem(at: database)
        let foreign = try ComparisonStore(url: database, inventoryEnabled: true); try await foreign.close()
        do { _ = try await coordinator(f).open(copyID: copyID, reference: f.bundle.reference, at: now); XCTFail("Foreign SQLite cannot satisfy identity") }
        catch { XCTAssertEqual(error as? PantryRecoveryCoordinator.Failure, .invalidIdentity) }
        let chunk = try XCTUnwrap(f.bundle.files.first { $0.name == "pantry-0.json" })
        try Data("{}".utf8).write(to: chunk.url)
        let refusedCopyID = UUID()
        do { _ = try await coordinator(f).create(copyID: refusedCopyID, reference: f.bundle.reference, at: now); XCTFail("Original history must be reverified") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(refusedCopyID.uuidString).path)) }
    }
}
