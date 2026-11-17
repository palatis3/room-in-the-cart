import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

@MainActor final class RecordsPantryToolsModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = Data(repeating: 9, count: 32).base64EncodedString()
    private final class Control {
        var allowed = true
        var dependencyAllowed = true
        var validate: (() async -> Void)?
        var capturing: (() async -> Void)?
        var discarded: (() -> Void)?
        var removed: Set<UUID> = []
        var discardedCaptures: [UUID] = []
        var opened: [UUID] = []
        var independent: PantryArchiveHandle?
    }
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let store: ComparisonStore
        let worker: PantryArchiveWorker
        let registry: RecoveryRegistry
        let handle: PantryArchiveHandle
        let control: Control
        let model: RecordsPantryToolsModel
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self), instant = now
        let store = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(store, ledger)
        let lotID = UUID()
        let command = InventoryCommand(id: UUID(), originID: store.workspaceID, lotID: lotID, eventID: UUID(), expectedRevision: nil,
            occurredAt: now, change: .create(.init(foodID: UUID(), name: "Milk", source: .manual(originID: store.workspaceID, sourceID: lotID),
                location: .fridge, unit: .liter, count: .unknown), observationID: UUID()))
        let token = try await store.inventorySourceToken()
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: command.id, expectedRevision: 0,
            request: Data("fixture activation".utf8), mode: .activate, sourceToken: token,
            writes: PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))), at: now)
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: store.workspaceID, ledgerWorkspaceID: ledger.workspaceID)
        let worker = try PantryArchiveWorker(root: directory.appendingPathComponent("archives"))
        let capture = PantryArchiveCapture(inventory: store, ledger: ledger, pending: pending, gate: PantryMutationGate(), authorize: { _, _ in true })
        let handle = try await capture.captureHandle(worker: worker, at: now)
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("registry.json")), control = Control()
        let model = RecordsPantryToolsModel(worker: worker, registry: registry,
            captureLive: { authorize in
                guard authorize() else { throw ArchiveError.unavailable }
                await control.capturing?()
                return handle
            },
            validateLocalDependencies: { _, authorize in
                await control.validate?()
                guard authorize(), control.dependencyAllowed else { throw ArchiveError.unavailable }
            },
            openRecovered: { copy, authorize in guard authorize() else { throw ArchiveError.unavailable }; control.opened.append(copy.id) },
            captureIndependent: { _, authorize in
                guard authorize(), let handle = control.independent else { throw ArchiveError.unavailable }; return handle
            },
            beginAuthorization: { guard control.allowed else { return nil }; return { control.allowed } },
            willRemove: { control.removed.formUnion($0) },
            discardCapture: { control.discardedCaptures.append($0.reference.bundleID); control.discarded?() }, cleanup: {}, clock: { instant })
        model.recoveryKey = key
        cleanup.track(worker, registry, model)
        return .init(directory: directory, cleanup: cleanup, store: store, worker: worker, registry: registry,
                     handle: handle, control: control, model: model)
    }
    private func reference(_ handle: PantryArchiveHandle) -> PantryRecoveryReference {
        .init(bundleID: handle.reference.bundleID, manifestDigest: handle.reference.manifestDigest,
              originID: handle.descriptor.originID, inventoryRevision: handle.descriptor.inventoryRevision)
    }
    private func saved(_ f: Fixture, copy: RecoveredPantryCopy? = nil, originID: UUID? = nil) async throws -> PantryBackupStatus? {
        try await f.registry.lastPantryBackup(originID: originID ?? f.store.workspaceID, recoveredCopy: copy)
    }
    private func register(_ f: Fixture, handle: PantryArchiveHandle? = nil) async throws -> RecoveredPantryCopy {
        let review = try await f.registry.reviewPantry(reference(handle ?? f.handle))
        return try await f.registry.applyPantry(review, now: now)
    }

    func testOnlyExactFilesCompletionMarksBackupAndAcceptedDismissalDoesNotCancelIt() async throws {
        let f = try await fixture()
        await f.model.prepareExport()
        let picker = try XCTUnwrap(f.model.picker)
        f.model.pickerDidPresent(operationID: picker.id)
        guard case .exportPackage(let source) = picker.mode else { return XCTFail("Expected encrypted export") }
        await f.model.completePicker(operationID: picker.id, outcome: .exported(source))
        XCTAssertEqual(f.model.picker?.id, picker.id, "Only an accepted delegate callback may finish this picker")
        let before = try await saved(f); XCTAssertNil(before)
        f.model.pickerWillComplete(operationID: picker.id)
        await f.model.pickerDidDismiss(operationID: picker.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await f.model.completePicker(operationID: UUID(), outcome: .exported(source))
        let unrelated = try await saved(f); XCTAssertNil(unrelated)
        await f.model.completePicker(operationID: picker.id, outcome: .exported(source))
        let savedBackup = try await saved(f)
        let marked = try XCTUnwrap(savedBackup)
        XCTAssertEqual(f.control.discardedCaptures, [f.handle.reference.bundleID])
        XCTAssertEqual(marked.reference, reference(f.handle))
        XCTAssertEqual(marked.savedAtMilliseconds, ArchiveCodec.milliseconds(now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        await f.model.completePicker(operationID: picker.id, outcome: .exported(source))
        let repeated = try await saved(f); XCTAssertEqual(repeated, marked)
    }

    func testKeyChangeAccessLossAndCancelNeverMarkBackupOrRemoveActiveFilesSourceEarly() async throws {
        for mode in 0..<3 {
            let f = try await fixture()
            await f.model.prepareExport()
            let picker = try XCTUnwrap(f.model.picker)
            f.model.pickerDidPresent(operationID: picker.id)
            guard case .exportPackage(let source) = picker.mode else { return XCTFail("Expected encrypted export") }
            if mode == 0 { f.model.recoveryKey = Data(repeating: 2, count: 32).base64EncodedString() }
            if mode == 1 { f.control.allowed = false; f.model.invalidate() }
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Files still owns a read of its source")
            f.model.pickerWillComplete(operationID: picker.id)
            await f.model.pickerDidDismiss(operationID: picker.id)
            await f.model.completePicker(operationID: picker.id, outcome: mode == 2 ? .cancelled : .exported(source))
            XCTAssertEqual(f.control.discardedCaptures, [f.handle.reference.bundleID])
            let mark = try await saved(f); XCTAssertNil(mark)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testRevokedCaptureAndUnmountedPickerRetireTheirPrivateFiles() async throws {
        for revokeDuringCapture in [true, false] {
            let f = try await fixture()
            let discarded = expectation(description: "Release the unique export capture")
            f.control.discarded = { discarded.fulfill() }
            var stagedURL: URL?
            if revokeDuringCapture {
                let started = expectation(description: "Capture suspended")
                var resume: CheckedContinuation<Void, Never>?
                f.control.capturing = { await withCheckedContinuation { resume = $0; started.fulfill() } }
                let work = Task { await f.model.prepareExport() }
                await fulfillment(of: [started], timeout: 2)
                f.model.invalidate()
                resume?.resume()
                await work.value
            } else {
                await f.model.prepareExport()
                guard case .exportPackage(let url) = f.model.picker?.mode else { return XCTFail("Expected staged export") }
                stagedURL = url
                f.model.invalidate() // SwiftUI has not mounted a picker or scheduled its dismissal.
            }
            await fulfillment(of: [discarded], timeout: 2)
            XCTAssertEqual(f.control.discardedCaptures, [f.handle.reference.bundleID])
            XCTAssertNil(f.model.picker)
            if let stagedURL { XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path)) }
            let mark = try await saved(f)
            XCTAssertNil(mark)
        }
    }

    func testVerifiedImportRequiresExplicitApplyAndDependencyCheckAgain() async throws {
        let f = try await fixture(), package = try await f.worker.encryptedExport(f.handle, key: key)
        f.model.beginImport()
        let id = try XCTUnwrap(f.model.picker?.id)
        f.model.pickerDidPresent(operationID: id)
        f.model.pickerWillComplete(operationID: id)
        await f.model.completePicker(operationID: id, outcome: .selectedForImport(package.url))
        XCTAssertEqual(f.model.importReview?.handle.lotCount, 1)
        let before = try await f.registry.listPantry(); XCTAssertTrue(before.isEmpty)
        f.control.dependencyAllowed = false
        await f.model.applyImport()
        let denied = try await f.registry.listPantry(); XCTAssertTrue(denied.isEmpty)
        XCTAssertNil(f.model.importReview)
        try await f.model.invalidateAndDrain()
        f.control.dependencyAllowed = true
        f.model.recoveryKey = key
        f.model.beginImport()
        let retry = try XCTUnwrap(f.model.picker?.id)
        f.model.pickerDidPresent(operationID: retry)
        f.model.pickerWillComplete(operationID: retry)
        await f.model.completePicker(operationID: retry, outcome: .selectedForImport(package.url))
        await f.model.applyImport()
        XCTAssertNil(f.model.error)
        XCTAssertEqual(f.model.copies.count, 1)
        XCTAssertNil(f.model.importReview)
        await f.model.applyImport()
        XCTAssertTrue(f.control.discardedCaptures.isEmpty, "Imported packages do not belong to the transient capture cleanup")
        let after = try await f.registry.listPantry(); XCTAssertEqual(after.count, 1)
        let state = try await f.store.inventoryState(); XCTAssertEqual(state.revision, 1)
        try await f.worker.discardExport(package)
    }

    func testInvalidationDuringDependencyAwaitCannotPublishOrApplyAnImport() async throws {
        let f = try await fixture(), package = try await f.worker.encryptedExport(f.handle, key: key)
        let started = expectation(description: "Dependency validation suspended")
        var resume: CheckedContinuation<Void, Never>?
        f.control.validate = { await withCheckedContinuation { resume = $0; started.fulfill() } }
        f.model.beginImport()
        let id = try XCTUnwrap(f.model.picker?.id)
        f.model.pickerDidPresent(operationID: id)
        f.model.pickerWillComplete(operationID: id)
        let work = Task { await f.model.completePicker(operationID: id, outcome: .selectedForImport(package.url)) }
        await fulfillment(of: [started], timeout: 2)
        f.model.invalidate(); resume?.resume()
        await work.value
        XCTAssertNil(f.model.importReview); XCTAssertTrue(f.model.copies.isEmpty)
        XCTAssertNil(f.model.status); XCTAssertNil(f.model.error)
        await f.model.applyImport()
        let copies = try await f.registry.listPantry(); XCTAssertTrue(copies.isEmpty)
        try await f.worker.discardExport(package)
    }

    func testReviewedCopyDeletionInvalidatesOnlySelectedCopyNotItsOriginOrSibling() async throws {
        let f = try await fixture(), first = try await register(f)
        // A second real verified bundle has the same pantry origin and a distinct bundle identity.
        let snapshot = try await f.store.inventoryState()
        XCTAssertEqual(snapshot.revision, f.handle.descriptor.inventoryRevision)
        let ledger = try LedgerStore(url: f.directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(ledger)
        let pending = try PantryPickupPendingStore(directory: f.directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: f.store.workspaceID, ledgerWorkspaceID: ledger.workspaceID)
        let capture = PantryArchiveCapture(inventory: f.store, ledger: ledger, pending: pending, gate: PantryMutationGate(), authorize: { _, _ in true })
        let siblingHandle = try await capture.captureHandle(worker: f.worker, at: now)
        let sibling = try await register(f, handle: siblingHandle)
        await f.model.reload()
        await f.model.reviewDeletion(first)
        XCTAssertEqual(f.model.deletionReview?.copies.map(\.id), [first.id])
        await f.model.applyDeletion()
        XCTAssertEqual(f.control.removed, [first.id])
        let remaining = try await f.registry.listPantry(); XCTAssertEqual(remaining.map(\.id), [sibling.id])
        let removed = try await f.registry.reviewPantry(first.reference)
        let retained = try await f.registry.reviewPantry(sibling.reference)
        XCTAssertEqual(removed.disposition, .erased); XCTAssertTrue(retained.canApply)
        let current = try await f.store.inventoryState(); XCTAssertEqual(current.revision, snapshot.revision)
    }

    func testEditedIndependentCopyExportUsesItsActualOriginAndCountRevision() async throws {
        let f = try await fixture(), copy = try await register(f)
        let start = try await f.registry.beginPantryMaterialization(copy), gate = PantryMutationGate()
        let coordinator = try PantryRecoveryCoordinator(root: f.directory.appendingPathComponent("copies"), worker: f.worker,
            gate: gate, protectedWorkspaceIDs: { [f.store.workspaceID] }, authorize: { _, _ in true })
        let opened = try await coordinator.create(copyID: copy.id, reference: f.handle.reference, at: now)
        f.cleanup.track(opened.store)
        let ready = try await f.registry.finishPantryMaterialization(start.copy, workspaceID: opened.store.workspaceID)
        let repository = PantryRepository(store: opened.store, mutationGate: gate, authorize: { true })
        f.cleanup.track(repository)
        let before = try await repository.load(at: now), lot = try XCTUnwrap(before.lots.first)
        _ = try await repository.apply(.init(id: UUID(), originID: opened.store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .count(.someLeft, observationID: UUID())),
            reviewedInventoryRevision: before.state.revision, at: now)
        let independent = try await PantryArchiveCapture.captureIndependent(worker: f.worker, inventory: opened.store,
            original: f.handle, identity: opened.identity, journalDirectory: f.directory.appendingPathComponent("copy-pending"),
            gate: gate, at: now, authorize: {})
        f.control.independent = independent
        await f.model.prepareExport(copy: ready)
        let picker = try XCTUnwrap(f.model.picker)
        f.model.pickerDidPresent(operationID: picker.id)
        guard case .exportPackage(let url) = picker.mode else { return XCTFail("Expected independent export") }
        f.model.pickerWillComplete(operationID: picker.id)
        await f.model.completePicker(operationID: picker.id, outcome: .exported(url))
        let marked = try await saved(f, copy: ready, originID: opened.store.workspaceID)
        XCTAssertEqual(marked?.reference, reference(independent))
        XCTAssertNotEqual(marked?.reference.originID, f.store.workspaceID)
        XCTAssertEqual(marked?.reference.inventoryRevision, before.state.revision + 1)
    }
}
